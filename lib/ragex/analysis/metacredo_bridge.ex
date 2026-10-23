defmodule Ragex.Analysis.MetaCredoBridge do
  @moduledoc """
  Bridge between MetaCredo's check system and Ragex's analysis modules.

  Provides helpers for:
  - Parsing source files into `MetaCredo.SourceFile` structs
  - Running MetaCredo checks and collecting issues
  - Converting `MetaCredo.Issue` structs to Ragex's internal formats
    (business logic issues, security vulnerabilities, code smells)
  """

  alias MetaCredo.{Issue, SourceFile}
  require Logger

  # -- Parsing --

  @doc """
  Parses a file into a `MetaCredo.SourceFile`.

  Returns `{:ok, source_file}` or `{:error, reason}`.
  """
  @spec parse_file(String.t()) :: {:ok, SourceFile.t()} | {:error, term()}
  def parse_file(path) do
    language = Ragex.LanguageSupport.detect_language(path)

    with {:ok, content} <- File.read(path),
         {:ok, content} <- ensure_utf8(content, path) do
      SourceFile.parse(content, path, language)
    end
  end

  @doc """
  Builds a `MetaCredo.SourceFile` from already-read content.
  """
  @spec parse_source_file(String.t(), String.t(), atom()) ::
          {:ok, SourceFile.t()} | {:error, term()}
  def parse_source_file(content, filename, language) do
    with {:ok, content} <- ensure_utf8(content, filename) do
      SourceFile.parse(content, filename, language)
    end
  end

  # -- Running checks --

  @doc """
  Runs a list of MetaCredo check modules on a source file.

  `checks` is a list of `{module, params}` tuples, matching MetaCredo's convention.
  Returns a flat list of `MetaCredo.Issue` structs.
  """
  @spec run_checks(SourceFile.t(), [{module(), keyword()}]) :: [Issue.t()]
  def run_checks(%SourceFile{} = source_file, checks) when is_list(checks) do
    Enum.flat_map(checks, fn {check_module, params} ->
      try do
        check_module.run(source_file, params)
      rescue
        e ->
          Logger.warning(
            "MetaCredo check #{inspect(check_module)} failed on #{source_file.filename}: #{inspect(e)}"
          )

          []
      end
    end)
  end

  @doc """
  Filters a list of `{check_module, params}` check tuples, removing any check modules
  that are disabled in the `.metacredo.exs` configuration file.
  """
  @spec filter_enabled_checks([{module(), keyword()}]) :: [{module(), keyword()}]
  def filter_enabled_checks(checks) when is_list(checks) do
    config = MetaCredo.Config.read()
    disabled = Map.get(config, :checks, %{}) |> Map.get(:disabled, [])

    disabled_modules =
      Enum.map(disabled, fn
        {mod, _} -> mod
        mod when is_atom(mod) -> mod
      end)

    Enum.reject(checks, fn {mod, _} -> mod in disabled_modules end)
  end

  @doc """
  Filters a list of check tuples `{check_module, params}` or modules based on `no_db` and `no_user` options.
  """
  @spec filter_checks(list(), keyword() | map()) :: list()
  def filter_checks(checks, opts) when is_list(checks) do
    no_db? = (opts[:no_db] && true) || false
    no_user? = (opts[:no_user] && true) || false

    checks =
      if no_db? do
        Enum.reject(checks, fn
          {mod, _} -> db_check?(mod)
          mod when is_atom(mod) -> db_check?(mod)
        end)
      else
        checks
      end

    if no_user? do
      Enum.reject(checks, fn
        {mod, _} -> user_check?(mod)
        mod when is_atom(mod) -> user_check?(mod)
      end)
    else
      checks
    end
  end

  @doc """
  Returns true if the check module or analyzer atom is DB-related.
  """
  @spec db_check?(module() | atom()) :: boolean()
  def db_check?(mod) when is_atom(mod) do
    tags = if function_exported?(mod, :tags, 0), do: mod.tags(), else: []

    :db in tags or
      mod in [:n_plus_one_query, :missing_preload, :sql_injection, :inefficient_filter] or
      String.contains?(to_string(mod), [
        "SQLInjection",
        "NPlusOneQuery",
        "MissingPreload",
        "Database"
      ])
  end

  def db_check?(_), do: false

  @doc """
  Returns true if the check module or analyzer atom is user-input-related.
  """
  @spec user_check?(module() | atom()) :: boolean()
  def user_check?(mod) when is_atom(mod) do
    tags = if function_exported?(mod, :tags, 0), do: mod.tags(), else: []

    :user in tags or :user_input in tags or
      mod in [
        :xss_vulnerability,
        :ssrf_vulnerability,
        :path_traversal,
        :insecure_direct_object_reference,
        :missing_authentication,
        :missing_authorization,
        :incorrect_authorization,
        :missing_csrf_protection,
        :sensitive_data_exposure,
        :unrestricted_file_upload,
        :improper_input_validation,
        :inline_javascript
      ] or
      String.contains?(to_string(mod), [
        "InputValidation",
        "XSS",
        "CSRF",
        "PathTraversal",
        "DirectObjectReference",
        "FileUpload",
        "SSRF",
        "SensitiveData",
        "InlineJavascript",
        "Authentication",
        "Authorization",
        "ParameterPatternMatching"
      ])
  end

  def user_check?(_), do: false

  # -- Issue conversion: Business Logic --

  @doc """
  Converts a `MetaCredo.Issue` to Ragex's business logic issue format.
  """
  @spec issue_to_ragex_issue(Issue.t(), String.t()) :: map()
  def issue_to_ragex_issue(%Issue{} = issue, file_path) do
    %{
      analyzer: check_to_analyzer_atom(issue.check),
      category: issue.category,
      severity: normalize_severity(issue.severity, issue.priority),
      message: issue.message,
      description: issue.message,
      suggestion: nil,
      context: %{trigger: issue.trigger},
      location: %{
        line: issue.line_no,
        column: issue.column,
        function: nil
      },
      line: issue.line_no,
      column: issue.column,
      file: file_path
    }
  end

  # -- Issue conversion: Security --

  @doc """
  Converts a `MetaCredo.Issue` to Ragex's security vulnerability format.
  """
  @spec issue_to_vulnerability(Issue.t(), String.t(), atom()) :: map()
  def issue_to_vulnerability(%Issue{} = issue, file_path, language) do
    %{
      category: issue.category,
      severity: normalize_severity(issue.severity, issue.priority),
      description: issue.message,
      recommendation: nil,
      cwe: issue.metadata[:cwe],
      context: %{trigger: issue.trigger},
      file: file_path,
      language: language,
      line: issue.line_no,
      column: issue.column
    }
  end

  # -- Issue conversion: Smells --

  @doc """
  Converts a `MetaCredo.Issue` to Ragex's smell format.
  """
  @spec issue_to_smell(Issue.t()) :: map()
  def issue_to_smell(%Issue{} = issue) do
    %{
      type: check_to_smell_type(issue.check),
      severity: normalize_smell_severity(issue.severity, issue.priority),
      description: issue.message,
      suggestion: "",
      context: %{trigger: issue.trigger},
      location: if(issue.line_no, do: %{line: issue.line_no, column: issue.column}, else: nil)
    }
  end

  # -- Helpers --

  # Ensures the binary is valid UTF-8. Files saved with legacy encodings
  # (e.g. Latin-1) contain bytes that are invalid UTF-8 and crash
  # `Code.string_to_quoted/2` via `String.to_charlist/1`.
  #
  # Invalid sequences are replaced with U+FFFD (the Unicode replacement
  # character) rather than skipping the file, matching `MetastaticBridge` and
  # `Analyzers.Directory`. Skipping here meant the same file was analysed by
  # one code path and silently ignored by another.
  defp ensure_utf8(content, path) when is_binary(content) do
    if String.valid?(content) do
      {:ok, content}
    else
      Logger.debug("Sanitizing non-UTF-8 content in #{path} (replacing invalid bytes)")
      {:ok, sanitize_utf8_bytes(content, <<>>)}
    end
  end

  defp sanitize_utf8_bytes(<<>>, acc), do: acc

  defp sanitize_utf8_bytes(<<c::utf8, rest::binary>>, acc) do
    sanitize_utf8_bytes(rest, <<acc::binary, c::utf8>>)
  end

  defp sanitize_utf8_bytes(<<_byte, rest::binary>>, acc) do
    # Replace invalid byte with U+FFFD REPLACEMENT CHARACTER
    sanitize_utf8_bytes(rest, <<acc::binary, 0xEF, 0xBF, 0xBD>>)
  end

  # Map MetaCredo check module to Ragex analyzer atom
  defp check_to_analyzer_atom(check_module) do
    check_module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  # Map MetaCredo check module to smell type atom
  defp check_to_smell_type(check_module) do
    check_module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  # Normalize MetaCredo severity + priority to Ragex severity
  defp normalize_severity(:error, _priority), do: :critical
  defp normalize_severity(:warning, :higher), do: :critical
  defp normalize_severity(:warning, :high), do: :high
  defp normalize_severity(:warning, _), do: :medium
  defp normalize_severity(:info, _), do: :low
  defp normalize_severity(:refactoring_opportunity, _), do: :info
  defp normalize_severity(severity, _), do: severity

  # Normalize to smell severity levels
  defp normalize_smell_severity(:error, _), do: :critical
  defp normalize_smell_severity(:warning, :higher), do: :critical
  defp normalize_smell_severity(:warning, :high), do: :high
  defp normalize_smell_severity(:warning, _), do: :medium
  defp normalize_smell_severity(:info, _), do: :low
  defp normalize_smell_severity(:refactoring_opportunity, _), do: :low
  defp normalize_smell_severity(_, _), do: :medium
end
