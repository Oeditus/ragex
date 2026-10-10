defmodule Ragex.Editor.Validators.Cure do
  @moduledoc """
  Cure code validator.

  Validates Cure syntax using `Metastatic.Adapters.Cure`.
  Cure source code produces MetaAST 3-tuples through Cure's lexer and parser pipeline.
  """

  @behaviour Ragex.Editor.Validator

  alias Metastatic.Adapters.Cure
  alias Ragex.Editor.Types
  require Logger

  @impl true
  def validate(content, opts \\ []) do
    maybe_ensure_cure_compiler(opts)

    case Cure.parse(content) do
      {:ok, _ast} ->
        {:ok, :valid}

      {:error, :cure_not_available} ->
        error =
          Types.validation_error(
            "Cure compiler not available. Ensure Cure is installed or built in the project.",
            severity: :warning
          )

        {:error, [error]}

      {:error, errors} when is_list(errors) ->
        validation_errors =
          errors
          |> Enum.map(&format_parse_error/1)
          |> Enum.reject(&is_nil/1)

        if validation_errors == [] do
          error = Types.validation_error("Syntax error in Cure source", severity: :error)
          {:error, [error]}
        else
          {:error, validation_errors}
        end

      {:error, single_error} ->
        error = format_parse_error(single_error)
        {:error, [error]}
    end
  rescue
    e ->
      Logger.error("Failed to validate Cure file: #{Exception.format(:error, e, __STACKTRACE__)}")

      error =
        Types.validation_error("Cure validation failed: #{Exception.message(e)}",
          severity: :error
        )

      {:error, [error]}
  end

  @impl true
  def can_validate?(path) when is_binary(path) do
    Path.extname(path) == ".cure"
  end

  def can_validate?(_), do: false

  # Private functions

  defp format_parse_error({:unterminated_string, line, col}) do
    Types.validation_error("Unterminated string", line: line, column: col, severity: :error)
  end

  defp format_parse_error({:unterminated_quoted_identifier, line, col}) do
    Types.validation_error("Unterminated quoted identifier",
      line: line,
      column: col,
      severity: :error
    )
  end

  defp format_parse_error({:invalid_character, char, line, col}) do
    Types.validation_error("Invalid character: #{inspect(char)}",
      line: line,
      column: col,
      severity: :error
    )
  end

  defp format_parse_error({:expected_token, expected, observed, _str, line, col, _span}) do
    Types.validation_error("Expected #{inspect(expected)}, observed #{inspect(observed)}",
      line: line,
      column: col,
      severity: :error
    )
  end

  defp format_parse_error({:expected_token, expected, observed, line, col}) do
    Types.validation_error("Expected #{inspect(expected)}, observed #{inspect(observed)}",
      line: line,
      column: col,
      severity: :error
    )
  end

  defp format_parse_error({tag, details}) when is_map(details) do
    line = Map.get(details, :line) || get_span_line(Map.get(details, :span))
    column = Map.get(details, :column) || get_span_column(Map.get(details, :span))

    message =
      cond do
        tag == :unexpected_token ->
          "Unexpected token #{inspect(details[:observed] || details[:token_type])}"

        tag == :function_parameters_unparenthesized ->
          "Parameters for function #{inspect(details[:function])} must be parenthesized"

        tag == :declaration_separator_missing ->
          "Missing separator near #{inspect(details[:key] || details[:observed])}"

        tag == :bare_brace_expression ->
          "Bare brace expression not allowed"

        details[:observed] ->
          "#{humanize_tag(tag)}: observed #{inspect(details[:observed])}"

        is_binary(details[:message]) ->
          details[:message]

        true ->
          humanize_tag(tag)
      end

    Types.validation_error(message, line: line, column: column, severity: :error)
  end

  defp format_parse_error({reason, line, col})
       when is_integer(line) and is_integer(col) and is_atom(reason) do
    Types.validation_error(humanize_tag(reason), line: line, column: col, severity: :error)
  end

  defp format_parse_error({reason, line}) when is_integer(line) and is_atom(reason) do
    Types.validation_error(humanize_tag(reason), line: line, severity: :error)
  end

  defp format_parse_error(message) when is_binary(message) do
    Types.validation_error(message, severity: :error)
  end

  defp format_parse_error(other) do
    Types.validation_error("Syntax error: #{inspect(other)}", severity: :error)
  end

  defp get_span_line(%{start_line: line}) when is_integer(line), do: line
  defp get_span_line(_), do: nil

  defp get_span_column(%{start_column: col}) when is_integer(col), do: col
  defp get_span_column(_), do: nil

  defp humanize_tag(tag) when is_atom(tag) do
    tag
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp humanize_tag(other), do: to_string(other)

  defp maybe_ensure_cure_compiler(opts) do
    if not cure_loaded?() do
      case Keyword.get(opts, :path) do
        path when is_binary(path) ->
          find_and_load_cure_ebin(path)

        _ ->
          :ok
      end
    end
  end

  defp cure_loaded? do
    :code.is_loaded(Cure.Compiler.Lexer) != false or
      (match?({:module, _}, Code.ensure_compiled(Cure.Compiler.Lexer)) and
         match?({:module, _}, Code.ensure_compiled(Cure.Compiler.Parser)))
  end

  defp find_and_load_cure_ebin(file_path) do
    dir = Path.dirname(Path.expand(file_path))
    search_ebin_upwards(dir, 5)
  end

  defp search_ebin_upwards(dir, depth) when depth <= 0 or dir in ["/", "."] do
    :ok
  end

  defp search_ebin_upwards(dir, depth) do
    ebin_paths = Path.wildcard(Path.join(dir, "_build/*/lib/cure/ebin"))

    if ebin_paths != [] do
      Enum.each(ebin_paths, &Code.append_path/1)
    else
      search_ebin_upwards(Path.dirname(dir), depth - 1)
    end
  end
end
