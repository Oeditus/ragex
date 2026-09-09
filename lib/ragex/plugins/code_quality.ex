defmodule Ragex.Plugins.CodeQuality do
  @moduledoc """
  Plugin providing code quality, smell detection, duplication, and complexity tools.
  """

  @behaviour Ragex.Plugin
  alias Ragex.MCP.Handlers.Tools

  @impl true
  def info do
    %{
      id: :code_quality,
      name: "Code Quality & Smells Engine",
      version: "1.0.0",
      description:
        "Detects code smells, complex functions, duplicated blocks, dead code, and quality metrics.",
      category: :analyzer,
      dependencies: [],
      priority: 30,
      capabilities: [:smell_detection, :complexity_analysis, :dead_code, :duplication]
    }
  end

  @impl true
  def tools do
    [
      %{
        name: "detect_smells",
        description:
          "Detect structural code smells: long functions, deep nesting, magic numbers, complex conditionals, large modules. Use to find readability and maintainability issues that don't rise to the level of bugs.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File or directory path to analyze"},
            recursive: %{
              type: "boolean",
              description: "Recursively analyze directories",
              default: true
            },
            min_severity: %{
              type: "string",
              description: "Minimum severity level to report",
              enum: ["low", "medium", "high", "critical"],
              default: "low"
            }
          },
          required: ["path"]
        }
      },
      %{
        name: "find_dead_code",
        description:
          "Find functions with no callers in the knowledge graph. Assigns a confidence score that distinguishes truly unreachable code from framework callbacks that appear unused but are called by the runtime.",
        inputSchema: %{
          type: "object",
          properties: %{
            scope: %{
              type: "string",
              description: "Analysis scope",
              enum: ["exports", "private", "all", "modules"],
              default: "all"
            },
            min_confidence: %{
              type: "number",
              description: "Minimum confidence threshold (0.0-1.0)",
              default: 0.5
            }
          }
        }
      },
      %{
        name: "find_duplicates",
        description:
          "Detect copy-paste code clones using AST structural comparison (Type I-IV). Returns clone groups with similarity scores.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{
              type: "string",
              description:
                "File path or directory to analyze (if two paths separated by comma, compares them)"
            },
            threshold: %{
              type: "number",
              default: 0.8,
              description: "Similarity threshold (0.0 to 1.0)"
            }
          },
          required: ["path"]
        }
      }
    ]
  end

  # Delegates to the full-featured implementations in Ragex.MCP.Handlers.Tools
  # (directory support, thresholds/scope/format options, two-file compare
  # mode) rather than reimplementing a single-file stub here that would
  # silently shadow the real logic -- see the Ragex Codebase Health &
  # Architecture Improvement Plan.
  @impl true
  def execute("detect_smells", args), do: Tools.detect_smells_tool(args)
  def execute("find_dead_code", args), do: Tools.find_dead_code_tool(args)
  def execute("find_duplicates", args), do: Tools.find_duplicates_tool(args)

  def execute(tool_name, _args) do
    {:error, "Unknown tool '#{tool_name}' for CodeQuality plugin"}
  end
end
