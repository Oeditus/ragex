defmodule Ragex.Retrieval.QueryExpansion do
  @moduledoc """
  Query expansion using MetaAST semantic features.

  Enhances search queries by:
  - Extracting semantic features from results
  - Adding cross-language synonyms
  - Expanding with related constructs
  - Building semantic context

  ## Examples

      # Basic expansion
      QueryExpansion.expand("find map function")
      # => "find map function collection transform iterate"

      # Context-aware expansion
      QueryExpansion.expand("debug error", intent: :debug)
      # => "debug error exception failure bug issue problem"
  """

  alias Ragex.Retrieval.MetaASTRanker

  @doc """
  Expand a query string with semantic features and synonyms.

  ## Options

  - `:intent` - Query intent (`:explain`, `:refactor`, `:example`, `:debug`) (default: auto-detect)
  - `:include_synonyms` - Include semantic synonyms (default: true)
  - `:include_cross_language` - Include cross-language terms (default: true)
  - `:max_terms` - Maximum expansion terms to add (default: 5)

  ## Examples

      QueryExpansion.expand("map over list")
      # => "map over list collection iterate transform apply"

      QueryExpansion.expand("fix bug", intent: :debug)
      # => "fix bug error exception failure issue problem"
  """
  @spec expand(String.t(), keyword()) :: String.t()
  def expand(query, opts \\ []) when is_binary(query) do
    intent = Keyword.get(opts, :intent)
    include_synonyms = Keyword.get(opts, :include_synonyms, true)
    include_cross_language = Keyword.get(opts, :include_cross_language, true)
    max_terms = Keyword.get(opts, :max_terms, 5)

    # Detect intent if not provided
    detected_intent = intent || detect_intent(query)

    # Extract base terms
    base_terms = extract_terms(query)

    # Build expansion
    expanded_terms =
      []
      |> maybe_add_intent_terms(detected_intent, include_synonyms)
      |> maybe_add_construct_synonyms(base_terms, include_synonyms)
      |> maybe_add_cross_language_terms(base_terms, include_cross_language)
      |> Enum.take(max_terms)
      |> Enum.uniq()

    # Combine original query with expansions
    ([query] ++ expanded_terms)
    |> Enum.join(" ")
    |> String.trim()
  end

  @doc """
  Extract semantic features from query results to enhance future queries.

  Analyzes MetaAST metadata from results to build a semantic feature set
  that can be used for query refinement.

  ## Examples

      results = [%{meta_ast: {:collection_op, :map, ...}}, ...]

      QueryExpansion.extract_features_from_results(results)
      # => ["collection", "map", "transform", "iteration", "apply"]
  """
  @spec extract_features_from_results([map()]) :: [String.t()]
  def extract_features_from_results(results) when is_list(results) do
    results
    |> Enum.flat_map(&MetaASTRanker.extract_semantic_features/1)
    |> Enum.uniq()
    |> Enum.take(20)
  end

  @doc """
  Build an enriched query from original query + result features.

  Useful for iterative search refinement.

  ## Examples

      results = [...]  # Initial search results
      features = QueryExpansion.extract_features_from_results(results)

      QueryExpansion.enrich_query("map function", features, max_features: 3)
      # => "map function collection transform iterate"
  """
  @spec enrich_query(String.t(), [String.t()], keyword()) :: String.t()
  def enrich_query(query, features, opts \\ []) when is_binary(query) and is_list(features) do
    max_features = Keyword.get(opts, :max_features, 5)

    # Filter out features already in query
    query_lower = String.downcase(query)

    new_features =
      features
      |> Enum.reject(fn feature ->
        String.contains?(query_lower, String.downcase(feature))
      end)
      |> Enum.take(max_features)

    ([query] ++ new_features)
    |> Enum.join(" ")
    |> String.trim()
  end

  @doc """
  Suggest query variations based on semantic analysis.

  Returns alternative phrasings that might yield better results.

  ## Examples

      QueryExpansion.suggest_variations("find map")
      # => [
      #   "find map function",
      #   "find transform operation",
      #   "find collection map",
      #   "find iterate apply"
      # ]
  """
  @spec suggest_variations(String.t(), keyword()) :: [String.t()]
  def suggest_variations(query, opts \\ []) when is_binary(query) do
    max_variations = Keyword.get(opts, :max_variations, 4)

    base_terms = extract_terms(query)
    constructs = identify_constructs(base_terms)

    # Take at least one variation from each construct type for fairness
    per_construct = max(1, div(max_variations, max(length(constructs), 1)))

    variations =
      constructs
      |> Enum.flat_map(fn construct ->
        get_construct_variations(construct, query)
        |> Enum.take(per_construct)
      end)
      |> Enum.uniq()
      |> Enum.take(max_variations)

    variations
  end

  # Private functions

  defp detect_intent(query) do
    query_lower = String.downcase(query)

    cond do
      String.contains?(query_lower, ["explain", "how", "what", "understand", "learn"]) ->
        :explain

      String.contains?(query_lower, ["refactor", "improve", "optimize", "clean", "better"]) ->
        :refactor

      String.contains?(query_lower, ["example", "show", "demonstrate", "sample", "usage"]) ->
        :example

      String.contains?(query_lower, ["debug", "fix", "bug", "error", "issue", "problem"]) ->
        :debug

      true ->
        :general
    end
  end

  defp extract_terms(query) do
    query
    |> String.downcase()
    |> String.split(~r/\s+/)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_add_intent_terms(terms, :explain, true) do
    terms ++ ["simple", "clear", "understand", "basic", "example"]
  end

  defp maybe_add_intent_terms(terms, :refactor, true) do
    terms ++ ["improve", "optimize", "clean", "better", "pattern"]
  end

  defp maybe_add_intent_terms(terms, :example, true) do
    terms ++ ["sample", "usage", "demo", "code", "implementation"]
  end

  defp maybe_add_intent_terms(terms, :debug, true) do
    terms ++ ["error", "exception", "failure", "issue", "problem", "trace"]
  end

  defp maybe_add_intent_terms(terms, :general, true) do
    terms ++ ["function", "code", "implementation"]
  end

  defp maybe_add_intent_terms(terms, _, false), do: terms

  defp maybe_add_construct_synonyms(terms, base_terms, true) do
    synonyms =
      base_terms
      |> Enum.flat_map(&get_construct_synonyms/1)
      |> Enum.uniq()

    terms ++ synonyms
  end

  defp maybe_add_construct_synonyms(terms, _base_terms, false), do: terms

  defp maybe_add_cross_language_terms(terms, base_terms, true) do
    cross_lang_terms =
      base_terms
      |> Enum.flat_map(&get_cross_language_terms/1)
      |> Enum.uniq()

    terms ++ cross_lang_terms
  end

  defp maybe_add_cross_language_terms(terms, _base_terms, false), do: terms

  defp get_construct_synonyms(term) do
    case term do
      # Collection operations
      "map" -> ["transform", "apply", "convert", "iterate"]
      "filter" -> ["select", "where", "predicate", "choose"]
      "reduce" -> ["fold", "accumulate", "aggregate", "combine"]
      "foreach" -> ["each", "iterate", "loop", "apply"]
      "find" -> ["search", "locate", "detect", "discover"]
      # Control flow
      "loop" -> ["iterate", "repeat", "cycle", "while"]
      "if" -> ["conditional", "branch", "choice", "switch"]
      "match" -> ["pattern", "case", "switch", "destructure"]
      # Functions
      "function" -> ["method", "procedure", "routine", "callable"]
      "lambda" -> ["anonymous", "closure", "arrow", "inline"]
      "pure" -> ["immutable", "referential", "deterministic", "safe"]
      # Data structures
      "list" -> ["array", "collection", "sequence", "vector"]
      "dict" -> ["map", "hash", "object", "table"]
      "tuple" -> ["pair", "record", "struct"]
      # Operations
      "sort" -> ["order", "arrange", "rank", "organize"]
      "reverse" -> ["flip", "invert", "backward"]
      "concat" -> ["join", "merge", "combine", "append"]
      # Debugging
      "error" -> ["exception", "failure", "problem", "issue"]
      "debug" -> ["trace", "inspect", "diagnose", "troubleshoot"]
      "fix" -> ["repair", "correct", "resolve", "patch"]
      _ -> []
    end
  end

  defp get_cross_language_terms(term) do
    case term do
      # Python → Other languages
      "comprehension" -> ["map", "filter", "select", "transform"]
      "dict" -> ["map", "hash", "object", "table"]
      # JavaScript → Other languages
      "arrow" -> ["lambda", "anonymous", "closure"]
      "promise" -> ["future", "async", "deferred", "task"]
      # Elixir → Other languages
      "pipe" -> ["chain", "compose", "flow", "thread"]
      "enum" -> ["collection", "iterable", "sequence"]
      # Erlang → Other languages
      "process" -> ["actor", "thread", "task", "worker"]
      "gen_server" -> ["server", "service", "handler"]
      _ -> []
    end
  end

  defp identify_constructs(terms) do
    terms
    |> Enum.map(&identify_construct/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp identify_construct(term) do
    cond do
      term in ["map", "filter", "reduce", "foreach", "find"] -> {:collection_op, term}
      term in ["loop", "while", "for", "foreach"] -> {:loop, term}
      term in ["lambda", "arrow", "anonymous", "closure"] -> {:lambda, term}
      term in ["match", "pattern", "case", "switch"] -> {:pattern_match, term}
      term in ["if", "conditional", "branch"] -> {:conditional, term}
      term in ["function", "method", "procedure"] -> {:function, term}
      true -> nil
    end
  end

  defp get_construct_variations({:collection_op, _op}, query) do
    [
      query <> " collection",
      query <> " transform",
      query <> " iterate",
      "#{query} over items"
    ]
  end

  defp get_construct_variations({:loop, _type}, query) do
    [
      query <> " iteration",
      query <> " repeat",
      "#{query} over collection"
    ]
  end

  defp get_construct_variations({:lambda, _}, query) do
    [
      query <> " anonymous function",
      query <> " closure",
      "#{query} inline function"
    ]
  end

  defp get_construct_variations({:pattern_match, _}, query) do
    [
      query <> " destructure",
      query <> " case analysis",
      "#{query} pattern matching"
    ]
  end

  defp get_construct_variations({:conditional, _}, query) do
    [
      query <> " branch",
      query <> " decision",
      "#{query} control flow"
    ]
  end

  defp get_construct_variations({:function, _}, query) do
    [
      query <> " implementation",
      query <> " definition",
      "#{query} method"
    ]
  end

  defp get_construct_variations(_, _query), do: []
end
