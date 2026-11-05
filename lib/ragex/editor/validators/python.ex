defmodule Ragex.Editor.Validators.Python do
  @moduledoc """
  Python code validator.

  Uses Python's `ast.parse()` via `Ragex.Editor.Validators.Subprocess` to
  validate Python syntax. Requires Python 3 to be installed on the system.
  """

  @behaviour Ragex.Editor.Validator

  alias Ragex.Editor.Validators.Subprocess

  @impl true
  def validate(content, _opts \\ []) do
    Subprocess.validate(content, spec())
  end

  @impl true
  def can_validate?(path) when is_binary(path) do
    Path.extname(path) == ".py"
  end

  def can_validate?(_), do: false

  # Private

  defp spec do
    [
      extension: ".py",
      bin: "python3",
      missing_message: "Python 3 not found. Please install Python 3 to validate Python files.",
      command: fn path, _content -> {"python3", ["-c", script(path)], []} end
    ]
  end

  defp script(path) do
    """
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
  end

  defp escape_path(path) do
    String.replace(path, "'", "\\'")
  end
end
