defmodule Ragex.MCP.JSON do
  @moduledoc """
  Shared JSON helpers for MCP transports.

  Both the stdio server (`Ragex.MCP.Server`) and the Unix socket server
  (`Ragex.MCP.SocketServer`) need to turn arbitrary Elixir terms coming out of
  the tool/resource handlers into something the JSON encoder accepts, and to
  encode it without raising.

  Keeping this logic in one place means both transports produce byte-identical
  responses for the same handler output, and there is a single spot to fix
  encoding edge cases.
  """

  @doc """
  Converts an arbitrary Elixir term into a JSON-safe structure.

  - tuples are rendered with `inspect/1` (JSON has no tuple type)
  - lists and maps are converted recursively
  - binary keys are preserved, other keys are stringified
  - invalid UTF-8 binaries are sanitized so the encoder cannot fail on them
  """
  @spec result_to_json(term()) :: term()
  def result_to_json(value) when is_tuple(value), do: inspect(value)
  def result_to_json(value) when is_list(value), do: Enum.map(value, &result_to_json/1)

  def result_to_json(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {result_to_json_key(k), result_to_json(v)} end)
  end

  def result_to_json(value) when is_binary(value) do
    if String.valid?(value), do: value, else: sanitize_utf8_binary(value)
  end

  def result_to_json(value), do: value

  @doc """
  Encodes an already JSON-safe term, falling back to `inspect/1` on failure.

  Never raises: if the encoder rejects the value (for example an unsupported
  map key), the inspected form is returned instead so the client still gets a
  readable payload.
  """
  @spec encode_or_inspect(term()) :: String.t()
  def encode_or_inspect(value) do
    case safe_json_encode(value) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value)
    end
  end

  @doc """
  Encodes a term as JSON, returning `{:ok, binary}` or `{:error, reason}`.
  """
  @spec safe_json_encode(term()) :: {:ok, String.t()} | {:error, term()}
  def safe_json_encode(value) do
    {:ok, :json.encode(value) |> IO.iodata_to_binary()}
  rescue
    e -> {:error, e}
  catch
    _, reason -> {:error, reason}
  end

  defp result_to_json_key(key) when is_binary(key) do
    if String.valid?(key), do: key, else: sanitize_utf8_binary(key)
  end

  defp result_to_json_key(key) when is_atom(key), do: key
  defp result_to_json_key(key), do: result_to_json(key) |> to_string()

  defp sanitize_utf8_binary(binary) do
    for <<c <- binary>>, into: "" do
      if c < 128, do: <<c>>, else: "\uFFFD"
    end
  end
end
