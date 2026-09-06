defmodule Ragex.Plugins.GitArchaeology do
  @moduledoc """
  Plugin providing Git archaeology tools (blame, history, PR info, co-change, enrich).
  """

  @behaviour Ragex.Plugin
  alias Ragex.MCP.Handlers.GitTools

  @impl true
  def info do
    %{
      id: :git_archaeology,
      name: "Git Archaeology & History Insights",
      version: "1.0.0",
      description:
        "Extracts git commit history, line-by-line blame, PR associations, co-change patterns, and repo enrichment.",
      category: :git,
      dependencies: [],
      priority: 20,
      capabilities: [:git_blame, :git_history, :co_change]
    }
  end

  @impl true
  def tools do
    [
      %{
        name: "git_blame",
        description:
          "Get line-by-line git blame information for a file, including author, commit hash, and timestamp.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to the target file"},
            start_line: %{type: "integer", description: "Optional starting line number"},
            end_line: %{type: "integer", description: "Optional ending line number"}
          },
          required: ["path"]
        }
      },
      %{
        name: "git_history",
        description:
          "Get git commit history for a file or directory with optional date and author filters.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File or directory path"},
            limit: %{type: "integer", default: 20, description: "Max commits to return"}
          },
          required: ["path"]
        }
      },
      %{
        name: "co_change_analysis",
        description:
          "Analyze files that frequently change together with a target file based on commit history.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File path to analyze co-change coupling for"},
            threshold: %{type: "integer", default: 3, description: "Min co-commit threshold"}
          },
          required: ["path"]
        }
      }
    ]
  end

  @impl true
  def execute(tool_name, args) when is_binary(tool_name) and is_map(args) do
    GitTools.call_tool(tool_name, args)
  end
end
