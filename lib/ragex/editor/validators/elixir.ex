defmodule Ragex.Editor.Validators.Elixir do
  @moduledoc """
  Elixir code validator.

  Uses `Code.string_to_quoted/2` to validate Elixir syntax.
  """

  @behaviour Ragex.Editor.Validator

  alias Ragex.Editor.Types

  @impl true
  def validate(content, _opts \\ []) do
    case Code.string_to_quoted(content) do
      {:ok, _ast} ->
        {:ok, :valid}

      {:error, {line, error_info, token}} ->
        error = parse_syntax_error(line, error_info, token)
        {:error, [error]}
    end
  end

  @impl true
  def can_validate?(path) when is_binary(path) do
    ext = Path.extname(path)
    ext in [".ex", ".exs"]
  end

  def can_validate?(_), do: false

  # Private functions

  defp parse_syntax_error(line, error_info, token) do
    message = format_error_message(error_info, token)

    Types.validation_error(message,
      line: line,
      severity: :error
    )
  end

  defp format_error_message(error_info, token) when is_binary(error_info) do
    if token && token != "" do
      "#{error_info}: #{inspect(token)}"
    else
      error_info
    end
  end

  defp format_error_message({:unicode, :invalid_codepoint, codepoint}, _token) do
    "invalid Unicode codepoint: #{inspect(codepoint)}"
  end

  defp format_error_message(error_info, token) when is_tuple(error_info) do
    # Handle complex error tuples
    case error_info do
      {message, _} when is_binary(message) ->
        if token && token != "" do
          "#{message}: #{inspect(token)}"
        else
          message
        end

      _ ->
        "syntax error: #{inspect(error_info)}"
    end
  end

  defp format_error_message(error_info, _token) do
    "syntax error: #{inspect(error_info)}"
  end
end
