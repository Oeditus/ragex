defmodule Ragex.Editor.Validators.Javascript do
  @moduledoc """
  JavaScript/TypeScript code validator.

  Uses Node.js to validate JavaScript/TypeScript syntax via the built-in parser.
  Requires Node.js to be installed on the system.
  """

  @behaviour Ragex.Editor.Validator

  alias Ragex.Editor.Types

  @impl true
  def validate(content, _opts \\ []) do
    # Create temporary file to avoid shell escaping issues
    with {:ok, temp_path} <- write_temp_file(content),
         result <- run_node_validation(temp_path),
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
    ext in [".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"]
  end

  def can_validate?(_), do: false

  # Private functions

  defp write_temp_file(content) do
    temp_dir = System.tmp_dir!()
    temp_path = Path.join(temp_dir, "ragex_js_validate_#{:rand.uniform(999_999)}.js")

    case File.write(temp_path, content) do
      :ok -> {:ok, temp_path}
      error -> error
    end
  end

  defp run_node_validation(path) do
    # Use Node.js to parse the file and report syntax errors
    # We use a JavaScript script that tries to parse the code
    node_script = """
    const fs = require('fs');
    const vm = require('vm');

    try {
        const code = fs.readFileSync('#{escape_path(path)}', 'utf8');
        // Try to compile the code (checks syntax without executing)
        new vm.Script(code);
        console.log('VALID');
        process.exit(0);
    } catch (e) {
        if (e instanceof SyntaxError) {
            // Extract line and column from stack trace if available
            const match = e.stack.match(/:([0-9]+):([0-9]+)/);
            if (match) {
                const line = match[1];
                const column = match[2];
                console.log(`SYNTAX_ERROR:${line}:${column}:${e.message}`);
            } else {
                console.log(`SYNTAX_ERROR:1:0:${e.message}`);
            }
            process.exit(1);
        } else {
            console.log(`ERROR:${e.message}`);
            process.exit(1);
        }
    }
    """

    case System.cmd("node", ["-e", node_script], stderr_to_stdout: true) do
      {"VALID\n", 0} ->
        {:ok, :valid}

      {output, 1} ->
        parse_node_error(output)

      {output, _exit_code} ->
        error =
          Types.validation_error("JavaScript validation failed: #{output}", severity: :error)

        {:error, [error]}
    end
  rescue
    e in ErlangError ->
      # Node not found
      if e.original == :enoent do
        error =
          Types.validation_error(
            "Node.js not found. Please install Node.js to validate JavaScript files.",
            severity: :warning
          )

        {:error, [error]}
      else
        reraise e, __STACKTRACE__
      end
  end

  defp escape_path(path) do
    # Escape single quotes in path for JavaScript string
    String.replace(path, "'", "\\'")
  end

  defp parse_node_error(output) do
    case String.split(String.trim(output), ":", parts: 4) do
      ["SYNTAX_ERROR", line_str, column_str, message] ->
        line = String.to_integer(line_str)
        column = String.to_integer(column_str)

        error =
          Types.validation_error("#{message}",
            line: line,
            column: column,
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
