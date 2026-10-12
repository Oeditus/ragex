defmodule Ragex.Editor.Validators.Agda do
  @moduledoc """
  Agda code validator.

  Validates Agda syntax and scoping using a hybrid strategy:
  1. Tries `Metastatic.Adapters.Agda.parse/1` first.
  2. If the Metastatic parser bridge is unavailable, falls back to the system `agda` CLI
     using `--only-scope-checking`.
  """

  @behaviour Ragex.Editor.Validator

  alias Metastatic.Adapters.Agda, as: AgdaParser
  alias Ragex.Editor.Types
  require Logger

  @impl true
  def validate(content, opts \\ []) do
    case AgdaParser.parse(content) do
      {:ok, _ast} ->
        {:ok, :valid}

      {:error, "Agda parser unavailable"} ->
        validate_via_cli(content, opts)

      {:error, reason} ->
        {:error, [format_metastatic_error(reason)]}
    end
  rescue
    e ->
      Logger.error(
        "Failed to validate Agda content: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      error =
        Types.validation_error("Agda validation failed: #{Exception.message(e)}",
          severity: :error
        )

      {:error, [error]}
  end

  @impl true
  def can_validate?(path) when is_binary(path) do
    Path.extname(path) in [".agda", ".lagda"]
  end

  def can_validate?(_), do: false

  # Private functions

  # `Metastatic.Adapters.Agda.parse/1` always reports failures as `String.t()`
  # reasons, possibly prefixed with "Parse error: ".
  defp format_metastatic_error(reason) when is_binary(reason) do
    Types.validation_error(reason, severity: :error)
  end

  defp validate_via_cli(content, opts) do
    case System.find_executable("agda") do
      nil ->
        error =
          Types.validation_error(
            "Neither Metastatic Agda parser nor 'agda' CLI executable found. Install Agda to validate .agda/.lagda files.",
            severity: :warning
          )

        {:error, [error]}

      agda_path ->
        run_agda_cli(agda_path, content, opts)
    end
  end

  defp run_agda_cli(agda_path, content, opts) do
    original_path = Keyword.get(opts, :path, "")
    ext = get_extension(original_path)
    module_parts = extract_module_parts(content, original_path)

    temp_root = Path.join(System.tmp_dir!(), "ragex_agda_#{:rand.uniform(9_999_999)}")

    try do
      module_dir =
        if length(module_parts) > 1 do
          subdirs = Enum.slice(module_parts, 0..-2//1)
          Path.join([temp_root | subdirs])
        else
          temp_root
        end

      File.mkdir_p!(module_dir)

      file_name = List.last(module_parts) <> ext
      file_path = Path.join(module_dir, file_name)
      File.write!(file_path, content)

      cmd_args = [
        "--only-scope-checking",
        "-i",
        temp_root,
        file_path
      ]

      case System.cmd(agda_path, cmd_args, stderr_to_stdout: true) do
        {_output, 0} ->
          {:ok, :valid}

        {output, _exit_code} ->
          parse_agda_cli_output(output)
      end
    rescue
      e ->
        error =
          Types.validation_error("Agda CLI validation error: #{Exception.message(e)}",
            severity: :error
          )

        {:error, [error]}
    after
      File.rm_rf(temp_root)
    end
  end

  defp get_extension(path) when is_binary(path) do
    case Path.extname(path) do
      ".lagda" -> ".lagda"
      _ -> ".agda"
    end
  end

  defp extract_module_parts(content, original_path) do
    case Regex.run(~r/^\s*module\s+([A-Za-z0-9_.\x27-]+)/m, content) do
      [_, mod_name] ->
        String.split(mod_name, ".")

      nil ->
        if is_binary(original_path) and original_path != "" do
          basename = Path.rootname(Path.basename(original_path))
          [basename]
        else
          ["Anonymous"]
        end
    end
  end

  defp parse_agda_cli_output(output) do
    clean_output =
      ~r/^Checking[^\n]*\n?/
      |> Regex.replace(output, "")
      |> String.trim()

    diag_regex =
      ~r/^([^:\n]+):(\d+)(?:\.(\d+)(?:-(\d+))?)?:\s*(error|warning)?:\s*(?:\[([^\]]+)\])?\s*\n?([\s\S]*)$/

    case Regex.run(diag_regex, clean_output) do
      [_, _file, line_str, col_str, _end_col, severity_str, tag, rest_msg] ->
        line = parse_int(line_str)
        col = parse_int(col_str)
        severity = if severity_str == "warning", do: :warning, else: :error
        tag_prefix = if tag != "", do: "[#{tag}] ", else: ""
        msg = tag_prefix <> String.trim(rest_msg)

        error =
          Types.validation_error(msg,
            line: line,
            column: col,
            severity: severity
          )

        {:error, [error]}

      [_, _file, line_str, col_str, _end_col, severity_str, rest_msg] ->
        line = parse_int(line_str)
        col = parse_int(col_str)
        severity = if severity_str == "warning", do: :warning, else: :error

        error =
          Types.validation_error(String.trim(rest_msg),
            line: line,
            column: col,
            severity: severity
          )

        {:error, [error]}

      _ ->
        error =
          Types.validation_error(clean_output,
            severity: :error
          )

        {:error, [error]}
    end
  end

  # Non-participating regex groups are returned as empty strings by `Regex.run/2`.
  defp parse_int(""), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {num, _} -> num
      :error -> nil
    end
  end
end
