defmodule Ragex.MCP.Handlers.Tools do
  @moduledoc """
  Handles MCP tool-related requests.

  Implements the tools/list and tools/call methods.
  """

  alias Ragex.Graph.Store
  alias Ragex.Graph.Algorithms
  alias Ragex.VectorStore
  alias Ragex.Retrieval.Hybrid
  alias Ragex.Analyzers.Elixir, as: ElixirAnalyzer
  alias Ragex.Analyzers.Erlang, as: ErlangAnalyzer
  alias Ragex.Analyzers.Python, as: PythonAnalyzer
  alias Ragex.Analyzers.JavaScript, as: JavaScriptAnalyzer
  alias Ragex.Analyzers.Directory
  alias Ragex.Watcher
  alias Ragex.Embeddings.Bumblebee
  alias Ragex.Embeddings.Helper, as: EmbeddingsHelper
  alias Ragex.Editor.{Core, Types, Transaction, Refactor}

  @doc """
  Lists all available tools.
  """
  def list_tools do
    %{
      tools: [
        %{
          name: "analyze_file",
          description:
            "Analyzes a source file and extracts code structure into the knowledge graph",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "Absolute or relative path to the file to analyze"
              },
              language: %{
                type: "string",
                description: "Programming language (auto-detect if not specified)",
                enum: ["elixir", "erlang", "python", "javascript", "typescript", "auto"]
              },
              generate_embeddings: %{
                type: "boolean",
                description: "Generate embeddings for semantic search (default: true)",
                default: true
              }
            },
            required: ["path"]
          }
        },
        %{
          name: "query_graph",
          description: "Queries the knowledge graph for code entities and relationships",
          inputSchema: %{
            type: "object",
            properties: %{
              query_type: %{
                type: "string",
                description: "Type of query to perform",
                enum: ["find_module", "find_function", "get_calls", "get_dependencies"]
              },
              params: %{
                type: "object",
                description: "Query-specific parameters"
              }
            },
            required: ["query_type", "params"]
          }
        },
        %{
          name: "list_nodes",
          description: "Lists all nodes in the knowledge graph with optional filtering",
          inputSchema: %{
            type: "object",
            properties: %{
              node_type: %{
                type: "string",
                description: "Filter by node type (module, function, etc.)"
              },
              limit: %{
                type: "integer",
                description: "Maximum number of results",
                default: 100
              }
            }
          }
        },
        %{
          name: "analyze_directory",
          description: "Recursively analyzes all supported files in a directory",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "Path to the directory (or file) to analyze"
              },
              max_depth: %{
                type: "integer",
                description: "Maximum directory depth to traverse",
                default: 10
              },
              exclude_patterns: %{
                type: "array",
                description: "Directory/file patterns to exclude (e.g., node_modules, .git)",
                items: %{type: "string"}
              }
            },
            required: ["path"]
          }
        },
        %{
          name: "watch_directory",
          description: "Start watching a directory for file changes and auto-reindex",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "Path to the directory to watch"
              }
            },
            required: ["path"]
          }
        },
        %{
          name: "unwatch_directory",
          description: "Stop watching a directory",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "Path to the directory to stop watching"
              }
            },
            required: ["path"]
          }
        },
        %{
          name: "list_watched",
          description: "List all currently watched directories",
          inputSchema: %{
            type: "object",
            properties: {}
          }
        },
        %{
          name: "semantic_search",
          description: "Search codebase using natural language queries via semantic similarity",
          inputSchema: %{
            type: "object",
            properties: %{
              query: %{
                type: "string",
                description: "Natural language search query (e.g., 'function to parse JSON')"
              },
              limit: %{
                type: "integer",
                description: "Maximum number of results",
                default: 10
              },
              threshold: %{
                type: "number",
                description: "Minimum similarity score (0.0 to 1.0)",
                default: 0.7
              },
              node_type: %{
                type: "string",
                description: "Filter by entity type",
                enum: ["module", "function"]
              },
              include_context: %{
                type: "boolean",
                description: "Include related entities (callers, callees, etc.)",
                default: true
              }
            },
            required: ["query"]
          }
        },
        %{
          name: "get_embeddings_stats",
          description: "Get statistics about indexed embeddings",
          inputSchema: %{
            type: "object",
            properties: {}
          }
        },
        %{
          name: "find_paths",
          description: "Find all paths (call chains) between two functions or modules",
          inputSchema: %{
            type: "object",
            properties: %{
              from: %{
                type: "string",
                description: "Source node ID (e.g., 'ModuleA.function/1')"
              },
              to: %{
                type: "string",
                description: "Target node ID (e.g., 'ModuleB.function/2')"
              },
              max_depth: %{
                type: "integer",
                description: "Maximum path length",
                default: 10
              }
            },
            required: ["from", "to"]
          }
        },
        %{
          name: "graph_stats",
          description:
            "Get comprehensive graph statistics including PageRank and centrality metrics",
          inputSchema: %{
            type: "object",
            properties: {}
          }
        },
        %{
          name: "hybrid_search",
          description:
            "Advanced search combining symbolic graph queries with semantic similarity",
          inputSchema: %{
            type: "object",
            properties: %{
              query: %{
                type: "string",
                description: "Natural language search query"
              },
              strategy: %{
                type: "string",
                description: "Search strategy",
                enum: ["fusion", "semantic_first", "graph_first"],
                default: "fusion"
              },
              limit: %{
                type: "integer",
                description: "Maximum number of results",
                default: 10
              },
              threshold: %{
                type: "number",
                description: "Minimum similarity score (0.0 to 1.0)",
                default: 0.7
              },
              node_type: %{
                type: "string",
                description: "Filter by entity type",
                enum: ["module", "function"]
              },
              include_context: %{
                type: "boolean",
                description: "Include related entities in results",
                default: true
              }
            },
            required: ["query"]
          }
        },
        %{
          name: "edit_file",
          description:
            "Safely edit a file with automatic backup, validation, and atomic operations",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "Path to the file to edit"
              },
              changes: %{
                type: "array",
                description: "List of changes to apply",
                items: %{
                  type: "object",
                  properties: %{
                    type: %{
                      type: "string",
                      enum: ["replace", "insert", "delete"],
                      description: "Type of change"
                    },
                    line_start: %{
                      type: "integer",
                      description: "Starting line number (1-indexed)"
                    },
                    line_end: %{
                      type: "integer",
                      description: "Ending line number (for replace/delete)"
                    },
                    content: %{
                      type: "string",
                      description: "New content (for replace/insert)"
                    }
                  },
                  required: ["type", "line_start"]
                }
              },
              validate: %{
                type: "boolean",
                description: "Validate syntax before applying (default: true)",
                default: true
              },
              create_backup: %{
                type: "boolean",
                description: "Create backup before editing (default: true)",
                default: true
              },
              language: %{
                type: "string",
                description: "Explicit language for validation (auto-detected from extension)",
                enum: ["elixir", "erlang", "python", "javascript"]
              }
            },
            required: ["path", "changes"]
          }
        },
        %{
          name: "validate_edit",
          description: "Preview validation of changes without applying them",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "Path to the file"
              },
              changes: %{
                type: "array",
                description: "List of changes to validate",
                items: %{
                  type: "object",
                  properties: %{
                    type: %{type: "string", enum: ["replace", "insert", "delete"]},
                    line_start: %{type: "integer"},
                    line_end: %{type: "integer"},
                    content: %{type: "string"}
                  },
                  required: ["type", "line_start"]
                }
              },
              language: %{
                type: "string",
                description: "Explicit language for validation",
                enum: ["elixir", "erlang", "python", "javascript"]
              }
            },
            required: ["path", "changes"]
          }
        },
        %{
          name: "rollback_edit",
          description: "Undo a recent edit by restoring from backup",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "Path to the file to rollback"
              },
              backup_id: %{
                type: "string",
                description: "Specific backup to restore (default: most recent)"
              }
            },
            required: ["path"]
          }
        },
        %{
          name: "edit_history",
          description: "Query backup history for a file",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "Path to the file"
              },
              limit: %{
                type: "integer",
                description: "Maximum number of backups to return",
                default: 10
              }
            },
            required: ["path"]
          }
        },
        %{
          name: "refactor_code",
          description: "Semantic refactoring operations using AST analysis and knowledge graph",
          inputSchema: %{
            type: "object",
            properties: %{
              operation: %{
                type: "string",
                description: "Type of refactoring operation",
                enum: ["rename_function", "rename_module"]
              },
              params: %{
                type: "object",
                description: "Operation-specific parameters",
                properties: %{
                  module: %{
                    type: "string",
                    description: "Module name (for rename_function)"
                  },
                  old_name: %{
                    type: "string",
                    description: "Current function or module name"
                  },
                  new_name: %{
                    type: "string",
                    description: "New function or module name"
                  },
                  arity: %{
                    type: "integer",
                    description: "Function arity (for rename_function)"
                  }
                },
                required: ["old_name", "new_name"]
              },
              scope: %{
                type: "string",
                description: "Refactoring scope",
                enum: ["module", "project"],
                default: "project"
              },
              validate: %{
                type: "boolean",
                description: "Validate before and after refactoring",
                default: true
              },
              format: %{
                type: "boolean",
                description: "Format code after refactoring",
                default: true
              }
            },
            required: ["operation", "params"]
          }
        },
        %{
          name: "edit_files",
          description: "Atomically edit multiple files with automatic rollback on failure",
          inputSchema: %{
            type: "object",
            properties: %{
              files: %{
                type: "array",
                description: "List of files to edit",
                items: %{
                  type: "object",
                  properties: %{
                    path: %{
                      type: "string",
                      description: "Path to the file to edit"
                    },
                    changes: %{
                      type: "array",
                      description: "List of changes to apply to this file",
                      items: %{
                        type: "object",
                        properties: %{
                          type: %{
                            type: "string",
                            enum: ["replace", "insert", "delete"],
                            description: "Type of change"
                          },
                          line_start: %{
                            type: "integer",
                            description: "Starting line number (1-indexed)"
                          },
                          line_end: %{
                            type: "integer",
                            description: "Ending line number (for replace/delete)"
                          },
                          content: %{
                            type: "string",
                            description: "New content (for replace/insert)"
                          }
                        },
                        required: ["type", "line_start"]
                      }
                    },
                    validate: %{
                      type: "boolean",
                      description: "Validate syntax for this file (overrides transaction default)"
                    },
                    format: %{
                      type: "boolean",
                      description: "Format code after editing (overrides transaction default)"
                    },
                    language: %{
                      type: "string",
                      description:
                        "Explicit language for validation (auto-detected from extension)",
                      enum: ["elixir", "erlang", "python", "javascript"]
                    }
                  },
                  required: ["path", "changes"]
                }
              },
              validate: %{
                type: "boolean",
                description: "Validate all files before applying changes (default: true)",
                default: true
              },
              create_backup: %{
                type: "boolean",
                description: "Create backups before editing (default: true)",
                default: true
              },
              format: %{
                type: "boolean",
                description: "Format code after editing (default: false)",
                default: false
              }
            },
            required: ["files"]
          }
        }
      ]
    }
  end

  @doc """
  Executes a tool call.
  """
  def call_tool(tool_name, arguments) do
    case tool_name do
      "analyze_file" ->
        analyze_file(arguments)

      "analyze_directory" ->
        analyze_directory(arguments)

      "query_graph" ->
        query_graph(arguments)

      "list_nodes" ->
        list_nodes(arguments)

      "watch_directory" ->
        watch_directory(arguments)

      "unwatch_directory" ->
        unwatch_directory(arguments)

      "list_watched" ->
        list_watched(arguments)

      "semantic_search" ->
        semantic_search(arguments)

      "get_embeddings_stats" ->
        get_embeddings_stats(arguments)

      "find_paths" ->
        find_paths_tool(arguments)

      "graph_stats" ->
        graph_stats_tool(arguments)

      "hybrid_search" ->
        hybrid_search_tool(arguments)

      "edit_file" ->
        edit_file_tool(arguments)

      "validate_edit" ->
        validate_edit_tool(arguments)

      "rollback_edit" ->
        rollback_edit_tool(arguments)

      "edit_history" ->
        edit_history_tool(arguments)

      "edit_files" ->
        edit_files_tool(arguments)

      "refactor_code" ->
        refactor_code_tool(arguments)

      _ ->
        {:error, "Unknown tool: #{tool_name}"}
    end
  end

  # Private functions

  defp analyze_file(%{"path" => path} = params) do
    language = Map.get(params, "language", "auto")
    generate_embeddings = Map.get(params, "generate_embeddings", true)

    case File.read(path) do
      {:ok, content} ->
        analyzer = get_analyzer(language, path)

        case analyzer.analyze(content, path) do
          {:ok, analysis} ->
            # Store the analysis results in the graph
            store_analysis(analysis)

            # Optionally generate embeddings
            embeddings_result =
              if generate_embeddings do
                case EmbeddingsHelper.generate_and_store_embeddings(analysis) do
                  :ok ->
                    %{embeddings_generated: true}

                  {:error, :model_not_ready} ->
                    %{embeddings_generated: false, reason: "model_not_ready"}

                  {:error, reason} ->
                    %{embeddings_generated: false, reason: inspect(reason)}
                end
              else
                %{embeddings_generated: false, reason: "disabled"}
              end

            result = %{
              status: "success",
              language: get_language_name(analyzer),
              analysis: analysis
            }

            {:ok, Map.merge(result, embeddings_result)}

          {:error, reason} ->
            {:error, "Failed to analyze file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to read file: #{inspect(reason)}"}
    end
  end

  defp analyze_file(_), do: {:error, "Invalid parameters for analyze_file"}

  defp analyze_directory(%{"path" => path} = params) do
    opts = []

    opts =
      if Map.has_key?(params, "max_depth") do
        Keyword.put(opts, :max_depth, params["max_depth"])
      else
        opts
      end

    opts =
      if Map.has_key?(params, "exclude_patterns") do
        Keyword.put(opts, :exclude_patterns, params["exclude_patterns"])
      else
        opts
      end

    Directory.analyze_directory(path, opts)
  end

  defp analyze_directory(_), do: {:error, "Invalid parameters for analyze_directory"}

  defp watch_directory(%{"path" => path}) do
    case Watcher.watch_directory(path) do
      :ok -> {:ok, %{status: "watching", path: path}}
      {:error, reason} -> {:error, "Failed to watch directory: #{inspect(reason)}"}
    end
  end

  defp watch_directory(_), do: {:error, "Invalid parameters for watch_directory"}

  defp unwatch_directory(%{"path" => path}) do
    case Watcher.unwatch_directory(path) do
      :ok -> {:ok, %{status: "unwatched", path: path}}
      {:error, reason} -> {:error, "Failed to unwatch directory: #{inspect(reason)}"}
    end
  end

  defp unwatch_directory(_), do: {:error, "Invalid parameters for unwatch_directory"}

  defp list_watched(_params) do
    watched = Watcher.list_watched()
    {:ok, %{watched_directories: watched, count: length(watched)}}
  end

  defp get_analyzer("auto", path) do
    ext = Path.extname(path)

    cond do
      ext in [".ex", ".exs"] -> ElixirAnalyzer
      ext in [".erl", ".hrl"] -> ErlangAnalyzer
      ext == ".py" -> PythonAnalyzer
      ext in [".js", ".jsx", ".ts", ".tsx", ".mjs"] -> JavaScriptAnalyzer
      # Default fallback
      true -> ElixirAnalyzer
    end
  end

  defp get_analyzer("elixir", _path), do: ElixirAnalyzer
  defp get_analyzer("erlang", _path), do: ErlangAnalyzer
  defp get_analyzer("python", _path), do: PythonAnalyzer
  defp get_analyzer("javascript", _path), do: JavaScriptAnalyzer
  defp get_analyzer("typescript", _path), do: JavaScriptAnalyzer
  defp get_analyzer(_, path), do: get_analyzer("auto", path)

  defp get_language_name(ElixirAnalyzer), do: "elixir"
  defp get_language_name(ErlangAnalyzer), do: "erlang"
  defp get_language_name(PythonAnalyzer), do: "python"
  defp get_language_name(JavaScriptAnalyzer), do: "javascript"
  defp get_language_name(_), do: "unknown"

  defp query_graph(%{"query_type" => query_type, "params" => params}) do
    case query_type do
      "find_module" ->
        find_module(params)

      "find_function" ->
        find_function(params)

      "get_calls" ->
        get_calls(params)

      "get_dependencies" ->
        get_dependencies(params)

      _ ->
        {:error, "Unknown query type: #{query_type}"}
    end
  end

  defp query_graph(_), do: {:error, "Invalid parameters for query_graph"}

  defp list_nodes(params) do
    node_type = Map.get(params, "node_type")
    limit = Map.get(params, "limit", 100)

    nodes = Store.list_nodes(node_type, limit)
    {:ok, %{nodes: nodes, count: length(nodes)}}
  end

  defp find_module(%{"name" => name}) do
    case Store.find_node(:module, name) do
      nil ->
        {:ok, %{found: false}}

      node ->
        # Add PageRank score
        pagerank_scores = Algorithms.pagerank()
        importance_score = Map.get(pagerank_scores, {:module, String.to_atom(name)}, 0.0)

        enhanced_node = Map.put(node, :importance_score, Float.round(importance_score, 6))
        {:ok, %{found: true, node: enhanced_node}}
    end
  end

  defp find_module(_), do: {:error, "Missing 'name' parameter"}

  defp find_function(%{"module" => module, "name" => name}) do
    case Store.find_function(module, name) do
      nil ->
        {:ok, %{found: false}}

      node ->
        # Add PageRank score
        pagerank_scores = Algorithms.pagerank()
        func_id = {:function, String.to_atom(module), String.to_atom(name), node.arity}
        importance_score = Map.get(pagerank_scores, func_id, 0.0)

        enhanced_node = Map.put(node, :importance_score, Float.round(importance_score, 6))
        {:ok, %{found: true, node: enhanced_node}}
    end
  end

  defp find_function(_), do: {:error, "Missing 'module' or 'name' parameter"}

  defp get_calls(%{"module" => module, "function" => function}) do
    calls = Store.get_outgoing_edges({:function, module, function}, :calls)
    {:ok, %{calls: calls}}
  end

  defp get_calls(_), do: {:error, "Missing 'module' or 'function' parameter"}

  defp get_dependencies(%{"module" => module}) do
    deps = Store.get_outgoing_edges({:module, module}, :imports)
    {:ok, %{dependencies: deps}}
  end

  defp get_dependencies(_), do: {:error, "Missing 'module' parameter"}

  defp semantic_search(%{"query" => query} = params) do
    # Check if embedding model is ready
    if not Bumblebee.ready?() do
      {:error, "Embedding model not ready. Please wait for model to load."}
    else
      # Generate query embedding
      case Bumblebee.embed(query) do
        {:ok, query_embedding} ->
          # Parse options
          limit = Map.get(params, "limit", 10)
          threshold = Map.get(params, "threshold", 0.7)

          node_type =
            case Map.get(params, "node_type") do
              "module" -> :module
              "function" -> :function
              _ -> nil
            end

          include_context = Map.get(params, "include_context", true)

          # Search
          search_opts = [
            limit: limit,
            threshold: threshold
          ]

          search_opts =
            if node_type, do: Keyword.put(search_opts, :node_type, node_type), else: search_opts

          results = VectorStore.search(query_embedding, search_opts)

          # Enrich results with context
          enriched_results =
            if include_context do
              Enum.map(results, &enrich_result/1)
            else
              Enum.map(results, &format_result/1)
            end

          {:ok,
           %{
             query: query,
             results: enriched_results,
             count: length(enriched_results)
           }}

        {:error, reason} ->
          {:error, "Failed to generate embedding: #{inspect(reason)}"}
      end
    end
  end

  defp semantic_search(_), do: {:error, "Missing 'query' parameter"}

  defp get_embeddings_stats(_params) do
    stats = VectorStore.stats()
    graph_stats = Store.stats()

    {:ok,
     %{
       embeddings: stats,
       graph: graph_stats,
       model_ready: Bumblebee.ready?()
     }}
  end

  defp hybrid_search_tool(%{"query" => query} = params) do
    # Check if embedding model is ready
    if not Bumblebee.ready?() do
      {:error, "Embedding model not ready. Please wait for model to load."}
    else
      # Parse options
      strategy =
        case Map.get(params, "strategy", "fusion") do
          "fusion" -> :fusion
          "semantic_first" -> :semantic_first
          "graph_first" -> :graph_first
          _ -> :fusion
        end

      limit = Map.get(params, "limit", 10)
      threshold = Map.get(params, "threshold", 0.7)

      node_type =
        case Map.get(params, "node_type") do
          "module" -> :module
          "function" -> :function
          _ -> nil
        end

      include_context = Map.get(params, "include_context", true)

      # Build search options
      search_opts = [
        strategy: strategy,
        limit: limit,
        threshold: threshold
      ]

      search_opts =
        if node_type, do: Keyword.put(search_opts, :node_type, node_type), else: search_opts

      # Perform hybrid search
      case Hybrid.search(query, search_opts) do
        {:ok, results} ->
          # Enrich results with context if requested
          enriched_results =
            if include_context do
              Enum.map(results, &enrich_result/1)
            else
              Enum.map(results, &format_result/1)
            end

          {:ok,
           %{
             query: query,
             strategy: Atom.to_string(strategy),
             results: enriched_results,
             count: length(enriched_results)
           }}

        {:error, reason} ->
          {:error, "Hybrid search failed: #{inspect(reason)}"}
      end
    end
  end

  defp hybrid_search_tool(_), do: {:error, "Missing 'query' parameter"}

  defp find_paths_tool(%{"from" => from, "to" => to} = params) do
    max_depth = Map.get(params, "max_depth", 10)

    # Convert string node IDs to proper format
    # Expected formats: "Module" or "Module.function/arity"
    from_id = parse_node_id(from)
    to_id = parse_node_id(to)

    case {from_id, to_id} do
      {{:error, _}, _} ->
        {:error, "Invalid 'from' node ID format. Use 'Module' or 'Module.function/arity'"}

      {_, {:error, _}} ->
        {:error, "Invalid 'to' node ID format. Use 'Module' or 'Module.function/arity'"}

      {{:ok, from_node}, {:ok, to_node}} ->
        paths = Algorithms.find_paths(from_node, to_node, max_depth)

        formatted_paths =
          Enum.map(paths, fn path ->
            Enum.map(path, &format_node_id/1)
          end)

        {:ok,
         %{
           from: from,
           to: to,
           paths: formatted_paths,
           count: length(formatted_paths),
           max_depth: max_depth
         }}
    end
  end

  defp find_paths_tool(_), do: {:error, "Missing 'from' or 'to' parameter"}

  defp graph_stats_tool(_params) do
    stats = Algorithms.graph_stats()
    centrality = Algorithms.degree_centrality()

    # Find top nodes by centrality
    top_by_degree =
      centrality
      |> Enum.sort_by(fn {_node, metrics} -> -metrics.total_degree end)
      |> Enum.take(10)
      |> Enum.map(fn {node, metrics} ->
        %{
          node_id: format_node_id(node),
          in_degree: metrics.in_degree,
          out_degree: metrics.out_degree,
          total_degree: metrics.total_degree
        }
      end)

    # Format top nodes by PageRank
    top_by_pagerank =
      Enum.map(stats.top_nodes, fn {node, score} ->
        %{
          node_id: format_node_id(node),
          pagerank_score: Float.round(score, 6)
        }
      end)

    {:ok,
     %{
       node_count: stats.node_count,
       node_counts_by_type: stats.node_counts_by_type,
       edge_count: stats.edge_count,
       average_degree: stats.average_degree,
       density: stats.density,
       top_by_pagerank: top_by_pagerank,
       top_by_degree: top_by_degree
     }}
  end

  defp parse_node_id(node_str) do
    cond do
      # Module.function/arity
      String.contains?(node_str, "/") and String.contains?(node_str, ".") ->
        case String.split(node_str, ".") do
          [module_str, func_arity] ->
            case String.split(func_arity, "/") do
              [func_str, arity_str] ->
                case Integer.parse(arity_str) do
                  {arity, ""} ->
                    {:ok,
                     {:function, String.to_atom(module_str), String.to_atom(func_str), arity}}

                  _ ->
                    {:error, :invalid_arity}
                end

              _ ->
                {:error, :invalid_format}
            end

          _ ->
            {:error, :invalid_format}
        end

      # Just a module name
      true ->
        {:ok, {:module, String.to_atom(node_str)}}
    end
  end

  defp format_result(result) do
    %{
      node_type: Atom.to_string(result.node_type),
      node_id: format_node_id(result.node_id),
      score: Float.round(result.score, 4),
      description: result.text
    }
  end

  defp enrich_result(result) do
    base = format_result(result)

    # Get the actual node data
    node_data = Store.find_node(result.node_type, result.node_id)

    # Add context based on node type
    context =
      case result.node_type do
        :function ->
          {module, name, arity} = result.node_id
          callers = Store.get_incoming_edges({:function, module, name, arity}, :calls)
          callees = Store.get_outgoing_edges({:function, module, name, arity}, :calls)

          %{
            module: Atom.to_string(module),
            function: Atom.to_string(name),
            arity: arity,
            file: node_data[:file],
            line: node_data[:line],
            visibility:
              if(node_data[:visibility], do: Atom.to_string(node_data[:visibility]), else: nil),
            callers: length(callers),
            callees: length(callees)
          }

        :module ->
          functions = Store.get_outgoing_edges({:module, result.node_id}, :defines)
          imports = Store.get_outgoing_edges({:module, result.node_id}, :imports)

          %{
            name: Atom.to_string(result.node_id),
            file: node_data[:file],
            line: node_data[:line],
            functions_count: length(functions),
            imports_count: length(imports)
          }

        _ ->
          %{}
      end

    Map.put(base, :context, context)
  end

  defp format_node_id(id) when is_atom(id), do: Atom.to_string(id)

  defp format_node_id({module, name, arity}) when is_atom(module) and is_atom(name) do
    "#{Atom.to_string(module)}.#{Atom.to_string(name)}/#{arity}"
  end

  defp format_node_id(id), do: inspect(id)

  defp store_analysis(%{modules: modules, functions: functions, calls: calls}) do
    # Store modules
    Enum.each(modules, fn module ->
      Store.add_node(:module, module.name, module)
    end)

    # Store functions
    Enum.each(functions, fn func ->
      Store.add_node(:function, {func.module, func.name, func.arity}, func)
      # Add edge from module to function
      Store.add_edge(
        {:module, func.module},
        {:function, func.module, func.name, func.arity},
        :defines
      )
    end)

    # Store call relationships
    Enum.each(calls, fn call ->
      Store.add_edge(
        {:function, call.from_module, call.from_function, call.from_arity},
        {:function, call.to_module, call.to_function, call.to_arity},
        :calls
      )
    end)
  end

  # Edit tool implementations

  defp edit_file_tool(%{"path" => path, "changes" => changes_data} = params) do
    # Convert JSON changes to Types.change() structs
    with {:ok, changes} <- parse_changes(changes_data),
         opts <- build_edit_opts(params),
         {:ok, result} <- Core.edit_file(path, changes, opts) do
      {:ok,
       %{
         status: "success",
         path: result.path,
         changes_applied: result.changes_applied,
         lines_changed: result.lines_changed,
         validation_performed: result.validation_performed,
         backup_id: result.backup_id,
         timestamp: result.timestamp
       }}
    else
      {:error, %{type: :validation_error, errors: errors}} ->
        {:error,
         %{
           "type" => "validation_error",
           "message" => "Validation failed",
           "errors" => Enum.map(errors, &format_validation_error/1)
         }}

      {:error, reason} ->
        {:error, "Edit failed: #{inspect(reason)}"}
    end
  end

  defp edit_file_tool(_), do: {:error, "Invalid parameters for edit_file"}

  defp validate_edit_tool(%{"path" => path, "changes" => changes_data} = params) do
    with {:ok, changes} <- parse_changes(changes_data),
         opts <- build_validation_opts(params),
         :ok <- Core.validate_changes(path, changes, opts) do
      {:ok,
       %{
         status: "valid",
         message: "Changes are valid"
       }}
    else
      {:error, %{type: :validation_error, errors: errors}} ->
        {:ok,
         %{
           status: "invalid",
           errors: Enum.map(errors, &format_validation_error/1)
         }}

      {:error, reason} ->
        {:error, "Validation failed: #{inspect(reason)}"}
    end
  end

  defp validate_edit_tool(_), do: {:error, "Invalid parameters for validate_edit"}

  defp rollback_edit_tool(%{"path" => path} = params) do
    opts =
      if backup_id = params["backup_id"] do
        [backup_id: backup_id]
      else
        []
      end

    case Core.rollback(path, opts) do
      {:ok, backup_info} ->
        {:ok,
         %{
           status: "restored",
           path: path,
           backup_id: backup_info.id,
           backup_path: backup_info.backup_path,
           timestamp: backup_info.created_at
         }}

      {:error, reason} ->
        {:error, "Rollback failed: #{inspect(reason)}"}
    end
  end

  defp rollback_edit_tool(_), do: {:error, "Invalid parameters for rollback_edit"}

  defp edit_history_tool(%{"path" => path} = params) do
    limit = Map.get(params, "limit", 10)
    opts = [limit: limit]

    case Core.history(path, opts) do
      {:ok, backups} ->
        {:ok,
         %{
           path: path,
           count: length(backups),
           backups:
             Enum.map(backups, fn backup ->
               %{
                 id: backup.id,
                 timestamp: backup.created_at,
                 size_bytes: backup.size,
                 path: backup.backup_path
               }
             end)
         }}

      {:error, reason} ->
        {:error, "Failed to get history: #{inspect(reason)}"}
    end
  end

  defp edit_history_tool(_), do: {:error, "Invalid parameters for edit_history"}

  defp edit_files_tool(%{"files" => files_data} = params) do
    # Build transaction with default options
    txn_opts = []

    txn_opts =
      if Map.has_key?(params, "validate") do
        Keyword.put(txn_opts, :validate, params["validate"])
      else
        txn_opts
      end

    txn_opts =
      if Map.has_key?(params, "create_backup") do
        Keyword.put(txn_opts, :create_backup, params["create_backup"])
      else
        txn_opts
      end

    txn_opts =
      if Map.has_key?(params, "format") do
        Keyword.put(txn_opts, :format, params["format"])
      else
        txn_opts
      end

    # Parse files and build transaction
    with {:ok, transaction} <- build_transaction(files_data, txn_opts) do
      case Transaction.commit(transaction) do
        {:ok, result} ->
          {:ok,
           %{
             status: "success",
             files_edited: result.files_edited,
             results:
               Enum.map(result.results, fn r ->
                 %{
                   path: r.path,
                   changes_applied: r.changes_applied,
                   lines_changed: r.lines_changed,
                   backup_id: r.backup_id,
                   validation_performed: r.validation_performed
                 }
               end)
           }}

        {:error, result} ->
          error_details =
            Enum.map(result.errors, fn {path, reason} ->
              %{path: path, reason: inspect(reason)}
            end)

          {:error,
           %{
             "type" => "transaction_error",
             "message" => "Transaction failed",
             "files_edited" => result.files_edited,
             "rolled_back" => result.rolled_back,
             "errors" => error_details
           }}
      end
    else
      {:error, reason} ->
        {:error, "Failed to build transaction: #{inspect(reason)}"}
    end
  end

  defp edit_files_tool(_), do: {:error, "Invalid parameters for edit_files"}

  defp build_transaction(files_data, txn_opts) when is_list(files_data) do
    result =
      Enum.reduce_while(files_data, Transaction.new(txn_opts), fn file_data, txn ->
        path = Map.get(file_data, "path")
        changes_data = Map.get(file_data, "changes")

        # Build per-file options
        file_opts = []

        file_opts =
          if Map.has_key?(file_data, "validate") do
            Keyword.put(file_opts, :validate, file_data["validate"])
          else
            file_opts
          end

        file_opts =
          if Map.has_key?(file_data, "format") do
            Keyword.put(file_opts, :format, file_data["format"])
          else
            file_opts
          end

        file_opts =
          if language = file_data["language"] do
            Keyword.put(file_opts, :language, String.to_atom(language))
          else
            file_opts
          end

        # Parse changes
        case parse_changes(changes_data) do
          {:ok, changes} ->
            {:cont, Transaction.add(txn, path, changes, file_opts)}

          {:error, reason} ->
            {:halt, {:error, "Failed to parse changes for #{path}: #{inspect(reason)}"}}
        end
      end)

    case result do
      {:error, _} = error -> error
      transaction -> {:ok, transaction}
    end
  end

  defp build_transaction(_, _), do: {:error, "Files must be a list"}

  defp refactor_code_tool(%{"operation" => operation, "params" => params} = arguments) do
    scope = String.to_atom(Map.get(arguments, "scope", "project"))
    validate = Map.get(arguments, "validate", true)
    format = Map.get(arguments, "format", true)
    opts = [scope: scope, validate: validate, format: format]

    case operation do
      "rename_function" ->
        handle_rename_function(params, opts)

      "rename_module" ->
        handle_rename_module(params, opts)

      _ ->
        {:error, "Unknown refactoring operation: #{operation}"}
    end
  end

  defp refactor_code_tool(_), do: {:error, "Invalid parameters for refactor_code"}

  defp handle_rename_function(params, opts) do
    with {:ok, module} <- get_required_param(params, "module"),
         {:ok, old_name} <- get_required_param(params, "old_name"),
         {:ok, new_name} <- get_required_param(params, "new_name"),
         {:ok, arity} <- get_required_param(params, "arity") do
      module_atom = String.to_atom(module)
      old_atom = String.to_atom(old_name)
      new_atom = String.to_atom(new_name)

      case Refactor.rename_function(module_atom, old_atom, new_atom, arity, opts) do
        {:ok, result} ->
          {:ok,
           %{
             status: "success",
             operation: "rename_function",
             files_modified: result.files_modified,
             details: %{
               module: module,
               old_name: old_name,
               new_name: new_name,
               arity: arity,
               scope: opts[:scope]
             }
           }}

        {:error, error_result} when is_map(error_result) ->
          {:error,
           %{
             "type" => "refactor_error",
             "operation" => "rename_function",
             "message" => "Refactoring failed",
             "files_modified" => error_result.files_modified,
             "rolled_back" => error_result.rolled_back,
             "errors" =>
               Enum.map(error_result.errors || [], fn
                 {path, reason} -> %{path: path, reason: inspect(reason)}
                 error -> %{error: inspect(error)}
               end)
           }}

        {:error, message} when is_binary(message) ->
          {:error,
           %{
             "type" => "refactor_error",
             "operation" => "rename_function",
             "message" => message
           }}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_rename_module(params, opts) do
    with {:ok, old_name} <- get_required_param(params, "old_name"),
         {:ok, new_name} <- get_required_param(params, "new_name") do
      old_atom = String.to_atom(old_name)
      new_atom = String.to_atom(new_name)

      case Refactor.rename_module(old_atom, new_atom, opts) do
        {:ok, result} ->
          {:ok,
           %{
             status: "success",
             operation: "rename_module",
             files_modified: result.files_modified,
             details: %{
               old_name: old_name,
               new_name: new_name
             }
           }}

        {:error, error_result} when is_map(error_result) ->
          {:error,
           %{
             "type" => "refactor_error",
             "operation" => "rename_module",
             "message" => "Module refactoring failed",
             "files_modified" => error_result.files_modified,
             "rolled_back" => error_result.rolled_back,
             "errors" =>
               Enum.map(error_result.errors || [], fn
                 {path, reason} -> %{path: path, reason: inspect(reason)}
                 error -> %{error: inspect(error)}
               end)
           }}

        {:error, message} when is_binary(message) ->
          {:error,
           %{
             "type" => "refactor_error",
             "operation" => "rename_module",
             "message" => message
           }}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_required_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, "Missing required parameter: #{key}"}
      value -> {:ok, value}
    end
  end

  # Helper functions for edit tools

  defp parse_changes(changes_data) when is_list(changes_data) do
    changes =
      Enum.reduce_while(changes_data, [], fn change, acc ->
        case parse_single_change(change) do
          {:ok, parsed} -> {:cont, [parsed | acc]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case changes do
      {:error, _} = error -> error
      changes -> {:ok, Enum.reverse(changes)}
    end
  end

  defp parse_changes(_), do: {:error, "Changes must be a list"}

  defp parse_single_change(%{
         "type" => "replace",
         "line_start" => start,
         "line_end" => end_line,
         "content" => content
       }) do
    {:ok, Types.replace(start, end_line, content)}
  end

  defp parse_single_change(%{"type" => "insert", "line_start" => start, "content" => content}) do
    {:ok, Types.insert(start, content)}
  end

  defp parse_single_change(%{"type" => "delete", "line_start" => start, "line_end" => end_line}) do
    {:ok, Types.delete(start, end_line)}
  end

  defp parse_single_change(_), do: {:error, "Invalid change structure"}

  defp build_edit_opts(params) do
    opts = []

    opts =
      if Map.has_key?(params, "validate") do
        Keyword.put(opts, :validate, params["validate"])
      else
        opts
      end

    opts =
      if Map.has_key?(params, "create_backup") do
        Keyword.put(opts, :create_backup, params["create_backup"])
      else
        opts
      end

    opts =
      if language = params["language"] do
        Keyword.put(opts, :language, String.to_atom(language))
      else
        opts
      end

    opts
  end

  defp build_validation_opts(params) do
    opts = []

    opts =
      if language = params["language"] do
        Keyword.put(opts, :language, String.to_atom(language))
      else
        opts
      end

    opts
  end

  defp format_validation_error(error) do
    base = %{message: error.message, severity: error.severity}

    base =
      if Map.has_key?(error, :line) and error.line do
        Map.put(base, :line, error.line)
      else
        base
      end

    base =
      if Map.has_key?(error, :column) and error.column do
        Map.put(base, :column, error.column)
      else
        base
      end

    base =
      if Map.has_key?(error, :context) and error.context do
        Map.put(base, :context, error.context)
      else
        base
      end

    base
  end
end
