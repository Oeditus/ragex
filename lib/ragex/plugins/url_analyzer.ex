defmodule Ragex.Plugins.URLAnalyzer do
  @moduledoc """
  Plugin implementation for URL and Git repository analysis.
  """

  @behaviour Ragex.Plugin

  @impl true
  def info do
    %{
      id: :url_analyzer,
      name: "URL & Git Repository Analyzer",
      version: "1.0.0",
      description:
        "Fetches and analyzes Git repositories, web documentation, API specs, and raw code files from URLs.",
      category: :analyzer,
      dependencies: [],
      priority: 50,
      capabilities: [:url_analysis, :git_analysis]
    }
  end

  @impl true
  def tools do
    [
      %{
        name: "analyze_url",
        description:
          "Fetches and analyzes a URL (GitHub/GitLab repo, web page, API specification, or raw code file). Returns a machine-understandable report and indexes findings into the knowledge graph.",
        inputSchema: %{
          type: "object",
          properties: %{
            url: %{
              type: "string",
              description:
                "Target URL to analyze (e.g., https://github.com/owner/repo or web page)"
            },
            depth: %{
              type: "string",
              enum: ["shallow", "deep"],
              default: "shallow",
              description: "Depth of analysis (shallow or deep)"
            },
            index_graph: %{
              type: "boolean",
              default: true,
              description: "Whether to index findings into the Ragex knowledge graph"
            },
            auth_token: %{
              type: "string",
              description: "Optional authentication token for private GitHub/GitLab repositories"
            }
          },
          required: ["url"]
        }
      }
    ]
  end

  @impl true
  def execute("analyze_url", %{"url" => url} = params) do
    opts = []

    opts =
      if Map.has_key?(params, "auth_token") do
        Keyword.put(opts, :auth_token, params["auth_token"])
      else
        opts
      end

    opts =
      if Map.has_key?(params, "depth") do
        depth_val = if params["depth"] == "deep", do: 5, else: 1
        Keyword.put(opts, :depth, depth_val)
      else
        opts
      end

    opts =
      if Map.has_key?(params, "index_graph") do
        Keyword.put(opts, :index_graph, params["index_graph"])
      else
        opts
      end

    case Ragex.URLAnalyzer.analyze(url, opts) do
      {:ok, report} ->
        {:ok, report}

      {:error, reason} ->
        {:error, "Failed to analyze URL: #{inspect(reason)}"}
    end
  end

  def execute("analyze_url", _),
    do: {:error, "Invalid parameters for analyze_url: 'url' parameter is required"}

  def execute(tool_name, _args) do
    {:error, "Unknown tool '#{tool_name}' for plugin URLAnalyzer"}
  end
end
