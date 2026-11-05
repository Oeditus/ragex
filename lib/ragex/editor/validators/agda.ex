defmodule Ragex.Editor.Validators.Agda do
  @moduledoc """
  Agda code validator.

  Validates Agda syntax and scoping using a hybrid strategy:
  1. Tries `Metastatic.Adapters.Agda.parse/1` first.
  2. If the Metastatic parser bridge is unavailable, falls back to the system `agda` CLI
     using `--only-scope-checking`.

  ## Include paths

  The CLI fallback writes the module into a temporary directory and passes it via `-i`.
  Modules imported from the Agda standard library (e.g. `Data.Nat`) do *not* live in
  that temp directory, so library include paths are resolved separately and added to
  the search path. Resolution order:

  1. `AGDA_DIR` / `~/.agda/libraries` -- the canonical Agda library file list.
  2. Well-known standard library installation directories.

  Without this, any file importing a library module fails with
  `[FileNotFound] Failed to find source of module Data.Nat`.

  When a library contains the module being validated, a temporary view of that
  library substitutes the edited source while retaining its other modules.
  """

  @behaviour Ragex.Editor.Validator

  # Default location of the Agda library file list.
  @agda_dir "~/.agda"

  # Candidate standard library roots, checked in order. Each entry is a directory
  # that either contains `.agda-lib` manifests or is itself a source root.
  @stdlib_candidates [
    "/usr/share/agda-stdlib",
    "/usr/local/share/agda-stdlib",
    "/usr/share/agda/lib/standard-library",
    "/opt/agda-stdlib"
  ]

  alias Metastatic.Adapters.Agda, as: AgdaParser
  alias Ragex.Editor.Types
  alias Ragex.LanguageSupport
  require Logger

  @impl true
  def validate(content, opts \\ []) do
    case AgdaParser.parse(content) do
      {:ok, _ast} ->
        case LanguageSupport.find_executable("agda") do
          nil -> {:ok, :valid}
          agda_path -> run_agda_cli(agda_path, content, opts)
        end

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
  # reasons, possibly prefixed with "Parse error: " or containing Haskell ParseError position info.
  defp format_metastatic_error(reason) when is_binary(reason) do
    line =
      case Regex.run(~r/posLine\s*=\s*(\d+)/, reason) do
        [_, line_str] -> parse_int(line_str)
        _ -> nil
      end

    col =
      case Regex.run(~r/posCol\s*=\s*(\d+)/, reason) do
        [_, col_str] -> parse_int(col_str)
        _ -> nil
      end

    Types.validation_error(reason, line: line, column: col, severity: :error)
  end

  defp validate_via_cli(content, opts) do
    case LanguageSupport.find_executable("agda") do
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

      include_args =
        [temp_root | prepare_library_paths(temp_root, module_parts)]
        |> Enum.flat_map(&["-i", &1])

      # Do not let defaults reintroduce the original roots. Keep library manifests
      # enabled so imported modules retain their compiler flags and cached interfaces.
      cmd_args =
        ["--only-scope-checking", "--no-default-libraries"] ++ include_args ++ [file_path]

      case System.cmd(agda_path, cmd_args,
             stderr_to_stdout: true,
             env: LanguageSupport.subprocess_env()
           ) do
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

  defp prepare_library_paths(temp_root, module_parts) do
    library_include_paths()
    |> Enum.with_index()
    |> Enum.map(fn {root, index} ->
      module_path = Path.join([root | module_parts])

      if Enum.any?([".agda", ".lagda"], &File.regular?(module_path <> &1)) do
        overlay = Path.join(temp_root, "library_#{index}")
        File.mkdir_p!(overlay)
        overlay_library(root, overlay, module_parts)
        overlay
      else
        root
      end
    end)
  end

  # Link whole subtrees except along the edited module's path. Omitting its source
  # and interface variants leaves the edited source as the only module match.
  defp overlay_library(source, destination, [part | rest]) do
    Enum.each(File.ls!(source), fn entry ->
      source_path = Path.join(source, entry)
      destination_path = Path.join(destination, entry)

      cond do
        rest != [] and entry == part and File.dir?(source_path) ->
          File.mkdir_p!(destination_path)
          overlay_library(source_path, destination_path, rest)

        rest == [] and String.starts_with?(entry, part <> ".") ->
          :ok

        true ->
          File.ln_s!(source_path, destination_path)
      end
    end)
  end

  # Resolves Agda library include paths so imports such as `Data.Nat` can be
  # scope-checked. Returns a (possibly empty) list of existing directories.
  @spec library_include_paths() :: [String.t()]
  defp library_include_paths do
    (paths_from_agda_libraries_file() ++ paths_from_stdlib_candidates())
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  # Reads `~/.agda/libraries`, whose lines are `.agda-lib` file paths. Each manifest
  # declares the library root plus an `include:` list of source subdirectories.
  defp paths_from_agda_libraries_file do
    agda_dir = System.get_env("AGDA_DIR") || Path.expand(@agda_dir)

    case File.read(Path.join(agda_dir, "libraries")) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> Enum.flat_map(&include_paths_from_manifest/1)

      {:error, _} ->
        []
    end
  end

  defp include_paths_from_manifest(manifest_path) do
    manifest_path = Path.expand(manifest_path)

    case File.read(manifest_path) do
      {:ok, contents} ->
        root = Path.dirname(manifest_path)

        includes =
          contents
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.starts_with?(&1, "include:"))
          |> Enum.map(fn line ->
            line |> String.replace_prefix("include:", "") |> String.trim()
          end)
          |> Enum.reject(&(&1 == ""))

        case includes do
          [] -> [root]
          dirs -> Enum.map(dirs, &Path.join(root, &1))
        end

      {:error, _} ->
        []
    end
  end

  # Falls back to scanning well-known standard library installations when no
  # `~/.agda/libraries` entry covers them.
  defp paths_from_stdlib_candidates do
    Enum.flat_map(@stdlib_candidates, fn root ->
      cond do
        File.regular?(Path.join(root, "Data/Nat.agda")) -> [root]
        File.regular?(Path.join(root, "src/Data/Nat.agda")) -> [Path.join(root, "src")]
        true -> []
      end
    end)
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
