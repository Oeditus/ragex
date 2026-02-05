defmodule Ragex.Retrieval.MetaASTRankerTest do
  use ExUnit.Case, async: true

  alias Ragex.Retrieval.MetaASTRanker

  describe "calculate_boost/2" do
    test "no boost for results without MetaAST metadata" do
      result = %{node_id: "test", score: 0.8}
      assert MetaASTRanker.calculate_boost(result) == 1.0
    end

    test "core-level constructs get boosted" do
      result = %{
        node_id: "test",
        score: 0.8,
        meta_ast_metadata: %{level: :core}
      }

      boost = MetaASTRanker.calculate_boost(result)
      assert boost == 1.2
    end

    test "pure functions get boosted" do
      result = %{
        node_id: "test",
        score: 0.8,
        meta_ast_metadata: %{purity: :pure}
      }

      boost = MetaASTRanker.calculate_boost(result)
      # 1.0 * 1.2 (default core level) * 1.3 (pure) = 1.56
      assert boost == 1.56
    end

    test "complex code gets penalized" do
      result = %{
        node_id: "test",
        score: 0.8,
        meta_ast_metadata: %{complexity: 10}
      }

      boost = MetaASTRanker.calculate_boost(result)
      # 1.0 * 1.2 (default core level) * (1.0 - (10 * 0.02)) = 1.2 * 0.8 = 0.96
      assert boost == 0.96
    end

    test "native constructs get penalized" do
      result = %{
        node_id: "test",
        score: 0.8,
        meta_ast_metadata: %{level: :native}
      }

      boost = MetaASTRanker.calculate_boost(result)
      assert boost == 0.9
    end

    test "combined effects: pure core function with low complexity" do
      result = %{
        node_id: "test",
        score: 0.8,
        meta_ast_metadata: %{
          level: :core,
          purity: :pure,
          complexity: 2
        }
      }

      boost = MetaASTRanker.calculate_boost(result)
      # 1.0 * 1.2 (core) * 1.3 (pure) * (1.0 - 0.04) = 1.4976
      assert_in_delta boost, 1.4976, 0.001
    end
  end

  describe "apply_ranking/2" do
    test "applies boosts and re-sorts results" do
      results = [
        %{node_id: "impure", score: 0.9, meta_ast_metadata: %{purity: :impure}},
        %{node_id: "pure", score: 0.8, meta_ast_metadata: %{purity: :pure}}
      ]

      ranked = MetaASTRanker.apply_ranking(results)

      # Pure function should rank higher despite lower base score
      assert [first, second] = ranked
      assert first.node_id == "pure"
      # 1.0 * 1.2 (default core level) * 1.3 (pure) = 1.56
      assert first[:metaast_boost] == 1.56
      assert first[:boosted_score] > second[:boosted_score]
    end

    test "handles results without MetaAST metadata" do
      results = [
        %{node_id: "test1", score: 0.9},
        %{node_id: "test2", score: 0.8}
      ]

      ranked = MetaASTRanker.apply_ranking(results)

      assert length(ranked) == 2
      assert Enum.all?(ranked, fn r -> r[:metaast_boost] == 1.0 end)
    end

    test "context-aware ranking with explain intent" do
      results = [
        %{node_id: "complex", score: 0.9, meta_ast_metadata: %{complexity: 10}},
        %{node_id: "simple", score: 0.8, meta_ast_metadata: %{complexity: 1}}
      ]

      ranked =
        MetaASTRanker.apply_ranking(results, query: "explain how this works", intent: :explain)

      # Simpler code should rank higher for explanations
      assert [first | _] = ranked
      assert first.node_id == "simple"
      assert first[:ranking_intent] == :explain
    end

    test "context-aware ranking with refactor intent" do
      results = [
        %{node_id: "pure_simple", score: 0.9, meta_ast_metadata: %{purity: :pure, complexity: 1}},
        %{
          node_id: "impure_complex",
          score: 0.8,
          meta_ast_metadata: %{purity: :impure, complexity: 10}
        }
      ]

      ranked = MetaASTRanker.apply_ranking(results, intent: :refactor)

      # Complex impure code should rank higher for refactoring
      assert [first | _] = ranked
      assert first.node_id == "impure_complex"
      assert first[:ranking_intent] == :refactor
    end
  end

  describe "semantically_equivalent?/2" do
    test "returns true for identical MetaAST structures" do
      # New 3-tuple format: {type, keyword_meta, children}
      result1 = %{meta_ast: {:collection_op, [op_type: :map], [:fn, :coll]}}
      result2 = %{meta_ast: {:collection_op, [op_type: :map], [:fn, :coll]}}

      assert MetaASTRanker.semantically_equivalent?(result1, result2)
    end

    test "returns false for different MetaAST structures" do
      result1 = %{meta_ast: {:collection_op, [op_type: :map], [:fn, :coll]}}
      result2 = %{meta_ast: {:collection_op, [op_type: :filter], [:fn, :coll]}}

      refute MetaASTRanker.semantically_equivalent?(result1, result2)
    end

    test "returns false when one result lacks MetaAST" do
      result1 = %{meta_ast: {:collection_op, [op_type: :map], [:fn, :coll]}}
      result2 = %{node_id: "test"}

      refute MetaASTRanker.semantically_equivalent?(result1, result2)
    end
  end

  describe "extract_semantic_features/1" do
    test "extracts features from collection operations" do
      # New 3-tuple format: {type, keyword_meta, children}
      result = %{meta_ast: {:collection_op, [op_type: :map], [:fn, :coll]}}

      features = MetaASTRanker.extract_semantic_features(result)

      assert "collection" in features
      assert "map" in features
      assert "transform" in features
    end

    test "extracts features from loop constructs" do
      # New 3-tuple format: {type, keyword_meta, children}
      result = %{meta_ast: {:loop, [loop_type: :while], [:cond, :body]}}

      features = MetaASTRanker.extract_semantic_features(result)

      assert "loop" in features
      assert "while" in features
      assert "iteration" in features
    end

    test "returns empty list for results without MetaAST" do
      result = %{node_id: "test"}

      features = MetaASTRanker.extract_semantic_features(result)

      assert features == []
    end
  end

  describe "find_cross_language_equivalents/2" do
    test "finds equivalent constructs in different languages" do
      # New 3-tuple format: {type, keyword_meta, children}
      target = %{
        meta_ast: {:collection_op, [op_type: :map], [:fn, :coll]},
        language: :elixir
      }

      all_results = [
        target,
        %{meta_ast: {:collection_op, [op_type: :map], [:fn, :coll]}, language: :python},
        %{meta_ast: {:collection_op, [op_type: :map], [:fn, :coll]}, language: :javascript},
        %{meta_ast: {:collection_op, [op_type: :filter], [:fn, :coll]}, language: :python}
      ]

      equivalents = MetaASTRanker.find_cross_language_equivalents(target, all_results)

      assert length(equivalents) == 2
      assert Enum.all?(equivalents, fn r -> r.language != :elixir end)
      assert Enum.all?(equivalents, fn r -> r.meta_ast == target.meta_ast end)
    end
  end
end
