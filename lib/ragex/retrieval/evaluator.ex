defmodule Ragex.Retrieval.Evaluator do
  @moduledoc """
  Retrieval quality evaluator for comparing search strategies.

  Computes standard IR metrics — NDCG, MRR, Precision@K, Recall@K — against a
  golden query set, making it possible to measure whether a retrieval change
  improves or degrades quality.

  ## Metrics

  - **NDCG@K** — Normalised Discounted Cumulative Gain: rewards relevant results
    that appear earlier in the ranked list.  Scores are graded (0–3) when
    multiple relevance levels are defined, or binary (0/1) otherwise.
  - **MRR** — Mean Reciprocal Rank: mean of 1/rank for the first relevant result
    across all queries.  Good proxy for "do users find *something* useful quickly?"
  - **Precision@K** — fraction of the top-K results that are relevant.
  - **Recall@K** — fraction of all known-relevant results that appear in top-K.

  ## Golden query set format

      [
        %{
          query: "function that retries HTTP requests",
          relevant: [
            %{node_type: :function, node_id: {MyModule, :retry, 2}, grade: 3},
            %{node_type: :function, node_id: {MyModule, :with_retry, 1}, grade: 2}
          ]
        },
        ...
      ]

  `grade` is optional (default 1).  Grades are used for NDCG when present.

  ## A/B comparison

      strategy_a = fn query -> Hybrid.search(query, strategy: :fusion, limit: 10) end
      strategy_b = fn query -> Hybrid.search(query, strategy: :fusion, rerank: true, limit: 10) end

      Evaluator.compare(golden_queries, strategy_a, strategy_b, k: 10)

  ## Usage

      golden = Evaluator.load_golden("priv/eval/golden_queries.json")
      results = Evaluator.run(golden, fn q -> Hybrid.search(q, limit: 10) end, k: 10)
      IO.inspect(results.ndcg)  # => 0.72
  """

  require Logger

  @default_k 10

  @type grade :: 0 | 1 | 2 | 3
  @type relevant_item :: %{
          node_type: atom(),
          node_id: term(),
          grade: grade()
        }
  @type golden_query :: %{
          query: String.t(),
          relevant: [relevant_item()]
        }
  @type result_item :: %{node_type: atom(), node_id: term()}
  @type search_fn :: (String.t() -> {:ok, [result_item()]} | {:error, term()})

  @type metrics :: %{
          ndcg: float(),
          mrr: float(),
          precision_at_k: float(),
          recall_at_k: float(),
          query_count: non_neg_integer(),
          k: pos_integer()
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Run a search function against a golden query set and return aggregate metrics.

  ## Options

  - `:k` — cutoff rank (default: #{@default_k})
  - `:verbose` — log per-query scores (default: false)
  """
  @spec run([golden_query()], search_fn(), keyword()) :: metrics()
  def run(golden_queries, search_fn, opts \\ []) when is_list(golden_queries) do
    k = Keyword.get(opts, :k, @default_k)
    verbose = Keyword.get(opts, :verbose, false)

    per_query =
      Enum.map(golden_queries, fn %{query: query, relevant: relevant} ->
        results = execute_search(search_fn, query, k)
        scores = query_metrics(results, relevant, k)

        if verbose do
          Logger.info(
            "Query: #{query} | NDCG: #{Float.round(scores.ndcg, 3)} | MRR: #{Float.round(scores.mrr, 3)}"
          )
        end

        scores
      end)

    aggregate(per_query, k)
  end

  @doc """
  Run two search functions against the same golden set and return a diff report.

  Returns a map with keys `:strategy_a`, `:strategy_b`, and `:delta` (B minus A).
  Positive delta values mean strategy B improved.
  """
  @spec compare([golden_query()], search_fn(), search_fn(), keyword()) :: map()
  def compare(golden_queries, strategy_a, strategy_b, opts \\ []) do
    metrics_a = run(golden_queries, strategy_a, opts)
    metrics_b = run(golden_queries, strategy_b, opts)

    delta = %{
      ndcg: Float.round(metrics_b.ndcg - metrics_a.ndcg, 4),
      mrr: Float.round(metrics_b.mrr - metrics_a.mrr, 4),
      precision_at_k: Float.round(metrics_b.precision_at_k - metrics_a.precision_at_k, 4),
      recall_at_k: Float.round(metrics_b.recall_at_k - metrics_a.recall_at_k, 4)
    }

    %{strategy_a: metrics_a, strategy_b: metrics_b, delta: delta}
  end

  @doc """
  Load a golden query set from a JSON file.

  Expected format: a JSON array of `{"query": "...", "relevant": [...]}` objects.
  Relevant items may have `"grade"` (integer 0–3, default 1) alongside
  `"node_type"` (string) and `"node_id"` (any JSON value).
  """
  @spec load_golden(String.t()) :: {:ok, [golden_query()]} | {:error, term()}
  def load_golden(path) do
    with {:ok, content} <- File.read(path),
         {:ok, raw} <- decode_json(content) do
      queries = Enum.map(raw, &parse_golden_query/1)
      {:ok, queries}
    end
  end

  # ---------------------------------------------------------------------------
  # Metric computation — public so they can be tested independently
  # ---------------------------------------------------------------------------

  @doc """
  Compute NDCG@K for a single query.

  `results` is a ranked list of `%{node_type, node_id}` maps.
  `relevant` is the golden set with optional `grade` values.
  """
  @spec ndcg(results :: [result_item()], relevant :: [relevant_item()], k :: pos_integer()) ::
          float()
  def ndcg(results, relevant, k) do
    relevance_map = build_relevance_map(relevant)
    top_k = Enum.take(results, k)

    dcg =
      top_k
      |> Enum.with_index(1)
      |> Enum.reduce(0.0, fn {item, rank}, acc ->
        grade = Map.get(relevance_map, item_key(item), 0)
        acc + gain(grade) / :math.log2(rank + 1)
      end)

    ideal_grades =
      relevant
      |> Enum.map(fn r -> Map.get(r, :grade, 1) end)
      |> Enum.sort(:desc)
      |> Enum.take(k)

    idcg =
      ideal_grades
      |> Enum.with_index(1)
      |> Enum.reduce(0.0, fn {grade, rank}, acc ->
        acc + gain(grade) / :math.log2(rank + 1)
      end)

    if idcg == 0.0, do: 0.0, else: Float.round(dcg / idcg, 6)
  end

  @doc """
  Compute MRR for a single query (reciprocal rank of first relevant result).
  """
  @spec mrr(results :: [result_item()], relevant :: [relevant_item()]) :: float()
  def mrr(results, relevant) do
    relevance_map = build_relevance_map(relevant)

    first_hit =
      results
      |> Enum.with_index(1)
      |> Enum.find(fn {item, _rank} -> Map.get(relevance_map, item_key(item), 0) > 0 end)

    case first_hit do
      nil -> 0.0
      {_item, rank} -> 1.0 / rank
    end
  end

  @doc """
  Compute Precision@K for a single query.
  """
  @spec precision_at_k(
          results :: [result_item()],
          relevant :: [relevant_item()],
          k :: pos_integer()
        ) :: float()
  def precision_at_k(results, relevant, k) do
    relevance_map = build_relevance_map(relevant)
    top_k = Enum.take(results, k)
    hits = Enum.count(top_k, fn item -> Map.get(relevance_map, item_key(item), 0) > 0 end)
    if k == 0, do: 0.0, else: hits / k
  end

  @doc """
  Compute Recall@K for a single query.
  """
  @spec recall_at_k(results :: [result_item()], relevant :: [relevant_item()], k :: pos_integer()) ::
          float()
  def recall_at_k(results, relevant, k) do
    total_relevant = length(relevant)

    if total_relevant == 0,
      do: 1.0,
      else: precision_at_k(results, relevant, k) * k / total_relevant
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp execute_search(search_fn, query, k) do
    case search_fn.(query) do
      {:ok, results} ->
        Enum.take(results, k)

      {:error, reason} ->
        Logger.debug("Search failed for query #{inspect(query)}: #{inspect(reason)}")
        []
    end
  end

  defp query_metrics(results, relevant, k) do
    %{
      ndcg: ndcg(results, relevant, k),
      mrr: mrr(results, relevant),
      precision_at_k: precision_at_k(results, relevant, k),
      recall_at_k: recall_at_k(results, relevant, k)
    }
  end

  defp aggregate(per_query, k) do
    n = length(per_query)

    if n == 0 do
      %{ndcg: 0.0, mrr: 0.0, precision_at_k: 0.0, recall_at_k: 0.0, query_count: 0, k: k}
    else
      sum = fn field -> Enum.reduce(per_query, 0.0, fn m, acc -> acc + m[field] end) end

      %{
        ndcg: Float.round(sum.(:ndcg) / n, 4),
        mrr: Float.round(sum.(:mrr) / n, 4),
        precision_at_k: Float.round(sum.(:precision_at_k) / n, 4),
        recall_at_k: Float.round(sum.(:recall_at_k) / n, 4),
        query_count: n,
        k: k
      }
    end
  end

  defp build_relevance_map(relevant) do
    Map.new(relevant, fn item ->
      node_type = Map.get(item, :node_type)
      node_id = Map.get(item, :node_id)
      grade = Map.get(item, :grade, 1)
      {{node_type, node_id}, grade}
    end)
  end

  defp item_key(%{node_type: type, node_id: id}), do: {type, id}
  defp item_key(item), do: item

  # Graded gain: 2^grade - 1 for NDCG
  defp gain(0), do: 0.0
  defp gain(grade), do: :math.pow(2, grade) - 1

  defp decode_json(content) do
    {:ok, :json.decode(content)}
  rescue
    _ ->
      case Jason.decode(content) do
        {:ok, _} = ok -> ok
        {:error, _} = err -> err
      end
  end

  defp parse_golden_query(%{"query" => query, "relevant" => relevant}) do
    %{
      query: query,
      relevant: Enum.map(relevant, &parse_relevant_item/1)
    }
  end

  defp parse_golden_query(other), do: other

  defp parse_relevant_item(item) when is_map(item) do
    node_type =
      case Map.get(item, "node_type") do
        s when is_binary(s) -> String.to_atom(s)
        a when is_atom(a) -> a
        _ -> :unknown
      end

    %{
      node_type: node_type,
      node_id: Map.get(item, "node_id"),
      grade: Map.get(item, "grade", 1)
    }
  end
end
