defmodule Ragex.MCP.Handlers.Prompts do
  @moduledoc """
  Handles MCP prompt-related requests.

  Implements the prompts/list and prompts/get methods.
  Prompts provide templated high-level workflows that compose multiple tools.
  """

  @doc """
  Lists all available prompts.

  Returns prompt definitions with names, descriptions, and argument schemas.
  """
  def list_prompts do
    %{
      prompts: [
        %{
          name: "analyze_architecture",
          description:
            "Performs comprehensive architectural analysis of a codebase including community detection, centrality metrics, and structural insights",
          arguments: [
            %{
              name: "path",
              description: "Path to the directory or file to analyze",
              required: true
            },
            %{
              name: "depth",
              description:
                "Analysis depth: 'shallow' for quick overview, 'deep' for detailed analysis",
              required: false
            }
          ]
        },
        %{
          name: "find_impact",
          description:
            "Analyzes the impact and importance of a function, including callers, importance scores, and refactoring risk",
          arguments: [
            %{
              name: "module",
              description: "Module name containing the function",
              required: true
            },
            %{
              name: "function",
              description: "Function name to analyze",
              required: true
            },
            %{
              name: "arity",
              description: "Function arity (number of arguments)",
              required: true
            }
          ]
        },
        %{
          name: "explain_code_flow",
          description:
            "Explains the execution flow between two functions with narrative description and code context",
          arguments: [
            %{
              name: "from_function",
              description: "Starting function (format: Module.function/arity)",
              required: true
            },
            %{
              name: "to_function",
              description: "Target function (format: Module.function/arity)",
              required: true
            },
            %{
              name: "context_lines",
              description: "Number of context lines to show around each step (default: 3)",
              required: false
            }
          ]
        },
        %{
          name: "find_similar_code",
          description:
            "Finds code similar to a natural language description using hybrid semantic and graph search",
          arguments: [
            %{
              name: "description",
              description: "Natural language description of the code to find",
              required: true
            },
            %{
              name: "file_type",
              description: "Optional file type filter (e.g., 'elixir', 'python')",
              required: false
            },
            %{
              name: "top_k",
              description: "Number of results to return (default: 5)",
              required: false
            }
          ]
        },
        %{
          name: "suggest_refactoring",
          description:
            "Analyzes code and suggests refactoring opportunities based on coupling, complexity, or modularity",
          arguments: [
            %{
              name: "target_path",
              description: "Path to the code to analyze for refactoring",
              required: true
            },
            %{
              name: "focus",
              description:
                "Refactoring focus: 'modularity' for module structure, 'coupling' for dependencies, 'complexity' for hotspots",
              required: false
            }
          ]
        },
        %{
          name: "safe_rename",
          description:
            "Previews and optionally performs safe semantic renaming of functions or modules with impact analysis",
          arguments: [
            %{
              name: "type",
              description: "Type of entity to rename: 'function' or 'module'",
              required: true
            },
            %{
              name: "old_name",
              description: "Current name of the entity",
              required: true
            },
            %{
              name: "new_name",
              description: "New name for the entity",
              required: true
            },
            %{
              name: "scope",
              description:
                "Rename scope: 'module' (current module only) or 'project' (default: project)",
              required: false
            }
          ]
        }
      ]
    }
  end

  @doc """
  Gets a prompt by name with filled-in arguments.

  Returns prompt messages and suggested tools to use.
  """
  def get_prompt(name, arguments) when is_binary(name) and is_map(arguments) do
    case name do
      "analyze_architecture" -> get_analyze_architecture_prompt(arguments)
      "find_impact" -> get_find_impact_prompt(arguments)
      "explain_code_flow" -> get_explain_code_flow_prompt(arguments)
      "find_similar_code" -> get_find_similar_code_prompt(arguments)
      "suggest_refactoring" -> get_suggest_refactoring_prompt(arguments)
      "safe_rename" -> get_safe_rename_prompt(arguments)
      _ -> {:error, "Unknown prompt: #{name}"}
    end
  end

  def get_prompt(_, _), do: {:error, "Invalid parameters for get_prompt"}

  # Private functions - Prompt implementations

  defp get_analyze_architecture_prompt(args) do
    with {:ok, path} <- get_required_arg(args, "path") do
      depth = Map.get(args, "depth", "shallow")

      tools =
        case depth do
          "deep" ->
            ["analyze_directory", "detect_communities", "betweenness_centrality", "graph_stats"]

          _ ->
            ["analyze_directory", "graph_stats"]
        end

      {:ok,
       %{
         description: "Architectural analysis workflow for #{path}",
         messages: [
           %{
             role: "user",
             content: %{
               type: "text",
               text: """
               Please analyze the architecture of the codebase at: #{path}

               Analysis depth: #{depth}

               #{if depth == "deep" do
                 """
                 Perform a comprehensive analysis including:
                 1. Analyze all files in the directory
                 2. Detect architectural communities/modules using Louvain algorithm
                 3. Identify bottleneck functions using betweenness centrality
                 4. Calculate overall graph statistics

                 Provide insights on:
                 - Architectural structure and modularity
                 - Key modules and their relationships
                 - Potential coupling issues
                 - Critical functions that act as bridges
                 """
               else
                 """
                 Perform a quick architectural overview:
                 1. Analyze all files in the directory
                 2. Calculate graph statistics

                 Provide insights on:
                 - Total entities and relationships
                 - Most important modules (by PageRank)
                 - Overall code density and connectivity
                 """
               end}
               """
             }
           }
         ],
         suggested_tools: tools
       }}
    end
  end

  defp get_find_impact_prompt(args) do
    with {:ok, module} <- get_required_arg(args, "module"),
         {:ok, function} <- get_required_arg(args, "function"),
         {:ok, arity} <- get_required_arg(args, "arity") do
      {:ok,
       %{
         description: "Impact analysis for #{module}.#{function}/#{arity}",
         messages: [
           %{
             role: "user",
             content: %{
               type: "text",
               text: """
               Please analyze the impact and importance of the function: #{module}.#{function}/#{arity}

               Perform the following analysis:
               1. Find the function in the knowledge graph (query_graph with type 'find_function')
               2. Get all callers of this function (query_graph with type 'get_callers')
               3. Calculate the PageRank importance score (graph_stats)
               4. Optionally find paths from entry points to this function

               Provide insights on:
               - How many functions call this one (impact radius)
               - How important is this function (PageRank score)
               - What modules would be affected by changes
               - Risk assessment for refactoring this function
               - Whether this is a critical architectural component
               """
             }
           }
         ],
         suggested_tools: ["query_graph", "graph_stats", "find_paths"]
       }}
    end
  end

  defp get_explain_code_flow_prompt(args) do
    with {:ok, from_function} <- get_required_arg(args, "from_function"),
         {:ok, to_function} <- get_required_arg(args, "to_function") do
      context_lines = Map.get(args, "context_lines", "3")

      {:ok,
       %{
         description: "Code flow explanation from #{from_function} to #{to_function}",
         messages: [
           %{
             role: "user",
             content: %{
               type: "text",
               text: """
               Please explain the execution flow from #{from_function} to #{to_function}

               Steps to follow:
               1. Find all paths between these functions using find_paths tool
               2. For each step in the paths, retrieve the function details from the graph
               3. Optionally use semantic_search to find related documentation or comments

               Provide a narrative explanation including:
               - How many different paths exist between these functions
               - A step-by-step explanation of the most direct path
               - What each intermediate function does
               - Any alternative paths and when they might be taken
               - Context about the overall execution flow (#{context_lines} lines of context)
               """
             }
           }
         ],
         suggested_tools: ["find_paths", "query_graph", "semantic_search"]
       }}
    end
  end

  defp get_find_similar_code_prompt(args) do
    with {:ok, description} <- get_required_arg(args, "description") do
      file_type = Map.get(args, "file_type")
      top_k = Map.get(args, "top_k", "5")

      file_type_filter =
        if file_type do
          "\nFilter results to #{file_type} files only."
        else
          ""
        end

      {:ok,
       %{
         description: "Find code similar to: #{String.slice(description, 0..50)}...",
         messages: [
           %{
             role: "user",
             content: %{
               type: "text",
               text: """
               Please find code similar to this description: #{description}
               #{file_type_filter}

               Number of results requested: #{top_k}

               Use the following approach:
               1. Perform hybrid_search with the description (combines semantic + graph search)
               2. Retrieve detailed information about each match from the knowledge graph
               3. Get source code context for the top matches

               Provide results including:
               - Similarity score for each match
               - File location and function name
               - Brief explanation of why each result matches
               - Code snippets showing the relevant implementation
               - Suggestions for which result best matches the intent
               """
             }
           }
         ],
         suggested_tools: ["hybrid_search", "query_graph"]
       }}
    end
  end

  defp get_suggest_refactoring_prompt(args) do
    with {:ok, target_path} <- get_required_arg(args, "target_path") do
      focus = Map.get(args, "focus", "modularity")

      analysis_steps =
        case focus do
          "modularity" ->
            """
            Focus on modularity:
            1. Analyze the directory to build the knowledge graph
            2. Detect communities to identify natural module boundaries
            3. Look for modules that should be split or merged
            """

          "coupling" ->
            """
            Focus on coupling:
            1. Analyze the directory
            2. Calculate degree centrality to find highly coupled functions
            3. Detect communities to see coupling patterns
            4. Identify functions/modules that depend on too many others
            """

          "complexity" ->
            """
            Focus on complexity hotspots:
            1. Analyze the directory
            2. Calculate betweenness centrality to find bottleneck functions
            3. Use degree centrality to find complex functions
            4. Identify functions that are critical points of failure
            """

          _ ->
            "Perform general analysis with all metrics"
        end

      {:ok,
       %{
         description: "Refactoring suggestions for #{target_path} (focus: #{focus})",
         messages: [
           %{
             role: "user",
             content: %{
               type: "text",
               text: """
               Please suggest refactoring opportunities for: #{target_path}

               Refactoring focus: #{focus}

               #{analysis_steps}

               Provide refactoring suggestions including:
               - Specific functions or modules that need attention
               - Why they are problematic (coupling, complexity, poor modularity)
               - Concrete refactoring actions (split module, extract function, reduce dependencies)
               - Priority level (high/medium/low) based on metrics
               - Potential risks of the refactoring
               """
             }
           }
         ],
         suggested_tools: [
           "analyze_directory",
           "detect_communities",
           "betweenness_centrality",
           "graph_stats"
         ]
       }}
    end
  end

  defp get_safe_rename_prompt(args) do
    with {:ok, type} <- get_required_arg(args, "type"),
         {:ok, old_name} <- get_required_arg(args, "old_name"),
         {:ok, new_name} <- get_required_arg(args, "new_name") do
      scope = Map.get(args, "scope", "project")

      query_step =
        case type do
          "function" ->
            "Use query_graph to verify the function exists and get its details"

          "module" ->
            "Use query_graph to verify the module exists and get its functions"

          _ ->
            "Verify the entity exists"
        end

      {:ok,
       %{
         description: "Safe rename of #{type} from #{old_name} to #{new_name}",
         messages: [
           %{
             role: "user",
             content: %{
               type: "text",
               text: """
               Please help me safely rename a #{type}:
               - Old name: #{old_name}
               - New name: #{new_name}
               - Scope: #{scope}

               Safety analysis steps:
               1. #{query_step}
               2. Find all references using the knowledge graph
               3. Calculate impact (number of callers, importance score)
               4. Preview what files would be changed

               Provide a safety assessment including:
               - Whether the #{type} exists and can be renamed
               - How many files would be affected
               - Impact on other modules (if scope is project-wide)
               - Any potential naming conflicts with #{new_name}
               - Risk level (low/medium/high)

               Ask the user if they want to proceed with the refactoring using the refactor_code tool.
               """
             }
           }
         ],
         suggested_tools: ["query_graph", "graph_stats", "refactor_code"]
       }}
    end
  end

  # Helper functions

  defp get_required_arg(args, key) do
    case Map.get(args, key) do
      nil -> {:error, "Missing required argument: #{key}"}
      value -> {:ok, value}
    end
  end
end
