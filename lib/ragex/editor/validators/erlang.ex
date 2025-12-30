defmodule Ragex.Editor.Validators.Erlang do
  @moduledoc """
  Erlang code validator.

  Uses `:erl_scan` and `:erl_parse` to validate Erlang syntax.
  """

  @behaviour Ragex.Editor.Validator

  alias Ragex.Editor.Types

  @impl true
  def validate(content, _opts \\ []) do
    charlist = String.to_charlist(content)

    with {:ok, tokens, _} <- :erl_scan.string(charlist),
         {:ok, _forms} <- parse_tokens(tokens) do
      {:ok, :valid}
    else
      {:error, {line, module, error_descriptor}, _} ->
        error = parse_error(line, module, error_descriptor)
        {:error, [error]}

      {:error, {line, module, error_descriptor}} ->
        error = parse_error(line, module, error_descriptor)
        {:error, [error]}
    end
  end

  @impl true
  def can_validate?(path) when is_binary(path) do
    ext = Path.extname(path)
    ext in [".erl", ".hrl"]
  end

  def can_validate?(_), do: false

  # Private functions

  defp parse_tokens(tokens) do
    # Erlang code consists of forms ending with '.'
    # We need to group tokens into forms
    case group_forms(tokens) do
      {:ok, forms} ->
        validate_forms(forms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp group_forms(tokens) do
    try do
      forms = split_into_forms(tokens)
      {:ok, forms}
    rescue
      e -> {:error, {1, :erl_parse, Exception.message(e)}}
    end
  end

  defp split_into_forms(tokens) do
    # Split tokens by dot followed by whitespace or EOF
    tokens
    |> Enum.chunk_by(fn
      {:dot, _} -> true
      _ -> false
    end)
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [form, [{:dot, _}]] -> form ++ [{:dot, 0}]
      [form] -> form
    end)
    |> Enum.filter(&(length(&1) > 0))
  end

  defp validate_forms(forms) do
    Enum.reduce_while(forms, {:ok, []}, fn form_tokens, {:ok, acc} ->
      case :erl_parse.parse_form(form_tokens) do
        {:ok, form} ->
          {:cont, {:ok, [form | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_error(line, module, error_descriptor) do
    message = format_error_message(module, error_descriptor)

    Types.validation_error(message,
      line: line,
      severity: :error
    )
  end

  defp format_error_message(module, error_descriptor) do
    try do
      # Try to format using the module's format_error function
      if function_exported?(module, :format_error, 1) do
        module.format_error(error_descriptor) |> to_string()
      else
        "syntax error: #{inspect(error_descriptor)}"
      end
    rescue
      _ -> "syntax error: #{inspect(error_descriptor)}"
    end
  end
end
