defmodule Ragex.Editor.Visualize do
  @moduledoc """
  Visualization utilities for refactoring operations.

  Generates visual representations of:
  - Call graph changes before/after refactoring
  - Impact radius (affected functions and modules)
  - Risk analysis based on centrality and dependencies

  Supports multiple output formats:
  - Graphviz DOT (for rendering with dot/neato/etc.)
  - D3.js JSON (for web visualization)
  - ASCII art (for terminal display)
  """

  alias Ragex.Graph.{Algorithms, Store}

  @type visualization_format :: :graphviz | :d3_json | :ascii
  @type impact_data :: %{
          affected_functions: [node_id()],
          affected_modules: [module_name()],
          impact_radius: non_neg_integer(),
          risk_score: float(),
          centrality_metrics: map()
        }

  @type node_id :: term()
  @type module_name :: atom()

  @doc """
  Visualizes the impact radius of a refactoring operation.

  Highlights the affected nodes and their immediate neighbors
  in the call graph.

  ## Parameters
  - `affected_files`: List of file paths modified by refactoring
  - `format`: Output format (:graphviz, :d3_json, or :ascii)
  - `opts`: Options
    - `:depth` - How many levels of neighbors to include (default: 1)
    - `:include_risk` - Include risk analysis (default: true)
    - `:color_by_risk` - Color nodes by risk score (default: true)

  ## Returns
  - `{:ok, visualization_string}` for :graphviz or :ascii
  - `{:ok, json_map}` for :d3_json
  - `{:error, reason}` on failure
  """
  @spec visualize_impact([String.t()], visualization_format(), keyword()) ::
          {:ok, String.t() | map()} | {:error, term()}
  def visualize_impact(affected_files, format \\ :graphviz, opts \\ []) do
    depth = Keyword.get(opts, :depth, 1)
    include_risk = Keyword.get(opts, :include_risk, true)

    with {:ok, impact_data} <- analyze_impact(affected_files, depth, include_risk) do
      case format do
        :graphviz -> generate_graphviz_impact(impact_data, opts)
        :d3_json -> generate_d3_impact(impact_data, opts)
        :ascii -> generate_ascii_impact(impact_data, opts)
        _ -> {:error, "Unknown format: #{format}"}
      end
    end
  end

  @doc """
  Analyzes the impact of changes to a set of files.

  Returns comprehensive impact data including affected nodes,
  impact radius, and risk analysis.

  ## Parameters
  - `affected_files`: List of file paths
  - `depth`: How many levels to traverse (default: 1)
  - `include_risk`: Compute risk metrics (default: true)

  ## Returns
  - `{:ok, impact_data}` with analysis results
  - `{:error, reason}` on failure
  """
  @spec analyze_impact([String.t()], non_neg_integer(), boolean()) ::
          {:ok, impact_data()} | {:error, term()}
  def analyze_impact(affected_files, depth \\ 1, include_risk \\ true) do
    # Find all functions/modules in affected files
    affected_nodes = find_nodes_in_files(affected_files)

    # Expand to include neighbors up to specified depth
    expanded_nodes = expand_impact_radius(affected_nodes, depth)

    # Extract affected modules
    affected_modules =
      expanded_nodes
      |> Enum.filter(&match?({:module, _}, &1))
      |> Enum.map(fn {:module, name} -> name end)
      |> Enum.uniq()

    # Compute risk metrics if requested
    risk_data =
      if include_risk do
        compute_risk_metrics(affected_nodes, expanded_nodes)
      else
        %{risk_score: 0.0, centrality_metrics: %{}}
      end

    {:ok,
     %{
       affected_functions: affected_nodes,
       affected_modules: affected_modules,
       impact_radius: length(expanded_nodes) - length(affected_nodes),
       risk_score: risk_data.risk_score,
       centrality_metrics: risk_data.centrality_metrics
     }}
  end

  @doc """
  Generates a diff visualization showing before/after state.

  Useful for visualizing graph structure changes.

  ## Parameters
  - `before_nodes`: Nodes before refactoring
  - `after_nodes`: Nodes after refactoring
  - `format`: Output format

  ## Returns
  - `{:ok, visualization}` with diff representation
  """
  @spec visualize_diff([node_id()], [node_id()], visualization_format()) ::
          {:ok, String.t() | map()} | {:error, term()}
  def visualize_diff(before_nodes, after_nodes, format \\ :ascii) do
    added = MapSet.difference(MapSet.new(after_nodes), MapSet.new(before_nodes))
    removed = MapSet.difference(MapSet.new(before_nodes), MapSet.new(after_nodes))
    unchanged = MapSet.intersection(MapSet.new(before_nodes), MapSet.new(after_nodes))

    case format do
      :ascii ->
        generate_ascii_diff(added, removed, unchanged)

      :graphviz ->
        generate_graphviz_diff(added, removed, unchanged)

      :d3_json ->
        generate_d3_diff(added, removed, unchanged)

      _ ->
        {:error, "Unknown format: #{format}"}
    end
  end

  # Private functions - Impact analysis

  defp find_nodes_in_files(file_paths) do
    file_set = MapSet.new(file_paths)

    Store.list_nodes()
    |> Enum.filter(fn node ->
      node_file = node[:file]
      node_file && MapSet.member?(file_set, node_file)
    end)
    |> Enum.map(fn node ->
      case {node.type, node.id} do
        {:function, {mod, name, arity}} -> {:function, mod, name, arity}
        {:module, id} -> {:module, id}
        {type, id} -> {type, id}
      end
    end)
  end

  defp expand_impact_radius(nodes, depth) when depth <= 0, do: nodes

  defp expand_impact_radius(nodes, depth) do
    # Get immediate neighbors (callers and callees)
    neighbors =
      nodes
      |> Enum.flat_map(fn node ->
        callers = Store.get_incoming_edges(node, :calls) |> Enum.map(& &1.from)
        callees = Store.get_outgoing_edges(node, :calls) |> Enum.map(& &1.to)
        callers ++ callees
      end)
      |> Enum.uniq()

    all_nodes = Enum.uniq(nodes ++ neighbors)

    if depth > 1 do
      expand_impact_radius(all_nodes, depth - 1)
    else
      all_nodes
    end
  end

  defp compute_risk_metrics(core_nodes, expanded_nodes) do
    # Get centrality metrics for all expanded nodes
    degree_centrality = Algorithms.degree_centrality()
    pagerank_scores = Algorithms.pagerank()

    # Compute risk score based on:
    # 1. Number of affected nodes
    # 2. Average centrality of affected nodes
    # 3. Proportion of high-centrality nodes affected

    core_set = MapSet.new(core_nodes)

    centrality_scores =
      expanded_nodes
      |> Enum.map(fn node ->
        is_core = MapSet.member?(core_set, node)
        degree = Map.get(degree_centrality, node, %{total_degree: 0}).total_degree
        pagerank = Map.get(pagerank_scores, node, 0.0)

        {node, %{is_core: is_core, degree: degree, pagerank: pagerank}}
      end)
      |> Map.new()

    # Risk score: weighted average of centrality metrics for core nodes
    core_pagerank_sum =
      core_nodes
      |> Enum.map(&Map.get(pagerank_scores, &1, 0.0))
      |> Enum.sum()

    core_degree_avg =
      core_nodes
      |> Enum.map(fn node ->
        Map.get(degree_centrality, node, %{total_degree: 0}).total_degree
      end)
      |> then(fn
        [_ | _] = degrees -> Enum.sum(degrees) / length(degrees)
        _ -> 0.0
      end)

    # Normalize to 0-1 scale (heuristic)
    risk_score = min(1.0, (core_pagerank_sum * 100 + core_degree_avg) / 100)

    %{
      risk_score: risk_score,
      centrality_metrics: centrality_scores
    }
  end

  # Private functions - Graphviz generation

  defp generate_graphviz_impact(impact_data, opts) do
    color_by_risk = Keyword.get(opts, :color_by_risk, true)

    nodes = impact_data.affected_functions
    core_set = MapSet.new(nodes)
    metrics = impact_data.centrality_metrics

    # Build DOT string
    dot_lines = [
      "digraph RefactorImpact {",
      "  rankdir=LR;",
      "  node [shape=box, style=filled];",
      ""
    ]

    # Add nodes
    node_lines =
      nodes
      |> Enum.map(fn node ->
        node_metrics = Map.get(metrics, node, %{})
        is_core = Map.get(node_metrics, :is_core, false)

        # Color by risk if enabled
        color =
          if color_by_risk && is_core do
            risk = impact_data.risk_score
            get_risk_color(risk)
          else
            if is_core, do: "#ffcccc", else: "#ccccff"
          end

        label = format_node_label(node)
        ~s(  "#{format_node_id(node)}" [label="#{label}", fillcolor="#{color}"];)
      end)

    # Add edges
    edge_lines =
      nodes
      |> Enum.flat_map(fn node ->
        Store.get_outgoing_edges(node, :calls)
        |> Enum.filter(fn edge -> MapSet.member?(core_set, edge.to) end)
        |> Enum.map(fn edge ->
          from = format_node_id(node)
          to = format_node_id(edge.to)
          ~s(  "#{from}" -> "#{to}";)
        end)
      end)

    all_lines = dot_lines ++ node_lines ++ [""] ++ edge_lines ++ ["}"]
    {:ok, Enum.join(all_lines, "\n")}
  end

  defp generate_graphviz_diff(added, removed, unchanged) do
    all_nodes = MapSet.union(added, removed) |> MapSet.union(unchanged)

    dot_lines = [
      "digraph RefactorDiff {",
      "  rankdir=LR;",
      "  node [shape=box, style=filled];",
      ""
    ]

    node_lines =
      all_nodes
      |> Enum.map(fn node ->
        {color, style} =
          cond do
            MapSet.member?(added, node) -> {"#ccffcc", "filled,bold"}
            MapSet.member?(removed, node) -> {"#ffcccc", "filled,dashed"}
            true -> {"#eeeeee", "filled"}
          end

        label = format_node_label(node)

        ~s(  "#{format_node_id(node)}" [label="#{label}", fillcolor="#{color}", style="#{style}"];)
      end)

    all_lines = dot_lines ++ node_lines ++ ["}"]
    {:ok, Enum.join(all_lines, "\n")}
  end

  defp get_risk_color(risk) when risk < 0.3, do: "#90ee90"
  defp get_risk_color(risk) when risk < 0.6, do: "#ffff99"
  defp get_risk_color(_risk), do: "#ff6666"

  # Private functions - D3.js JSON generation

  defp generate_d3_impact(impact_data, _opts) do
    nodes = impact_data.affected_functions
    metrics = impact_data.centrality_metrics

    node_list =
      nodes
      |> Enum.map(fn node ->
        node_metrics = Map.get(metrics, node, %{})

        %{
          id: format_node_id_string(node),
          label: format_node_label(node),
          is_core: Map.get(node_metrics, :is_core, false),
          degree: Map.get(node_metrics, :degree, 0),
          pagerank: Map.get(node_metrics, :pagerank, 0.0),
          risk_score: impact_data.risk_score
        }
      end)

    node_set = MapSet.new(nodes)

    links =
      nodes
      |> Enum.flat_map(fn node ->
        Store.get_outgoing_edges(node, :calls)
        |> Enum.filter(fn edge -> MapSet.member?(node_set, edge.to) end)
        |> Enum.map(fn edge ->
          %{
            source: format_node_id_string(node),
            target: format_node_id_string(edge.to),
            weight: 1.0
          }
        end)
      end)

    {:ok, %{nodes: node_list, links: links, impact_radius: impact_data.impact_radius}}
  end

  defp generate_d3_diff(added, removed, unchanged) do
    all_nodes = MapSet.union(added, removed) |> MapSet.union(unchanged)

    node_list =
      all_nodes
      |> Enum.map(fn node ->
        status =
          cond do
            MapSet.member?(added, node) -> "added"
            MapSet.member?(removed, node) -> "removed"
            true -> "unchanged"
          end

        %{
          id: format_node_id_string(node),
          label: format_node_label(node),
          status: status
        }
      end)

    {:ok, %{nodes: node_list, links: []}}
  end

  # Private functions - ASCII generation

  defp generate_ascii_impact(impact_data, _opts) do
    lines = [
      "=== Refactoring Impact Visualization ===",
      "",
      "Affected Functions: #{length(impact_data.affected_functions)}",
      "Impact Radius: #{impact_data.impact_radius} additional nodes",
      "Risk Score: #{Float.round(impact_data.risk_score, 3)} (0=low, 1=high)",
      "",
      "Core Affected Nodes:"
    ]

    node_lines =
      impact_data.affected_functions
      |> Enum.take(20)
      |> Enum.map(fn node ->
        metrics = Map.get(impact_data.centrality_metrics, node, %{})
        degree = Map.get(metrics, :degree, 0)
        pagerank = Map.get(metrics, :pagerank, 0.0) |> Float.round(4)

        "  - #{format_node_label(node)} (degree: #{degree}, pagerank: #{pagerank})"
      end)

    footer =
      if length(impact_data.affected_functions) > 20 do
        ["", "  ... and #{length(impact_data.affected_functions) - 20} more"]
      else
        []
      end

    result = Enum.join(lines ++ node_lines ++ footer, "\n")
    {:ok, result}
  end

  defp generate_ascii_diff(added, removed, unchanged) do
    lines = [
      "=== Refactoring Diff ===",
      "",
      "Added: #{MapSet.size(added)}",
      "Removed: #{MapSet.size(removed)}",
      "Unchanged: #{MapSet.size(unchanged)}",
      ""
    ]

    added_lines =
      if MapSet.size(added) > 0 do
        ["Added Nodes:"] ++
          (added |> Enum.take(10) |> Enum.map(&"  + #{format_node_label(&1)}"))
      else
        []
      end

    removed_lines =
      if MapSet.size(removed) > 0 do
        ["", "Removed Nodes:"] ++
          (removed |> Enum.take(10) |> Enum.map(&"  - #{format_node_label(&1)}"))
      else
        []
      end

    result = Enum.join(lines ++ added_lines ++ removed_lines, "\n")
    {:ok, result}
  end

  # Private functions - Formatting helpers

  defp format_node_id(node) do
    format_node_id_string(node)
    |> String.replace(".", "_")
    |> String.replace(":", "_")
  end

  defp format_node_id_string({:function, mod, name, arity}) do
    "#{mod}.#{name}/#{arity}"
  end

  defp format_node_id_string({:module, name}) do
    "#{name}"
  end

  defp format_node_id_string(node) do
    inspect(node)
  end

  defp format_node_label({:function, mod, name, arity}) do
    "#{mod}.#{name}/#{arity}"
  end

  defp format_node_label({:module, name}) do
    "Module: #{name}"
  end

  defp format_node_label(node) do
    inspect(node)
  end
end
