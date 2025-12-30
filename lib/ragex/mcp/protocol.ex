defmodule Ragex.MCP.Protocol do
  @moduledoc """
  Implements the Model Context Protocol (MCP) JSON-RPC 2.0 protocol.

  Handles encoding/decoding of MCP messages and protocol-level validation.
  """

  @type method :: String.t()
  @type params :: map() | list() | nil
  @type id :: String.t() | integer() | nil

  @type request :: %{
          jsonrpc: String.t(),
          method: method(),
          params: params(),
          id: id()
        }

  @type response :: %{
          jsonrpc: String.t(),
          result: any(),
          id: id()
        }

  @type error_response :: %{
          jsonrpc: String.t(),
          error: %{
            code: integer(),
            message: String.t(),
            data: any()
          },
          id: id()
        }

  @type notification :: %{
          jsonrpc: String.t(),
          method: method(),
          params: params()
        }

  # JSON-RPC error codes
  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  @doc """
  Decodes a JSON-RPC message from a string.
  """
  @spec decode(String.t()) :: {:ok, request() | notification()} | {:error, term()}
  def decode(json_string) do
    case Jason.decode(json_string) do
      {:ok, %{"jsonrpc" => "2.0"} = message} ->
        {:ok, message}

      {:ok, _} ->
        {:error, :invalid_jsonrpc_version}

      {:error, reason} ->
        {:error, {:parse_error, reason}}
    end
  end

  @doc """
  Encodes a response to JSON string.
  """
  @spec encode(response() | error_response() | notification()) ::
          {:ok, String.t()} | {:error, term()}
  def encode(message) do
    Jason.encode(message)
  end

  @doc """
  Creates a successful response message.
  """
  @spec success_response(any(), id()) :: response()
  def success_response(result, id) do
    %{
      jsonrpc: "2.0",
      result: result,
      id: id
    }
  end

  @doc """
  Creates an error response message.
  """
  @spec error_response(integer(), String.t(), any(), id()) :: error_response()
  def error_response(code, message, data \\ nil, id) do
    error = %{
      code: code,
      message: message
    }

    error = if data, do: Map.put(error, :data, data), else: error

    %{
      jsonrpc: "2.0",
      error: error,
      id: id
    }
  end

  @doc """
  Creates a notification message.
  """
  @spec notification(method(), params()) :: notification()
  def notification(method, params \\ nil) do
    message = %{
      jsonrpc: "2.0",
      method: method
    }

    if params, do: Map.put(message, :params, params), else: message
  end

  @doc """
  Standard error codes and helpers.
  """
  def parse_error(id), do: error_response(@parse_error, "Parse error", nil, id)
  def invalid_request(id), do: error_response(@invalid_request, "Invalid request", nil, id)

  def method_not_found(method, id),
    do: error_response(@method_not_found, "Method not found: #{method}", nil, id)

  def invalid_params(message, id),
    do: error_response(@invalid_params, "Invalid params: #{message}", nil, id)

  def internal_error(message, id),
    do: error_response(@internal_error, "Internal error: #{message}", nil, id)

  @doc """
  Validates if a message is a request (has an id).
  """
  @spec request?(map()) :: boolean()
  def request?(%{"id" => _}), do: true
  def request?(_), do: false

  @doc """
  Validates if a message is a notification (no id).
  """
  @spec notification?(map()) :: boolean()
  def notification?(message), do: not request?(message)
end
