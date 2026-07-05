defmodule Ragex.Retrieval.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Ragex.Retrieval.Evaluator

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp make_result(node_id), do: %{node_type: :function, node_id: node_id}

  defp make_relevant(node_id, grade \\ 1),
    do: %{node_type: :function, node_id: node_id, grade: grade}

  # Perfect retrieval: [A, B, C] where all 3 are relevant at grade 1
  @perfect_results Enum.map([:a, :b, :c], &%{node_type: :function, node_id: &1})
  @relevant_abc Enum.map([:a, :b, :c], &%{node_type: :function, node_id: &1, grade: 1})

  # ---------------------------------------------------------------------------
  # NDCG tests
  # ---------------------------------------------------------------------------

  describe "ndcg/3" do
    test "perfect rank returns 1.0" do
      score = Evaluator.ndcg(@perfect_results, @relevant_abc, 3)
      assert_in_delta score, 1.0, 0.0001
    end

    test "empty results returns 0.0" do
      assert Evaluator.ndcg([], @relevant_abc, 5) == 0.0
    end

    test "no relevant items (empty golden) returns 0.0" do
      assert Evaluator.ndcg(@perfect_results, [], 3) == 0.0
    end

    test "single relevant item found at rank 1 returns 1.0" do
      results = [make_result(:a), make_result(:b)]
      relevant = [make_relevant(:a)]
      score = Evaluator.ndcg(results, relevant, 5)
      assert_in_delta score, 1.0, 0.0001
    end

    test "single relevant item found at rank 2 is less than at rank 1" do
      at_1 = Evaluator.ndcg([make_result(:a)], [make_relevant(:a)], 5)
      at_2 = Evaluator.ndcg([make_result(:b), make_result(:a)], [make_relevant(:a)], 5)
      assert at_2 < at_1
    end

    test "graded relevance gives higher score to better-graded first result" do
      # grade 3 result first
      grade3_first =
        Evaluator.ndcg(
          [make_result(:a), make_result(:b)],
          [make_relevant(:a, 3), make_relevant(:b, 1)],
          2
        )

      # grade 1 result first
      grade1_first =
        Evaluator.ndcg(
          [make_result(:b), make_result(:a)],
          [make_relevant(:a, 3), make_relevant(:b, 1)],
          2
        )

      assert grade3_first > grade1_first
    end

    test "completely irrelevant results returns 0.0" do
      results = [make_result(:x), make_result(:y)]
      relevant = [make_relevant(:a), make_relevant(:b)]
      assert Evaluator.ndcg(results, relevant, 5) == 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # MRR tests
  # ---------------------------------------------------------------------------

  describe "mrr/2" do
    test "first result relevant returns 1.0" do
      assert_in_delta Evaluator.mrr([make_result(:a)], [make_relevant(:a)]), 1.0, 0.0001
    end

    test "second result relevant returns 0.5" do
      rr = Evaluator.mrr([make_result(:x), make_result(:a)], [make_relevant(:a)])
      assert_in_delta rr, 0.5, 0.0001
    end

    test "no relevant result returns 0.0" do
      assert Evaluator.mrr([make_result(:x)], [make_relevant(:a)]) == 0.0
    end

    test "empty results returns 0.0" do
      assert Evaluator.mrr([], [make_relevant(:a)]) == 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # Precision@K tests
  # ---------------------------------------------------------------------------

  describe "precision_at_k/3" do
    test "all K results relevant returns 1.0" do
      score = Evaluator.precision_at_k(@perfect_results, @relevant_abc, 3)
      assert_in_delta score, 1.0, 0.0001
    end

    test "half relevant returns 0.5 for K=2 with 1 hit" do
      results = [make_result(:a), make_result(:x)]
      relevant = [make_relevant(:a)]
      score = Evaluator.precision_at_k(results, relevant, 2)
      assert_in_delta score, 0.5, 0.0001
    end

    test "no relevant returns 0.0" do
      score = Evaluator.precision_at_k([make_result(:x)], [make_relevant(:a)], 5)
      assert score == 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # Recall@K tests
  # ---------------------------------------------------------------------------

  describe "recall_at_k/3" do
    test "all relevant in top-K returns 1.0" do
      score = Evaluator.recall_at_k(@perfect_results, @relevant_abc, 3)
      assert_in_delta score, 1.0, 0.0001
    end

    test "2 of 4 relevant in top-K returns 0.5" do
      results = Enum.map([:a, :b, :x, :y], &make_result/1)
      relevant = Enum.map([:a, :b, :c, :d], &make_relevant/1)
      score = Evaluator.recall_at_k(results, relevant, 4)
      assert_in_delta score, 0.5, 0.0001
    end

    test "empty golden set returns 1.0 (nothing to miss)" do
      assert Evaluator.recall_at_k(@perfect_results, [], 5) == 1.0
    end
  end

  # ---------------------------------------------------------------------------
  # run/3 (aggregate)
  # ---------------------------------------------------------------------------

  describe "run/3" do
    test "perfect retrieval returns all 1.0 metrics" do
      golden = [%{query: "q1", relevant: @relevant_abc}]
      search_fn = fn _query -> {:ok, @perfect_results} end

      metrics = Evaluator.run(golden, search_fn, k: 3)

      assert_in_delta metrics.ndcg, 1.0, 0.001
      assert_in_delta metrics.mrr, 1.0, 0.001
      assert_in_delta metrics.precision_at_k, 1.0, 0.001
      assert metrics.query_count == 1
      assert metrics.k == 3
    end

    test "empty golden returns all-zero metrics" do
      metrics = Evaluator.run([], fn _q -> {:ok, []} end, k: 5)
      assert metrics.ndcg == 0.0
      assert metrics.mrr == 0.0
      assert metrics.query_count == 0
    end

    test "failed search returns 0 for that query" do
      golden = [%{query: "q1", relevant: [make_relevant(:a)]}]
      search_fn = fn _q -> {:error, :no_model} end

      metrics = Evaluator.run(golden, search_fn, k: 5)
      assert metrics.ndcg == 0.0
      assert metrics.mrr == 0.0
    end

    test "averages correctly across multiple queries" do
      perfect_fn = fn _q -> {:ok, @perfect_results} end
      empty_fn = fn _q -> {:ok, []} end

      golden = [
        %{query: "q1", relevant: @relevant_abc},
        %{query: "q2", relevant: @relevant_abc}
      ]

      # One perfect, one empty — average should be 0.5
      mix_fn = fn q ->
        if q == "q1", do: perfect_fn.("q1"), else: empty_fn.("q2")
      end

      metrics = Evaluator.run(golden, mix_fn, k: 3)
      assert metrics.ndcg > 0.0 and metrics.ndcg < 1.0
    end
  end

  # ---------------------------------------------------------------------------
  # compare/4
  # ---------------------------------------------------------------------------

  describe "compare/4" do
    test "identical strategies return zero delta" do
      golden = [%{query: "q1", relevant: @relevant_abc}]
      search_fn = fn _q -> {:ok, @perfect_results} end

      report = Evaluator.compare(golden, search_fn, search_fn, k: 3)

      assert report.delta.ndcg == 0.0
      assert report.delta.mrr == 0.0
    end

    test "better strategy B gives positive NDCG delta" do
      golden = [%{query: "q1", relevant: [make_relevant(:a)]}]

      # Strategy A returns irrelevant results
      a_fn = fn _q -> {:ok, [make_result(:x), make_result(:y)]} end
      # Strategy B finds the relevant item first
      b_fn = fn _q -> {:ok, [make_result(:a), make_result(:x)]} end

      report = Evaluator.compare(golden, a_fn, b_fn, k: 5)
      assert report.delta.ndcg > 0.0
      assert report.delta.mrr > 0.0
    end

    test "report contains :strategy_a, :strategy_b, :delta keys" do
      golden = [%{query: "q", relevant: @relevant_abc}]
      f = fn _q -> {:ok, @perfect_results} end
      report = Evaluator.compare(golden, f, f, k: 3)

      assert Map.has_key?(report, :strategy_a)
      assert Map.has_key?(report, :strategy_b)
      assert Map.has_key?(report, :delta)
    end
  end

  # ---------------------------------------------------------------------------
  # load_golden/1
  # ---------------------------------------------------------------------------

  describe "load_golden/1" do
    test "returns error for non-existent file" do
      assert {:error, _} = Evaluator.load_golden("/nonexistent/path/golden.json")
    end

    test "parses a valid JSON golden file" do
      json =
        Jason.encode!([
          %{
            query: "parse HTTP",
            relevant: [
              %{node_type: "function", node_id: "MyMod.parse", grade: 2}
            ]
          }
        ])

      path = System.tmp_dir!() |> Path.join("golden_test_#{:os.getpid()}.json")
      File.write!(path, json)

      {:ok, golden} = Evaluator.load_golden(path)

      assert length(golden) == 1
      [q] = golden
      assert q.query == "parse HTTP"
      assert length(q.relevant) == 1
      [r] = q.relevant
      assert r.node_type == :function
      assert r.grade == 2

      File.rm(path)
    end
  end
end
