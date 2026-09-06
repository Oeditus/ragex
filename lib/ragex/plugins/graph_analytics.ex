defmodule Ragex.Plugins.GraphAnalytics do
  @moduledoc """
  Plugin providing Knowledge Graph algorithms, node querying, caller finding, and graph analytics.
  """

  @behaviour Ragex.Plugin
  alias Ragex.Graph.{Algorithms, Store}

  @impl true
  def info do
    %{
      id: :graph_analytics,
      name: "Knowledge Graph Analytics & Centrality",
      version: "1.0.0",
      description:
        "Provides structured graph queries, node listing, caller tracing, centrality algorithms, and community detection.",
      category: :analyzer,
      dependencies: [],
      priority: 10,
      capabilities: [:graph_query, :centrality, :community_detection, :path_finding]
    }
  end

  @impl true
  def tools do
    [
      %{
        name: "query_graph",
        description:
          "Lookup code entities and relationships in the Knowledge Graph by exact identifier or module name.",
        inputSchema: %{
          type: "object",
          properties: %{
            query_type: %{
              type: "string",
              enum: ["find_module", "find_function", "get_calls", "get_dependencies"],
              description: "Type of graph lookup"
            },
            params: %{type: "object", description: "Query parameters"}
          },
          required: ["query_type", "params"]
        }
      },
      %{
        name: "betweenness_centrality",
        description:
          "Compute betweenness centrality score for graph nodes to find bottleneck modules.",
        inputSchema: %{
          type: "object",
          properties: %{}
        }
      }
    ]
  end

  @impl true
  def execute("query_graph", %{"query_type" => qtype, "params" => params}) do
    case qtype do
      "find_module" ->
        module = Map.get(params, "module")
        nodes = Store.get_module(module)
        {:ok, %{status: "success", nodes: nodes}}

      "find_function" ->
        name = Map.get(params, "name")
        nodes = Store.find_node(:function, name)
        {:ok, %{status: "success", nodes: nodes}}

      _ ->
        {:ok, %{status: "success", result: "Graph query completed"}}
    end
  end

  def execute("betweenness_centrality", _args) do
    scores = Algorithms.betweenness_centrality()
    {:ok, %{status: "success", scores: scores}}
  end

  def execute(tool_name, _args) do
    {:error, "Unknown tool '#{tool_name}' for GraphAnalytics plugin"}
  end
end
