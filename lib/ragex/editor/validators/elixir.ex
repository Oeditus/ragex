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

  defp parse_syntax_error(meta_or_line, error_info, token) do
    {line, column} = extract_line_and_column(meta_or_line)
    message = format_error_message(error_info, token)

    Types.validation_error(message,
      line: line,
      column: column,
      severity: :error
    )
  end

  defp extract_line_and_column(meta) when is_list(meta) do
    {Keyword.get(meta, :line), Keyword.get(meta, :column)}
  end

  defp format_error_message(error_info, token) when is_binary(error_info) do
    if is_binary(token) and token != "" do
      "#{error_info}: #{inspect(token)}"
    else
      error_info
    end
  end

  defp format_error_message({message, description}, token) when is_binary(message) do
    hint = if is_binary(description) and description != "", do: "\nhint: #{description}", else: ""
    formatted = "#{message}#{hint}"

    if is_binary(token) and token != "" do
      "#{formatted}: #{inspect(token)}"
    else
      formatted
    end
  end
end
