defmodule Ragex.MCP.Server do
  @moduledoc """
  MCP Server implementation that communicates via stdio.

  Reads JSON-RPC messages from stdin, processes them, and writes responses to stdout.
  """

  use GenServer
  require Logger

  alias Ragex.MCP.Protocol
  alias Ragex.MCP.Handlers.Tools

  defmodule State do
    @moduledoc false
    defstruct [
      :initialized,
      :server_info,
      :client_info
    ]
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Start reading from stdin in a separate process, unless disabled for tests
    if Application.get_env(:ragex, :start_server, true) do
      spawn_link(fn -> read_stdin() end)
    end

    state = %State{
      initialized: false,
      server_info: %{
        name: "ragex",
        version: "0.1.0"
      }
    }

    Logger.info("MCP Server started")
    {:ok, state}
  end

  @impl true
  def handle_cast({:process_message, line}, state) do
    case Protocol.decode(line) do
      {:ok, message} ->
        new_state = handle_message(message, state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to decode message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # Private functions

  defp read_stdin do
    case IO.read(:stdio, :line) do
      :eof ->
        Logger.info("Received EOF, shutting down")
        System.halt(0)

      {:error, reason} ->
        Logger.error("Error reading stdin: #{inspect(reason)}")
        System.halt(1)

      line when is_binary(line) ->
        line = String.trim(line)

        unless line == "" do
          GenServer.cast(__MODULE__, {:process_message, line})
        end

        read_stdin()
    end
  end

  defp handle_message(%{"method" => method} = message, state) do
    id = Map.get(message, "id")
    params = Map.get(message, "params", %{})

    response =
      case method do
        "initialize" ->
          handle_initialize(params, id, state)

        "tools/list" ->
          handle_tools_list(id)

        "tools/call" ->
          handle_tools_call(params, id)

        "ping" ->
          Protocol.success_response(%{}, id)

        _ ->
          Protocol.method_not_found(method, id)
      end

    send_response(response)

    # Update state if this was an initialize call
    case method do
      "initialize" -> %{state | initialized: true, client_info: params}
      _ -> state
    end
  end

  defp handle_message(message, state) do
    Logger.warning("Received invalid message: #{inspect(message)}")
    id = Map.get(message, "id")

    if id do
      send_response(Protocol.invalid_request(id))
    end

    state
  end

  defp handle_initialize(params, id, state) do
    Logger.info("Initializing with client: #{inspect(params)}")

    result = %{
      protocolVersion: "2024-11-05",
      serverInfo: state.server_info,
      capabilities: %{
        tools: %{}
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

    case Tools.call_tool(tool_name, arguments) do
      {:ok, result} ->
        Protocol.success_response(%{content: [%{type: "text", text: Jason.encode!(result)}]}, id)

      {:error, reason} ->
        Protocol.internal_error(reason, id)
    end
  end

  defp send_response(response) do
    case Protocol.encode(response) do
      {:ok, json} ->
        IO.puts(json)
        :ok

      {:error, reason} ->
        Logger.error("Failed to encode response: #{inspect(reason)}")
        :error
    end
  end
end
