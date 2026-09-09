defmodule Ragex.MCP.Debug do
  @moduledoc """
  Helper functions for debugging MCP protocol issues.

  Usage in IEx:

      iex> Ragex.MCP.Debug.test_initialize()
      iex> Ragex.MCP.Debug.test_tools_list()
      iex> Ragex.MCP.Debug.test_analyze()
  """

  alias Ragex.MCP.{Handlers.Tools, Protocol}
  require Logger

  @doc """
  Test the initialize handshake.
  """
  @spec test_initialize() :: {:ok, map()} | {:error, term()}
  def test_initialize do
    message = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "clientInfo" => %{
          "name" => "debug-client",
          "version" => "1.0.0"
        }
      }
    }

    Logger.info("Testing initialize...")
    test_message(message)
  end

  @doc """
  Test listing tools.
  """
  @spec test_tools_list() :: {:ok, map()} | {:error, term()}
  def test_tools_list do
    message = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/list",
      "params" => %{}
    }

    Logger.info("Testing tools/list...")
    test_message(message)
  end

  @doc """
  Test analyzing a directory.
  """
  @spec test_analyze(String.t()) :: {:ok, map()} | {:error, term()}
  def test_analyze(path \\ ".") do
    message = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "tools/call",
      "params" => %{
        "name" => "analyze_directory",
        "arguments" => %{
          "path" => path
        }
      }
    }

    Logger.info("Testing analyze_directory...")
    test_message(message)
  end

  @doc """
  Test a raw message and show the response.
  """
  @spec test_message(map()) :: {:ok, map()} | {:error, term()}
  def test_message(message) when is_map(message) do
    # Encode the message
    {:ok, json_request} = Jason.encode(message)
    Logger.debug("Request: #{json_request}")

    # Decode it (simulating stdin)
    {:ok, decoded} = Protocol.decode(json_request)
    Logger.debug("Decoded: #{inspect(decoded)}")

    # Process it
    response = process_message(decoded)
    Logger.debug("Response map: #{inspect(response)}")

    # Encode response
    case Protocol.encode(response) do
      {:ok, json_response} ->
        Logger.info("✓ Response: #{json_response}")
        {:ok, Jason.decode!(json_response)}

      {:error, reason} ->
        Logger.error("✗ Encoding failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Process a decoded message (simulating Server.handle_message).
  """
  @spec process_message(map()) :: map()
  def process_message(%{"method" => method} = message) do
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

  defp handle_initialize(params, id) do
    Logger.debug("Initialize params: #{inspect(params)}")

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
    Logger.debug("Tools list: #{inspect(result)}")
    Protocol.success_response(result, id)
  end

  defp handle_tools_call(params, id) do
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})

    Logger.debug("Calling tool: #{tool_name} with #{inspect(arguments)}")

    case Tools.call_tool(tool_name, arguments) do
      {:ok, result} ->
        # Format according to MCP spec
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
        Logger.error("Tool error: #{inspect(reason)}")
        Protocol.internal_error(inspect(reason), id)
    end
  end

  @doc """
  Start IEx with helpful context.
  """
  @spec help() :: :ok
  def help do
    IO.puts("""

    === Ragex MCP Debug Helper ===

    Available functions:

      Ragex.MCP.Debug.test_initialize()
      - Test the MCP initialize handshake
      
      Ragex.MCP.Debug.test_tools_list()
      - Test listing available tools
      
      Ragex.MCP.Debug.test_analyze("/path/to/code")
      - Test analyzing a directory
      
      Ragex.MCP.Debug.test_message(%{...})
      - Test a raw JSON-RPC message

    The server should be running in the background.
    Check logs with: Logger.configure(level: :debug)

    """)
  end
end
