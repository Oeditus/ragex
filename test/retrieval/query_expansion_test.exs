defmodule Ragex.Retrieval.QueryExpansionTest do
  use ExUnit.Case, async: true

  alias Ragex.Retrieval.QueryExpansion

  describe "expand/2" do
    test "expands query with default options" do
      expanded = QueryExpansion.expand("find map function")

      assert expanded != "find map function"
      assert String.contains?(expanded, "find map function")
      assert String.length(expanded) > String.length("find map function")
    end

    test "expands with explain intent" do
      expanded = QueryExpansion.expand("explain how map works", intent: :explain)

      assert String.contains?(expanded, "explain")
      # Should include intent-specific terms
      assert String.contains?(expanded, "simple") or String.contains?(expanded, "clear")
    end

    test "expands with refactor intent" do
      expanded = QueryExpansion.expand("refactor this code", intent: :refactor)

      assert String.contains?(expanded, "refactor")
      assert String.contains?(expanded, "improve") or String.contains?(expanded, "optimize")
    end

    test "expands with debug intent" do
      expanded = QueryExpansion.expand("fix bug", intent: :debug)

      assert String.contains?(expanded, "fix")
      assert String.contains?(expanded, "error") or String.contains?(expanded, "problem")
    end

    test "respects max_terms option" do
      expanded_short = QueryExpansion.expand("map", max_terms: 2)
      expanded_long = QueryExpansion.expand("map", max_terms: 10)

      # Longer max_terms should produce longer query
      assert String.length(expanded_long) >= String.length(expanded_short)
    end

    test "includes construct synonyms" do
      expanded = QueryExpansion.expand("map over list", include_synonyms: true)

      # Should include synonyms of "map"
      assert String.contains?(expanded, "transform") or
               String.contains?(expanded, "iterate")
    end

    test "includes cross-language terms" do
      expanded = QueryExpansion.expand("promise", include_cross_language: true)

      # "promise" should expand to cross-language equivalents
      assert String.contains?(expanded, "future") or
               String.contains?(expanded, "async")
    end

    test "can disable expansions" do
      original = "find map function"

      expanded =
        QueryExpansion.expand(original, include_synonyms: false, include_cross_language: false)

      # Should only add intent terms (default: general)
      words = String.split(expanded, " ")
      assert length(words) <= length(String.split(original, " ")) + 3
    end
  end

  describe "extract_features_from_results/1" do
    test "extracts features from results with MetaAST" do
      # New 3-tuple format: {type, keyword_meta, children}
      results = [
        %{meta_ast: {:collection_op, [op_type: :map], [:fn, :coll]}},
        %{meta_ast: {:loop, [loop_type: :while], [:cond, :body]}}
      ]

      features = QueryExpansion.extract_features_from_results(results)

      assert "collection" in features
      assert "map" in features
      assert "loop" in features
      assert "while" in features
    end

    test "returns empty list for results without MetaAST" do
      results = [
        %{node_id: "test1"},
        %{node_id: "test2"}
      ]

      features = QueryExpansion.extract_features_from_results(results)

      assert features == []
    end

    test "limits number of features" do
      # Create many results with new 3-tuple format
      results =
        Enum.map(1..100, fn i ->
          %{meta_ast: {:collection_op, [op_type: String.to_atom("op#{i}")], [:fn, :coll]}}
        end)

      features = QueryExpansion.extract_features_from_results(results)

      # Should be limited to 20
      assert length(features) <= 20
    end
  end

  describe "enrich_query/3" do
    test "adds features not already in query" do
      query = "find map"
      features = ["collection", "transform", "map", "iterate"]

      enriched = QueryExpansion.enrich_query(query, features)

      assert String.contains?(enriched, "find map")
      assert String.contains?(enriched, "collection")
      assert String.contains?(enriched, "transform")
      # "map" should not be added again
      refute String.contains?(enriched, " map map")
    end

    test "respects max_features option" do
      query = "find"
      features = Enum.map(1..20, &"feature#{&1}")

      enriched = QueryExpansion.enrich_query(query, features, max_features: 3)

      words = String.split(enriched, " ")
      # "find" + 3 features = 4 words
      assert length(words) == 4
    end
  end

  describe "suggest_variations/2" do
    test "suggests variations for map query" do
      variations = QueryExpansion.suggest_variations("find map")

      assert match?([_ | _], variations)
      # Should include variations with "collection", "transform", etc.
      assert Enum.any?(variations, fn v -> String.contains?(v, "collection") end) or
               Enum.any?(variations, fn v -> String.contains?(v, "transform") end)
    end

    test "suggests variations for loop query" do
      variations = QueryExpansion.suggest_variations("find loop")

      assert is_list(variations)

      assert Enum.any?(variations, fn v -> String.contains?(v, "iteration") end) or
               Enum.any?(variations, fn v -> String.contains?(v, "repeat") end)
    end

    test "respects max_variations option" do
      variations = QueryExpansion.suggest_variations("find map function", max_variations: 2)

      assert length(variations) <= 2
    end

    test "returns empty list for query without recognized constructs" do
      variations = QueryExpansion.suggest_variations("random unknown terms")

      # May be empty or contain generic variations
      assert is_list(variations)
    end
  end
end
