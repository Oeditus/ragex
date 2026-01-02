defmodule Ragex.Graph.Algorithms do
  @moduledoc """
  Graph algorithms for analyzing code structure and relationships.

  Provides algorithms for:
  - PageRank: Importance scoring based on call relationships
  - Path Finding: Discovering call chains between functions
  - Centrality Metrics: Degree, betweenness, clustering
  - Graph Statistics: Overall graph analysis
  """

  alias Ragex.Graph.Store

  @doc """
  Computes PageRank scores for all nodes in the graph.

  PageRank measures the importance of nodes based on incoming edges.
  Higher scores indicate more "important" functions/modules (those called by many others).

  ## Parameters
  - `damping_factor`: Probability of following an edge (default: 0.85)
  - `max_iterations`: Maximum iterations (default: 100)
  - `tolerance`: Convergence threshold (default: 0.0001)

  ## Returns
  Map of node_id => pagerank_score
  """
  def pagerank(opts \\ []) do
    damping = Keyword.get(opts, :damping_factor, 0.85)
    max_iter = Keyword.get(opts, :max_iterations, 100)
    tolerance = Keyword.get(opts, :tolerance, 0.0001)

    # Get all edges
    edges = get_call_edges()

    # Build adjacency structure
    {out_edges, in_edges} = build_adjacency(edges)

    # Get all nodes involved in the call graph
    node_ids =
      edges
      |> Enum.flat_map(fn {from, to} -> [from, to] end)
      |> Enum.uniq()

    n = length(node_ids)

    if n == 0 do
      %{}
    else
      initial_score = 1.0 / n
      scores = Map.new(node_ids, fn id -> {id, initial_score} end)

      # Iterate until convergence
      iterate_pagerank(scores, node_ids, out_edges, in_edges, damping, max_iter, tolerance)
    end
  end

  @doc """
  Finds all paths between two nodes up to a maximum depth.

  ## Parameters
  - `from`: Source node ID
  - `to`: Target node ID
  - `opts`: Keyword list of options
    - `:max_depth` - Maximum path length in edges (default: 10)
    - `:max_paths` - Maximum number of paths to return (default: 100)
    - `:warn_dense` - Emit warnings for dense graphs (default: true)

  ## Returns
  List of paths, where each path is a list of node IDs.
  Returns up to `max_paths` paths to prevent hangs on dense graphs.

  ## Examples

      # Find up to 100 paths with max depth of 10
      find_paths(from, to)
      
      # Find up to 50 paths with max depth of 5
      find_paths(from, to, max_depth: 5, max_paths: 50)
      
      # Disable warnings for dense graphs
      find_paths(from, to, warn_dense: false)

  """
  def find_paths(from, to, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 10)
    max_paths = Keyword.get(opts, :max_paths, 100)
    warn_dense = Keyword.get(opts, :warn_dense, true)

    edges = get_call_edges()
    adjacency = build_out_adjacency(edges)

    # Check for dense graphs and emit warning if needed
    if warn_dense do
      check_dense_graph(from, adjacency)
    end

    # Use accumulator to track path count for early stopping
    {paths, _count} =
      find_paths_dfs(
        from,
        to,
        adjacency,
        max_depth,
        max_paths,
        [from],
        MapSet.new([from]),
        0
      )

    paths
  end

  @doc """
  Computes degree centrality for all nodes.

  Returns:
  - `in_degree`: Number of incoming edges (callers)
  - `out_degree`: Number of outgoing edges (callees)
  - `total_degree`: Sum of in and out degree
  """
  def degree_centrality do
    edges = get_call_edges()

    in_degrees =
      edges
      |> Enum.group_by(fn {_from, to} -> to end)
      |> Map.new(fn {node, list} -> {node, length(list)} end)

    out_degrees =
      edges
      |> Enum.group_by(fn {from, _to} -> from end)
      |> Map.new(fn {node, list} -> {node, length(list)} end)

    # Get all nodes - calls use 4-tuple format {:function, module, name, arity}
    # But nodes are stored with 3-tuple IDs {module, name, arity}
    # So we need to normalize to the 4-tuple format to match call edges
    all_nodes =
      Store.list_nodes()
      |> Enum.map(fn node ->
        case {node.type, node.id} do
          {:function, {module, name, arity}} -> {:function, module, name, arity}
          {:module, id} -> {:module, id}
          {type, id} -> {type, id}
        end
      end)
      |> MapSet.new()

    Map.new(all_nodes, fn node ->
      in_deg = Map.get(in_degrees, node, 0)
      out_deg = Map.get(out_degrees, node, 0)

      {node,
       %{
         in_degree: in_deg,
         out_degree: out_deg,
         total_degree: in_deg + out_deg
       }}
    end)
  end

  @doc """
  Computes betweenness centrality for nodes in the graph.

  Betweenness measures how often a node appears on shortest paths between other nodes.
  Higher scores indicate "bridge" or "bottleneck" functions.

  Uses Brandes' algorithm (O(nm) complexity).

  ## Parameters
  - `:max_nodes` - Limit computation to N highest-degree nodes (default: 1000)
  - `:normalize` - Return normalized scores 0-1 (default: true)
  - `:directed` - Treat graph as directed (default: true)

  ## Returns
  Map of node_id => betweenness_score

  ## Examples

      # Compute for all nodes (up to 1000)
      betweenness_centrality()

      # Compute for top 100 nodes by degree
      betweenness_centrality(max_nodes: 100)

      # Get raw (unnormalized) scores
      betweenness_centrality(normalize: false)
  """
  def betweenness_centrality(opts \\ []) do
    max_nodes = Keyword.get(opts, :max_nodes, 1000)
    normalize = Keyword.get(opts, :normalize, true)

    edges = get_call_edges()

    # Get all nodes
    node_ids =
      edges
      |> Enum.flat_map(fn {from, to} -> [from, to] end)
      |> Enum.uniq()

    # If too many nodes, select top nodes by degree
    nodes_to_compute =
      if length(node_ids) > max_nodes do
        # Get degree centrality and select top nodes
        centrality = degree_centrality()

        centrality
        |> Enum.sort_by(fn {_node, metrics} -> -metrics.total_degree end)
        |> Enum.take(max_nodes)
        |> Enum.map(fn {node, _metrics} -> node end)
      else
        node_ids
      end

    # Build adjacency for shortest paths
    adjacency = build_out_adjacency(edges)

    # Initialize betweenness scores to 0
    betweenness = Map.new(node_ids, fn node -> {node, 0.0} end)

    # Compute betweenness using Brandes' algorithm
    betweenness =
      Enum.reduce(nodes_to_compute, betweenness, fn source, acc ->
        compute_betweenness_from_source(source, adjacency, acc)
      end)

    # Normalize if requested
    if normalize and map_size(betweenness) > 2 do
      n = map_size(betweenness)
      # Normalization factor for directed graphs
      factor = (n - 1) * (n - 2)

      betweenness
      |> Map.new(fn {node, score} -> {node, score / factor} end)
    else
      betweenness
    end
  end

  @doc """
  Computes closeness centrality for nodes in the graph.

  Closeness is the inverse of the average shortest path distance from a node
  to all other reachable nodes. Higher scores indicate more "central" functions.

  ## Parameters
  - `:normalize` - Return normalized scores 0-1 (default: true)

  ## Returns
  Map of node_id => closeness_score

  ## Examples

      # Compute closeness for all nodes
      closeness_centrality()

      # Get raw (unnormalized) scores
      closeness_centrality(normalize: false)
  """
  def closeness_centrality(opts \\ []) do
    normalize = Keyword.get(opts, :normalize, true)

    edges = get_call_edges()
    adjacency = build_out_adjacency(edges)

    # Get all nodes
    node_ids =
      edges
      |> Enum.flat_map(fn {from, to} -> [from, to] end)
      |> Enum.uniq()

    # Compute closeness for each node
    node_ids
    |> Map.new(fn node ->
      {distances, _} = shortest_paths_bfs(node, adjacency)

      # Calculate average distance to reachable nodes
      reachable = Map.delete(distances, node)

      if map_size(reachable) == 0 do
        {node, 0.0}
      else
        total_distance = reachable |> Map.values() |> Enum.sum()
        avg_distance = total_distance / map_size(reachable)

        closeness =
          if avg_distance > 0 do
            1.0 / avg_distance
          else
            0.0
          end

        # Normalize by the fraction of reachable nodes
        closeness =
          if normalize do
            n_total = length(node_ids)
            n_reachable = map_size(reachable)

            if n_total > 1 do
              closeness * (n_reachable / (n_total - 1))
            else
              closeness
            end
          else
            closeness
          end

        {node, closeness}
      end
    end)
  end

  @doc """
  Detects communities in the graph using the Louvain method.

  The Louvain algorithm iteratively optimizes modularity to discover communities.
  It naturally produces a hierarchy through aggregation phases.

  ## Parameters
  - `:max_iterations` - Maximum optimization iterations (default: 10)
  - `:min_improvement` - Minimum modularity improvement to continue (default: 0.0001)
  - `:resolution` - Resolution parameter for multi-scale detection (default: 1.0)
  - `:hierarchical` - Return hierarchical community structure (default: false)

  ## Returns
  - When `:hierarchical` is false: Map of community_id => [node_ids]
  - When `:hierarchical` is true: Map with :communities, :hierarchy, :modularity_per_level

  ## Examples

      # Detect communities
      detect_communities()

      # Get hierarchical structure
      detect_communities(hierarchical: true)

      # Adjust resolution for finer/coarser communities
      detect_communities(resolution: 0.5)
  """
  def detect_communities(opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, 10)
    min_improvement = Keyword.get(opts, :min_improvement, 0.0001)
    resolution = Keyword.get(opts, :resolution, 1.0)
    hierarchical = Keyword.get(opts, :hierarchical, false)

    edges = get_call_edges()

    # Get edge weights
    edge_weights = get_edge_weights(edges)
    total_weight = Enum.sum(Map.values(edge_weights))

    # Get all nodes
    node_ids =
      edges
      |> Enum.flat_map(fn {from, to} -> [from, to] end)
      |> Enum.uniq()

    if node_ids == [] do
      if hierarchical do
        %{communities: %{}, hierarchy: [], modularity_per_level: []}
      else
        %{}
      end
    else
      # Initial: each node in its own community
      node_to_community = Map.new(node_ids, fn node -> {node, node} end)

      result =
        louvain_optimize(
          node_to_community,
          edges,
          edge_weights,
          total_weight,
          resolution,
          max_iterations,
          min_improvement,
          hierarchical
        )

      if hierarchical do
        result
      else
        # Convert to community => [nodes] format
        node_to_community = result.node_to_community

        node_to_community
        |> Enum.group_by(fn {_node, comm} -> comm end, fn {node, _comm} -> node end)
      end
    end
  end

  @doc """
  Detects communities using label propagation algorithm.

  Fast alternative to Louvain. Each node adopts the most common label among neighbors.
  Converges quickly but results can be non-deterministic.

  ## Parameters
  - `:max_iterations` - Maximum iterations (default: 20)
  - `:seed` - Random seed for deterministic results (optional)

  ## Returns
  Map of community_id => [node_ids]

  ## Examples

      # Detect communities with label propagation
      detect_communities_lp()

      # With deterministic seed
      detect_communities_lp(seed: 42)
  """
  def detect_communities_lp(opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, 20)
    seed = Keyword.get(opts, :seed)

    # Set random seed if provided
    if seed, do: :rand.seed(:exsplus, {seed, seed, seed})

    edges = get_call_edges()
    adjacency = build_out_adjacency(edges)
    in_adjacency = build_in_adjacency(edges)

    # Get all nodes
    node_ids =
      edges
      |> Enum.flat_map(fn {from, to} -> [from, to] end)
      |> Enum.uniq()

    if node_ids == [] do
      %{}
    else
      # Initial: each node gets its own label
      labels = Map.new(node_ids, fn node -> {node, node} end)

      # Iterate label propagation
      final_labels =
        label_propagation_iterate(node_ids, adjacency, in_adjacency, labels, max_iterations)

      # Group by final labels
      final_labels
      |> Enum.group_by(fn {_node, label} -> label end, fn {node, _label} -> node end)
    end
  end

  @doc """
  Exports the graph in Graphviz DOT format.

  ## Parameters
  - `:include_communities` - Include community clustering (default: true)
  - `:color_by` - Centrality metric for node coloring: :pagerank, :betweenness, :degree (default: :pagerank)
  - `:max_nodes` - Maximum nodes to include (default: 500)

  ## Returns
  `{:ok, dot_string}` or `{:error, reason}`

  ## Examples

      # Export with default settings
      {:ok, dot} = export_graphviz()

      # Color by betweenness centrality
      {:ok, dot} = export_graphviz(color_by: :betweenness)
  """
  def export_graphviz(opts \\ []) do
    include_communities = Keyword.get(opts, :include_communities, true)
    color_by = Keyword.get(opts, :color_by, :pagerank)
    max_nodes = Keyword.get(opts, :max_nodes, 500)

    edges = get_call_edges()

    # Get all nodes
    all_nodes =
      edges
      |> Enum.flat_map(fn {from, to} -> [from, to] end)
      |> Enum.uniq()
      |> Enum.take(max_nodes)

    if all_nodes == [] do
      {:ok, "digraph G {\n}\n"}
    else
      # Compute metrics for coloring
      metrics =
        case color_by do
          :pagerank ->
            pagerank()

          :betweenness ->
            betweenness_centrality(max_nodes: max_nodes)

          :degree ->
            degree_centrality()
            |> Map.new(fn {node, m} -> {node, m.total_degree / 1.0} end)

          _ ->
            %{}
        end

      # Detect communities if requested
      communities = if include_communities, do: detect_communities(), else: %{}

      # Build DOT string
      dot = build_graphviz_dot(all_nodes, edges, communities, metrics, color_by)
      {:ok, dot}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Exports the graph in D3.js force-directed JSON format.

  ## Parameters
  - `:include_communities` - Include community metadata (default: true)
  - `:max_nodes` - Maximum nodes to include (default: 500)

  ## Returns
  `{:ok, json_map}` or `{:error, reason}`

  ## Examples

      # Export for D3.js visualization
      {:ok, json} = export_d3_json()
      File.write!("graph.json", Jason.encode!(json))
  """
  def export_d3_json(opts \\ []) do
    include_communities = Keyword.get(opts, :include_communities, true)
    max_nodes = Keyword.get(opts, :max_nodes, 500)

    edges = get_call_edges()

    # Get all nodes
    all_nodes =
      edges
      |> Enum.flat_map(fn {from, to} -> [from, to] end)
      |> Enum.uniq()
      |> Enum.take(max_nodes)

    if all_nodes == [] do
      {:ok, %{nodes: [], links: []}}
    else
      # Get metrics
      pagerank_scores = pagerank()
      degree_metrics = degree_centrality()

      # Detect communities
      communities = if include_communities, do: detect_communities(), else: %{}
      node_to_community = invert_community_map(communities)

      # Build nodes list
      nodes =
        Enum.map(all_nodes, fn node ->
          %{
            id: format_node_id_string(node),
            type: get_node_type(node),
            pagerank: Map.get(pagerank_scores, node, 0.0),
            degree: Map.get(degree_metrics, node, %{total_degree: 0}).total_degree,
            community: Map.get(node_to_community, node)
          }
        end)

      # Build edges list
      node_set = MapSet.new(all_nodes)

      links =
        edges
        |> Enum.filter(fn {from, to} ->
          MapSet.member?(node_set, from) and MapSet.member?(node_set, to)
        end)
        |> Enum.map(fn {from, to} ->
          weight = get_edge_weight_value(from, to)

          %{
            source: format_node_id_string(from),
            target: format_node_id_string(to),
            weight: weight
          }
        end)

      {:ok, %{nodes: nodes, links: links}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Computes comprehensive graph statistics.

  Returns a map with:
  - Node counts by type
  - Edge counts
  - Average degree
  - Density
  - Connected components count
  - Top nodes by PageRank
  """
  def graph_stats do
    nodes = Store.list_nodes()
    edges = get_call_edges()

    node_counts =
      nodes
      |> Enum.group_by(& &1.type)
      |> Map.new(fn {type, list} -> {type, length(list)} end)

    centrality = degree_centrality()

    degrees = centrality |> Map.values() |> Enum.map(& &1.total_degree)
    avg_degree = if degrees != [], do: Enum.sum(degrees) / length(degrees), else: 0.0

    n = length(nodes)
    m = length(edges)
    density = if n > 1, do: m / (n * (n - 1)), else: 0.0

    # Compute PageRank
    pr_scores = pagerank()

    top_by_pagerank =
      pr_scores
      |> Enum.sort_by(fn {_id, score} -> -score end)
      |> Enum.take(10)

    %{
      node_count: n,
      node_counts_by_type: node_counts,
      edge_count: m,
      average_degree: Float.round(avg_degree, 2),
      density: Float.round(density, 4),
      top_nodes: top_by_pagerank
    }
  end

  # Private functions

  defp iterate_pagerank(
         scores,
         node_ids,
         out_edges,
         in_edges,
         damping,
         max_iter,
         tolerance,
         iter \\ 0
       )

  defp iterate_pagerank(
         scores,
         _node_ids,
         _out_edges,
         _in_edges,
         _damping,
         max_iter,
         _tolerance,
         iter
       )
       when iter >= max_iter do
    scores
  end

  defp iterate_pagerank(scores, node_ids, out_edges, in_edges, damping, max_iter, tolerance, iter) do
    n = length(node_ids)
    base_score = (1.0 - damping) / n

    # Compute new scores
    new_scores =
      Map.new(node_ids, fn node ->
        # Sum contributions from incoming edges
        incoming_contribution =
          case Map.get(in_edges, node, []) do
            [] ->
              0.0

            inbound ->
              Enum.reduce(inbound, 0.0, fn from_node, acc ->
                from_score = Map.get(scores, from_node, 0.0)
                out_count = length(Map.get(out_edges, from_node, []))

                if out_count > 0 do
                  acc + from_score / out_count
                else
                  acc
                end
              end)
          end

        score = base_score + damping * incoming_contribution
        {node, score}
      end)

    # Check convergence
    max_diff =
      Enum.reduce(node_ids, 0.0, fn node, max_d ->
        old_score = Map.get(scores, node, 0.0)
        new_score = Map.get(new_scores, node, 0.0)
        diff = abs(new_score - old_score)
        max(max_d, diff)
      end)

    if max_diff < tolerance do
      new_scores
    else
      iterate_pagerank(
        new_scores,
        node_ids,
        out_edges,
        in_edges,
        damping,
        max_iter,
        tolerance,
        iter + 1
      )
    end
  end

  # Check if we've hit the max_paths limit (early stopping)
  defp find_paths_dfs(_from, _to, _adjacency, _max_depth, max_paths, _path, _visited, count)
       when count >= max_paths do
    {[], count}
  end

  # Check if path length (number of edges) exceeds max_depth
  # Path length in edges = number of nodes - 1
  defp find_paths_dfs(_from, _to, _adjacency, max_depth, _max_paths, path, _visited, count)
       when length(path) - 1 > max_depth do
    {[], count}
  end

  defp find_paths_dfs(current, target, adjacency, max_depth, max_paths, path, visited, count) do
    cond do
      current == target ->
        # Found a path, increment count
        {[Enum.reverse(path)], count + 1}

      length(path) - 1 >= max_depth ->
        # Don't explore further if we've already reached max depth
        {[], count}

      true ->
        explore_neighbors(adjacency, current, target, max_depth, max_paths, path, visited, count)
    end
  end

  defp explore_neighbors(adjacency, current, target, max_depth, max_paths, path, visited, count) do
    neighbors = Map.get(adjacency, current, [])

    # Accumulate paths and count with early stopping
    neighbors
    |> Enum.reject(&MapSet.member?(visited, &1))
    |> Enum.reduce({[], count}, fn neighbor, {acc_paths, acc_count} ->
      explore_neighbor(
        neighbor,
        {target, adjacency, max_depth, max_paths, path, visited},
        {acc_paths, acc_count}
      )
    end)
  end

  defp explore_neighbor(
         neighbor,
         {target, adjacency, max_depth, max_paths, path, visited},
         {acc_paths, acc_count}
       ) do
    # Stop exploring if we've hit max_paths
    if acc_count >= max_paths do
      {acc_paths, acc_count}
    else
      new_path = [neighbor | path]
      new_visited = MapSet.put(visited, neighbor)

      {new_paths, new_count} =
        find_paths_dfs(
          neighbor,
          target,
          adjacency,
          max_depth,
          max_paths,
          new_path,
          new_visited,
          acc_count
        )

      {acc_paths ++ new_paths, new_count}
    end
  end

  defp get_call_edges do
    # Get all :calls edges from the edges table
    # Edges are stored as {{from_node, to_node, edge_type}, metadata}
    :ets.match(:ragex_edges, {{:"$1", :"$2", :calls}, :_})
    |> Enum.map(fn [from, to] -> {from, to} end)
    |> Enum.uniq()
  end

  defp build_adjacency(edges) do
    out_edges =
      edges
      |> Enum.group_by(fn {from, _to} -> from end, fn {_from, to} -> to end)

    in_edges =
      edges
      |> Enum.group_by(fn {_from, to} -> to end, fn {from, _to} -> from end)

    {out_edges, in_edges}
  end

  defp build_out_adjacency(edges) do
    edges
    |> Enum.group_by(fn {from, _to} -> from end, fn {_from, to} -> to end)
  end

  # Check if starting node has high degree (potential for exponential explosion)
  defp check_dense_graph(from, adjacency) do
    out_degree = length(Map.get(adjacency, from, []))

    cond do
      out_degree >= 20 ->
        require Logger

        Logger.warning(
          "Dense graph detected: Node #{inspect(from)} has #{out_degree} outgoing edges. " <>
            "Path finding may be slow or return partial results. Consider reducing max_depth or max_paths."
        )

      out_degree >= 10 ->
        require Logger

        Logger.info(
          "Moderately connected node: #{inspect(from)} has #{out_degree} outgoing edges. " <>
            "Path finding may take some time."
        )

      true ->
        :ok
    end
  end

  # BFS-based shortest paths from a source node
  # Returns {distances, path_counts} maps
  defp shortest_paths_bfs(source, adjacency) do
    # Initialize
    distances = %{source => 0}
    path_counts = %{source => 1}
    queue = :queue.from_list([source])

    bfs_iterate(queue, adjacency, distances, path_counts)
  end

  defp bfs_iterate(queue, adjacency, distances, path_counts) do
    case :queue.out(queue) do
      {{:value, node}, rest_queue} ->
        current_dist = Map.get(distances, node)
        neighbors = Map.get(adjacency, node, [])

        # Process each neighbor
        {new_queue, new_distances, new_path_counts} =
          Enum.reduce(neighbors, {rest_queue, distances, path_counts}, fn neighbor,
                                                                          {q, dists, counts} ->
            neighbor_dist = Map.get(dists, neighbor)

            cond do
              # First time visiting this node
              neighbor_dist == nil ->
                new_dists = Map.put(dists, neighbor, current_dist + 1)
                new_counts = Map.put(counts, neighbor, Map.get(counts, node, 1))
                new_q = :queue.in(neighbor, q)
                {new_q, new_dists, new_counts}

              # Found another shortest path to this node
              neighbor_dist == current_dist + 1 ->
                old_count = Map.get(counts, neighbor, 0)
                node_count = Map.get(counts, node, 1)
                new_counts = Map.put(counts, neighbor, old_count + node_count)
                {q, dists, new_counts}

              # Already visited via a shorter path
              true ->
                {q, dists, counts}
            end
          end)

        bfs_iterate(new_queue, adjacency, new_distances, new_path_counts)

      {:empty, _} ->
        {distances, path_counts}
    end
  end

  # Get edge weights for all edges
  defp get_edge_weights(edges) do
    edges
    |> Map.new(fn {from, to} ->
      weight = Store.get_edge_weight(from, to, :calls) || 1.0
      {{from, to}, weight}
    end)
  end

  # Get single edge weight
  defp get_edge_weight_value(from, to) do
    Store.get_edge_weight(from, to, :calls) || 1.0
  end

  # Build incoming adjacency
  defp build_in_adjacency(edges) do
    edges
    |> Enum.group_by(fn {_from, to} -> to end, fn {from, _to} -> from end)
  end

  # Louvain optimization with optional hierarchical tracking
  defp louvain_optimize(
         node_to_community,
         edges,
         edge_weights,
         total_weight,
         resolution,
         max_iterations,
         min_improvement,
         hierarchical
       ) do
    hierarchy = if hierarchical, do: [], else: nil
    modularity_history = if hierarchical, do: [], else: nil

    initial_modularity =
      compute_modularity(node_to_community, edges, edge_weights, total_weight, resolution)

    result =
      louvain_iterate(
        node_to_community,
        edges,
        edge_weights,
        total_weight,
        resolution,
        initial_modularity,
        max_iterations,
        min_improvement,
        0,
        hierarchy,
        modularity_history
      )

    if hierarchical do
      final_communities =
        result.node_to_community
        |> Enum.group_by(fn {_node, comm} -> comm end, fn {node, _comm} -> node end)

      %{
        communities: final_communities,
        hierarchy: result.hierarchy || [],
        modularity_per_level: result.modularity_history || [],
        node_to_community: result.node_to_community
      }
    else
      result
    end
  end

  # credo:disable-for-next-line
  defp louvain_iterate(
         node_to_community,
         _edges,
         _edge_weights,
         _total_weight,
         _resolution,
         _current_modularity,
         max_iterations,
         _min_improvement,
         iteration,
         hierarchy,
         modularity_history
       )
       when iteration >= max_iterations do
    %{
      node_to_community: node_to_community,
      hierarchy: hierarchy,
      modularity_history: modularity_history
    }
  end

  # credo:disable-for-next-line
  defp louvain_iterate(
         node_to_community,
         edges,
         edge_weights,
         total_weight,
         resolution,
         current_modularity,
         max_iterations,
         min_improvement,
         iteration,
         hierarchy,
         modularity_history
       ) do
    # Phase 1: Local optimization
    {new_node_to_community, improved} =
      louvain_local_move(node_to_community, edges, edge_weights, total_weight, resolution)

    new_modularity =
      compute_modularity(new_node_to_community, edges, edge_weights, total_weight, resolution)

    improvement = new_modularity - current_modularity

    # Track hierarchy if requested
    new_hierarchy =
      if hierarchy != nil do
        communities =
          new_node_to_community
          |> Enum.group_by(fn {_node, comm} -> comm end, fn {node, _comm} -> node end)

        hierarchy ++ [%{level: iteration, communities: communities, modularity: new_modularity}]
      else
        nil
      end

    new_modularity_history =
      if modularity_history != nil do
        modularity_history ++ [new_modularity]
      else
        nil
      end

    # Check if we should continue
    if improved and improvement > min_improvement do
      louvain_iterate(
        new_node_to_community,
        edges,
        edge_weights,
        total_weight,
        resolution,
        new_modularity,
        max_iterations,
        min_improvement,
        iteration + 1,
        new_hierarchy,
        new_modularity_history
      )
    else
      %{
        node_to_community: new_node_to_community,
        hierarchy: new_hierarchy,
        modularity_history: new_modularity_history
      }
    end
  end

  # Local move phase of Louvain: try moving each node to neighbor's community
  defp louvain_local_move(node_to_community, edges, edge_weights, total_weight, resolution) do
    # Build adjacency
    adjacency = build_out_adjacency(edges)
    in_adjacency = build_in_adjacency(edges)

    nodes = Map.keys(node_to_community)

    # Try moving each node
    Enum.reduce(nodes, {node_to_community, false}, fn node, {current_assignment, any_improved} ->
      current_comm = Map.get(current_assignment, node)

      # Get neighboring communities
      out_neighbors = Map.get(adjacency, node, [])
      in_neighbors = Map.get(in_adjacency, node, [])

      neighbor_communities =
        (out_neighbors ++ in_neighbors)
        |> Enum.map(fn neighbor -> Map.get(current_assignment, neighbor) end)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == current_comm))

      # Calculate modularity gain for each move
      best_move =
        neighbor_communities
        |> Enum.map(fn target_comm ->
          gain =
            modularity_gain(
              node,
              current_comm,
              target_comm,
              current_assignment,
              edges,
              edge_weights,
              total_weight,
              resolution
            )

          {target_comm, gain}
        end)
        |> Enum.max_by(fn {_comm, gain} -> gain end, fn -> {current_comm, 0.0} end)

      {best_comm, best_gain} = best_move

      if best_gain > 0.0 do
        {Map.put(current_assignment, node, best_comm), true}
      else
        {current_assignment, any_improved}
      end
    end)
  end

  # Compute modularity Q
  defp compute_modularity(node_to_community, edges, edge_weights, total_weight, resolution) do
    if total_weight == 0 do
      0.0
    else
      # Compute internal edges weight for each community
      internal_weight =
        edges
        |> Enum.reduce(0.0, fn {from, to}, acc ->
          from_comm = Map.get(node_to_community, from)
          to_comm = Map.get(node_to_community, to)
          weight = Map.get(edge_weights, {from, to}, 1.0)

          if from_comm == to_comm do
            acc + weight
          else
            acc
          end
        end)

      # Compute degree sums for each community
      community_degrees =
        node_to_community
        |> Enum.group_by(fn {_node, comm} -> comm end, fn {node, _comm} -> node end)
        |> Map.new(fn {comm, nodes} ->
          degree_sum =
            edges
            |> Enum.reduce(0.0, fn {from, to}, acc ->
              weight = Map.get(edge_weights, {from, to}, 1.0)

              cond do
                Enum.member?(nodes, from) -> acc + weight
                Enum.member?(nodes, to) -> acc + weight
                true -> acc
              end
            end)

          {comm, degree_sum}
        end)

      expected_weight =
        community_degrees
        |> Map.values()
        |> Enum.reduce(0.0, fn degree_sum, acc ->
          acc + degree_sum * degree_sum / (2.0 * total_weight)
        end)

      resolution * (internal_weight / total_weight - expected_weight / total_weight)
    end
  end

  # Calculate modularity gain from moving a node to a new community
  defp modularity_gain(
         node,
         from_comm,
         to_comm,
         node_to_community,
         edges,
         edge_weights,
         total_weight,
         resolution
       ) do
    # This is a simplified version; full implementation would track community stats
    # For now, compute delta Q approximately

    # Edges from node to each community
    edges_to_comm = fn comm ->
      edges
      |> Enum.reduce(0.0, fn {from, to}, acc ->
        weight = Map.get(edge_weights, {from, to}, 1.0)
        to_comm_actual = Map.get(node_to_community, to)
        from_comm_actual = Map.get(node_to_community, from)

        cond do
          from == node and to_comm_actual == comm -> acc + weight
          to == node and from_comm_actual == comm -> acc + weight
          true -> acc
        end
      end)
    end

    edges_to_from = edges_to_comm.(from_comm)
    edges_to_to = edges_to_comm.(to_comm)

    # Simplified gain calculation
    gain = resolution * ((edges_to_to - edges_to_from) / total_weight)
    gain
  end

  # Label propagation iteration
  defp label_propagation_iterate(_node_ids, _adjacency, _in_adjacency, labels, 0) do
    labels
  end

  defp label_propagation_iterate(node_ids, adjacency, in_adjacency, labels, iterations_left) do
    # Randomize node order for better convergence
    shuffled_nodes = Enum.shuffle(node_ids)

    new_labels =
      Enum.reduce(shuffled_nodes, labels, fn node, current_labels ->
        # Get all neighbors (in + out)
        out_neighbors = Map.get(adjacency, node, [])
        in_neighbors = Map.get(in_adjacency, node, [])
        all_neighbors = out_neighbors ++ in_neighbors

        if all_neighbors == [] do
          current_labels
        else
          # Count label frequencies among neighbors
          label_counts =
            all_neighbors
            |> Enum.map(fn neighbor -> Map.get(current_labels, neighbor) end)
            |> Enum.frequencies()

          # Pick most common label (ties broken randomly)
          {most_common_label, _count} =
            label_counts
            |> Enum.max_by(fn {_label, count} -> count end)

          Map.put(current_labels, node, most_common_label)
        end
      end)

    # Check for convergence
    if new_labels == labels do
      labels
    else
      label_propagation_iterate(
        node_ids,
        adjacency,
        in_adjacency,
        new_labels,
        iterations_left - 1
      )
    end
  end

  # Build Graphviz DOT string
  defp build_graphviz_dot(nodes, edges, communities, metrics, _color_by) do
    # Start graph
    lines = ["digraph G {"]
    lines = lines ++ ["  rankdir=LR;"]
    lines = lines ++ ["  node [shape=box, style=filled];"]
    lines = lines ++ [""]

    # Get max metric value for color scaling
    max_metric =
      if map_size(metrics) > 0 do
        metrics |> Map.values() |> Enum.max()
      else
        1.0
      end

    # Group nodes by community for clustering
    node_to_community = invert_community_map(communities)

    nodes_by_community =
      if map_size(communities) > 0 do
        Enum.group_by(nodes, fn node -> Map.get(node_to_community, node, 0) end)
      else
        %{0 => nodes}
      end

    # Add nodes with communities as subgraphs
    lines =
      Enum.reduce(nodes_by_community, lines, fn {comm_id, comm_nodes}, acc ->
        if map_size(communities) > 0 do
          # Create safe cluster ID (alphanumeric only) for the subgraph name
          safe_comm_id = safe_cluster_id(comm_id)
          # Create readable label showing the actual community ID
          readable_label = format_community_label(comm_id, length(comm_nodes))
          acc = acc ++ ["  subgraph cluster_#{safe_comm_id} {"]
          acc = acc ++ ["    label = \"#{readable_label}\";"]
          acc = acc ++ ["    style = filled;"]
          acc = acc ++ ["    color = lightgrey;"]
          acc = acc ++ [""]

          acc =
            Enum.reduce(comm_nodes, acc, fn node, node_acc ->
              node_acc ++ [format_dot_node(node, metrics, max_metric)]
            end)

          acc ++ ["  }", ""]
        else
          Enum.reduce(comm_nodes, acc, fn node, node_acc ->
            node_acc ++ [format_dot_node(node, metrics, max_metric)]
          end)
        end
      end)

    # Add edges
    node_set = MapSet.new(nodes)
    lines = lines ++ [""]

    lines =
      edges
      |> Enum.filter(fn {from, to} ->
        MapSet.member?(node_set, from) and MapSet.member?(node_set, to)
      end)
      |> Enum.reduce(lines, fn {from, to}, acc ->
        weight = get_edge_weight_value(from, to)
        # Scale edge thickness
        penwidth = 1.0 + (weight - 1.0) * 2.0
        from_str = format_node_id_dot(from)
        to_str = format_node_id_dot(to)
        acc ++ ["  #{from_str} -> #{to_str} [penwidth=#{Float.round(penwidth, 1)}];"]
      end)

    lines = lines ++ ["}"]
    Enum.join(lines, "\n") <> "\n"
  end

  defp format_dot_node(node, metrics, max_metric) do
    node_str = format_node_id_dot(node)
    label = format_node_id_string(node)
    metric_value = Map.get(metrics, node, 0.0)

    # Color from white (0) to red (max)
    intensity = if max_metric > 0, do: metric_value / max_metric, else: 0.0
    # HSV: 0 = red, reduce saturation for lighter colors
    color = "\"0.0 #{Float.round(intensity, 2)} 1.0\""

    "    #{node_str} [label=\"#{String.replace(label, "\"", "\\\"")}\", fillcolor=#{color}];"
  end

  defp format_node_id_dot(node) do
    # Create valid DOT identifier
    "n_" <> (format_node_id_string(node) |> String.replace(~r/[^a-zA-Z0-9_]/, "_"))
  end

  defp safe_cluster_id(comm_id) do
    # Convert community ID to safe alphanumeric string
    cond do
      is_integer(comm_id) ->
        Integer.to_string(comm_id)

      is_atom(comm_id) ->
        Atom.to_string(comm_id) |> String.replace(~r/[^a-zA-Z0-9_]/, "_")

      is_tuple(comm_id) ->
        # Hash the tuple to get a consistent integer ID
        :erlang.phash2(comm_id) |> Integer.to_string()

      true ->
        # Fallback: hash any other type
        :erlang.phash2(comm_id) |> Integer.to_string()
    end
  end

  defp format_community_label(comm_id, node_count) do
    # Create readable label for community
    label_text =
      cond do
        is_integer(comm_id) ->
          "Community #{comm_id}"

        is_atom(comm_id) ->
          "Community: #{Atom.to_string(comm_id)}"

        is_tuple(comm_id) ->
          # For tuple (likely a function node), show a shortened version
          case comm_id do
            {:function, module, name, arity} ->
              "Cluster: #{module}.#{name}/#{arity}"

            {:module, id} ->
              "Module: #{id}"

            _ ->
              # For other tuples, show first element or hash
              elem_count = tuple_size(comm_id)

              if elem_count > 0 do
                first = elem(comm_id, 0)
                "Community: #{inspect(first)}... (#{elem_count} elements)"
              else
                "Community #{:erlang.phash2(comm_id)}"
              end
          end

        true ->
          "Community #{:erlang.phash2(comm_id)}"
      end

    # Add node count
    "#{label_text} (#{node_count} nodes)"
  end

  defp format_node_id_string(node) do
    case node do
      {:function, module, name, arity} -> "#{trim_elixir_prefix(module)}.#{name}/#{arity}"
      {:module, id} -> trim_elixir_prefix(id)
      _ -> inspect(node)
    end
  end

  defp trim_elixir_prefix(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp trim_elixir_prefix(other), do: to_string(other)

  defp get_node_type(node) do
    case node do
      {:function, _, _, _} -> "function"
      {:module, _} -> "module"
      _ -> "unknown"
    end
  end

  defp invert_community_map(communities) do
    communities
    |> Enum.flat_map(fn {comm_id, nodes} ->
      Enum.map(nodes, fn node -> {node, comm_id} end)
    end)
    |> Map.new()
  end

  # Compute betweenness contribution from a single source using Brandes' algorithm
  defp compute_betweenness_from_source(source, adjacency, betweenness) do
    # Run BFS to get distances and path counts
    {distances, path_counts} = shortest_paths_bfs(source, adjacency)

    # Build predecessor lists (nodes that lead to each node on shortest paths)
    predecessors =
      Enum.reduce(distances, %{}, fn {node, dist}, acc ->
        if node == source do
          acc
        else
          preds =
            adjacency
            |> Enum.filter(fn {pred_node, neighbors} ->
              pred_node != node and Enum.member?(neighbors, node) and
                Map.get(distances, pred_node, :infinity) == dist - 1
            end)
            |> Enum.map(fn {pred_node, _} -> pred_node end)

          Map.put(acc, node, preds)
        end
      end)

    # Compute dependency scores (bottom-up from furthest nodes)
    nodes_by_distance =
      distances
      |> Enum.sort_by(fn {_node, dist} -> -dist end)
      |> Enum.map(fn {node, _dist} -> node end)

    dependency = Map.new(distances, fn {node, _} -> {node, 0.0} end)

    {_, updated_betweenness} =
      Enum.reduce(nodes_by_distance, {dependency, betweenness}, fn node, {dep, btwn} ->
        if node == source do
          {dep, btwn}
        else
          preds = Map.get(predecessors, node, [])
          node_dep = Map.get(dep, node, 0.0)
          node_paths = Map.get(path_counts, node, 1)

          # Distribute dependency to predecessors
          new_dep =
            Enum.reduce(preds, dep, fn pred, acc_dep ->
              pred_paths = Map.get(path_counts, pred, 1)
              contribution = pred_paths / node_paths * (1.0 + node_dep)
              Map.update(acc_dep, pred, contribution, &(&1 + contribution))
            end)

          # Update betweenness for this node (but not the source)
          new_btwn = Map.update(btwn, node, node_dep, &(&1 + node_dep))

          {new_dep, new_btwn}
        end
      end)

    updated_betweenness
  end
end
