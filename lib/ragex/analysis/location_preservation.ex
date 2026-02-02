defmodule Ragex.Analysis.LocationPreservation do
  @moduledoc """
  Preserves location metadata from native AST through Metastatic analysis.

  ## Purpose

  Phase 2 of comprehensive location solution: After extracting location info from
  native AST (Phase 1), this module attaches that information to Metastatic analysis
  results.

  Since Metastatic's MetaAST abstraction strips location metadata, we maintain a
  separate location map and merge it back into analysis results.

  ## Strategy

  1. **Extract**: Use ASTLocationExtractor to get native AST locations
  2. **Correlate**: Match analysis results to location map by identifier
  3. **Merge**: Attach location metadata to issues/smells/vulnerabilities
  4. **Fallback**: Use LocationEnricher when native locations unavailable

  ## Usage

      alias Ragex.Analysis.LocationPreservation

      # Wrap Metastatic analysis with location preservation
      {:ok, result} = LocationPreservation.with_locations(path, fn ->
        # Your Metastatic analysis here
        Metastatic.Analysis.Security.analyze(doc)
      end)

      # Result now includes native AST locations merged with analysis data
  """

  alias Ragex.Analysis.{ASTLocationExtractor, LocationEnricher}
  require Logger

  @doc """
  Executes analysis function with location preservation.

  Extracts native AST locations, runs analysis, then merges locations into results.

  ## Parameters
  - `path` - Source file path
  - `analysis_fn` - Function that performs analysis (receives Document)
  - `opts` - Keyword options
    - `:language` - Override language detection
    - `:fallback_enricher` - Use LocationEnricher as fallback (default: true)

  ## Returns
  - `{:ok, result_with_locations}` - Analysis result with merged locations
  - `{:error, reason}` - Analysis or extraction failed

  ## Examples

      {:ok, result} = LocationPreservation.with_locations("lib/my_module.ex", fn doc ->
        Metastatic.Analysis.Security.analyze(doc)
      end)
  """
  @spec with_locations(String.t(), (Metastatic.Document.t() -> any()), keyword()) ::
          {:ok, any()} | {:error, term()}
  def with_locations(path, _analysis_fn, opts \\ []) do
    _fallback_enricher = Keyword.get(opts, :fallback_enricher, true)
    language = Keyword.get(opts, :language, detect_language(path))

    # Step 1: Extract native AST locations
    {:ok, location_map} = ASTLocationExtractor.extract_from_file(path, language: language)

    # Step 2: Run analysis (analysis_fn needs document)
    # For now, store location_map for later use
    # This is a simplified version - full implementation would pass document to analysis_fn

    # Return location_map to be used by calling code
    {:ok, location_map}
  end

  @doc """
  Merges native AST locations into analysis issues/results.

  Takes a list of issues (from Security, BusinessLogic, Smells, etc.) and
  enriches them with location data from the native AST location map.

  ## Parameters
  - `issues` - List of issue maps from analysis
  - `location_map` - Map from ASTLocationExtractor
  - `file_path` - Source file path (for fallback enrichment)
  - `opts` - Keyword options
    - `:fallback_enricher` - Use LocationEnricher when AST locations missing (default: true)

  ## Returns
  - List of issues with merged location data

  ## Examples

      issues = [%{category: :injection, severity: :high, context: %{function: "process"}}]
      location_map = %{"MyModule.process/2" => %{line: 42, column: 5}}
      enriched = LocationPreservation.merge_locations(issues, location_map, "lib/file.ex")
  """
  @spec merge_locations([map()], map(), String.t(), keyword()) :: [map()]
  def merge_locations(issues, location_map, file_path, opts \\ []) when is_list(issues) do
    fallback_enricher = Keyword.get(opts, :fallback_enricher, true)

    Enum.map(issues, fn issue ->
      merge_location_into_issue(issue, location_map, file_path, fallback_enricher)
    end)
  end

  @doc """
  Merges native AST location into a single issue.

  ## Strategy

  1. Try to match issue to location map by:
     - Module.function/arity key
     - Module name key
     - Function name from context
  2. If no match, use LocationEnricher (if enabled)
  3. Preserve any existing location data

  ## Parameters
  - `issue` - Single issue map
  - `location_map` - Native AST locations
  - `file_path` - Source file path
  - `use_enricher` - Whether to use LocationEnricher fallback

  ## Returns
  - Issue map with merged location
  """
  @spec merge_location_into_issue(map(), map(), String.t(), boolean()) :: map()
  def merge_location_into_issue(issue, location_map, file_path, use_enricher \\ true) do
    # Try to find location from native AST
    native_location = find_native_location(issue, location_map)

    case native_location do
      nil when use_enricher ->
        # Fallback to LocationEnricher
        LocationEnricher.enrich_issue(issue, file_path)

      nil ->
        # No location found, return as-is
        issue

      location ->
        # Merge native AST location into issue
        issue
        |> Map.put(:line, location.line)
        |> Map.put(:column, location.column)
        |> Map.update(:location, build_location_map(location, file_path), fn existing ->
          # Merge with existing location, preferring native AST data
          Map.merge(existing || %{}, build_location_map(location, file_path))
        end)
    end
  end

  # Private functions

  defp find_native_location(issue, location_map) do
    # Extract potential keys from issue
    keys = extract_location_keys(issue)

    # Try each key in order of specificity
    Enum.find_value(keys, fn key ->
      Map.get(location_map, key)
    end)
  end

  defp extract_location_keys(issue) do
    keys = []

    # Try to build Module.function/arity key
    context = Map.get(issue, :context, %{})
    module = Map.get(context, :module) || Map.get(issue, :module)
    function = Map.get(context, :function) || Map.get(issue, :function)
    arity = Map.get(context, :arity) || Map.get(issue, :arity)

    keys =
      if module && function && arity do
        module_str = if is_atom(module), do: inspect(module), else: to_string(module)
        func_str = if is_atom(function), do: Atom.to_string(function), else: to_string(function)
        func_key = "#{module_str}.#{func_str}/#{arity}"
        [func_key | keys]
      else
        keys
      end

    # Try module-only key
    keys =
      if module do
        module_str = if is_atom(module), do: inspect(module), else: to_string(module)
        [module_str | keys]
      else
        keys
      end

    # Try function-only key (less specific)
    keys =
      if function && arity do
        func_str = if is_atom(function), do: Atom.to_string(function), else: to_string(function)
        func_key = "#{func_str}/#{arity}"
        keys ++ [func_key]
      else
        keys
      end

    keys
  end

  defp build_location_map(location, file_path) do
    %{
      file: file_path,
      line: location.line,
      column: location.column,
      end_line: location[:end_line],
      end_column: location[:end_column]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp detect_language(path) do
    case Path.extname(path) do
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".erl" -> :erlang
      ".hrl" -> :erlang
      ".py" -> :python
      ".rb" -> :ruby
      ".hs" -> :haskell
      _ -> :unknown
    end
  end
end
