defmodule Ragex.MCP.SingleRequest do
  @moduledoc """
  Handles a single MCP request from stdin and exits.

  This is for clients that start a new process per request (like LunarVim)
  instead of maintaining a persistent connection.

  Usage:
      echo '{"jsonrpc":"2.0","id":1,"method":"tools/call",...}' | mix run -e 'Ragex.MCP.SingleRequest.handle()'
  """

  alias Ragex.MCP.{Handlers.Tools, Protocol}
  require Logger

  @doc """
  Read one request from stdin, process it, write response to stdout, and exit.
  """
  def handle do
    # Ensure the application is started
    {:ok, _} = Application.ensure_all_started(:ragex)

    # Read the entire stdin
    request = IO.read(:stdio, :eof)

    case Protocol.decode(request) do
      {:ok, message} ->
        response = process_message(message)

        case Protocol.encode(response) do
          {:ok, json} ->
            IO.puts(json)
            System.halt(0)

          {:error, reason} ->
            Logger.error("Failed to encode response: #{inspect(reason)}")
            System.halt(1)
        end

      {:error, reason} ->
        Logger.error("Failed to decode request: #{inspect(reason)}")
        error = Protocol.parse_error(nil)

        case Protocol.encode(error) do
          {:ok, json} -> IO.puts(json)
          _ -> :ok
        end

        System.halt(1)
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
        formatted = %{
          content: [
            %{
              type: "text",
              text: Jason.encode!(result)
            }
          ]
        }

        Protocol.success_response(formatted, id)

      {:error, reason} ->
        Protocol.internal_error(inspect(reason), id)
    end
  end
end
