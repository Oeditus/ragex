defmodule Ragex.Editor.Validators.Ruby do
  @moduledoc """
  Ruby code validator.

  Uses `ruby -c` to validate Ruby syntax.
  Requires Ruby to be installed on the system.
  """

  @behaviour Ragex.Editor.Validator

  alias Ragex.Editor.Types

  @impl true
  def validate(content, _opts \\ []) do
    with {:ok, temp_path} <- write_temp_file(content),
         result <- run_ruby_validation(temp_path),
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
    Path.extname(path) == ".rb"
  end

  def can_validate?(_), do: false

  # Private functions

  defp write_temp_file(content) do
    temp_dir = System.tmp_dir!()
    temp_path = Path.join(temp_dir, "ragex_ruby_validate_#{:rand.uniform(999_999)}.rb")

    case File.write(temp_path, content) do
      :ok -> {:ok, temp_path}
      error -> error
    end
  end

  defp run_ruby_validation(path) do
    case System.cmd("ruby", ["-c", path], stderr_to_stdout: true) do
      {output, 0} ->
        if String.contains?(output, "Syntax OK") do
          {:ok, :valid}
        else
          {:ok, :valid}
        end

      {output, _exit_code} ->
        parse_ruby_error(output)
    end
  rescue
    e in ErlangError ->
      if e.original == :enoent do
        error =
          Types.validation_error(
            "Ruby not found. Please install Ruby to validate Ruby files.",
            severity: :warning
          )

        {:error, [error]}
      else
        reraise e, __STACKTRACE__
      end
  end

  defp parse_ruby_error(output) do
    # Ruby error format: "path:line: syntax error, unexpected ..."
    case Regex.run(~r/:(\d+):\s*(.+)/, output) do
      [_, line_str, message] ->
        line = String.to_integer(line_str)

        error =
          Types.validation_error(String.trim(message),
            line: line,
            severity: :error
          )

        {:error, [error]}

      _ ->
        error = Types.validation_error("Syntax error: #{String.trim(output)}", severity: :error)
        {:error, [error]}
    end
  end
end
