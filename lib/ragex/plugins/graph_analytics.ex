defmodule Ragex.Plugins.GraphAnalytics do
  @moduledoc """
  Plugin providing Knowledge Graph algorithms, node querying, caller finding, and graph analytics.
  """

  @behaviour Ragex.Plugin
  alias Ragex.MCP.Handlers.Tools

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
          "Compute betweenness centrality to identify bridge/bottleneck functions in the call graph.",
        inputSchema: %{
          type: "object",
          properties: %{
            max_nodes: %{
              type: "integer",
              description: "Limit computation to N highest-degree nodes",
              default: 1000
            },
            normalize: %{
              type: "boolean",
              description: "Return normalized scores (0-1)",
              default: true
            }
          }
        }
      }
    ]
  end

  # Delegates to the full-featured implementations in Ragex.MCP.Handlers.Tools
  # (find_module/find_function/get_calls/get_dependencies/get_callers with
  # PageRank enrichment, and max_nodes/normalize-aware betweenness
  # centrality) rather than reimplementing a stripped-down subset here that
  # would silently shadow the real logic -- see the Ragex Codebase Health &
  # Architecture Improvement Plan.
  @impl true
  def execute("query_graph", %{"query_type" => _qtype, "params" => _params} = args) do
    Tools.query_graph(args)
  end

  def execute("betweenness_centrality", args) do
    Tools.betweenness_centrality_tool(args)
  end

  def execute(tool_name, _args) do
    {:error, "Unknown tool '#{tool_name}' for GraphAnalytics plugin"}
  end
end
