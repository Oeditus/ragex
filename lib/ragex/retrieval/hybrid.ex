defmodule Ragex.Retrieval.Hybrid do
  @moduledoc """
  Hybrid retrieval combining symbolic graph queries with semantic similarity search.

  Provides multiple strategies for combining structural and semantic search:
  - **Semantic-first**: Use embeddings to find candidates, refine with graph
  - **Graph-first**: Use symbolic queries to filter, rank by similarity
  - **Fusion**: Combine results from both approaches using RRF, including a
    BM25 full-text search leg via dllb/Tantivy when dllb is enabled

  ## FTS leg

  When `Ragex.Dllb.Adapter.enabled?/0` is true, `fusion_search/2` adds a
  third result set from a Tantivy BM25 `SEARCH ast_node source_text` query.
  BM25 scores are min-max normalized to [0,1] before RRF fusion so they are
  comparable to the cosine similarity scores from the semantic leg. When dllb
  is disabled the FTS leg silently returns an empty list.
  """

  require Logger

  alias Ragex.Dllb.Adapter, as: DllbAdapter
  alias Ragex.Embeddings.Bumblebee
  alias Ragex.Graph.Store
  alias Ragex.Retrieval.{MetaASTRanker, QueryExpansion}
  alias Ragex.VectorStore

  @doc """
  Performs hybrid search combining semantic and symbolic approaches.

  ## Strategies

  - `:semantic_first` - Semantic search followed by graph filtering
  - `:graph_first` - Graph query followed by semantic ranking
  - `:fusion` - Combine both with Reciprocal Rank Fusion (default)
  - `:graph_algo` - dllb PageRank-based retrieval: rank nodes by structural
    importance, filter to those matching the semantic query.

  ## Options

  - `:strategy` - Search strategy (default: :fusion)
  - `:limit` - Maximum results (default: 10)
  - `:threshold` - Semantic similarity threshold (default: 0.7)
  - `:node_type` - Filter by entity type
  - `:graph_filter` - Additional graph constraints
  - `:metaast_ranking` - Enable MetaAST-based ranking boosts (default: true)
  - `:metaast_opts` - Options for MetaAST ranking:
    - `:prefer_pure` - Boost pure functions more (default: true)
    - `:penalize_complex` - Penalize complex code more (default: true)
    - `:cross_language` - Enable cross-language equivalence search (default: false)
  - `:hyde` - Enable HyDE query expansion (default: false). When true, a
    hypothetical code snippet is generated from the query via AI, embedded, and
    its embedding is fused with the standard semantic leg. Falls back silently
    if the AI provider is unavailable.
  - `:hyde_opts` - Options forwarded to `QueryExpansion.hyde_embedding/2`:
    - `:language` - target language hint (default: "elixir")
    - `:provider` - AI provider override

  ## Examples

      # Fusion strategy (default)
      Hybrid.search("parse JSON", limit: 5)
      
      # Semantic-first strategy
      Hybrid.search("HTTP handler", strategy: :semantic_first)
      
      # Graph-first with constraints
      Hybrid.search("calculate", 
        strategy: :graph_first,
        graph_filter: %{module: "Math"}
      )

      # With MetaAST ranking for cross-language results
      Hybrid.search("map operations",
        metaast_ranking: true,
        metaast_opts: [cross_language: true]
      )
  """
  def search(query, opts \\ []) when is_binary(query) do
    strategy = Keyword.get(opts, :strategy, :fusion)

    case strategy do
      :semantic_first -> semantic_first_search(query, opts)
      :graph_first -> graph_first_search(query, opts)
      :graph_algo -> graph_algo_search(query, opts)
      :fusion -> fusion_search(query, opts)
      _ -> {:error, "Unknown strategy: #{strategy}"}
    end
  end

  @doc """
  Performs Reciprocal Rank Fusion on multiple result sets.

  RRF combines rankings from different sources by:
  1. Converting ranks to scores: 1 / (rank + k)
  2. Summing scores across all sources
  3. Re-ranking by combined score

  The constant k (default 60) prevents high rankings from dominating.
  """
  def reciprocal_rank_fusion(result_sets, opts \\ []) do
    k = Keyword.get(opts, :k, 60)
    limit = Keyword.get(opts, :limit, 10)

    # Collect all unique items with their RRF scores
    all_items =
      result_sets
      |> Enum.with_index()
      |> Enum.flat_map(fn {results, _source_idx} ->
        results
        |> Enum.with_index()
        |> Enum.map(fn {item, rank} ->
          rrf_score = 1.0 / (rank + k)
          {get_item_key(item), item, rrf_score}
        end)
      end)

    # Sum scores for duplicate items
    fused_scores =
      all_items
      |> Enum.group_by(fn {key, _item, _score} -> key end)
      |> Enum.map(fn {key, items} ->
        total_score = Enum.reduce(items, 0.0, fn {_k, _i, score}, acc -> acc + score end)
        # Take the item from the first occurrence
        {_k, item, _s} = hd(items)
        {key, item, total_score}
      end)
      |> Enum.sort_by(fn {_k, _i, score} -> score end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {_key, item, score} ->
        Map.put(item, :fusion_score, Float.round(score, 4))
      end)

    fused_scores
  end

  # Private functions

  defp semantic_first_search(query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.7)
    node_type = Keyword.get(opts, :node_type)
    graph_filter = Keyword.get(opts, :graph_filter, %{})
    use_hyde = Keyword.get(opts, :hyde, false)
    hyde_opts = Keyword.get(opts, :hyde_opts, [])

    # Generate query embedding
    case Bumblebee.embed(query) do
      {:ok, query_embedding} ->
        search_opts = [limit: limit * 2, threshold: threshold]

        search_opts =
          if node_type, do: Keyword.put(search_opts, :node_type, node_type), else: search_opts

        raw_results = VectorStore.search(query_embedding, search_opts)

        # Optionally add a HyDE leg: embed a hypothetical answer and search by it,
        # then RRF-fuse with the raw semantic results.
        semantic_results =
          if use_hyde do
            hyde_results = run_hyde_search(query, search_opts, hyde_opts)

            if hyde_results != [] do
              reciprocal_rank_fusion([raw_results, hyde_results], limit: limit * 2)
            else
              raw_results
            end
          else
            raw_results
          end

        # Apply graph filters
        filtered_results =
          semantic_results
          |> Enum.filter(&matches_graph_filter?(&1, graph_filter))

        # Apply MetaAST ranking if enabled
        ranked_results =
          if Keyword.get(opts, :metaast_ranking, true) do
            metaast_opts =
              opts
              |> Keyword.get(:metaast_opts, [])
              |> Keyword.put(:query, query)

            MetaASTRanker.apply_ranking(filtered_results, metaast_opts)
          else
            filtered_results
          end
          |> Enum.take(limit)

        {:ok, ranked_results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp graph_first_search(query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    # Lower threshold for graph-first
    threshold = Keyword.get(opts, :threshold, 0.5)
    graph_filter = Keyword.get(opts, :graph_filter, %{})

    # Generate query embedding
    case Bumblebee.embed(query) do
      {:ok, query_embedding} ->
        # Get candidates from graph (all nodes matching filters)
        candidates = get_graph_candidates(graph_filter)

        # Get embeddings for candidates and calculate similarity
        candidate_results =
          candidates
          |> Enum.map(fn {node_type, node_id} ->
            case Store.get_embedding(node_type, node_id) do
              {embedding, text} ->
                score = VectorStore.cosine_similarity(query_embedding, embedding)

                %{
                  node_type: node_type,
                  node_id: node_id,
                  score: score,
                  text: text,
                  embedding: embedding
                }

              nil ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.filter(fn result -> result.score >= threshold end)

        # Apply MetaAST ranking if enabled
        ranked_results =
          if Keyword.get(opts, :metaast_ranking, true) do
            metaast_opts =
              opts
              |> Keyword.get(:metaast_opts, [])
              |> Keyword.put(:query, query)

            MetaASTRanker.apply_ranking(candidate_results, metaast_opts)
          else
            candidate_results
            |> Enum.sort_by(fn result -> result.score end, :desc)
          end
          |> Enum.take(limit)

        {:ok, ranked_results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fusion_search(query, opts) do
    limit = Keyword.get(opts, :limit, 10)

    # Run semantic + graph legs, then optionally add FTS and graph-algo legs.
    case {semantic_first_search(query, opts), graph_first_search(query, opts)} do
      {{:ok, semantic_results}, {:ok, graph_results}} ->
        fts_results = fts_search(query, limit * 2)

        algo_results =
          if Keyword.get(opts, :graph_algo_boost, false) do
            pagerank_candidates(limit * 2)
          else
            []
          end

        result_sets =
          [semantic_results, graph_results, fts_results, algo_results]
          |> Enum.reject(&Enum.empty?/1)

        pre_fusion_results =
          reciprocal_rank_fusion(result_sets, limit: limit * 2)

        fused_results =
          if Keyword.get(opts, :metaast_ranking, true) do
            metaast_opts =
              opts
              |> Keyword.get(:metaast_opts, [])
              |> Keyword.put(:query, query)

            MetaASTRanker.apply_ranking(pre_fusion_results, metaast_opts)
          else
            pre_fusion_results
          end
          |> Enum.take(limit)

        {:ok, fused_results}

      {{:error, reason}, _} ->
        {:error, reason}

      {_, {:error, reason}} ->
        {:error, reason}
    end
  end

  defp matches_graph_filter?(_result, filter) when map_size(filter) == 0, do: true

  defp matches_graph_filter?(result, filter) do
    node_data = Store.find_node(result.node_type, result.node_id)

    Enum.all?(filter, fn {key, value} ->
      case key do
        :module when result.node_type == :function ->
          {module, _name, _arity} = result.node_id
          Atom.to_string(module) == value or module == String.to_atom(value)

        _ ->
          # Check node data
          node_data[key] == value or
            (is_atom(node_data[key]) and Atom.to_string(node_data[key]) == value)
      end
    end)
  end

  defp get_graph_candidates(filter) do
    # Get nodes based on filter
    node_type =
      case filter[:node_type] do
        "module" -> :module
        "function" -> :function
        _ -> nil
      end

    # Get all nodes of specified type (or all if no type)
    nodes = Store.list_nodes(node_type, 1000)

    # Convert to {type, id} tuples
    Enum.map(nodes, fn node -> {node.type, node.id} end)
  end

  defp get_item_key(%{node_type: type, node_id: id}), do: {type, id}
  defp get_item_key(item), do: inspect(item)

  # ---------------------------------------------------------------------------
  # Graph-algorithm retrieval leg
  # ---------------------------------------------------------------------------

  # A standalone strategy that retrieves nodes ranked by dllb PageRank, then
  # filters to those whose embedding is above the semantic similarity threshold
  # to the query.  Falls back to graph_first if dllb is disabled.
  defp graph_algo_search(query, opts) do
    if DllbAdapter.enabled?() do
      limit = Keyword.get(opts, :limit, 10)
      threshold = Keyword.get(opts, :threshold, 0.5)

      candidates = pagerank_candidates(limit * 3)

      # Filter by semantic similarity
      case Bumblebee.embed(query) do
        {:ok, query_embedding} ->
          results =
            candidates
            |> Enum.map(fn candidate ->
              case Store.get_embedding(candidate.node_type, candidate.node_id) do
                {embedding, text} ->
                  score = VectorStore.cosine_similarity(query_embedding, embedding)
                  Map.merge(candidate, %{score: score, text: text})

                nil ->
                  nil
              end
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.filter(fn r -> r.score >= threshold end)
            |> Enum.sort_by(
              fn r ->
                # Blend pagerank importance with semantic score
                pr = r[:pagerank] || 0.0
                r.score * 0.7 + pr * 0.3
              end,
              :desc
            )
            |> Enum.take(limit)

          {:ok, results}

        {:error, reason} ->
          {:error, reason}
      end
    else
      graph_first_search(query, opts)
    end
  end

  # Fetch top-N nodes by PageRank from dllb. Returns a flat list of
  # %{node_type, node_id, pagerank} maps. Returns [] when dllb is disabled.
  defp pagerank_candidates(n) do
    pr_query = Dllb.Query.graph_pagerank("ast_node_edges", limit: n)

    case DllbAdapter.query(pr_query) do
      {:ok, %Dllb.Result.Rows{data: rows}} when is_list(rows) ->
        rows
        |> Enum.map(fn row ->
          id = Map.get(row, "id") || Map.get(row, :id) || ""
          pr = Map.get(row, "score") || Map.get(row, :score) || 0.0

          # dllb ids are in the form "ast_node:module_name_10" — extract kind
          {node_type, node_id} = parse_dllb_id(id)
          %{node_type: node_type, node_id: node_id, pagerank: pr}
        end)
        |> Enum.reject(fn r -> is_nil(r.node_id) end)

      _ ->
        []
    end
  end

  # Parse a dllb record ID like "ast_node:module_my_module_1" back to a
  # ragex {node_type, node_id} tuple.  Best-effort: falls back to :unknown.
  defp parse_dllb_id(id) when is_binary(id) do
    case String.split(id, ":", parts: 2) do
      [_table, name] ->
        # Heuristic: module names start with uppercase, function names contain "_"
        if String.match?(name, ~r/^[A-Z]/) do
          {:module, String.to_atom(name)}
        else
          {:function, name}
        end

      _ ->
        {:unknown, id}
    end
  end

  defp parse_dllb_id(_), do: {:unknown, nil}

  # ---------------------------------------------------------------------------
  # HyDE retrieval helper
  # ---------------------------------------------------------------------------

  # Generate a hypothetical code snippet embedding and run a semantic search
  # against it. Returns an empty list on any failure so fusion is unaffected.
  defp run_hyde_search(query, search_opts, hyde_opts) do
    case QueryExpansion.hyde_embedding(query, hyde_opts) do
      {:ok, hypo_embedding} ->
        VectorStore.search(hypo_embedding, search_opts)

      {:error, reason} ->
        Logger.debug("HyDE embedding failed (ignored): #{inspect(reason)}")
        []
    end
  end

  # ---------------------------------------------------------------------------
  # FTS (Tantivy / dllb) retrieval leg
  # ---------------------------------------------------------------------------

  # Run a BM25 full-text search via dllb and convert results to the same map
  # shape used by the semantic/graph legs so they can be fused with RRF.
  # Returns an empty list when dllb is disabled or the query fails.
  defp fts_search(query, limit) do
    fts_query = Dllb.Query.search("ast_node", "source_text", query, limit: limit)

    case DllbAdapter.query(fts_query) do
      {:ok, %Dllb.Result.Rows{data: rows}} when is_list(rows) and rows != [] ->
        rows
        |> normalize_bm25_scores()
        |> Enum.map(&fts_row_to_result/1)

      {:ok, _} ->
        []

      {:error, :dllb_disabled} ->
        []

      {:error, reason} ->
        Logger.debug("FTS search failed (ignored in fusion): #{inspect(reason)}")
        []
    end
  end

  # Min-max normalize BM25 scores across the result set to [0, 1].
  defp normalize_bm25_scores(rows) do
    scores = Enum.map(rows, &(Map.get(&1, "score") || Map.get(&1, :score) || 0.0))
    min_s = Enum.min(scores, fn -> 0.0 end)
    max_s = Enum.max(scores, fn -> 1.0 end)
    range = max(max_s - min_s, 1.0e-9)

    Enum.zip(rows, scores)
    |> Enum.map(fn {row, raw} ->
      Map.put(row, :normalized_bm25, (raw - min_s) / range)
    end)
  end

  defp fts_row_to_result(row) do
    kind = Map.get(row, "kind") || Map.get(row, :kind)
    name = Map.get(row, "name") || Map.get(row, :name)
    file = Map.get(row, "file_path") || Map.get(row, :file_path)
    line = Map.get(row, "line_start") || Map.get(row, :line_start)
    source = Map.get(row, "source_text") || Map.get(row, :source_text) || ""

    node_type =
      case kind do
        "module" -> :module
        "function_def" -> :function
        _ -> :unknown
      end

    node_id =
      case node_type do
        :module ->
          name && String.to_atom(name)

        :function ->
          mod_str = Map.get(row, "module") || Map.get(row, :module) || ""
          arity = Map.get(row, "arity") || Map.get(row, :arity) || 0
          {String.to_atom(mod_str), String.to_atom(name || "unknown"), arity}

        _ ->
          name
      end

    %{
      node_type: node_type,
      node_id: node_id,
      score: Map.get(row, :normalized_bm25, 0.0),
      text: String.slice(source, 0, 500),
      file: file,
      line: line,
      source: :fts
    }
  end
end
