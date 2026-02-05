defmodule Ragex.Analyzers.Metastatic do
  @moduledoc """
  Analyzer implementation using Metastatic MetaAST library.

  Provides richer semantic analysis compared to native regex-based parsers:
  - Cross-language semantic equivalence
  - Purity analysis (detects side effects like I/O operations)
  - Comprehensive complexity metrics:
    - Cyclomatic complexity (McCabe metric)
    - Cognitive complexity (structural complexity with nesting penalties)
    - Maximum nesting depth
    - Enhanced Halstead metrics (volume, difficulty, effort)
    - Detailed LoC (physical, logical, comments, blank)
    - Function-level metrics (statements, returns, variables, parameters)
  - Three-layer MetaAST (M2.1/M2.2/M2.3)

  ## Hybrid Approach

  This analyzer uses a hybrid strategy:
  1. Parse source code with Metastatic to get MetaAST representation
  2. Use native language analyzers for detailed entity extraction (modules, functions, calls)
  3. Enrich function metadata with metrics calculated from MetaAST

  This combines the strengths of both approaches:
  - Native analyzers provide complete, language-specific entity extraction
  - Metastatic provides cross-language semantic analysis and quality metrics

  ## Enrichment

  Each function in the analysis result is enriched with a `:metastatic` key in its metadata:

      %{
        metastatic: %{
          cyclomatic: 3,
          cognitive: 2,
          max_nesting: 1,
          halstead: %{volume: 50.0, difficulty: 2.5, effort: 125.0, ...},
          loc: %{physical: 10, logical: 8, comments: 2, blank: 0},
          function_metrics: %{statement_count: 8, return_points: 1, variable_count: 3}
        }
      }

  ## Fallback Behavior

  If Metastatic parsing fails, the analyzer falls back to native analyzers
  (if `:fallback_to_native_analyzers` feature flag is enabled). This ensures
  robustness even when encountering code that Metastatic cannot parse.
  """

  @behaviour Ragex.Analyzers.Behaviour

  require Logger
  alias Metastatic.{Analysis.Complexity, Builder, Document}

  alias Ragex.Analyzers.Elixir, as: ExAnalyzer
  alias Ragex.Analyzers.Erlang, as: ErlAnalyzer
  alias Ragex.Analyzers.Python, as: PyAnalyzer

  @impl true
  def analyze(source, file_path) do
    language = detect_language(file_path)

    case Builder.from_source(source, language) do
      {:ok, doc} ->
        # For now, use native analyzer but enrich with Metastatic data
        # This gives us immediate functionality while we build out full MetaAST extraction
        analyze_with_enrichment(source, file_path, language, doc)

      {:error, reason} ->
        Logger.warning(
          "Metastatic parsing failed for #{file_path}: #{inspect(reason)}. " <>
            "Falling back to native analyzer."
        )

        fallback_analyze(source, file_path, language)
    end
  end

  @impl true
  def supported_extensions do
    # Metastatic supports these languages
    [".ex", ".exs", ".erl", ".hrl", ".py", ".rb"]
  end

  # Private

  defp detect_language(file_path) do
    case Metastatic.Adapter.detect_language(file_path) do
      {:ok, lang} -> lang
      {:error, _} -> :unknown
    end
  end

  defp analyze_with_enrichment(source, file_path, language, %Document{} = doc) do
    # Get base analysis from native analyzer
    case fallback_analyze(source, file_path, language) do
      {:ok, analysis} ->
        # Enrich with Metastatic data
        {:ok, enrich_analysis(analysis, doc)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enrich_analysis(analysis, %Document{ast: meta_ast, metadata: metadata}) do
    # Add MetaAST information to the analysis
    analysis
    |> Map.put(:meta_ast, meta_ast)
    |> Map.put(:meta_ast_metadata, metadata)
    |> enrich_functions_with_metastatic(meta_ast)
  end

  defp enrich_functions_with_metastatic(analysis, meta_ast) do
    # Extract function-level metrics from MetaAST
    # Returns a map of function_name (atom) => {body, metadata}
    function_data = extract_function_data(meta_ast)

    # Enrich each function with corresponding MetaAST data
    enriched_functions =
      Enum.map(analysis.functions, fn func ->
        # Match function by name (arity comes from native analyzer)
        case Map.get(function_data, func.name) do
          nil ->
            # No MetaAST data available for this function
            func

          {body, _meta} ->
            # Calculate comprehensive metrics from MetaAST body
            metrics = calculate_function_metrics(body)

            # Merge MetaAST metrics into function metadata
            metadata =
              Map.merge(func.metadata, %{
                metastatic: metrics
              })

            %{func | metadata: metadata}
        end
      end)

    %{analysis | functions: enriched_functions}
  end

  defp extract_function_data(meta_ast) do
    # Walk the MetaAST and extract function data
    # Returns a map of function_name (atom) => {body, metadata}

    meta_ast
    |> extract_all_functions()
    |> Map.new()
  end

  defp extract_all_functions(ast, acc \\ []) do
    # Extract all function definitions from the MetaAST
    # New 3-tuple format: {:function_def, [name: ..., params: ..., visibility: ...], body}
    # Returns list of {function_name_atom, {body, metadata}} tuples

    case ast do
      # Match new 3-tuple function definitions
      {:function_def, meta, body} when is_list(meta) ->
        # Extract function name from metadata keyword list
        case Keyword.get(meta, :name) do
          name when is_binary(name) ->
            # Convert string name to atom
            func_name = String.to_atom(name)
            # Build metadata map from keyword list
            metadata = %{
              function_name: name,
              params: Keyword.get(meta, :params, []),
              visibility: Keyword.get(meta, :visibility, :public),
              body: body
            }

            [{func_name, {body, metadata}} | acc]

          _ ->
            acc
        end

      # Match container nodes (modules) and traverse their body
      {:container, _meta, body} when is_list(body) ->
        Enum.reduce(body, acc, &extract_all_functions/2)

      # Match block nodes
      {:block, _meta, statements} when is_list(statements) ->
        Enum.reduce(statements, acc, &extract_all_functions/2)

      # Recursively traverse any 3-tuple with list children
      {_type, _meta, children} when is_list(children) ->
        Enum.reduce(children, acc, &extract_all_functions/2)

      # Recursively traverse lists
      list when is_list(list) ->
        Enum.reduce(list, acc, &extract_all_functions/2)

      # Skip other nodes (literals, variables, etc.)
      _ ->
        acc
    end
  end

  defp calculate_function_metrics(ast_node) do
    # Calculate comprehensive metrics using Metastatic.Analysis.Complexity
    # Create a document for this function's AST
    doc = Document.new(ast_node, :elixir)

    case Complexity.analyze(doc) do
      {:ok, complexity} ->
        %{
          cyclomatic: complexity.cyclomatic,
          cognitive: complexity.cognitive,
          max_nesting: complexity.max_nesting,
          halstead: complexity.halstead,
          loc: complexity.loc,
          function_metrics: complexity.function_metrics
        }

      {:error, _reason} ->
        # Fallback to basic metrics if analysis fails
        %{
          cyclomatic: 1,
          cognitive: 0,
          max_nesting: 0,
          halstead: %{},
          loc: %{},
          function_metrics: %{}
        }
    end
  end

  defp fallback_analyze(source, file_path, language) do
    # Fall back to native analyzers if feature flag is enabled
    if Application.get_env(:ragex, :features)[:fallback_to_native_analyzers] do
      case language do
        :elixir -> ExAnalyzer.analyze(source, file_path)
        :erlang -> ErlAnalyzer.analyze(source, file_path)
        :python -> PyAnalyzer.analyze(source, file_path)
        _ -> {:error, :no_fallback_analyzer}
      end
    else
      {:error, :metastatic_failed_no_fallback}
    end
  end
end
