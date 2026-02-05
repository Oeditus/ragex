defmodule Ragex.Retrieval.MetaASTRanker do
  @moduledoc """
  Enhances retrieval ranking using MetaAST metadata from Metastatic.

  Provides ranking boosts based on semantic properties extracted from MetaAST:
  - Purity analysis (pure functions rank higher for query contexts)
  - Complexity metrics (simpler code ranks higher for explanations)
  - Cross-language semantic equivalence
  - Meta-level properties (M2.1 core vs M2.3 native)

  ## MetaAST Levels

  - **M2.1 Core**: Universal constructs (literals, variables, binary_op, etc.)
  - **M2.2 Extended**: Common patterns (loops, lambdas, collections)
  - **M2.3 Native**: Language-specific escape hatches

  ## Ranking Strategy

  Higher scores are given to:
  1. Core-level constructs (more portable/understandable)
  2. Pure functions (no side effects)
  3. Lower complexity (easier to understand)
  4. Cross-language semantic matches
  """

  require Logger

  @doc """
  Calculate MetaAST-based ranking boost for a retrieval result.

  Returns a boost multiplier (1.0 = no boost, >1.0 = boost, <1.0 = penalty).

  ## Options

  - `:boost_core` - Boost for M2.1 core constructs (default: 1.2)
  - `:boost_pure` - Boost for pure functions (default: 1.3)
  - `:complexity_penalty` - Penalty per complexity unit (default: 0.02)
  - `:native_penalty` - Penalty for M2.3 native constructs (default: 0.9)
  """
  @spec calculate_boost(map(), keyword()) :: float()
  def calculate_boost(result, opts \\ []) do
    # Get configuration
    boost_core = Keyword.get(opts, :boost_core, 1.2)
    boost_pure = Keyword.get(opts, :boost_pure, 1.3)
    complexity_penalty = Keyword.get(opts, :complexity_penalty, 0.02)
    native_penalty = Keyword.get(opts, :native_penalty, 0.9)

    # Extract MetaAST metadata if available
    case get_meta_ast_metadata(result) do
      nil ->
        1.0

      meta_ast_metadata ->
        boost = 1.0

        # Boost for core-level constructs
        boost =
          case get_meta_level(meta_ast_metadata) do
            :core -> boost * boost_core
            :extended -> boost * 1.1
            :native -> boost * native_penalty
            _ -> boost
          end

        # Boost for pure functions
        boost =
          if pure_function?(meta_ast_metadata) do
            boost * boost_pure
          else
            boost
          end

        # Penalty for complexity
        complexity = get_complexity(meta_ast_metadata)

        boost =
          if complexity > 0 do
            # Reduce boost based on complexity (max penalty: 50%)
            penalty = min(complexity * complexity_penalty, 0.5)
            boost * (1.0 - penalty)
          else
            boost
          end

        boost
    end
  end

  @doc """
  Apply context-aware MetaAST ranking boosts to retrieval results.

  Analyzes query context to apply appropriate ranking strategies:
  - **Explanation queries**: Prefer simple, pure, core-level code
  - **Refactoring queries**: Prefer code with improvement opportunities
  - **Example queries**: Prefer diverse, cross-language examples
  - **Debugging queries**: Prefer code with side effects/complexity

  ## Options

  - `:query` - The original query string for context detection
  - `:intent` - Explicitly specify intent (`:explain`, `:refactor`, `:example`, `:debug`)
  - All options from `calculate_boost/2`

  ## Examples

      results = [...]

      # Auto-detect intent from query
      MetaASTRanker.apply_ranking(results, query: "explain how map works")

      # Explicit intent
      MetaASTRanker.apply_ranking(results, intent: :refactor)
  """
  @spec apply_ranking([map()], keyword()) :: [map()]
  def apply_ranking(results, opts \\ []) do
    query = Keyword.get(opts, :query)
    intent = Keyword.get(opts, :intent) || detect_intent(query)

    # Adjust boost options based on intent
    boost_opts = adjust_boosts_for_intent(intent, opts)

    results
    |> Enum.map(fn result ->
      boost = calculate_boost(result, boost_opts)
      original_score = result[:score] || 0.0
      boosted_score = original_score * boost

      result
      |> Map.put(:boosted_score, Float.round(boosted_score, 4))
      |> Map.put(:metaast_boost, Float.round(boost, 4))
      |> Map.put(:ranking_intent, intent)
    end)
    |> Enum.sort_by(fn result -> result[:boosted_score] || result[:score] || 0.0 end, :desc)
  end

  @doc """
  Check if two results represent semantically equivalent constructs.

  Uses MetaAST comparison to identify cross-language equivalents.

  ## Examples

      # Python list comprehension and Elixir Enum.map are equivalent at M2 level
      result1 = %{meta_ast: {:collection_op, :map, ...}, language: :python}
      result2 = %{meta_ast: {:collection_op, :map, ...}, language: :elixir}

      MetaASTRanker.semantically_equivalent?(result1, result2)
      # => true
  """
  @spec semantically_equivalent?(map(), map()) :: boolean()
  def semantically_equivalent?(result1, result2) do
    ast1 = get_meta_ast(result1)
    ast2 = get_meta_ast(result2)

    case {ast1, ast2} do
      {nil, _} -> false
      {_, nil} -> false
      {a1, a2} -> asts_equivalent?(a1, a2)
    end
  end

  @doc """
  Extract semantic features from MetaAST for query expansion.

  Returns a list of semantic tags that can be used for query expansion.

  ## Examples

      result = %{meta_ast: {:collection_op, :map, fn, collection}}

      MetaASTRanker.extract_semantic_features(result)
      # => ["collection", "map", "transform", "iteration"]
  """
  @spec extract_semantic_features(map()) :: [String.t()]
  def extract_semantic_features(result) do
    ast = get_meta_ast(result)

    if ast do
      extract_features_from_ast(ast)
    else
      []
    end
  end

  @doc """
  Find cross-language equivalents for a given result.

  Returns results that have semantically equivalent MetaAST structures
  but are from different languages.

  ## Examples

      python_map = %{meta_ast: {:collection_op, :map, ...}, language: :python}
      all_results = [python_map, elixir_map, javascript_map, ...]

      MetaASTRanker.find_cross_language_equivalents(python_map, all_results)
      # => [elixir_map, javascript_map]
  """
  @spec find_cross_language_equivalents(map(), [map()]) :: [map()]
  def find_cross_language_equivalents(target_result, all_results) do
    target_language = Map.get(target_result, :language)

    all_results
    |> Enum.filter(fn result ->
      # Different language but semantically equivalent
      result_language = Map.get(result, :language)

      result_language != target_language and
        semantically_equivalent?(target_result, result)
    end)
  end

  # Private helpers

  # Query intent detection
  defp detect_intent(nil), do: :general

  defp detect_intent(query) when is_binary(query) do
    query_lower = String.downcase(query)

    cond do
      String.contains?(query_lower, ["explain", "how does", "what is", "understand"]) ->
        :explain

      String.contains?(query_lower, ["refactor", "improve", "optimize", "clean"]) ->
        :refactor

      String.contains?(query_lower, ["example", "show me", "demonstrate", "sample"]) ->
        :example

      String.contains?(query_lower, ["debug", "fix", "bug", "error", "issue"]) ->
        :debug

      true ->
        :general
    end
  end

  defp detect_intent(_), do: :general

  # Adjust boost parameters based on query intent
  defp adjust_boosts_for_intent(:explain, opts) do
    # Explanations: prefer simple, pure, core-level code
    opts
    |> Keyword.put_new(:boost_core, 1.5)
    |> Keyword.put_new(:boost_pure, 1.4)
    |> Keyword.put_new(:complexity_penalty, 0.03)
    |> Keyword.put_new(:native_penalty, 0.8)
  end

  defp adjust_boosts_for_intent(:refactor, opts) do
    # Refactoring: prefer code with improvement opportunities (complex, impure)
    opts
    |> Keyword.put_new(:boost_core, 1.0)
    |> Keyword.put_new(:boost_pure, 0.8)
    |> Keyword.put_new(:complexity_penalty, -0.01)
    |> Keyword.put_new(:native_penalty, 1.2)
  end

  defp adjust_boosts_for_intent(:example, opts) do
    # Examples: prefer diverse, cross-language, moderate complexity
    opts
    |> Keyword.put_new(:boost_core, 1.3)
    |> Keyword.put_new(:boost_pure, 1.1)
    |> Keyword.put_new(:complexity_penalty, 0.01)
    |> Keyword.put_new(:native_penalty, 1.1)
  end

  defp adjust_boosts_for_intent(:debug, opts) do
    # Debugging: prefer code with side effects and complexity
    opts
    |> Keyword.put_new(:boost_core, 0.9)
    |> Keyword.put_new(:boost_pure, 0.7)
    |> Keyword.put_new(:complexity_penalty, -0.02)
    |> Keyword.put_new(:native_penalty, 1.3)
  end

  defp adjust_boosts_for_intent(:general, opts) do
    # General: use default balanced settings
    opts
    |> Keyword.put_new(:boost_core, 1.2)
    |> Keyword.put_new(:boost_pure, 1.3)
    |> Keyword.put_new(:complexity_penalty, 0.02)
    |> Keyword.put_new(:native_penalty, 0.9)
  end

  defp adjust_boosts_for_intent(_, opts), do: adjust_boosts_for_intent(:general, opts)

  defp get_meta_ast_metadata(%{meta_ast_metadata: metadata}) when is_map(metadata),
    do: metadata

  defp get_meta_ast_metadata(_), do: nil

  defp get_meta_ast(%{meta_ast: ast}), do: ast
  defp get_meta_ast(_), do: nil

  defp get_meta_level(%{level: level}), do: level
  defp get_meta_level(%{native_constructs: count}) when count > 0, do: :native
  defp get_meta_level(_), do: :core

  defp pure_function?(%{purity: :pure}), do: true
  defp pure_function?(%{side_effects: false}), do: true
  defp pure_function?(_), do: false

  defp get_complexity(%{complexity: complexity}) when is_number(complexity), do: complexity
  defp get_complexity(%{depth: depth}) when is_number(depth), do: depth
  defp get_complexity(_), do: 0

  # AST equivalence checking for new 3-tuple format: {type, meta, children}
  defp asts_equivalent?(ast1, ast2) when is_tuple(ast1) and is_tuple(ast2) do
    case {tuple_size(ast1), tuple_size(ast2)} do
      # Both are 3-tuples (new MetaAST format)
      {3, 3} ->
        {type1, meta1, children1} = ast1
        {type2, meta2, children2} = ast2

        # Same type and same metadata (including op_type, loop_type, etc.)
        type1 == type2 and meta1 == meta2 and children1 == children2

      # Same size tuples - compare directly
      {n, n} ->
        ast1 == ast2

      # Different sizes - not equivalent
      _ ->
        false
    end
  end

  defp asts_equivalent?(ast1, ast2), do: ast1 == ast2

  # Feature extraction from AST (new 3-tuple format)
  # Format: {type, keyword_meta, children_or_value}
  defp extract_features_from_ast({:collection_op, meta, _children}) when is_list(meta) do
    base = ["collection", "iteration", "transform"]
    op = Keyword.get(meta, :op_type)

    op_features =
      case op do
        :map -> ["map", "transform", "apply"]
        :filter -> ["filter", "select", "predicate"]
        :reduce -> ["reduce", "fold", "accumulate", "aggregate"]
        :find -> ["find", "search", "locate"]
        _ -> []
      end

    base ++ op_features
  end

  defp extract_features_from_ast({:loop, meta, _children}) when is_list(meta) do
    base = ["loop", "iteration", "repeat"]
    loop_type = Keyword.get(meta, :loop_type)

    type_features =
      case loop_type do
        :while -> ["while", "conditional"]
        :for -> ["for", "iterate"]
        :for_each -> ["foreach", "each", "iterate"]
        _ -> []
      end

    base ++ type_features
  end

  defp extract_features_from_ast({:lambda, _meta, _body}) do
    ["lambda", "function", "closure", "anonymous"]
  end

  defp extract_features_from_ast({:pattern_match, _meta, _children}) do
    ["pattern", "match", "destructure", "case"]
  end

  defp extract_features_from_ast({:binary_op, meta, _children}) when is_list(meta) do
    category = Keyword.get(meta, :category)
    operator = Keyword.get(meta, :operator)

    case category do
      :arithmetic -> ["arithmetic", "calculation", "math", atom_to_string(operator)]
      :comparison -> ["comparison", "predicate", "test", atom_to_string(operator)]
      :boolean -> ["boolean", "logic", atom_to_string(operator)]
      _ -> ["operation", atom_to_string(operator)]
    end
  end

  defp extract_features_from_ast({:function_call, meta, _args}) when is_list(meta) do
    fn_name = Keyword.get(meta, :name, "unknown")
    ["call", "invoke", "function", to_string(fn_name)]
  end

  defp extract_features_from_ast({:conditional, _meta, _children}) do
    ["conditional", "branch", "if", "choice"]
  end

  defp extract_features_from_ast({:function_def, meta, _body}) when is_list(meta) do
    name = Keyword.get(meta, :name, "unknown")
    ["function", "definition", "def", to_string(name)]
  end

  defp extract_features_from_ast({:container, meta, _body}) when is_list(meta) do
    container_type = Keyword.get(meta, :container_type)
    name = Keyword.get(meta, :name, "unknown")

    type_features =
      case container_type do
        :module -> ["module"]
        :class -> ["class", "oop"]
        :namespace -> ["namespace"]
        _ -> []
      end

    ["container", to_string(name)] ++ type_features
  end

  defp extract_features_from_ast(_ast) do
    # Default features for unrecognized constructs
    ["code", "construct"]
  end

  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp atom_to_string(other), do: to_string(other)
end
