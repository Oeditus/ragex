defmodule Ragex.Analyzers.SCIP.Registry do
  @moduledoc """
  Maps project marker files to languages and their SCIP indexer tools.

  Detects which languages are present in a project directory by looking
  for marker files (e.g. `go.mod` -> Go, `Cargo.toml` -> Rust), and
  knows which SCIP indexer binary to run for each language.

  ## Source of truth

  The list of SCIP languages is **derived from `Ragex.Languages`** (which in
  turn derives from `Metastatic.Languages`). A language is SCIP-indexable when
  its `%Ragex.Language{}` descriptor carries SCIP indexer metadata *and* it has
  no Metastatic adapter -- languages Ragex can parse natively (Elixir, Erlang,
  Python, JavaScript/TypeScript, Ruby, ...) are excluded because Ragex's own
  analyzers or Metastatic provide deeper AST access for them.

  Adding a new SCIP-only language therefore means adding it to the
  `@scip_languages` overlay in `Ragex.Languages`, not editing this module.
  """

  @type language_info :: %{
          language: String.t(),
          indexer: String.t(),
          indexer_args: [String.t()],
          extensions: [String.t()],
          marker_files: [String.t()]
        }

  # Derived at compile time from the Ragex language registry. Every language
  # that carries SCIP indexer metadata is included -- including ones that also
  # have a Metastatic adapter (e.g. Ruby), matching the historical set.
  @languages (
               for %Ragex.Language{language: lang, scip_indexer: indexer} <-
                     Ragex.Languages.scip_languages(),
                   indexer != nil do
                 %{
                   language: Atom.to_string(lang),
                   indexer: indexer.indexer,
                   indexer_args: indexer.indexer_args,
                   extensions: indexer.extensions,
                   marker_files: indexer.marker_files
                 }
               end
             )

  @doc "Returns all known SCIP-supported language definitions."
  @spec all_languages() :: [language_info()]
  def all_languages, do: @languages

  @doc """
  Detect which SCIP-supported languages are present in a directory.

  Returns a list of language info maps for each detected language.
  """
  @spec detect_languages(String.t()) :: [language_info()]
  def detect_languages(project_dir) do
    entries =
      case File.ls(project_dir) do
        {:ok, list} -> list
        _ -> []
      end

    Enum.filter(@languages, fn lang ->
      Enum.any?(lang.marker_files, fn marker ->
        if String.contains?(marker, "*") do
          # Glob pattern (e.g. "*.csproj")
          pattern = String.replace(marker, "*", "")
          Enum.any?(entries, &String.ends_with?(&1, pattern))
        else
          marker in entries
        end
      end)
    end)
  end

  @doc """
  Check which SCIP indexer binaries are available on the system.

  Returns a map of `%{language => %{available: bool, path: String.t() | nil}}`.
  """
  @spec check_indexers() :: %{String.t() => %{available: boolean(), path: String.t() | nil}}
  def check_indexers do
    @languages
    |> Enum.uniq_by(& &1.indexer)
    |> Map.new(fn lang ->
      path = System.find_executable(lang.indexer)
      {lang.language, %{available: path != nil, path: path, indexer: lang.indexer}}
    end)
  end

  @doc "Check if the `scip` CLI is available."
  @spec scip_cli_available?() :: boolean()
  def scip_cli_available? do
    System.find_executable("scip") != nil
  end

  @doc "Returns language info for a given language name, or nil."
  @spec get_language(String.t()) :: language_info() | nil
  def get_language(name) do
    Enum.find(@languages, fn lang -> lang.language == name end)
  end

  @doc "Returns all file extensions handled by SCIP (not by native analyzers)."
  @spec scip_extensions() :: [String.t()]
  def scip_extensions do
    @languages |> Enum.flat_map(& &1.extensions) |> Enum.uniq()
  end
end
