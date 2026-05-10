defmodule Ragex.MCP.Client do
  @moduledoc """
  Client for communicating with a running Ragex MCP server via Unix socket.

  Allows mix tasks and other callers to delegate work to an already-running
  Ragex instance instead of starting a new BEAM VM (which would try to
  allocate GPU memory for Bumblebee a second time).

  ## Usage

      if Ragex.MCP.Client.server_running?() do
        {:ok, conn} = Ragex.MCP.Client.connect()
        {:ok, result} = Ragex.MCP.Client.call_tool(conn, "analyze_directory", %{"path" => "."})
        Ragex.MCP.Client.disconnect(conn)
      end
  """

  @socket_path ~c"/tmp/ragex_mcp.sock"
  @connect_timeout 3_000
  @recv_timeout 300_000

  defstruct [:socket, request_id: 1]

  @type t :: %__MODULE__{socket: :gen_tcp.socket(), request_id: non_neg_integer()}

  @doc """
  Returns true if a Ragex MCP server is reachable on the Unix socket.

  Sends a `ping` request and checks for a valid response.
  """
  @spec server_running?() :: boolean()
  def server_running? do
    case connect() do
      {:ok, conn} ->
        result = ping(conn)
        disconnect(conn)
        match?({:ok, _}, result)

      {:error, _} ->
        false
    end
  end

  @doc """
  Opens a connection to the Ragex MCP socket server.

  Returns `{:ok, conn}` or `{:error, reason}`.
  """
  @spec connect() :: {:ok, t()} | {:error, term()}
  def connect do
    # NOTE: {:ip, {:local, path}} is for listen (server), NOT connect (client).
    # The destination is passed as the first arg to :gen_tcp.connect.
    opts = [:binary, {:active, false}]

    case :gen_tcp.connect({:local, @socket_path}, 0, opts, @connect_timeout) do
      {:ok, socket} ->
        conn = %__MODULE__{socket: socket}
        # Send initialize handshake
        case initialize(conn) do
          {:ok, conn} ->
            {:ok, conn}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Calls an MCP tool on the remote server.

  Returns `{:ok, result}` where result is the decoded JSON response,
  or `{:error, reason}`.
  """
  @spec call_tool(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(%__MODULE__{} = conn, tool_name, arguments \\ %{}) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => conn.request_id,
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => arguments
      }
    }

    case send_and_receive(conn, request) do
      {:ok, %{"result" => result}} ->
        # MCP wraps tool results in content array
        parsed = extract_tool_result(result)
        {:ok, parsed}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends a ping to the server. Returns `{:ok, response}` or `{:error, reason}`.
  """
  @spec ping(t()) :: {:ok, map()} | {:error, term()}
  def ping(%__MODULE__{} = conn) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => conn.request_id,
      "method" => "ping",
      "params" => %{}
    }

    send_and_receive(conn, request)
  end

  @doc """
  Closes the connection to the server.
  """
  @spec disconnect(t()) :: :ok
  def disconnect(%__MODULE__{socket: socket}) do
    :gen_tcp.close(socket)
    :ok
  end

  # Private functions

  defp initialize(conn) do
    request = %{
      "jsonrpc" => "2.0",
      "id" => conn.request_id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "clientInfo" => %{
          "name" => "ragex-client",
          "version" => "1.0.0"
        },
        "capabilities" => %{}
      }
    }

    case send_and_receive(conn, request) do
      {:ok, %{"result" => _}} ->
        {:ok, %{conn | request_id: conn.request_id + 1}}

      {:ok, %{"error" => error}} ->
        {:error, {:initialize_failed, error}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_and_receive(conn, request) do
    json = :json.encode(request) |> IO.iodata_to_binary()

    case :gen_tcp.send(conn.socket, json <> "\n") do
      :ok ->
        receive_response(conn)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_response(conn) do
    # Read until we get a complete JSON line
    receive_line(conn, <<>>)
  end

  defp receive_line(conn, buffer) do
    case :gen_tcp.recv(conn.socket, 0, @recv_timeout) do
      {:ok, data} ->
        combined = buffer <> data
        # Split on newlines - the response is a single JSON line
        case String.split(combined, "\n", parts: 2) do
          [line, _rest] when line != "" ->
            decode_response(line)

          _ ->
            # Haven't received a complete line yet, keep reading
            receive_line(conn, combined)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_response(line) do
    case Jason.decode(line) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, {:decode_error, reason}}
    end
  end

  defp extract_tool_result(%{"content" => [%{"type" => "text", "text" => text} | _]}) do
    case Jason.decode(text) do
      {:ok, parsed} -> parsed
      {:error, _} -> text
    end
  end

  defp extract_tool_result(other), do: other
end
