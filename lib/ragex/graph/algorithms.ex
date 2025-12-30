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
    # Get all call relationships from the graph
    Store.list_nodes()
    |> Enum.filter(&(&1.type == :call))
    |> Enum.map(fn call_node ->
      # Call nodes have caller and callee in data
      {call_node.data.caller, call_node.data.callee}
    end)
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
end
