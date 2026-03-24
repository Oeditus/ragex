defmodule Ragex.MCP.SocketServer do
  @moduledoc """
  Unix socket server for MCP protocol.

  Allows multiple clients to connect to a persistent server instance.
  Each connection handles requests independently.

  Uses the :gen_tcp module with inet_af_local for Unix domain socket support.
  """

  use GenServer
  require Logger

  alias Ragex.MCP.Handlers.{Prompts, Resources, Tools}
  alias Ragex.MCP.Protocol

  @socket_path ~c"/tmp/ragex_mcp.sock"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Remove existing socket file (use charlist path)
    case File.rm(to_string(@socket_path)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("Could not remove socket file: #{inspect(reason)}")
    end

    # Create Unix domain socket using gen_tcp with local address family
    # The key is using ip: {:local, charlist_path}
    listen_opts = [
      :binary,
      {:active, false},
      {:reuseaddr, true},
      {:ip, {:local, @socket_path}}
    ]

    case :gen_tcp.listen(0, listen_opts) do
      {:ok, listen_socket} ->
        Logger.info("MCP Socket Server listening on #{@socket_path}")

        # Verify socket file was created
        if File.exists?(to_string(@socket_path)) do
          Logger.info("Socket file verified: #{@socket_path}")
        else
          Logger.error("Socket file not created!")
        end

        # Start accept loop with better error handling
        pid = spawn_link(fn -> accept_loop(listen_socket) end)
        Logger.info("Accept loop started with PID: #{inspect(pid)}")

        {:ok, %{socket: listen_socket, acceptor: pid}}

      {:error, reason} ->
        Logger.error("Failed to create Unix socket: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{socket: socket}) do
    :gen_tcp.close(socket)
    File.rm(to_string(@socket_path))
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp accept_loop(listen_socket) do
    # This log should appear immediately when loop starts
    Logger.info("[ACCEPT LOOP] Starting, socket: #{inspect(listen_socket)}")

    try do
      Logger.info("[ACCEPT LOOP] About to call :gen_tcp.accept...")

      # Accept without timeout now that we removed {:packet, :line}
      case :gen_tcp.accept(listen_socket) do
        {:ok, client_socket} ->
          # Write directly to file for debugging
          File.write!(
            "/tmp/ragex_debug.log",
            "#{:os.system_time(:millisecond)} CLIENT CONNECTED\n",
            [:append]
          )

          Logger.info("Client connected: #{inspect(client_socket)}")

          spawn(fn ->
            Logger.info("[HANDLER] Starting client handler")
            handle_client(client_socket)
          end)

          accept_loop(listen_socket)

        {:error, :closed} ->
          Logger.info("Listen socket closed, stopping accept loop")

        {:error, reason} ->
          Logger.error("Accept failed: #{inspect(reason)}")
          # Wait a bit before retrying to avoid busy loop
          Process.sleep(100)
          accept_loop(listen_socket)
      end
    catch
      kind, reason ->
        Logger.error("Accept loop crashed: #{kind} - #{inspect(reason)}")
        Logger.error("Stacktrace: #{inspect(__STACKTRACE__)}")
        # Wait before retrying
        Process.sleep(1000)
        accept_loop(listen_socket)
    end
  end

  defp handle_client(socket) do
    Logger.info("[HANDLER] Waiting for data on #{inspect(socket)}...")

    File.write!("/tmp/ragex_debug.log", "#{:os.system_time(:millisecond)} HANDLER WAITING\n", [
      :append
    ])

    # Since we removed {:packet, :line}, we need to read until newline manually
    # Read all available data (0 means read what's available)
    recv_result = :gen_tcp.recv(socket, 0, 30_000)

    File.write!(
      "/tmp/ragex_debug.log",
      "#{:os.system_time(:millisecond)} RECV RESULT: #{inspect(recv_result)}\n",
      [:append]
    )

    case recv_result do
      {:ok, data} ->
        Logger.info("[HANDLER] Received data: #{inspect(data)}")
        # Split by newlines and process each line
        lines = String.split(data, "\n", trim: true)

        Enum.each(lines, fn line ->
          process_line(socket, String.trim(line))
        end)

        # Continue handling
        handle_client(socket)

      {:error, :closed} ->
        Logger.debug("Client disconnected")
        :gen_tcp.close(socket)

      {:error, :timeout} ->
        Logger.debug("Client connection timeout")
        :gen_tcp.close(socket)

      {:error, reason} ->
        Logger.error("Recv failed: #{inspect(reason)}")
        :gen_tcp.close(socket)
    end
  end

  defp process_line(socket, line) do
    unless line == "" do
      case Protocol.decode(line) do
        {:ok, message} ->
          Logger.info("[HANDLER] Processing message: #{inspect(Map.get(message, "method"))}")
          response = process_message(message)
          Logger.info("[HANDLER] Generated response for ID: #{inspect(response.id)}")

          case Protocol.encode(response) do
            {:ok, json} ->
              Logger.info("[HANDLER] Sending response (#{byte_size(json)} bytes)...")

              case :gen_tcp.send(socket, json <> "\n") do
                :ok ->
                  Logger.info("[HANDLER] Response sent successfully")

                {:error, reason} ->
                  Logger.error("[HANDLER] Failed to send response: #{inspect(reason)}")
              end

            {:error, reason} ->
              Logger.error("Failed to encode response: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.error("Failed to decode message: #{inspect(reason)}")
          error = Protocol.parse_error(nil)

          case Protocol.encode(error) do
            {:ok, json} -> :gen_tcp.send(socket, json <> "\n")
            _ -> :ok
          end
      end
    end
  end

  defp process_message(%{"method" => method} = message) do
    id = Map.get(message, "id")
    params = Map.get(message, "params", %{})

    case method do
      "initialize" ->
        handle_initialize(params, id)

      "tools/list" ->
        handle_tools_list(id)

      "tools/call" ->
        handle_tools_call(params, id)

      "resources/list" ->
        handle_resources_list(id)

      "resources/read" ->
        handle_resources_read(params, id)

      "prompts/list" ->
        handle_prompts_list(id)

      "prompts/get" ->
        handle_prompts_get(params, id)

      "ping" ->
        Protocol.success_response(%{}, id)

      _ ->
        Protocol.method_not_found(method, id)
    end
  end

  defp process_message(_message) do
    Protocol.invalid_request(nil)
  end

  defp handle_initialize(_params, id) do
    result = %{
      protocolVersion: "2024-11-05",
      serverInfo: %{
        name: "ragex",
        version: "0.2.0"
      },
      capabilities: %{
        tools: %{},
        resources: %{},
        prompts: %{}
      }
    }

    Protocol.success_response(result, id)
  end

  defp handle_tools_list(id) do
    result = Tools.list_tools()
    Protocol.success_response(result, id)
  end

  defp handle_tools_call(params, id) do
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    Logger.info("[HANDLER] Calling tool: #{tool_name} with id: #{inspect(id)}")

    case Tools.call_tool(tool_name, arguments) do
      {:ok, result} ->
        Logger.info("[HANDLER] Tool returned: #{inspect(result) |> String.slice(0, 200)}")

        # Convert result to JSON-safe format (handling tuples, etc.)
        json_safe_result = result_to_json(result)
        text = :json.encode(json_safe_result) |> IO.iodata_to_binary()

        formatted = %{
          content: [
            %{
              type: "text",
              text: text
            }
          ]
        }

        response = Protocol.success_response(formatted, id)
        Logger.info("[HANDLER] Response prepared with id: #{inspect(response.id)}")
        response

      {:error, reason} ->
        Logger.error("[HANDLER] Tool error: #{inspect(reason)}")
        Protocol.internal_error(inspect(reason), id)
    end
  end

  defp handle_resources_list(id) do
    result = Resources.list_resources()
    Protocol.success_response(result, id)
  end

  defp handle_resources_read(params, id) do
    uri = Map.get(params, "uri")

    case Resources.read_resource(uri) do
      {:ok, contents} ->
        # Convert contents to JSON and wrap in MCP resource format
        json_text = :json.encode(contents) |> IO.iodata_to_binary()

        Protocol.success_response(
          %{
            contents: [
              %{
                uri: uri,
                mimeType: "application/json",
                text: json_text
              }
            ]
          },
          id
        )

      {:error, reason} ->
        Protocol.internal_error(reason, id)
    end
  end

  defp handle_prompts_list(id) do
    result = Prompts.list_prompts()
    Protocol.success_response(result, id)
  end

  defp handle_prompts_get(params, id) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    case Prompts.get_prompt(name, arguments) do
      {:ok, prompt} ->
        Protocol.success_response(prompt, id)

      {:error, reason} ->
        Protocol.internal_error(reason, id)
    end
  end

  # Convert Elixir terms to JSON-safe format
  # Tuples are converted to strings since JSON doesn't support them
  defp result_to_json(value) when is_tuple(value) do
    inspect(value)
  end

  defp result_to_json(value) when is_list(value) do
    Enum.map(value, &result_to_json/1)
  end

  defp result_to_json(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, result_to_json(v)} end)
  end

  defp result_to_json(value), do: value
end
