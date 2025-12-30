defmodule Ragex.Editor.Validators.Python do
  @moduledoc """
  Python code validator.

  Uses Python's `ast.parse()` via shell command to validate Python syntax.
  Requires Python 3 to be installed on the system.
  """

  @behaviour Ragex.Editor.Validator

  alias Ragex.Editor.Types

  @impl true
  def validate(content, _opts \\ []) do
    # Create temporary file to avoid shell escaping issues
    with {:ok, temp_path} <- write_temp_file(content),
         result <- run_python_validation(temp_path),
         :ok <- File.rm(temp_path) do
      result
    else
      {:error, reason} when is_binary(reason) ->
        error = Types.validation_error(reason, severity: :error)
        {:error, [error]}

      {:error, reason} ->
        error = Types.validation_error("Failed to validate: #{inspect(reason)}", severity: :error)
        {:error, [error]}
    end
  end

  @impl true
  def can_validate?(path) when is_binary(path) do
    ext = Path.extname(path)
    ext == ".py"
  end

  def can_validate?(_), do: false

  # Private functions

  defp write_temp_file(content) do
    temp_dir = System.tmp_dir!()
    temp_path = Path.join(temp_dir, "ragex_python_validate_#{:rand.uniform(999_999)}.py")

    case File.write(temp_path, content) do
      :ok -> {:ok, temp_path}
      error -> error
    end
  end

  defp run_python_validation(path) do
    # Use Python to parse the file and report syntax errors
    python_script = """
    import ast
    import sys

    try:
        with open('#{escape_path(path)}', 'r') as f:
            code = f.read()
        ast.parse(code)
        print('VALID')
        sys.exit(0)
    except SyntaxError as e:
        print(f'SYNTAX_ERROR:{e.lineno}:{e.offset}:{e.msg}')
        sys.exit(1)
    except Exception as e:
        print(f'ERROR:{str(e)}')
        sys.exit(1)
    """

    case System.cmd("python3", ["-c", python_script], stderr_to_stdout: true) do
      {"VALID\n", 0} ->
        {:ok, :valid}

      {output, 1} ->
        parse_python_error(output)

      {output, _exit_code} ->
        error = Types.validation_error("Python validation failed: #{output}", severity: :error)
        {:error, [error]}
    end
  rescue
    e in ErlangError ->
      # Python not found
      if e.original == :enoent do
        error =
          Types.validation_error(
            "Python 3 not found. Please install Python 3 to validate Python files.",
            severity: :warning
          )

        {:error, [error]}
      else
        reraise e, __STACKTRACE__
      end
  end

  defp escape_path(path) do
    # Escape single quotes in path for Python string
    String.replace(path, "'", "\\'")
  end

  defp parse_python_error(output) do
    case String.split(String.trim(output), ":", parts: 4) do
      ["SYNTAX_ERROR", line_str, offset_str, message] ->
        line = String.to_integer(line_str)
        offset = String.to_integer(offset_str)

        error =
          Types.validation_error("#{message}",
            line: line,
            column: offset,
            severity: :error
          )

        {:error, [error]}

      ["ERROR", message] ->
        error = Types.validation_error(message, severity: :error)
        {:error, [error]}

      _ ->
        error = Types.validation_error("Unknown error: #{output}", severity: :error)
        {:error, [error]}
    end
  end
end
