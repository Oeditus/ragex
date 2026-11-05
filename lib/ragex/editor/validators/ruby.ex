defmodule Ragex.Editor.Validators.Ruby do
  @moduledoc """
  Ruby code validator.

  Uses `ruby -c` via `Ragex.Editor.Validators.Subprocess` to validate Ruby
  syntax. Requires Ruby to be installed on the system.
  """

  @behaviour Ragex.Editor.Validator

  alias Ragex.Editor.Types
  alias Ragex.Editor.Validators.Subprocess

  @impl true
  def validate(content, _opts \\ []) do
    Subprocess.validate(content, spec())
  end

  @impl true
  def can_validate?(path) when is_binary(path) do
    Path.extname(path) == ".rb"
  end

  def can_validate?(_), do: false

  # Private

  defp spec do
    [
      extension: ".rb",
      bin: "ruby",
      missing_message: "Ruby not found. Please install Ruby to validate Ruby files.",
      command: fn path, _content -> {"ruby", ["-c", path], []} end,
      parse: &parse_ruby_error/2
    ]
  end

  # Ruby reports `path:line: message` on failure.
  defp parse_ruby_error(output, _exit_code) do
    case Regex.run(~r/:(\d+):\s*(.+)/, output) do
      [_, line_str, message] ->
        {:error,
         [
           Types.validation_error(String.trim(message),
             line: String.to_integer(line_str),
             severity: :error
           )
         ]}

      _ ->
        {:error, [Types.validation_error("Syntax error: #{String.trim(output)}", severity: :error)]}
    end
  end
end
