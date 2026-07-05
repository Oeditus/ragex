defmodule Ragex.MCP.Server do
  @moduledoc """
  MCP Server implementation that communicates via stdio.

  Reads JSON-RPC messages from stdin, processes them, and writes responses to stdout.
  """

  use GenServer
  require Logger

  alias Ragex.MCP.Formatter
  alias Ragex.MCP.Handlers.{Prompts, Resources, Tools}
  alias Ragex.MCP.Protocol
  alias Ragex.MCP.Telemetry, as: MCPTelemetry

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

  @doc """
  Send a notification to the client.

  Notifications are one-way messages with no response expected.
  """
  def send_notification(method, params \\ nil) do
    GenServer.cast(__MODULE__, {:send_notification, method, params})
  end

  @doc """
  Stream a partial content chunk to the client during a long-running tool call.

  Emits a `notifications/progress` message carrying the partial text so clients
  can display incremental output before the final `tools/call` response arrives.

  - `request_id` — the JSON-RPC `id` of the originating `tools/call` request
  - `partial`    — the new chunk of text to append to any previous output
  - `done`       — set to `true` on the final chunk (default `false`)
  """
  @spec send_progress(term(), String.t(), boolean()) :: :ok
  def send_progress(request_id, partial, done \\ false) do
    GenServer.cast(__MODULE__, {:send_progress, request_id, partial, done})
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
        version:
          case Application.spec(:ragex, :vsn) do
            nil -> "0.10.0"
            vsn -> to_string(vsn)
          end
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

  @impl true
  def handle_cast({:send_notification, method, params}, state) do
    notification = Protocol.notification(method, params)
    send_response(notification)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send_progress, request_id, partial, done}, state) do
    notification =
      Protocol.notification("notifications/progress", %{
        progressToken: request_id,
        value: %{type: "text", text: partial, done: done}
      })

    send_response(notification)
    {:noreply, state}
  end

  # Private functions

  defp read_stdin do
    case IO.read(:stdio, :line) do
      :eof ->
        Logger.info("Received EOF on stdin")

        # Only halt if socket server is NOT running (pure stdio mode)
        if Application.get_env(:ragex, :start_server, true) do
          Logger.info("Socket server is running, stdin reader stopping gracefully")
        else
          Logger.info("No socket server, shutting down")
          System.halt(0)
        end

      {:error, reason} ->
        Logger.warning("Error reading stdin: #{inspect(reason)}, stdin reader stopping")

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

    # Streaming tools return nil and send their response asynchronously via handle_info
    if response != nil do
      send_response(response)
    end

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

  @impl true
  def handle_info({:send_response_async, response}, state) do
    send_response(response)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_initialize(params, id, state) do
    Logger.info("Initializing with client: #{inspect(params)}")

    result = %{
      protocolVersion: "2024-11-05",
      serverInfo: state.server_info,
      capabilities: %{
        tools: %{},
        resources: %{},
        prompts: %{},
        # Signal that this server emits notifications/progress during streaming tool calls
        notifications: %{progress: true}
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
    format_opts = Formatter.extract_opts(arguments)

    if streaming_tool?(tool_name) do
      # Run streaming tool asynchronously; each chunk is pushed via notifications/progress
      # before the final tools/call response is sent.
      server = self()

      progress_fn = fn partial, done ->
        send_progress(id, partial, done)
      end

      Task.start(fn ->
        result =
          MCPTelemetry.execute(tool_name, fn ->
            Tools.call_tool_streaming(tool_name, arguments, progress_fn)
          end)

        response =
          case result do
            {:ok, r} ->
              formatted = Formatter.format(r, tool_name, format_opts)
              json_safe = result_to_json(formatted)
              text = :json.encode(json_safe) |> IO.iodata_to_binary()
              Protocol.success_response(%{content: [%{type: "text", text: text}]}, id)

            {:error, reason} ->
              Protocol.internal_error(reason, id)
          end

        send(server, {:send_response_async, response})
      end)

      # Return nil to skip the synchronous send_response — the Task handles it
      nil
    else
      case MCPTelemetry.execute(tool_name, fn -> Tools.call_tool(tool_name, arguments) end) do
        {:ok, result} ->
          formatted = Formatter.format(result, tool_name, format_opts)
          json_safe_result = result_to_json(formatted)
          text = :json.encode(json_safe_result) |> IO.iodata_to_binary()
          Protocol.success_response(%{content: [%{type: "text", text: text}]}, id)

        {:error, reason} ->
          Protocol.internal_error(reason, id)
      end
    end
  end

  defp streaming_tool?(name), do: String.ends_with?(name || "", "_stream")

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
  defp result_to_json(value) when is_tuple(value), do: inspect(value)
  defp result_to_json(value) when is_list(value), do: Enum.map(value, &result_to_json/1)

  defp result_to_json(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, result_to_json(v)} end)
  end

  defp result_to_json(value), do: value

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
