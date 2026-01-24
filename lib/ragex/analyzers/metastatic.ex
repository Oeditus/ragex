defmodule Ragex.Analyzers.Metastatic do
  @moduledoc """
  Analyzer implementation using Metastatic MetaAST library.

  Provides richer semantic analysis compared to native regex-based parsers:
  - Cross-language semantic equivalence
  - Purity analysis (detects side effects like I/O operations)
  - Complexity metrics (cyclomatic complexity, decision points)
  - Halstead metrics (vocabulary, operators, operands)
  - Lines of code estimation
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
          complexity: %{cyclomatic: 3, decision_points: 2},
          purity: %{pure: false, side_effects: [:io_or_mutation]},
          halstead: %{unique_operators: 5, unique_operands: 3, vocabulary: 8},
          loc: %{expressions: 4, estimated: 4}
        }
      }

  ## Fallback Behavior

  If Metastatic parsing fails, the analyzer falls back to native analyzers
  (if `:fallback_to_native_analyzers` feature flag is enabled). This ensures
  robustness even when encountering code that Metastatic cannot parse.
  """

  @behaviour Ragex.Analyzers.Behaviour

  require Logger
  alias Metastatic.{Builder, Document}

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
            # Calculate metrics from MetaAST body
            metrics = calculate_function_metrics(body)
            
            # Merge MetaAST metrics into function metadata
            metadata = Map.merge(func.metadata, %{
              metastatic: %{
                complexity: metrics.complexity,
                purity: metrics.purity,
                halstead: metrics.halstead,
                loc: metrics.loc
              }
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
    # MetaAST uses :language_specific wrappers with metadata
    # Structure: {:language_specific, :elixir, native_ast, :function_definition, %{function_name: ..., body: ...}}
    # Returns list of {function_name_atom, {body, metadata}} tuples
    
    case ast do
      # Match language_specific function definitions
      {:language_specific, _lang, _native_ast, :function_definition, metadata} ->
        # Extract function name from metadata
        case Map.get(metadata, :function_name) do
          name when is_binary(name) ->
            # Convert string name to atom
            func_name = String.to_atom(name)
            # Get body from metadata
            body = Map.get(metadata, :body)
            [{func_name, {body, metadata}} | acc]
          
          _ ->
            acc
        end
      
      # Recursively traverse tuples
      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.reduce(acc, &extract_all_functions/2)
      
      # Recursively traverse lists
      list when is_list(list) ->
        Enum.reduce(list, acc, &extract_all_functions/2)
      
      # Recursively traverse maps (check metadata and body fields)
      %{} = map ->
        # Check if this map itself contains function data
        acc = case Map.get(map, :body) do
          {:language_specific, _, _, :function_definition, _} = func_def ->
            extract_all_functions(func_def, acc)
          _ ->
            acc
        end
        
        # Also traverse all map values
        map
        |> Map.values()
        |> Enum.reduce(acc, &extract_all_functions/2)
      
      # Skip other nodes
      _ ->
        acc
    end
  end
  
  defp calculate_function_metrics(ast_node) do
    # Calculate metrics for a single function's AST
    # These are basic metrics - more sophisticated analysis could be added
    
    %{
      complexity: calculate_complexity(ast_node),
      purity: analyze_purity(ast_node),
      halstead: calculate_halstead(ast_node),
      loc: calculate_loc(ast_node)
    }
  end
  
  defp calculate_complexity(ast) do
    # Calculate cyclomatic complexity by counting decision points
    # Start at 1, add 1 for each branching construct
    
    decision_points = count_decision_points(ast, 0)
    
    %{
      cyclomatic: 1 + decision_points,
      decision_points: decision_points
    }
  end
  
  defp count_decision_points(ast, count) do
    case ast do
      # Control flow constructs that add complexity
      {:if, _, _} -> count + 1
      {:case, _, _} -> count + 1
      {:cond, _, _} -> count + 1
      {:and, _, _} -> count + 1
      {:or, _, _} -> count + 1
      {:try, _, _} -> count + 1
      
      # Recursively count in nested structures
      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.reduce(count, &count_decision_points/2)
      
      list when is_list(list) ->
        Enum.reduce(list, count, &count_decision_points/2)
      
      _ ->
        count
    end
  end
  
  defp analyze_purity(ast) do
    # Simple purity analysis: check for side effects
    # A function is pure if it doesn't perform I/O or mutation
    
    has_side_effects = check_side_effects(ast)
    
    %{
      pure: not has_side_effects,
      side_effects: if(has_side_effects, do: [:io_or_mutation], else: [])
    }
  end
  
  defp check_side_effects(ast) do
    case ast do
      # I/O operations
      {:call, _, :IO, _func, _} -> true
      {:call, _, :File, _func, _} -> true
      {:call, _, :Logger, _func, _} -> true
      
      # Process operations (message passing)
      {:call, _, :send, _} -> true
      {:call, _, :receive, _} -> true
      
      # Recursively check nested structures
      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.any?(&check_side_effects/1)
      
      list when is_list(list) ->
        Enum.any?(list, &check_side_effects/1)
      
      _ ->
        false
    end
  end
  
  defp calculate_halstead(ast) do
    # Calculate basic Halstead metrics
    # operators: unique operations, operands: unique data
    
    operators = count_operators(ast, MapSet.new())
    operands = count_operands(ast, MapSet.new())
    
    n1 = MapSet.size(operators)  # unique operators
    n2 = MapSet.size(operands)   # unique operands
    
    %{
      unique_operators: n1,
      unique_operands: n2,
      vocabulary: n1 + n2
    }
  end
  
  defp count_operators(ast, acc) do
    case ast do
      # Binary operations
      {op, _, _, _} when op in [:+, :-, :*, :/, :==, :!=, :<, :>, :and, :or] ->
        MapSet.put(acc, op)
      
      # Function calls are operators
      {:call, _, _mod, func, _args} when is_atom(func) ->
        MapSet.put(acc, func)
      
      # Recursively process nested structures
      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.reduce(acc, &count_operators/2)
      
      list when is_list(list) ->
        Enum.reduce(list, acc, &count_operators/2)
      
      _ ->
        acc
    end
  end
  
  defp count_operands(ast, acc) do
    case ast do
      # Variables are operands
      {:variable, name} when is_binary(name) or is_atom(name) ->
        MapSet.put(acc, name)
      
      # Literals are operands
      {:literal, _type, value} ->
        MapSet.put(acc, value)
      
      # Recursively process nested structures
      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.reduce(acc, &count_operands/2)
      
      list when is_list(list) ->
        Enum.reduce(list, acc, &count_operands/2)
      
      _ ->
        acc
    end
  end
  
  defp calculate_loc(ast) do
    # Calculate lines of code (approximation from AST)
    # Count the number of expression nodes
    
    expressions = count_expressions(ast, 0)
    
    %{
      expressions: expressions,
      # Rough estimate: assume 1 expression per line on average
      estimated: max(expressions, 1)
    }
  end
  
  defp count_expressions(ast, count) do
    case ast do
      # Expression nodes
      {:call, _, _, _, _} -> count + 1
      {:if, _, _} -> count + 1
      {:case, _, _} -> count + 1
      {:assignment, _, _, _} -> count + 1
      
      # Recursively count in nested structures
      tuple when is_tuple(tuple) ->
        tuple
        |> Tuple.to_list()
        |> Enum.reduce(count, &count_expressions/2)
      
      list when is_list(list) ->
        Enum.reduce(list, count, &count_expressions/2)
      
      _ ->
        count
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
