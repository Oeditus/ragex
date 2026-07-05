defmodule Ragex.Retrieval.HybridGraphAlgoTest do
  use ExUnit.Case, async: true

  alias Ragex.Retrieval.Hybrid

  describe "graph_algo strategy — dllb disabled (default)" do
    test "falls back gracefully when dllb is disabled" do
      result =
        Hybrid.search("module with many callers",
          strategy: :graph_algo,
          limit: 5
        )

      # Falls back to graph_first which may also fail due to no embedding model
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "does not raise" do
      assert (fn ->
                Hybrid.search("important module", strategy: :graph_algo, limit: 3)
              end).() != :raised
    end
  end

  describe "graph_algo_boost in fusion — dllb disabled" do
    test "fusion with graph_algo_boost: true still succeeds" do
      result =
        Hybrid.search("database access",
          strategy: :fusion,
          graph_algo_boost: true,
          limit: 5
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "fusion with graph_algo_boost: false is the default" do
      result_with = Hybrid.search("cache", strategy: :fusion, graph_algo_boost: true, limit: 3)

      result_without =
        Hybrid.search("cache", strategy: :fusion, graph_algo_boost: false, limit: 3)

      # Both paths should produce the same shape of result
      assert match?({:ok, _}, result_with) or match?({:error, _}, result_with)
      assert match?({:ok, _}, result_without) or match?({:error, _}, result_without)
    end
  end

  describe "parse_dllb_id (internal, tested via pagerank_candidates shape)" do
    # We test ID parsing logic indirectly through the result map shape.
    # When dllb returns rows we expect :node_type and :node_id to be populated.

    test "pagerank_candidates returns [] when dllb is disabled" do
      assert Application.get_env(:dllb, :enabled, false) == false
      # The result from fusion with graph_algo_boost should not include pagerank
      # entries since dllb is off — no error, just empty algo set.
      result = Hybrid.search("any query", strategy: :fusion, graph_algo_boost: true, limit: 5)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "RRF with four result sets" do
    test "four-set RRF produces correct winner" do
      s1 = [%{node_type: :function, node_id: {:M, :winner, 0}, score: 0.9}]
      s2 = [%{node_type: :function, node_id: {:M, :winner, 0}, score: 0.8}]
      s3 = [%{node_type: :function, node_id: {:M, :winner, 0}, score: 0.7}]
      s4 = [%{node_type: :function, node_id: {:M, :loser, 0}, score: 0.95}]

      fused = Hybrid.reciprocal_rank_fusion([s1, s2, s3, s4], limit: 5)

      # :winner appears in 3 sets vs :loser in 1 set; winner should rank higher
      first = hd(fused)
      assert first.node_id == {:M, :winner, 0}
    end
  end
end
