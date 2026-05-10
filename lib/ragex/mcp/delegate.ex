defmodule Ragex.MCP.Delegate do
  @moduledoc """
  Helper for Mix tasks to delegate work to a running Ragex MCP server.

  When a Ragex server is already running (with Bumblebee loaded on the GPU),
  Mix tasks can use this module to delegate heavy work to the server via
  Unix socket instead of starting a second BEAM VM.

  ## Usage

      alias Ragex.MCP.Delegate

      case Delegate.with_server(fn conn ->
        {:ok, result} = Delegate.call(conn, "analyze_directory", %{"path" => "."})
        result
      end) do
        {:ok, result} -> handle_result(result)
        {:error, :not_running} -> fallback_to_local()
      end
  """

  alias Ragex.MCP.Client

  @doc """
  Checks if a running Ragex server is available for delegation.
  """
  @spec server_available?() :: boolean()
  def server_available?, do: Client.server_running?()

  @doc """
  Connects to the running server, runs the callback, and disconnects.

  Returns `{:ok, callback_result}` on success, or `{:error, reason}` if
  the server is not reachable or the callback fails.
  """
  @spec with_server((Client.t() -> term())) :: {:ok, term()} | {:error, term()}
  def with_server(fun) when is_function(fun, 1) do
    case Client.connect() do
      {:ok, conn} ->
        try do
          result = fun.(conn)
          {:ok, result}
        rescue
          e -> {:error, {:callback_error, Exception.message(e)}}
        after
          Client.disconnect(conn)
        end

      {:error, _reason} ->
        {:error, :not_running}
    end
  end

  @doc """
  Calls an MCP tool on the connected server.

  Thin wrapper around `Client.call_tool/3` that normalises the result
  with `atomize_keys/1` on success.
  """
  @spec call(Client.t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call(conn, tool_name, arguments \\ %{}) do
    case Client.call_tool(conn, tool_name, arguments) do
      {:ok, result} -> {:ok, atomize_keys(result)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Calls an MCP tool and returns the result directly (raises on error).
  """
  @spec call!(Client.t(), String.t(), map()) :: term()
  def call!(conn, tool_name, arguments \\ %{}) do
    case call(conn, tool_name, arguments) do
      {:ok, result} -> result
      {:error, reason} -> raise "MCP tool #{tool_name} failed: #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Result normalisation
  # ---------------------------------------------------------------------------

  @doc """
  Recursively converts string-keyed maps to atom-keyed maps.

  MCP tool results are JSON-decoded and arrive with string keys.  The
  existing Mix task formatters expect atom keys.

  ## Examples

      iex> Ragex.MCP.Delegate.atomize_keys(%{"foo" => 1, "bar" => %{"baz" => 2}})
      %{foo: 1, bar: %{baz: 2}}

      iex> Ragex.MCP.Delegate.atomize_keys([%{"a" => 1}, %{"b" => 2}])
      [%{a: 1}, %{b: 2}]
  """
  @spec atomize_keys(term()) :: term()
  def atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {safe_to_atom(key), atomize_keys(value)}

      {key, value} ->
        {key, atomize_keys(value)}
    end)
  end

  def atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end

  def atomize_keys(other), do: other

  @doc """
  Converts known string values back to atoms for fields that require them.

  The `fields` argument lists which map keys should have their values atomized.

  ## Examples

      iex> Ragex.MCP.Delegate.atomize_values(%{severity: "high", count: 3}, [:severity])
      %{severity: :high, count: 3}
  """
  @spec atomize_values(map(), [atom()]) :: map()
  def atomize_values(map, fields) when is_map(map) and is_list(fields) do
    Enum.reduce(fields, map, fn field, acc ->
      case Map.get(acc, field) do
        value when is_binary(value) -> Map.put(acc, field, safe_to_atom(value))
        _ -> acc
      end
    end)
  end

  @doc """
  Converts module name strings like "Elixir.Foo.Bar" or "Foo.Bar" back to
  atoms so they render correctly with `inspect/1`.
  """
  @spec to_module_atom(String.t() | atom()) :: atom()
  def to_module_atom(name) when is_atom(name), do: name

  def to_module_atom("Elixir." <> _ = name), do: String.to_atom(name)

  def to_module_atom(name) when is_binary(name) do
    if String.starts_with?(name, "Elixir.") or String.match?(name, ~r/^[A-Z]/) do
      String.to_atom("Elixir." <> name)
    else
      String.to_atom(name)
    end
  end

  # Private helpers

  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> String.to_atom(str)
  end
end
