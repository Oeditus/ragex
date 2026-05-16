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

    with {:ok, content} <- File.read(path) do
      SourceFile.parse(content, path, language)
    end
  end

  @doc """
  Builds a `MetaCredo.SourceFile` from already-read content.
  """
  @spec parse_source_file(String.t(), String.t(), atom()) ::
          {:ok, SourceFile.t()} | {:error, term()}
  def parse_source_file(content, filename, language) do
    SourceFile.parse(content, filename, language)
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
