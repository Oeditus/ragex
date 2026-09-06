defmodule Ragex.Plugins.CodeQuality do
  @moduledoc """
  Plugin providing code quality, smell detection, duplication, and complexity tools.
  """

  @behaviour Ragex.Plugin
  alias Ragex.Analysis.{DeadCode, Duplication, Smells}

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
          "Analyze a file or directory for code smells (long functions, deep nesting, large modules, complex logic).",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to file or directory"}
          },
          required: ["path"]
        }
      },
      %{
        name: "find_dead_code",
        description: "Identify unused functions, unreferenced modules, and dead code pathways.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to target directory"}
          },
          required: ["path"]
        }
      },
      %{
        name: "find_duplicates",
        description: "Detect duplicate code fragments across the codebase.",
        inputSchema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Path to directory"},
            threshold: %{
              type: "number",
              default: 0.85,
              description: "Similarity threshold (0.0 to 1.0)"
            }
          },
          required: ["path"]
        }
      }
    ]
  end

  @impl true
  def execute("detect_smells", %{"path" => path}) do
    case Smells.analyze_file(path, []) do
      {:ok, smells} -> {:ok, %{status: "success", smells: smells}}
      {:error, reason} -> {:error, "Smell detection failed: #{inspect(reason)}"}
    end
  end

  def execute("find_dead_code", %{"path" => path}) do
    case DeadCode.analyze_file(path, []) do
      {:ok, result} -> {:ok, %{status: "success", dead_code: result}}
      {:error, reason} -> {:error, "Dead code analysis failed: #{inspect(reason)}"}
    end
  end

  def execute("find_duplicates", %{"path" => path} = opts) do
    threshold = Map.get(opts, "threshold", 0.85)

    case Duplication.detect_in_directory(path) do
      {:ok, result} -> {:ok, %{status: "success", duplicates: result, threshold: threshold}}
      {:error, reason} -> {:error, "Duplication analysis failed: #{inspect(reason)}"}
    end
  end

  def execute(tool_name, _args) do
    {:error, "Unknown tool '#{tool_name}' for CodeQuality plugin"}
  end
end
