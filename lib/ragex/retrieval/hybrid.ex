defmodule Ragex.Retrieval.Hybrid do
  @moduledoc """
  Hybrid retrieval combining symbolic graph queries with semantic similarity search.

  Provides multiple strategies for combining structural and semantic search:
  - **Semantic-first**: Use embeddings to find candidates, refine with graph
  - **Graph-first**: Use symbolic queries to filter, rank by similarity
  - **Fusion**: Combine results from both approaches using RRF
  """

  alias Ragex.Embeddings.Bumblebee
  alias Ragex.Graph.Store
  alias Ragex.VectorStore

  @doc """
  Performs hybrid search combining semantic and symbolic approaches.

  ## Strategies

  - `:semantic_first` - Semantic search followed by graph filtering
  - `:graph_first` - Graph query followed by semantic ranking
  - `:fusion` - Combine both with Reciprocal Rank Fusion (default)

  ## Options

  - `:strategy` - Search strategy (default: :fusion)
  - `:limit` - Maximum results (default: 10)
  - `:threshold` - Semantic similarity threshold (default: 0.7)
  - `:node_type` - Filter by entity type
  - `:graph_filter` - Additional graph constraints

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
  """
  def search(query, opts \\ []) when is_binary(query) do
    strategy = Keyword.get(opts, :strategy, :fusion)

    case strategy do
      :semantic_first -> semantic_first_search(query, opts)
      :graph_first -> graph_first_search(query, opts)
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

    # Generate query embedding
    case Bumblebee.embed(query) do
      {:ok, query_embedding} ->
        # Semantic search
        # Get more candidates
        search_opts = [limit: limit * 2, threshold: threshold]

        search_opts =
          if node_type, do: Keyword.put(search_opts, :node_type, node_type), else: search_opts

        semantic_results = VectorStore.search(query_embedding, search_opts)

        # Apply graph filters
        filtered_results =
          semantic_results
          |> Enum.filter(&matches_graph_filter?(&1, graph_filter))
          |> Enum.take(limit)

        {:ok, filtered_results}

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
        ranked_results =
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
          |> Enum.sort_by(fn result -> result.score end, :desc)
          |> Enum.take(limit)

        {:ok, ranked_results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fusion_search(query, opts) do
    limit = Keyword.get(opts, :limit, 10)

    # Run both strategies
    case {semantic_first_search(query, opts), graph_first_search(query, opts)} do
      {{:ok, semantic_results}, {:ok, graph_results}} ->
        # Apply RRF fusion
        fused_results =
          reciprocal_rank_fusion(
            [semantic_results, graph_results],
            limit: limit
          )

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
end
