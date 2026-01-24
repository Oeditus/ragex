defmodule Ragex.MCP.Handlers.Tools do
  @moduledoc """
  Handles MCP tool-related requests.

  Implements the tools/list and tools/call methods.
  """
  alias Ragex.AI.{Cache, Usage}

  alias Ragex.Analysis.{
    DeadCode,
    DependencyGraph,
    Duplication,
    Impact,
    MetastaticBridge,
    QualityStore,
    Security,
    Smells,
    Suggestions
  }

  alias Ragex.Analyzers.Directory
  alias Ragex.Analyzers.Elixir, as: ElixirAnalyzer
  alias Ragex.Analyzers.Erlang, as: ErlangAnalyzer
  alias Ragex.Analyzers.JavaScript, as: JavaScriptAnalyzer
  alias Ragex.Analyzers.Metastatic
  alias Ragex.Analyzers.Python, as: PythonAnalyzer

  alias Ragex.Editor.{
    Conflict,
    Core,
    Refactor,
    Refactor.AIPreview,
    Transaction,
    Types,
    Undo,
    ValidationAI,
    Visualize
  }

  alias Ragex.Embeddings.Bumblebee
  alias Ragex.Embeddings.Helper, as: EmbeddingsHelper
  alias Ragex.Graph.Algorithms
  alias Ragex.Graph.Store
  alias Ragex.RAG.Pipeline
  alias Ragex.Retrieval.{CrossLanguage, Hybrid, QueryExpansion}
  alias Ragex.VectorStore
  alias Ragex.Watcher

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
            properties: %{}
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
                description: "Minimum similarity score (0.0 to 1.0, typical: 0.1-0.3)",
                default: 0.2
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
            properties: %{}
          }
        },
        %{
          name: "get_ai_usage",
          description: "Get AI provider usage statistics (requests, tokens, costs)",
          inputSchema: %{
            type: "object",
            properties: %{
              provider: %{
                type: "string",
                description: "Filter by provider (openai, anthropic, deepseek_r1, ollama)",
                enum: ["openai", "anthropic", "deepseek_r1", "ollama"]
              }
            }
          }
        },
        %{
          name: "get_ai_cache_stats",
          description: "Get AI response cache statistics and hit rates",
          inputSchema: %{
            type: "object",
            properties: %{}
          }
        },
        %{
          name: "clear_ai_cache",
          description: "Clear AI response cache (all or specific operation)",
          inputSchema: %{
            type: "object",
            properties: %{
              operation: %{
                type: "string",
                description: "Operation to clear (query, explain, suggest, or all)",
                enum: ["query", "explain", "suggest", "all"]
              }
            }
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
            properties: %{}
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
                description: "Minimum similarity score (0.0 to 1.0, typical: 0.1-0.3)",
                default: 0.15
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
          name: "metaast_search",
          description:
            "Search for semantically equivalent code constructs across languages using MetaAST analysis",
          inputSchema: %{
            type: "object",
            properties: %{
              source_language: %{
                type: "string",
                description: "Source language",
                enum: ["elixir", "erlang", "python", "javascript"]
              },
              source_construct: %{
                type: "string",
                description:
                  "Source construct (e.g., 'Enum.map/2', 'list_comprehension', or MetaAST pattern)"
              },
              target_languages: %{
                type: "array",
                description: "Target languages to search (empty = all languages)",
                items: %{
                  type: "string",
                  enum: ["elixir", "erlang", "python", "javascript"]
                },
                default: []
              },
              limit: %{
                type: "integer",
                description: "Maximum results per language",
                default: 5
              },
              threshold: %{
                type: "number",
                description: "Semantic similarity threshold (0.0-1.0)",
                default: 0.6
              },
              strict_equivalence: %{
                type: "boolean",
                description: "Require exact AST match (default: false)",
                default: false
              }
            },
            required: ["source_language", "source_construct"]
          }
        },
        %{
          name: "cross_language_alternatives",
          description: "Suggest cross-language alternatives for a code construct",
          inputSchema: %{
            type: "object",
            properties: %{
              language: %{
                type: "string",
                description: "Source language",
                enum: ["elixir", "erlang", "python", "javascript"]
              },
              code: %{
                type: "string",
                description: "Code snippet or construct description"
              },
              target_languages: %{
                type: "array",
                description: "Languages to generate alternatives for",
                items: %{
                  type: "string",
                  enum: ["elixir", "erlang", "python", "javascript"]
                },
                default: []
              }
            },
            required: ["language", "code"]
          }
        },
        %{
          name: "expand_query",
          description: "Expand a search query with semantic synonyms and cross-language terms",
          inputSchema: %{
            type: "object",
            properties: %{
              query: %{
                type: "string",
                description: "Original search query"
              },
              intent: %{
                type: "string",
                description: "Query intent (auto-detected if not specified)",
                enum: ["explain", "refactor", "example", "debug", "general"]
              },
              max_terms: %{
                type: "integer",
                description: "Maximum expansion terms to add",
                default: 5
              },
              include_synonyms: %{
                type: "boolean",
                description: "Include semantic synonyms",
                default: true
              },
              include_cross_language: %{
                type: "boolean",
                description: "Include cross-language terms",
                default: true
              }
            },
            required: ["query"]
          }
        },
        %{
          name: "find_metaast_pattern",
          description: "Find all implementations of a MetaAST pattern across all languages",
          inputSchema: %{
            type: "object",
            properties: %{
              pattern: %{
                type: "string",
                description: "MetaAST pattern (e.g., 'collection_op:map', 'loop:for', 'lambda')"
              },
              languages: %{
                type: "array",
                description: "Filter by languages (empty = all)",
                items: %{
                  type: "string",
                  enum: ["elixir", "erlang", "python", "javascript"]
                },
                default: []
              },
              limit: %{
                type: "integer",
                description: "Maximum results",
                default: 20
              }
            },
            required: ["pattern"]
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
          name: "advanced_refactor",
          description:
            "Advanced refactoring operations: extract_function, inline_function, convert_visibility, rename_parameter, modify_attributes, change_signature, move_function, extract_module",
          inputSchema: %{
            type: "object",
            properties: %{
              operation: %{
                type: "string",
                description: "Type of advanced refactoring operation",
                enum: [
                  "extract_function",
                  "inline_function",
                  "convert_visibility",
                  "rename_parameter",
                  "modify_attributes",
                  "change_signature",
                  "move_function",
                  "extract_module"
                ]
              },
              params: %{
                type: "object",
                description:
                  "Operation-specific parameters. See documentation for each operation type."
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
              },
              scope: %{
                type: "string",
                description: "Refactoring scope (for applicable operations)",
                enum: ["module", "project"],
                default: "project"
              }
            },
            required: ["operation", "params"]
          }
        },
        %{
          name: "betweenness_centrality",
          description:
            "Compute betweenness centrality to identify bridge/bottleneck functions in the call graph",
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
        },
        %{
          name: "closeness_centrality",
          description:
            "Compute closeness centrality to identify central functions in the call graph",
          inputSchema: %{
            type: "object",
            properties: %{
              normalize: %{
                type: "boolean",
                description: "Return normalized scores (0-1)",
                default: true
              }
            }
          }
        },
        %{
          name: "detect_communities",
          description:
            "Detect communities/clusters in the call graph to identify architectural modules",
          inputSchema: %{
            type: "object",
            properties: %{
              algorithm: %{
                type: "string",
                description: "Community detection algorithm",
                enum: ["louvain", "label_propagation"],
                default: "louvain"
              },
              max_iterations: %{
                type: "integer",
                description: "Maximum optimization iterations",
                default: 10
              },
              resolution: %{
                type: "number",
                description: "Resolution parameter for multi-scale detection (Louvain only)",
                default: 1.0
              },
              hierarchical: %{
                type: "boolean",
                description: "Return hierarchical community structure (Louvain only)",
                default: false
              },
              seed: %{
                type: "integer",
                description: "Random seed for deterministic results (label propagation only)"
              }
            }
          }
        },
        %{
          name: "export_graph",
          description:
            "Export the call graph in visualization formats (Graphviz DOT or D3.js JSON)",
          inputSchema: %{
            type: "object",
            properties: %{
              format: %{
                type: "string",
                description: "Export format",
                enum: ["graphviz", "d3"],
                default: "graphviz"
              },
              include_communities: %{
                type: "boolean",
                description: "Include community clustering",
                default: true
              },
              color_by: %{
                type: "string",
                description: "Centrality metric for node coloring (graphviz only)",
                enum: ["pagerank", "betweenness", "degree"],
                default: "pagerank"
              },
              max_nodes: %{
                type: "integer",
                description: "Maximum nodes to include",
                default: 500
              }
            },
            required: ["format"]
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
        },
        %{
          name: "rag_query",
          description: "Query codebase using RAG (Retrieval-Augmented Generation) with AI",
          inputSchema: %{
            type: "object",
            properties: %{
              query: %{
                type: "string",
                description: "Natural language query about the codebase"
              },
              limit: %{
                type: "integer",
                description: "Maximum number of code snippets to retrieve",
                default: 10
              },
              include_code: %{
                type: "boolean",
                description: "Include full code snippets in context",
                default: true
              },
              provider: %{
                type: "string",
                description: "AI provider override",
                enum: ["deepseek_r1", "openai", "anthropic", "ollama"]
              }
            },
            required: ["query"]
          }
        },
        %{
          name: "rag_explain",
          description: "Explain code using RAG with AI assistance",
          inputSchema: %{
            type: "object",
            properties: %{
              target: %{
                type: "string",
                description: "File path or function identifier (e.g., 'MyModule.function/2')"
              },
              aspect: %{
                type: "string",
                description: "What to explain",
                enum: ["purpose", "complexity", "dependencies", "all"],
                default: "all"
              }
            },
            required: ["target"]
          }
        },
        %{
          name: "rag_suggest",
          description: "Suggest code improvements using RAG with AI",
          inputSchema: %{
            type: "object",
            properties: %{
              target: %{
                type: "string",
                description: "File path or function identifier"
              },
              focus: %{
                type: "string",
                description: "Improvement focus area",
                enum: ["performance", "readability", "testing", "security", "all"],
                default: "all"
              }
            },
            required: ["target"]
          }
        },
        %{
          name: "rag_query_stream",
          description:
            "Query codebase using RAG with streaming AI response (internally uses streaming, returns complete result)",
          inputSchema: %{
            type: "object",
            properties: %{
              query: %{
                type: "string",
                description: "Natural language query about the codebase"
              },
              limit: %{
                type: "integer",
                description: "Maximum number of code snippets to retrieve",
                default: 10
              },
              include_code: %{
                type: "boolean",
                description: "Include full code snippets in context",
                default: true
              },
              provider: %{
                type: "string",
                description: "AI provider override",
                enum: ["deepseek_r1", "openai", "anthropic", "ollama"]
              },
              show_chunks: %{
                type: "boolean",
                description: "Include intermediate chunks in response for debugging",
                default: false
              }
            },
            required: ["query"]
          }
        },
        %{
          name: "rag_explain_stream",
          description:
            "Explain code using RAG with streaming AI response (internally uses streaming, returns complete result)",
          inputSchema: %{
            type: "object",
            properties: %{
              target: %{
                type: "string",
                description: "File path or function identifier (e.g., 'MyModule.function/2')"
              },
              aspect: %{
                type: "string",
                description: "What to explain",
                enum: ["purpose", "complexity", "dependencies", "all"],
                default: "all"
              },
              show_chunks: %{
                type: "boolean",
                description: "Include intermediate chunks in response for debugging",
                default: false
              }
            },
            required: ["target"]
          }
        },
        %{
          name: "rag_suggest_stream",
          description:
            "Suggest code improvements using RAG with streaming AI (internally uses streaming, returns complete result)",
          inputSchema: %{
            type: "object",
            properties: %{
              target: %{
                type: "string",
                description: "File path or function identifier"
              },
              focus: %{
                type: "string",
                description: "Improvement focus area",
                enum: ["performance", "readability", "testing", "security", "all"],
                default: "all"
              },
              show_chunks: %{
                type: "boolean",
                description: "Include intermediate chunks in response for debugging",
                default: false
              }
            },
            required: ["target"]
          }
        },
        %{
          name: "preview_refactor",
          description:
            "Preview refactoring changes without applying them - shows diffs, conflicts, and statistics with optional AI commentary",
          inputSchema: %{
            type: "object",
            properties: %{
              operation: %{
                type: "string",
                description: "Refactoring operation type",
                enum: ["rename_function", "rename_module", "extract_function", "inline_function"]
              },
              params: %{
                type: "object",
                description: "Operation-specific parameters"
              },
              format: %{
                type: "string",
                description: "Preview output format",
                enum: ["unified", "side_by_side", "json"],
                default: "unified"
              },
              ai_commentary: %{
                type: "boolean",
                description:
                  "Generate AI-powered summary and risk assessment (default: from config)",
                default: true
              }
            },
            required: ["operation", "params"]
          }
        },
        %{
          name: "refactor_conflicts",
          description:
            "Check for conflicts before applying a refactoring operation - detects naming, dependency, and scope conflicts",
          inputSchema: %{
            type: "object",
            properties: %{
              operation: %{
                type: "string",
                description: "Refactoring operation type",
                enum: ["rename_function", "rename_module", "move_function", "extract_module"]
              },
              params: %{
                type: "object",
                description: "Operation-specific parameters"
              }
            },
            required: ["operation", "params"]
          }
        },
        %{
          name: "undo_refactor",
          description:
            "Undo the most recent refactoring operation by restoring files to their previous state",
          inputSchema: %{
            type: "object",
            properties: %{
              project_path: %{
                type: "string",
                description: "Project root path (uses current directory if not specified)"
              }
            }
          }
        },
        %{
          name: "refactor_history",
          description: "List refactoring operation history with timestamps and file counts",
          inputSchema: %{
            type: "object",
            properties: %{
              project_path: %{
                type: "string",
                description: "Project root path (uses current directory if not specified)"
              },
              limit: %{
                type: "integer",
                description: "Maximum number of entries to return",
                default: 50
              },
              include_undone: %{
                type: "boolean",
                description: "Include undone operations",
                default: false
              }
            }
          }
        },
        %{
          name: "visualize_impact",
          description:
            "Visualize the impact of refactoring changes - shows affected functions, impact radius, and risk analysis",
          inputSchema: %{
            type: "object",
            properties: %{
              files: %{
                type: "array",
                description: "List of file paths affected by refactoring",
                items: %{type: "string"}
              },
              format: %{
                type: "string",
                description: "Visualization format",
                enum: ["graphviz", "d3_json", "ascii"],
                default: "ascii"
              },
              depth: %{
                type: "integer",
                description: "Impact radius depth (number of neighbor levels)",
                default: 1
              },
              include_risk: %{
                type: "boolean",
                description: "Include risk analysis based on centrality metrics",
                default: true
              }
            },
            required: ["files"]
          }
        },
        %{
          name: "analyze_quality",
          description:
            "Analyze code quality metrics for a file or directory using Metastatic - provides complexity, purity, and other code quality indicators",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "File or directory path to analyze"
              },
              metrics: %{
                type: "array",
                description:
                  "Specific metrics to compute (if not specified, computes all available metrics)",
                items: %{
                  type: "string",
                  enum: [
                    "cyclomatic",
                    "cognitive",
                    "nesting",
                    "halstead",
                    "loc",
                    "function_metrics",
                    "purity"
                  ]
                }
              },
              store_results: %{
                type: "boolean",
                description: "Store results in knowledge graph for later querying",
                default: true
              },
              recursive: %{
                type: "boolean",
                description: "Recursively analyze directories",
                default: true
              }
            },
            required: ["path"]
          }
        },
        %{
          name: "quality_report",
          description:
            "Generate a comprehensive quality report for analyzed files - includes statistics, trends, and language-specific breakdowns",
          inputSchema: %{
            type: "object",
            properties: %{
              report_type: %{
                type: "string",
                description: "Type of report to generate",
                enum: ["summary", "detailed", "by_language", "trends"],
                default: "summary"
              },
              format: %{
                type: "string",
                description: "Output format",
                enum: ["text", "json", "markdown"],
                default: "text"
              },
              include_files: %{
                type: "boolean",
                description: "Include individual file details",
                default: false
              }
            }
          }
        },
        %{
          name: "find_complex_code",
          description:
            "Find files or functions exceeding complexity thresholds - useful for identifying refactoring candidates",
          inputSchema: %{
            type: "object",
            properties: %{
              metric: %{
                type: "string",
                description: "Complexity metric to evaluate",
                enum: ["cyclomatic", "cognitive", "nesting"],
                default: "cyclomatic"
              },
              threshold: %{
                type: "number",
                description: "Threshold value (files exceeding this are returned)",
                default: 10
              },
              comparison: %{
                type: "string",
                description: "Comparison operator",
                enum: ["gt", "gte", "lt", "lte", "eq"],
                default: "gt"
              },
              limit: %{
                type: "integer",
                description: "Maximum number of results",
                default: 20
              },
              sort_order: %{
                type: "string",
                description: "Sort order for results",
                enum: ["asc", "desc"],
                default: "desc"
              }
            }
          }
        },
        %{
          name: "analyze_dependencies",
          description:
            "Analyze module dependencies - shows coupling metrics, circular dependencies, and dependency relationships",
          inputSchema: %{
            type: "object",
            properties: %{
              module: %{
                type: "string",
                description:
                  "Module name to analyze (optional - if not provided, analyzes all modules)"
              },
              include_transitive: %{
                type: "boolean",
                description: "Include transitive dependencies (dependencies of dependencies)",
                default: false
              },
              format: %{
                type: "string",
                description: "Output format",
                enum: ["summary", "detailed", "json"],
                default: "summary"
              }
            }
          }
        },
        %{
          name: "find_circular_dependencies",
          description:
            "Find circular dependencies in the codebase - helps identify architectural issues",
          inputSchema: %{
            type: "object",
            properties: %{
              scope: %{
                type: "string",
                description: "Analysis scope",
                enum: ["module", "function"],
                default: "module"
              },
              min_cycle_length: %{
                type: "integer",
                description: "Minimum cycle length to report",
                default: 2
              },
              limit: %{
                type: "integer",
                description: "Maximum number of cycles to return",
                default: 100
              }
            }
          }
        },
        %{
          name: "find_dead_code",
          description:
            "Find potentially unused code (functions with no callers) - includes confidence scoring to distinguish callbacks from truly dead code",
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
              },
              exclude_tests: %{
                type: "boolean",
                description: "Exclude test modules from analysis",
                default: true
              },
              include_callbacks: %{
                type: "boolean",
                description: "Include potential callbacks (GenServer, Phoenix, etc.)",
                default: false
              },
              format: %{
                type: "string",
                description: "Output format",
                enum: ["summary", "detailed", "suggestions"],
                default: "summary"
              }
            }
          }
        },
        %{
          name: "analyze_dead_code_patterns",
          description:
            "Analyze files for intraprocedural dead code patterns (unreachable code, constant conditionals) using AST analysis - complements find_dead_code which finds unused functions",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "File path or directory to analyze"
              },
              min_confidence: %{
                type: "string",
                description: "Minimum confidence level for reporting",
                enum: ["low", "medium", "high"],
                default: "low"
              },
              format: %{
                type: "string",
                description: "Output format",
                enum: ["summary", "detailed", "json"],
                default: "summary"
              }
            },
            required: ["path"]
          }
        },
        %{
          name: "coupling_report",
          description:
            "Generate coupling metrics report - shows afferent/efferent coupling and instability for all modules",
          inputSchema: %{
            type: "object",
            properties: %{
              format: %{
                type: "string",
                description: "Output format",
                enum: ["text", "json", "markdown"],
                default: "text"
              },
              sort_by: %{
                type: "string",
                description: "Sort modules by metric",
                enum: ["name", "instability", "afferent", "efferent"],
                default: "instability"
              },
              include_transitive: %{
                type: "boolean",
                description: "Include transitive coupling metrics",
                default: false
              },
              threshold: %{
                type: "integer",
                description: "Only show modules with total coupling >= threshold (0 = show all)",
                default: 0
              }
            }
          }
        },
        %{
          name: "find_duplicates",
          description:
            "Find code duplicates using AST-based clone detection (Type I-IV) - works across different languages via Metastatic",
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
                description: "Similarity threshold for Type III clones (0.0-1.0)",
                default: 0.8
              },
              recursive: %{
                type: "boolean",
                description: "Recursively scan directories",
                default: true
              },
              format: %{
                type: "string",
                description: "Output format",
                enum: ["summary", "detailed", "json"],
                default: "summary"
              },
              exclude_patterns: %{
                type: "array",
                description: "Patterns to exclude from scan",
                items: %{type: "string"},
                default: ["_build", "deps", ".git"]
              }
            },
            required: ["path"]
          }
        },
        %{
          name: "find_similar_code",
          description:
            "Find semantically similar code using embedding-based similarity - complements AST-based duplicate detection",
          inputSchema: %{
            type: "object",
            properties: %{
              threshold: %{
                type: "number",
                description: "Similarity threshold (0.0-1.0)",
                default: 0.95
              },
              limit: %{
                type: "integer",
                description: "Maximum number of similar pairs to return",
                default: 100
              },
              node_type: %{
                type: "string",
                description: "Type of code entity to compare",
                enum: ["function", "module"],
                default: "function"
              },
              format: %{
                type: "string",
                description: "Output format",
                enum: ["summary", "detailed", "json"],
                default: "summary"
              }
            }
          }
        },
        %{
          name: "analyze_impact",
          description:
            "Analyze the impact of changing a function or module - finds all affected code via graph traversal",
          inputSchema: %{
            type: "object",
            properties: %{
              target: %{
                type: "string",
                description:
                  "Target to analyze (format: 'Module.function/arity' or 'Module' for modules)"
              },
              depth: %{
                type: "integer",
                description: "Maximum traversal depth",
                default: 5
              },
              include_tests: %{
                type: "boolean",
                description: "Include test files in analysis",
                default: true
              },
              format: %{
                type: "string",
                description: "Output format",
                enum: ["summary", "detailed", "json"],
                default: "summary"
              }
            },
            required: ["target"]
          }
        },
        %{
          name: "estimate_refactoring_effort",
          description:
            "Estimate effort required for a refactoring operation - provides time estimates and recommendations",
          inputSchema: %{
            type: "object",
            properties: %{
              operation: %{
                type: "string",
                description: "Refactoring operation type",
                enum: [
                  "rename_function",
                  "rename_module",
                  "extract_function",
                  "inline_function",
                  "move_function",
                  "change_signature"
                ]
              },
              target: %{
                type: "string",
                description:
                  "Target to refactor (format: 'Module.function/arity' or 'Module' for modules)"
              },
              format: %{
                type: "string",
                description: "Output format",
                enum: ["summary", "detailed", "json"],
                default: "summary"
              }
            },
            required: ["operation", "target"]
          }
        },
        %{
          name: "risk_assessment",
          description:
            "Calculate risk score for changing a function or module - combines importance, coupling, and complexity",
          inputSchema: %{
            type: "object",
            properties: %{
              target: %{
                type: "string",
                description:
                  "Target to assess (format: 'Module.function/arity' or 'Module' for modules)"
              },
              format: %{
                type: "string",
                description: "Output format",
                enum: ["summary", "detailed", "json"],
                default: "summary"
              }
            },
            required: ["target"]
          }
        },
        %{
          name: "suggest_refactorings",
          description:
            "Analyze code and generate prioritized refactoring suggestions using pattern detection and AI - Phase 11G",
          inputSchema: %{
            type: "object",
            properties: %{
              target: %{
                type: "string",
                description:
                  "Target to analyze: file path, directory path, or module name (format: 'Module' or 'Module.function/arity')"
              },
              patterns: %{
                type: "array",
                description: "Filter by specific patterns (empty = all patterns)",
                items: %{
                  type: "string",
                  enum: [
                    "extract_function",
                    "inline_function",
                    "split_module",
                    "merge_modules",
                    "remove_dead_code",
                    "reduce_coupling",
                    "simplify_complexity",
                    "extract_module"
                  ]
                }
              },
              min_priority: %{
                type: "string",
                description: "Minimum priority level to include",
                enum: ["info", "low", "medium", "high", "critical"],
                default: "low"
              },
              include_actions: %{
                type: "boolean",
                description: "Include action plans with step-by-step instructions",
                default: true
              },
              use_rag: %{
                type: "boolean",
                description: "Use RAG for AI-powered advice (requires AI provider)",
                default: false
              },
              format: %{
                type: "string",
                description: "Output format",
                enum: ["summary", "detailed", "json"],
                default: "summary"
              }
            },
            required: ["target"]
          }
        },
        %{
          name: "explain_suggestion",
          description:
            "Get detailed explanation for a specific refactoring suggestion - Phase 11G",
          inputSchema: %{
            type: "object",
            properties: %{
              suggestion_id: %{
                type: "string",
                description: "ID of the suggestion (from suggest_refactorings response)"
              },
              include_code_context: %{
                type: "boolean",
                description: "Include relevant code snippets",
                default: true
              },
              use_rag: %{
                type: "boolean",
                description: "Generate enhanced explanation using RAG",
                default: false
              }
            },
            required: ["suggestion_id"]
          }
        },
        %{
          name: "validate_with_ai",
          description:
            "Validate code with AI-enhanced error explanations and fix suggestions - Phase B",
          inputSchema: %{
            type: "object",
            properties: %{
              content: %{
                type: "string",
                description: "Code content to validate"
              },
              path: %{
                type: "string",
                description: "File path (for language detection)"
              },
              language: %{
                type: "string",
                description: "Explicit language override",
                enum: ["elixir", "erlang", "python", "javascript", "typescript"]
              },
              ai_explain: %{
                type: "boolean",
                description: "Enable AI explanations (default: from config)",
                default: true
              },
              surrounding_lines: %{
                type: "integer",
                description: "Lines of context around errors",
                default: 3
              }
            },
            required: ["content"]
          }
        },
        %{
          name: "scan_security",
          description:
            "Scan file or directory for security vulnerabilities (injection, unsafe deserialization, hardcoded secrets, weak crypto) - Phase 1",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "File or directory path to scan"
              },
              recursive: %{
                type: "boolean",
                description: "Recursively scan directories",
                default: true
              },
              min_severity: %{
                type: "string",
                description: "Minimum severity level to report",
                enum: ["low", "medium", "high", "critical"],
                default: "low"
              },
              categories: %{
                type: "array",
                description: "Filter by vulnerability categories (empty = all)",
                items: %{
                  type: "string",
                  enum: [
                    "injection",
                    "unsafe_deserialization",
                    "hardcoded_secret",
                    "weak_cryptography",
                    "insecure_protocol"
                  ]
                }
              }
            },
            required: ["path"]
          }
        },
        %{
          name: "security_audit",
          description:
            "Generate comprehensive security audit report for project with CWE mapping and recommendations - Phase 1",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "Directory path to audit"
              },
              format: %{
                type: "string",
                description: "Report format",
                enum: ["json", "markdown", "text"],
                default: "text"
              },
              min_severity: %{
                type: "string",
                description: "Minimum severity to include",
                enum: ["low", "medium", "high", "critical"],
                default: "low"
              }
            },
            required: ["path"]
          }
        },
        %{
          name: "check_secrets",
          description:
            "Scan for hardcoded secrets (API keys, passwords, tokens) in source code - Phase 1",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "File or directory path to scan"
              },
              recursive: %{
                type: "boolean",
                description: "Recursively scan directories",
                default: true
              }
            },
            required: ["path"]
          }
        },
        %{
          name: "detect_smells",
          description:
            "Detect code smells (long functions, deep nesting, magic numbers, complex conditionals) - Phase 3",
          inputSchema: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "File or directory path to analyze"
              },
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
              },
              thresholds: %{
                type: "object",
                description: "Custom thresholds for smell detection",
                properties: %{
                  max_statements: %{
                    type: "integer",
                    description: "Maximum statements per function",
                    default: 50
                  },
                  max_nesting: %{
                    type: "integer",
                    description: "Maximum nesting depth",
                    default: 4
                  },
                  max_parameters: %{
                    type: "integer",
                    description: "Maximum parameters per function",
                    default: 5
                  },
                  max_cognitive: %{
                    type: "integer",
                    description: "Maximum cognitive complexity",
                    default: 15
                  }
                }
              },
              smell_types: %{
                type: "array",
                description: "Filter by specific smell types (empty = all)",
                items: %{
                  type: "string",
                  enum: [
                    "long_function",
                    "deep_nesting",
                    "magic_number",
                    "complex_conditional",
                    "long_parameter_list"
                  ]
                }
              }
            },
            required: ["path"]
          }
        }
      ]
    }
  end

  @doc """
  Executes a tool call.
  """
  # credo:disable-for-lines:72
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

      "get_ai_usage" ->
        get_ai_usage_tool(arguments)

      "get_ai_cache_stats" ->
        get_ai_cache_stats_tool(arguments)

      "clear_ai_cache" ->
        clear_ai_cache_tool(arguments)

      "find_paths" ->
        find_paths_tool(arguments)

      "graph_stats" ->
        graph_stats_tool(arguments)

      "hybrid_search" ->
        hybrid_search_tool(arguments)

      "metaast_search" ->
        metaast_search_tool(arguments)

      "cross_language_alternatives" ->
        cross_language_alternatives_tool(arguments)

      "expand_query" ->
        expand_query_tool(arguments)

      "find_metaast_pattern" ->
        find_metaast_pattern_tool(arguments)

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

      "advanced_refactor" ->
        advanced_refactor_tool(arguments)

      "betweenness_centrality" ->
        betweenness_centrality_tool(arguments)

      "closeness_centrality" ->
        closeness_centrality_tool(arguments)

      "detect_communities" ->
        detect_communities_tool(arguments)

      "export_graph" ->
        export_graph_tool(arguments)

      "rag_query" ->
        rag_query_tool(arguments)

      "rag_explain" ->
        rag_explain_tool(arguments)

      "rag_suggest" ->
        rag_suggest_tool(arguments)

      "rag_query_stream" ->
        rag_query_stream_tool(arguments)

      "rag_explain_stream" ->
        rag_explain_stream_tool(arguments)

      "rag_suggest_stream" ->
        rag_suggest_stream_tool(arguments)

      "preview_refactor" ->
        preview_refactor_tool(arguments)

      "refactor_conflicts" ->
        refactor_conflicts_tool(arguments)

      "undo_refactor" ->
        undo_refactor_tool(arguments)

      "refactor_history" ->
        refactor_history_tool(arguments)

      "visualize_impact" ->
        visualize_impact_tool(arguments)

      "analyze_quality" ->
        analyze_quality_tool(arguments)

      "quality_report" ->
        quality_report_tool(arguments)

      "find_complex_code" ->
        find_complex_code_tool(arguments)

      "analyze_dependencies" ->
        analyze_dependencies_tool(arguments)

      "find_circular_dependencies" ->
        find_circular_dependencies_tool(arguments)

      "find_dead_code" ->
        find_dead_code_tool(arguments)

      "analyze_dead_code_patterns" ->
        analyze_dead_code_patterns_tool(arguments)

      "coupling_report" ->
        coupling_report_tool(arguments)

      "find_duplicates" ->
        find_duplicates_tool(arguments)

      "find_similar_code" ->
        find_similar_code_tool(arguments)

      "analyze_impact" ->
        analyze_impact_tool(arguments)

      "estimate_refactoring_effort" ->
        estimate_refactoring_effort_tool(arguments)

      "risk_assessment" ->
        risk_assessment_tool(arguments)

      "suggest_refactorings" ->
        suggest_refactorings_tool(arguments)

      "explain_suggestion" ->
        explain_suggestion_tool(arguments)

      "validate_with_ai" ->
        validate_with_ai_tool(arguments)

      "scan_security" ->
        scan_security_tool(arguments)

      "security_audit" ->
        security_audit_tool(arguments)

      "check_secrets" ->
        check_secrets_tool(arguments)

      "detect_smells" ->
        detect_smells_tool(arguments)

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
    # Check if Metastatic is enabled and supports this file
    if use_metastatic?() and metastatic_supports?(path) do
      Ragex.Analyzers.Metastatic
    else
      get_native_analyzer(path)
    end
  end

  defp get_analyzer("elixir", path) do
    if use_metastatic?() and metastatic_supports?(path),
      do: Ragex.Analyzers.Metastatic,
      else: ElixirAnalyzer
  end

  defp get_analyzer("erlang", path) do
    if use_metastatic?() and metastatic_supports?(path),
      do: Ragex.Analyzers.Metastatic,
      else: ErlangAnalyzer
  end

  defp get_analyzer("python", path) do
    if use_metastatic?() and metastatic_supports?(path),
      do: Ragex.Analyzers.Metastatic,
      else: PythonAnalyzer
  end

  defp get_analyzer("javascript", _path), do: JavaScriptAnalyzer
  defp get_analyzer("typescript", _path), do: JavaScriptAnalyzer
  defp get_analyzer(_, path), do: get_analyzer("auto", path)

  defp use_metastatic? do
    Application.get_env(:ragex, :features)[:use_metastatic] == true
  end

  defp metastatic_supports?(path) do
    ext = Path.extname(path)
    ext in Metastatic.supported_extensions()
  end

  defp get_native_analyzer(path) do
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

  defp get_language_name(Ragex.Analyzers.Metastatic), do: "metastatic"
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

      "get_callers" ->
        get_callers(params)

      _ ->
        {:error, "Unknown query type: #{query_type}"}
    end
  end

  defp query_graph(_), do: {:error, "Invalid parameters for query_graph"}

  defp list_nodes(params) do
    # Convert node_type string to atom (MCP sends strings, Store expects atoms)
    node_type =
      case Map.get(params, "node_type") do
        "module" -> :module
        "function" -> :function
        "type" -> :type
        "variable" -> :variable
        "file" -> :file
        atom when is_atom(atom) -> atom
        _ -> nil
      end

    limit = Map.get(params, "limit", 100)

    nodes = Store.list_nodes(node_type, limit)

    # Get actual total count from graph stats
    stats = Store.stats()

    total_count =
      if node_type do
        # For specific node type, we need to count directly from ETS
        # since stats() doesn't break down by type
        Store.count_nodes_by_type(node_type)
      else
        stats.nodes
      end

    {:ok, %{nodes: nodes, count: length(nodes), total_count: total_count}}
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

  defp get_callers(%{"module" => module, "function" => function, "arity" => arity}) do
    # Get incoming edges (callers)
    module_atom = String.to_existing_atom("Elixir." <> module)
    function_atom = String.to_atom(function)
    full_id = {:function, module_atom, function_atom, arity}

    callers = Store.get_incoming_edges(full_id, :calls)

    # Enrich with file/line information
    enriched_callers =
      Enum.map(callers, fn %{from: {:function, mod, func, ar}} = edge ->
        case Store.find_node(:function, {mod, func, ar}) do
          nil ->
            edge

          node ->
            Map.merge(edge, %{
              caller_module: Atom.to_string(mod),
              caller_function: Atom.to_string(func),
              caller_arity: ar,
              file: node[:file],
              line: node[:line]
            })
        end
      end)

    {:ok, %{callers: enriched_callers, count: length(enriched_callers)}}
  end

  defp get_callers(_), do: {:error, "Missing 'module', 'function', or 'arity' parameter"}

  defp semantic_search(%{"query" => query} = params) do
    # Check if embedding model is ready
    if Bumblebee.ready?() do
      # Generate query embedding
      case Bumblebee.embed(query) do
        {:ok, query_embedding} ->
          # Parse options
          limit = Map.get(params, "limit", 10)

          default_threshold =
            Application.get_env(:ragex, :search, []) |> Keyword.get(:default_threshold, 0.2)

          threshold = Map.get(params, "threshold", default_threshold)

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
    else
      {:error, "Embedding model not ready. Please wait for model to load."}
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
    if Bumblebee.ready?() do
      # Parse options
      strategy =
        case Map.get(params, "strategy", "fusion") do
          "fusion" -> :fusion
          "semantic_first" -> :semantic_first
          "graph_first" -> :graph_first
          _ -> :fusion
        end

      limit = Map.get(params, "limit", 10)

      default_threshold =
        Application.get_env(:ragex, :search, []) |> Keyword.get(:hybrid_threshold, 0.15)

      threshold = Map.get(params, "threshold", default_threshold)

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
    else
      {:error, "Embedding model not ready. Please wait for model to load."}
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
    if String.contains?(node_str, "/") and String.contains?(node_str, ".") do
      # Module.function/arity
      case String.split(node_str, ".") do
        [module_str, func_arity] ->
          case String.split(func_arity, "/") do
            [func_str, arity_str] ->
              case Integer.parse(arity_str) do
                {arity, ""} ->
                  {:ok, {:function, String.to_atom(module_str), String.to_atom(func_str), arity}}

                _ ->
                  {:error, :invalid_arity}
              end

            _ ->
              {:error, :invalid_format}
          end

        _ ->
          {:error, :invalid_format}
      end
    else
      # Just a module name
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
    case build_transaction(files_data, txn_opts) do
      {:ok, transaction} ->
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
      # Convert to atoms - Elixir automatically adds Elixir. prefix for module atoms
      module_atom = String.to_existing_atom("Elixir." <> module)
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
      # Convert to atoms - Elixir automatically adds Elixir. prefix for module atoms
      old_atom = String.to_existing_atom("Elixir." <> old_name)
      new_atom = String.to_existing_atom("Elixir." <> new_name)

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

  defp advanced_refactor_tool(%{"operation" => operation, "params" => params} = arguments) do
    validate = Map.get(arguments, "validate", true)
    format = Map.get(arguments, "format", true)
    scope = String.to_atom(Map.get(arguments, "scope", "project"))
    opts = [validate: validate, format: format, scope: scope]

    case operation do
      "extract_function" ->
        handle_extract_function(params, opts)

      "inline_function" ->
        handle_inline_function(params, opts)

      "convert_visibility" ->
        handle_convert_visibility(params, opts)

      "rename_parameter" ->
        handle_rename_parameter(params, opts)

      "modify_attributes" ->
        handle_modify_attributes(params, opts)

      "change_signature" ->
        handle_change_signature(params, opts)

      "move_function" ->
        handle_move_function(params, opts)

      "extract_module" ->
        handle_extract_module(params, opts)

      _ ->
        {:error, "Unknown advanced refactoring operation: #{operation}"}
    end
  end

  defp advanced_refactor_tool(_), do: {:error, "Invalid parameters for advanced_refactor"}

  defp handle_extract_function(params, opts) do
    with {:ok, module} <- get_required_param(params, "module"),
         {:ok, source_function} <- get_required_param(params, "source_function"),
         {:ok, source_arity} <- get_required_param(params, "source_arity"),
         {:ok, new_function} <- get_required_param(params, "new_function"),
         {:ok, line_start} <- get_required_param(params, "line_start"),
         {:ok, line_end} <- get_required_param(params, "line_end") do
      module_atom = String.to_existing_atom("Elixir." <> module)
      source_fn_atom = String.to_atom(source_function)
      new_fn_atom = String.to_atom(new_function)
      line_range = {line_start, line_end}

      # Add optional parameters
      opts =
        opts
        |> add_optional_atom_param(params, "placement", :placement)

      case Refactor.extract_function(
             module_atom,
             source_fn_atom,
             source_arity,
             new_fn_atom,
             line_range,
             opts
           ) do
        {:ok, result} ->
          format_refactor_success(
            "extract_function",
            result,
            %{
              module: module,
              source_function: source_function,
              new_function: new_function,
              line_range: {line_start, line_end}
            }
          )

        error ->
          format_refactor_error("extract_function", error)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_inline_function(params, opts) do
    with {:ok, module} <- get_required_param(params, "module"),
         {:ok, function} <- get_required_param(params, "function"),
         {:ok, arity} <- get_required_param(params, "arity") do
      module_atom = String.to_existing_atom("Elixir." <> module)
      function_atom = String.to_atom(function)

      case Refactor.inline_function(module_atom, function_atom, arity, opts) do
        {:ok, result} ->
          format_refactor_success(
            "inline_function",
            result,
            %{module: module, function: function, arity: arity}
          )

        error ->
          format_refactor_error("inline_function", error)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_convert_visibility(params, opts) do
    with {:ok, module} <- get_required_param(params, "module"),
         {:ok, function} <- get_required_param(params, "function"),
         {:ok, arity} <- get_required_param(params, "arity"),
         {:ok, visibility} <- get_required_param(params, "visibility") do
      module_atom = String.to_existing_atom("Elixir." <> module)
      function_atom = String.to_atom(function)
      visibility_atom = String.to_atom(visibility)

      if visibility_atom in [:public, :private] do
        case Refactor.convert_visibility(module_atom, function_atom, arity, visibility_atom, opts) do
          {:ok, result} ->
            format_refactor_success(
              "convert_visibility",
              result,
              %{module: module, function: function, arity: arity, visibility: visibility}
            )

          error ->
            format_refactor_error("convert_visibility", error)
        end
      else
        {:error, "Visibility must be 'public' or 'private'"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_rename_parameter(params, opts) do
    with {:ok, module} <- get_required_param(params, "module"),
         {:ok, function} <- get_required_param(params, "function"),
         {:ok, arity} <- get_required_param(params, "arity"),
         {:ok, old_param} <- get_required_param(params, "old_param"),
         {:ok, new_param} <- get_required_param(params, "new_param") do
      module_atom = String.to_existing_atom("Elixir." <> module)
      function_atom = String.to_atom(function)

      case Refactor.rename_parameter(
             module_atom,
             function_atom,
             arity,
             old_param,
             new_param,
             opts
           ) do
        {:ok, result} ->
          format_refactor_success(
            "rename_parameter",
            result,
            %{
              module: module,
              function: function,
              arity: arity,
              old_param: old_param,
              new_param: new_param
            }
          )

        error ->
          format_refactor_error("rename_parameter", error)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_modify_attributes(params, opts) do
    with {:ok, module} <- get_required_param(params, "module"),
         {:ok, changes} <- get_required_param(params, "changes") do
      module_atom = String.to_existing_atom("Elixir." <> module)

      # Parse attribute changes
      case parse_attribute_changes(changes) do
        {:ok, parsed_changes} ->
          case Refactor.modify_attributes(module_atom, parsed_changes, opts) do
            {:ok, result} ->
              format_refactor_success(
                "modify_attributes",
                result,
                %{module: module, changes_count: length(parsed_changes)}
              )

            error ->
              format_refactor_error("modify_attributes", error)
          end

        {:error, reason} ->
          {:error, "Failed to parse attribute changes: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_change_signature(params, opts) do
    with {:ok, module} <- get_required_param(params, "module"),
         {:ok, function} <- get_required_param(params, "function"),
         {:ok, old_arity} <- get_required_param(params, "old_arity"),
         {:ok, changes} <- get_required_param(params, "changes") do
      module_atom = String.to_existing_atom("Elixir." <> module)
      function_atom = String.to_atom(function)

      # Parse signature changes
      case parse_signature_changes(changes) do
        {:ok, parsed_changes} ->
          case Refactor.change_signature(
                 module_atom,
                 function_atom,
                 old_arity,
                 parsed_changes,
                 opts
               ) do
            {:ok, result} ->
              format_refactor_success(
                "change_signature",
                result,
                %{
                  module: module,
                  function: function,
                  old_arity: old_arity,
                  changes_count: length(parsed_changes)
                }
              )

            error ->
              format_refactor_error("change_signature", error)
          end

        {:error, reason} ->
          {:error, "Failed to parse signature changes: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_move_function(params, opts) do
    with {:ok, source_module} <- get_required_param(params, "source_module"),
         {:ok, target_module} <- get_required_param(params, "target_module"),
         {:ok, function} <- get_required_param(params, "function"),
         {:ok, arity} <- get_required_param(params, "arity") do
      source_atom = String.to_existing_atom("Elixir." <> source_module)
      target_atom = String.to_existing_atom("Elixir." <> target_module)
      function_atom = String.to_atom(function)

      case Refactor.move_function(source_atom, target_atom, function_atom, arity, opts) do
        {:ok, result} ->
          format_refactor_success(
            "move_function",
            result,
            %{
              source_module: source_module,
              target_module: target_module,
              function: function,
              arity: arity
            }
          )

        error ->
          format_refactor_error("move_function", error)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_extract_module(params, opts) do
    with {:ok, source_module} <- get_required_param(params, "source_module"),
         {:ok, new_module} <- get_required_param(params, "new_module"),
         {:ok, functions} <- get_required_param(params, "functions") do
      source_atom = String.to_existing_atom("Elixir." <> source_module)
      new_atom = String.to_existing_atom("Elixir." <> new_module)

      # Parse function list: [{name, arity}, ...]
      case parse_function_list(functions) do
        {:ok, parsed_functions} ->
          case Refactor.extract_module(source_atom, new_atom, parsed_functions, opts) do
            {:ok, result} ->
              format_refactor_success(
                "extract_module",
                result,
                %{
                  source_module: source_module,
                  new_module: new_module,
                  functions_count: length(parsed_functions)
                }
              )

            error ->
              format_refactor_error("extract_module", error)
          end

        {:error, reason} ->
          {:error, "Failed to parse function list: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Helper functions for advanced_refactor

  defp parse_attribute_changes(changes) when is_list(changes) do
    parsed =
      Enum.reduce_while(changes, [], fn change, acc ->
        case parse_single_attribute_change(change) do
          {:ok, parsed} -> {:cont, [parsed | acc]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case parsed do
      {:error, _} = error -> error
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp parse_attribute_changes(_), do: {:error, "Changes must be a list"}

  defp parse_single_attribute_change(%{"action" => "add", "name" => name, "value" => value}) do
    {:ok, {:add, String.to_atom(name), value}}
  end

  defp parse_single_attribute_change(%{"action" => "remove", "name" => name}) do
    {:ok, {:remove, String.to_atom(name)}}
  end

  defp parse_single_attribute_change(%{
         "action" => "update",
         "name" => name,
         "value" => value
       }) do
    {:ok, {:update, String.to_atom(name), value}}
  end

  defp parse_single_attribute_change(_),
    do: {:error, "Invalid attribute change structure"}

  defp parse_signature_changes(changes) when is_list(changes) do
    parsed =
      Enum.reduce_while(changes, [], fn change, acc ->
        case parse_single_signature_change(change) do
          {:ok, parsed} -> {:cont, [parsed | acc]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case parsed do
      {:error, _} = error -> error
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp parse_signature_changes(_), do: {:error, "Changes must be a list"}

  defp parse_single_signature_change(%{
         "action" => "add",
         "name" => name,
         "position" => position,
         "default" => default
       }) do
    {:ok, {:add, name, position, default}}
  end

  defp parse_single_signature_change(%{
         "action" => "add",
         "name" => name,
         "position" => position
       }) do
    {:ok, {:add, name, position, nil}}
  end

  defp parse_single_signature_change(%{"action" => "remove", "position" => position}) do
    {:ok, {:remove, position}}
  end

  defp parse_single_signature_change(%{
         "action" => "reorder",
         "from" => from,
         "to" => to
       }) do
    {:ok, {:reorder, from, to}}
  end

  defp parse_single_signature_change(%{
         "action" => "rename",
         "position" => position,
         "new_name" => new_name
       }) do
    {:ok, {:rename, position, new_name}}
  end

  defp parse_single_signature_change(_),
    do: {:error, "Invalid signature change structure"}

  defp parse_function_list(functions) when is_list(functions) do
    parsed =
      Enum.reduce_while(functions, [], fn func, acc ->
        case parse_single_function(func) do
          {:ok, parsed} -> {:cont, [parsed | acc]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case parsed do
      {:error, _} = error -> error
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp parse_function_list(_), do: {:error, "Functions must be a list"}

  defp parse_single_function(%{"name" => name, "arity" => arity})
       when is_integer(arity) do
    {:ok, {String.to_atom(name), arity}}
  end

  defp parse_single_function(_),
    do: {:error, "Function must have 'name' and 'arity'"}

  defp add_optional_atom_param(opts, params, key, opt_key) do
    case Map.get(params, key) do
      nil -> opts
      value -> Keyword.put(opts, opt_key, String.to_atom(value))
    end
  end

  defp format_refactor_success(operation, result, details) do
    {:ok,
     %{
       status: "success",
       operation: operation,
       files_modified: result.files_modified,
       details: details
     }}
  end

  defp format_refactor_error(operation, {:error, error_result}) when is_map(error_result) do
    {:error,
     %{
       "type" => "refactor_error",
       "operation" => operation,
       "message" => "Refactoring failed",
       "files_modified" => error_result.files_modified,
       "rolled_back" => error_result.rolled_back,
       "errors" =>
         Enum.map(error_result.errors || [], fn
           {path, reason} -> %{path: path, reason: inspect(reason)}
           error -> %{error: inspect(error)}
         end)
     }}
  end

  defp format_refactor_error(operation, {:error, message}) when is_binary(message) do
    {:error,
     %{
       "type" => "refactor_error",
       "operation" => operation,
       "message" => message
     }}
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

  # New algorithm tools

  defp betweenness_centrality_tool(params) do
    max_nodes = Map.get(params, "max_nodes", 1000)
    normalize = Map.get(params, "normalize", true)

    scores = Algorithms.betweenness_centrality(max_nodes: max_nodes, normalize: normalize)

    # Sort by score descending and format
    top_nodes =
      scores
      |> Enum.sort_by(fn {_node, score} -> -score end)
      # Limit output
      |> Enum.take(100)
      |> Enum.map(fn {node, score} ->
        %{
          node_id: format_node_id(node),
          betweenness_score: Float.round(score, 6)
        }
      end)

    {:ok,
     %{
       total_nodes: map_size(scores),
       top_nodes: top_nodes
     }}
  end

  defp closeness_centrality_tool(params) do
    normalize = Map.get(params, "normalize", true)

    scores = Algorithms.closeness_centrality(normalize: normalize)

    # Sort by score descending and format
    top_nodes =
      scores
      |> Enum.sort_by(fn {_node, score} -> -score end)
      # Limit output
      |> Enum.take(100)
      |> Enum.map(fn {node, score} ->
        %{
          node_id: format_node_id(node),
          closeness_score: Float.round(score, 6)
        }
      end)

    {:ok,
     %{
       total_nodes: map_size(scores),
       top_nodes: top_nodes
     }}
  end

  defp detect_communities_tool(params) do
    algorithm = Map.get(params, "algorithm", "louvain")
    max_iterations = Map.get(params, "max_iterations", 10)
    resolution = Map.get(params, "resolution", 1.0)
    hierarchical = Map.get(params, "hierarchical", false)
    seed = Map.get(params, "seed")

    result =
      case algorithm do
        "louvain" ->
          Algorithms.detect_communities(
            max_iterations: max_iterations,
            resolution: resolution,
            hierarchical: hierarchical
          )

        "label_propagation" ->
          opts = [max_iterations: max_iterations]
          opts = if seed, do: Keyword.put(opts, :seed, seed), else: opts
          Algorithms.detect_communities_lp(opts)

        _ ->
          Algorithms.detect_communities(max_iterations: max_iterations)
      end

    # Format communities
    formatted =
      if is_map(result) and Map.has_key?(result, :communities) do
        # Hierarchical result
        %{
          communities: format_communities(result.communities),
          hierarchy: result.hierarchy,
          modularity_per_level: result.modularity_per_level
        }
      else
        # Simple result
        format_communities(result)
      end

    {:ok, formatted}
  end

  defp format_communities(communities) when is_map(communities) do
    communities
    |> Enum.map(fn {comm_id, nodes} ->
      %{
        community_id: inspect(comm_id),
        size: length(nodes),
        members: Enum.map(nodes, &format_node_id/1)
      }
    end)
  end

  defp export_graph_tool(params) do
    format = Map.get(params, "format", "graphviz")
    include_communities = Map.get(params, "include_communities", true)
    color_by = String.to_atom(Map.get(params, "color_by", "pagerank"))
    max_nodes = Map.get(params, "max_nodes", 500)

    case format do
      "graphviz" ->
        opts = [
          include_communities: include_communities,
          color_by: color_by,
          max_nodes: max_nodes
        ]

        Algorithms.export_graphviz(opts)

      "d3" ->
        opts = [
          include_communities: include_communities,
          max_nodes: max_nodes
        ]

        Algorithms.export_d3_json(opts)

      _ ->
        {:error, "Unknown format: #{format}"}
    end
  end

  # RAG tool implementations

  defp rag_query_tool(%{"query" => query} = params) do
    limit = Map.get(params, "limit", 10)
    include_code = Map.get(params, "include_code", true)
    provider = parse_provider(Map.get(params, "provider"))

    opts = [
      limit: limit,
      include_code: include_code
    ]

    opts = if provider, do: Keyword.put(opts, :provider, provider), else: opts

    case Pipeline.query(query, opts) do
      {:ok, result} ->
        {:ok,
         %{
           status: "success",
           query: query,
           response: result.content,
           sources_count: length(result.sources),
           model_used: result.model
         }}

      {:error, reason} ->
        {:error, "RAG query failed: #{inspect(reason)}"}
    end
  end

  defp rag_query_tool(_), do: {:error, "Missing 'query' parameter"}

  defp rag_explain_tool(%{"target" => target} = params) do
    aspect = String.to_atom(Map.get(params, "aspect", "all"))

    opts = [aspect: aspect]

    case Pipeline.explain(target, aspect, opts) do
      {:ok, result} ->
        {:ok,
         %{
           status: "success",
           target: target,
           explanation: result.content,
           aspect: Atom.to_string(aspect),
           sources_count: length(result.sources),
           model_used: result.model
         }}

      {:error, reason} ->
        {:error, "RAG explain failed: #{inspect(reason)}"}
    end
  end

  defp rag_explain_tool(_), do: {:error, "Missing 'target' parameter"}

  defp rag_suggest_tool(%{"target" => target} = params) do
    focus = String.to_atom(Map.get(params, "focus", "all"))

    opts = [focus: focus]

    case Pipeline.suggest(target, focus, opts) do
      {:ok, result} ->
        {:ok,
         %{
           status: "success",
           target: target,
           suggestions: result.content,
           focus: Atom.to_string(focus),
           sources_count: length(result.sources),
           model_used: result.model
         }}

      {:error, reason} ->
        {:error, "RAG suggest failed: #{inspect(reason)}"}
    end
  end

  defp rag_suggest_tool(_), do: {:error, "Missing 'target' parameter"}

  # Streaming RAG tool implementations
  # Note: These collect all chunks and return complete response
  # Full MCP streaming protocol support will be added in Phase 5C

  defp rag_query_stream_tool(%{"query" => query} = params) do
    limit = Map.get(params, "limit", 10)
    include_code = Map.get(params, "include_code", true)
    provider = parse_provider(Map.get(params, "provider"))
    show_chunks = Map.get(params, "show_chunks", false)

    opts = [
      limit: limit,
      include_code: include_code
    ]

    opts = if provider, do: Keyword.put(opts, :provider, provider), else: opts

    case Pipeline.stream_query(query, opts) do
      {:ok, stream} ->
        # Collect all chunks
        result = collect_stream_chunks(stream, show_chunks)

        {:ok,
         %{
           status: "success",
           query: query,
           response: result.content,
           sources_count: result.sources_count,
           model_used: result.model,
           streaming: true,
           chunks_count: result.chunks_count
         }
         |> maybe_add_chunks(result, show_chunks)}

      {:error, reason} ->
        {:error, "RAG streaming query failed: #{inspect(reason)}"}
    end
  end

  defp rag_query_stream_tool(_), do: {:error, "Missing 'query' parameter"}

  defp rag_explain_stream_tool(%{"target" => target} = params) do
    aspect = String.to_atom(Map.get(params, "aspect", "all"))
    show_chunks = Map.get(params, "show_chunks", false)

    opts = [aspect: aspect]

    case Pipeline.stream_explain(target, aspect, opts) do
      {:ok, stream} ->
        result = collect_stream_chunks(stream, show_chunks)

        {:ok,
         %{
           status: "success",
           target: target,
           explanation: result.content,
           aspect: Atom.to_string(aspect),
           sources_count: result.sources_count,
           model_used: result.model,
           streaming: true,
           chunks_count: result.chunks_count
         }
         |> maybe_add_chunks(result, show_chunks)}

      {:error, reason} ->
        {:error, "RAG streaming explain failed: #{inspect(reason)}"}
    end
  end

  defp rag_explain_stream_tool(_), do: {:error, "Missing 'target' parameter"}

  defp rag_suggest_stream_tool(%{"target" => target} = params) do
    focus = String.to_atom(Map.get(params, "focus", "all"))
    show_chunks = Map.get(params, "show_chunks", false)

    opts = [focus: focus]

    case Pipeline.stream_suggest(target, focus, opts) do
      {:ok, stream} ->
        result = collect_stream_chunks(stream, show_chunks)

        {:ok,
         %{
           status: "success",
           target: target,
           suggestions: result.content,
           focus: Atom.to_string(focus),
           sources_count: result.sources_count,
           model_used: result.model,
           streaming: true,
           chunks_count: result.chunks_count
         }
         |> maybe_add_chunks(result, show_chunks)}

      {:error, reason} ->
        {:error, "RAG streaming suggest failed: #{inspect(reason)}"}
    end
  end

  defp rag_suggest_stream_tool(_), do: {:error, "Missing 'target' parameter"}

  defp collect_stream_chunks(stream, show_chunks) do
    chunks = if show_chunks, do: [], else: nil

    {content, metadata, collected_chunks} =
      Enum.reduce(stream, {"", nil, chunks}, fn
        %{done: false, content: chunk_content} = chunk, {acc_content, _meta, acc_chunks} ->
          new_chunks = if show_chunks, do: [chunk | acc_chunks], else: acc_chunks
          {acc_content <> chunk_content, nil, new_chunks}

        %{done: true, metadata: final_meta}, {acc_content, _meta, acc_chunks} ->
          {acc_content, final_meta, acc_chunks}

        {:error, reason}, {acc_content, meta, acc_chunks} ->
          # Handle error chunks
          new_meta = if meta, do: Map.put(meta, :error, reason), else: %{error: reason}
          {acc_content, new_meta, acc_chunks}

        _other, acc ->
          acc
      end)

    metadata = metadata || %{}

    %{
      content: content,
      model: metadata[:model],
      sources_count: length(metadata[:sources] || []),
      chunks_count: if(show_chunks, do: length(collected_chunks), else: :not_tracked),
      chunks: if(show_chunks, do: Enum.reverse(collected_chunks), else: nil),
      metadata: metadata
    }
  end

  defp maybe_add_chunks(result, %{chunks: chunks}, true) when is_list(chunks) do
    Map.put(result, :chunks, chunks)
  end

  defp maybe_add_chunks(result, _stream_result, _show_chunks), do: result

  defp parse_provider(nil), do: nil
  defp parse_provider("deepseek_r1"), do: :deepseek_r1
  defp parse_provider("openai"), do: :openai
  defp parse_provider("anthropic"), do: :anthropic
  defp parse_provider("ollama"), do: :ollama
  defp parse_provider(_), do: nil

  # AI monitoring tool implementations

  defp get_ai_usage_tool(params) do
    provider_str = Map.get(params, "provider")

    stats =
      if provider_str do
        provider = String.to_atom(provider_str)
        %{provider => Usage.get_stats(provider)}
      else
        Usage.get_stats(:all)
      end

    {:ok,
     %{
       status: "success",
       providers:
         Enum.map(stats, fn {provider, provider_stats} ->
           %{
             provider: Atom.to_string(provider),
             total_requests: provider_stats.total_requests,
             total_prompt_tokens: provider_stats.total_prompt_tokens,
             total_completion_tokens: provider_stats.total_completion_tokens,
             total_tokens: provider_stats.total_tokens,
             estimated_cost: provider_stats.estimated_cost,
             by_model:
               Enum.map(provider_stats.by_model, fn {model, model_stats} ->
                 %{
                   model: model,
                   requests: model_stats.requests,
                   total_tokens: model_stats.total_tokens,
                   cost: model_stats.cost
                 }
               end)
           }
         end)
     }}
  end

  defp get_ai_cache_stats_tool(_params) do
    stats = Cache.stats()

    {:ok,
     %{
       status: "success",
       enabled: stats.enabled,
       size: stats.size,
       max_size: stats.max_size,
       ttl: stats.ttl,
       hits: stats.hits,
       misses: stats.misses,
       puts: stats.puts,
       evictions: stats.evictions,
       hit_rate: Float.round(stats.hit_rate, 4),
       by_operation:
         Enum.map(stats.by_operation, fn {operation, op_stats} ->
           %{
             operation: Atom.to_string(operation),
             size: op_stats.size,
             ttl: op_stats.ttl,
             max_size: op_stats.max_size,
             hits: op_stats.hits,
             misses: op_stats.misses,
             hit_rate: Float.round(op_stats.hit_rate, 4)
           }
         end)
     }}
  end

  defp clear_ai_cache_tool(params) do
    operation_str = Map.get(params, "operation", "all")

    case operation_str do
      "all" ->
        Cache.clear()

      op ->
        Cache.clear(String.to_atom(op))
    end

    {:ok,
     %{
       status: "success",
       message: "Cache cleared for: #{operation_str}"
     }}
  end

  # MetaAST tool implementations

  defp metaast_search_tool(
         %{"source_language" => source_lang, "source_construct" => construct} = params
       ) do
    source_language = String.to_atom(source_lang)
    target_languages = parse_language_list(Map.get(params, "target_languages", []))
    limit = Map.get(params, "limit", 5)
    threshold = Map.get(params, "threshold", 0.6)
    strict = Map.get(params, "strict_equivalence", false)

    opts = [
      limit: limit,
      threshold: threshold,
      strict_equivalence: strict
    ]

    case CrossLanguage.search_equivalent(source_language, construct, target_languages, opts) do
      {:ok, results} ->
        formatted_results =
          Enum.map(results, fn {language, language_results} ->
            %{
              language: Atom.to_string(language),
              matches:
                Enum.map(language_results, fn result ->
                  %{
                    node_id: format_node_id(result.node_id),
                    score: Float.round(result.score, 4),
                    code_sample: result[:text] || ""
                  }
                end)
            }
          end)

        total_matches =
          Enum.reduce(formatted_results, 0, fn lang, acc -> acc + length(lang.matches) end)

        {:ok,
         %{
           status: "success",
           source_language: source_lang,
           source_construct: construct,
           results: formatted_results,
           total_matches: total_matches
         }}

      {:error, reason} ->
        {:error, "MetaAST search failed: #{inspect(reason)}"}
    end
  end

  defp metaast_search_tool(_), do: {:error, "Missing required parameters"}

  defp cross_language_alternatives_tool(%{"language" => lang, "code" => code} = params) do
    language = String.to_atom(lang)
    target_languages = parse_language_list(Map.get(params, "target_languages", []))

    source = %{
      language: language,
      code: code
    }

    case CrossLanguage.suggest_alternatives(source, target_languages) do
      {:ok, suggestions} ->
        {:ok,
         %{
           status: "success",
           source_language: lang,
           alternatives:
             Enum.map(suggestions, fn suggestion ->
               %{
                 language: Atom.to_string(suggestion.language),
                 node_id: format_node_id(suggestion.node_id),
                 score: Float.round(suggestion.score, 4),
                 code_sample: suggestion.code_sample,
                 explanation: suggestion.explanation
               }
             end),
           count: length(suggestions)
         }}

      {:error, reason} ->
        {:error, "Failed to generate alternatives: #{inspect(reason)}"}
    end
  end

  defp cross_language_alternatives_tool(_), do: {:error, "Missing required parameters"}

  defp expand_query_tool(%{"query" => query} = params) do
    intent =
      case Map.get(params, "intent") do
        nil -> nil
        str -> String.to_atom(str)
      end

    max_terms = Map.get(params, "max_terms", 5)
    include_synonyms = Map.get(params, "include_synonyms", true)
    include_cross_language = Map.get(params, "include_cross_language", true)

    opts = [
      max_terms: max_terms,
      include_synonyms: include_synonyms,
      include_cross_language: include_cross_language
    ]

    opts = if intent, do: Keyword.put(opts, :intent, intent), else: opts

    expanded_query = QueryExpansion.expand(query, opts)
    variations = QueryExpansion.suggest_variations(query)

    {:ok,
     %{
       status: "success",
       original_query: query,
       expanded_query: expanded_query,
       suggested_variations: variations
     }}
  end

  defp expand_query_tool(_), do: {:error, "Missing 'query' parameter"}

  defp find_metaast_pattern_tool(%{"pattern" => pattern_str} = params) do
    languages = parse_language_list(Map.get(params, "languages", []))
    limit = Map.get(params, "limit", 20)

    # Parse pattern string (e.g., "collection_op:map" -> {:collection_op, :map, :_, :_})
    pattern =
      case String.split(pattern_str, ":") do
        [tag, op] ->
          {:"#{tag}", String.to_atom(op), :_, :_}

        [tag] ->
          case tag do
            "lambda" -> {:lambda, :_, :_, :_}
            "conditional" -> {:conditional, :_, :_, :_}
            _ -> {:"#{tag}", :_, :_, :_}
          end

        _ ->
          :_
      end

    opts = [
      limit: limit,
      languages: languages
    ]

    {:ok, results} = CrossLanguage.find_all_implementations(pattern, opts)

    formatted_results =
      Enum.map(results, fn result ->
        %{
          node_id: format_node_id(result.node_id),
          language: Atom.to_string(result.language || :unknown),
          score: Float.round(result.score, 4),
          code_sample: result[:text] || ""
        }
      end)

    # Group by language
    by_language =
      formatted_results
      |> Enum.group_by(& &1.language)
      |> Enum.map(fn {lang, items} ->
        %{language: lang, count: length(items), items: items}
      end)

    {:ok,
     %{
       status: "success",
       pattern: pattern_str,
       total_matches: length(formatted_results),
       by_language: by_language
     }}
  end

  defp find_metaast_pattern_tool(_), do: {:error, "Missing 'pattern' parameter"}

  defp parse_language_list(lang_list) when is_list(lang_list) do
    Enum.map(lang_list, &String.to_atom/1)
  end

  defp parse_language_list(_), do: []

  # Phase 10C MCP tool implementations

  defp preview_refactor_tool(%{"operation" => operation, "params" => params} = args) do
    format = Map.get(args, "format", "unified")
    ai_commentary = Map.get(args, "ai_commentary", true)

    # Build preview data structure
    preview_data = %{
      operation: String.to_atom(operation),
      params: atomize_params(params),
      affected_files: extract_affected_files(params),
      stats: %{}
    }

    # Base preview result
    base_result = %{
      status: "preview",
      operation: operation,
      params: params,
      format: format,
      affected_files: preview_data.affected_files,
      file_count: length(preview_data.affected_files)
    }

    # Add AI commentary if enabled
    result =
      if ai_commentary do
        case AIPreview.generate_commentary(
               preview_data,
               ai_preview: ai_commentary
             ) do
          {:ok, commentary} ->
            Map.put(base_result, :ai_commentary, %{
              summary: commentary.summary,
              risk_level: Atom.to_string(commentary.risk_level),
              risks: commentary.risks,
              recommendations: commentary.recommendations,
              impact: commentary.estimated_impact,
              confidence: Float.round(commentary.confidence, 2)
            })

          {:error, :ai_preview_disabled} ->
            base_result

          {:error, reason} ->
            require Logger
            Logger.warning("Failed to generate AI commentary: #{inspect(reason)}")
            Map.put(base_result, :ai_commentary_error, inspect(reason))
        end
      else
        base_result
      end

    {:ok, result}
  end

  defp preview_refactor_tool(_), do: {:error, "Missing required parameters"}

  defp atomize_params(params) when is_map(params) do
    Enum.into(params, %{}, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, v}
    end)
  end

  defp extract_affected_files(params) do
    # Extract affected files based on operation params
    # This is a simplified implementation - in production you'd query the actual files
    cond do
      Map.has_key?(params, "module") ->
        # For function refactors, estimate affected files
        ["lib/#{String.downcase(params["module"])}.ex"]

      Map.has_key?(params, "old_module") ->
        # For module renames
        ["lib/#{String.downcase(params["old_module"])}.ex"]

      true ->
        []
    end
  end

  defp refactor_conflicts_tool(%{"operation" => operation, "params" => params}) do
    # Check conflicts based on operation type
    result =
      case operation do
        "rename_function" ->
          with {:ok, module} <- get_required_param(params, "module"),
               {:ok, _old_name} <- get_required_param(params, "old_name"),
               {:ok, new_name} <- get_required_param(params, "new_name"),
               {:ok, arity} <- get_required_param(params, "arity") do
            module_atom = String.to_existing_atom("Elixir." <> module)
            new_atom = String.to_atom(new_name)

            Conflict.check_rename_conflicts(module_atom, new_atom, arity)
          else
            {:error, reason} -> {:error, reason}
          end

        "rename_module" ->
          with {:ok, old_name} <- get_required_param(params, "old_name"),
               {:ok, new_name} <- get_required_param(params, "new_name") do
            old_atom = String.to_existing_atom("Elixir." <> old_name)
            new_atom = String.to_existing_atom("Elixir." <> new_name)

            # For module rename, check if new name conflicts
            Conflict.check_rename_conflicts(old_atom, new_atom, 0)
          else
            {:error, reason} -> {:error, reason}
          end

        "move_function" ->
          with {:ok, source_module} <- get_required_param(params, "source_module"),
               {:ok, target_module} <- get_required_param(params, "target_module"),
               {:ok, function} <- get_required_param(params, "function"),
               {:ok, arity} <- get_required_param(params, "arity") do
            source_atom = String.to_existing_atom("Elixir." <> source_module)
            target_atom = String.to_existing_atom("Elixir." <> target_module)
            function_atom = String.to_atom(function)

            Conflict.check_move_conflicts(source_atom, target_atom, function_atom, arity)
          else
            {:error, reason} -> {:error, reason}
          end

        "extract_module" ->
          with {:ok, source_module} <- get_required_param(params, "source_module"),
               {:ok, new_module} <- get_required_param(params, "new_module"),
               {:ok, functions} <- get_required_param(params, "functions") do
            source_atom = String.to_existing_atom("Elixir." <> source_module)
            new_atom = String.to_existing_atom("Elixir." <> new_module)

            case parse_function_list(functions) do
              {:ok, parsed_functions} ->
                Conflict.check_extract_module_conflicts(
                  source_atom,
                  new_atom,
                  parsed_functions
                )

              {:error, reason} ->
                {:error, reason}
            end
          else
            {:error, reason} -> {:error, reason}
          end

        _ ->
          {:error, "Unknown operation: #{operation}"}
      end

    case result do
      {:error, reason} ->
        {:error, reason}

      {:ok, conflict_result} ->
        formatted =
          Enum.map(conflict_result.conflicts, fn conflict ->
            %{
              type: conflict.type,
              severity: conflict.severity,
              message: conflict.message,
              file: conflict.file,
              line: conflict.line,
              suggestion: conflict.suggestion
            }
          end)

        {:ok,
         %{
           status: "checked",
           operation: operation,
           has_conflicts: conflict_result.has_conflicts,
           conflicts: formatted,
           stats: conflict_result.stats,
           can_proceed: conflict_result.stats.errors == 0
         }}
    end
  end

  defp refactor_conflicts_tool(_), do: {:error, "Missing required parameters"}

  defp undo_refactor_tool(params) do
    project_path = Map.get(params, "project_path", ".")

    case Undo.undo(project_path) do
      {:ok, result} ->
        {:ok,
         %{
           status: "undone",
           operation: result.operation,
           description: result.description,
           files_restored: result.files_restored
         }}

      {:error, :no_undo_history} ->
        {:ok, %{status: "none", message: "No undo history found"}}

      {:error, reason} ->
        {:error, "Failed to undo: #{inspect(reason)}"}
    end
  end

  defp refactor_history_tool(params) do
    project_path = Map.get(params, "project_path", ".")
    limit = Map.get(params, "limit", 50)
    include_undone = Map.get(params, "include_undone", false)

    case Undo.list_undo_stack(project_path, limit: limit, include_undone: include_undone) do
      {:ok, entries} ->
        formatted =
          Enum.map(entries, fn entry ->
            %{
              id: entry.id,
              operation: entry.operation,
              description: entry.description,
              timestamp: DateTime.to_iso8601(entry.timestamp),
              files_affected: length(entry.files_affected),
              result: entry.result,
              undone: Map.get(entry, :undone, false)
            }
          end)

        {:ok, %{status: "success", entries: formatted, count: length(formatted)}}

      {:error, :no_undo_history} ->
        {:ok, %{status: "empty", entries: [], count: 0}}
    end
  end

  defp visualize_impact_tool(%{"files" => files} = params) do
    format_atom =
      case Map.get(params, "format", "ascii") do
        "graphviz" -> :graphviz
        "d3_json" -> :d3_json
        "ascii" -> :ascii
        _ -> :ascii
      end

    depth = Map.get(params, "depth", 1)
    include_risk = Map.get(params, "include_risk", true)

    opts = [
      depth: depth,
      include_risk: include_risk
    ]

    case Visualize.visualize_impact(files, format_atom, opts) do
      {:ok, visualization} when format_atom == :d3_json ->
        {:ok, %{status: "success", format: "d3_json", data: visualization}}

      {:ok, visualization} ->
        {:ok, %{status: "success", format: Atom.to_string(format_atom), content: visualization}}

      {:error, reason} ->
        {:error, "Failed to visualize impact: #{inspect(reason)}"}
    end
  end

  defp visualize_impact_tool(_), do: {:error, "Missing required 'files' parameter"}

  # Quality analysis tool implementations (Phase 11)

  defp analyze_quality_tool(%{"path" => path} = params) do
    # Parse options
    metrics = parse_quality_metrics(Map.get(params, "metrics", []))
    store_results = Map.get(params, "store_results", true)
    recursive = Map.get(params, "recursive", true)

    opts = []
    opts = if metrics != [], do: Keyword.put(opts, :metrics, metrics), else: opts
    opts = Keyword.put(opts, :mode, if(recursive, do: :parallel, else: :sequential))

    # Check if path is file or directory
    case File.stat(path) do
      {:ok, %{type: :directory}} ->
        # Analyze directory
        case MetastaticBridge.analyze_directory(path, opts) do
          {:ok, results} ->
            # Optionally store results
            if store_results do
              Enum.each(results, fn {:ok, result} ->
                QualityStore.store_metrics(result)
              end)
            end

            # Format response
            success_count = Enum.count(results, &match?({:ok, _}, &1))
            error_count = Enum.count(results, &match?({:error, _}, &1))

            files_analyzed =
              Enum.map(results, fn
                {:ok, result} ->
                  %{
                    path: result.path,
                    language: result.language,
                    metrics: format_metrics(result)
                  }

                {:error, {path, reason}} ->
                  %{
                    path: path,
                    error: inspect(reason)
                  }
              end)

            {:ok,
             %{
               status: "success",
               type: "directory",
               path: path,
               files_analyzed: success_count,
               errors: error_count,
               results: files_analyzed,
               stored: store_results
             }}

          {:error, reason} ->
            {:error, "Failed to analyze directory: #{inspect(reason)}"}
        end

      {:ok, %{type: :regular}} ->
        # Analyze single file
        case MetastaticBridge.analyze_file(path, opts) do
          {:ok, result} ->
            # Optionally store result
            if store_results do
              QualityStore.store_metrics(result)
            end

            {:ok,
             %{
               status: "success",
               type: "file",
               path: result.path,
               language: result.language,
               metrics: format_metrics(result),
               stored: store_results
             }}

          {:error, reason} ->
            {:error, "Failed to analyze file: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:error, "Path does not exist: #{path}"}

      {:error, reason} ->
        {:error, "Failed to access path: #{inspect(reason)}"}
    end
  end

  defp analyze_quality_tool(_), do: {:error, "Missing required 'path' parameter"}

  defp quality_report_tool(params) do
    report_type = Map.get(params, "report_type", "summary")
    format = Map.get(params, "format", "text")
    include_files = Map.get(params, "include_files", false)

    result =
      case report_type do
        "summary" ->
          stats = QualityStore.project_stats()
          format_summary_report(stats, format)

        "detailed" ->
          stats = QualityStore.project_stats()
          files = if include_files, do: list_all_files_with_metrics(), else: []
          format_detailed_report(stats, files, format)

        "by_language" ->
          by_lang = QualityStore.stats_by_language()
          format_language_report(by_lang, format)

        "trends" ->
          # Trends require historical data - for now return current snapshot
          stats = QualityStore.project_stats()
          format_trends_report(stats, format)

        _ ->
          {:error, "Unknown report type: #{report_type}"}
      end

    case result do
      {:ok, content} ->
        {:ok,
         %{
           status: "success",
           report_type: report_type,
           format: format,
           content: content,
           files_included: include_files
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_complex_code_tool(params) do
    metric = String.to_atom(Map.get(params, "metric", "cyclomatic"))
    threshold = Map.get(params, "threshold", 10)
    comparison = String.to_atom(Map.get(params, "comparison", "gt"))
    limit = Map.get(params, "limit", 20)
    sort_order = String.to_atom(Map.get(params, "sort_order", "desc"))

    # Find files exceeding threshold
    results = QualityStore.find_by_threshold(metric, threshold, comparison)

    # Sort and limit
    sorted =
      case sort_order do
        :asc ->
          Enum.sort_by(results, fn {_path, value} -> value end)

        :desc ->
          Enum.sort_by(results, fn {_path, value} -> -value end)
      end
      |> Enum.take(limit)

    # Format results
    formatted_results =
      Enum.map(sorted, fn {path, value} ->
        metrics = QualityStore.get_metrics(path)

        # Extract language safely
        language =
          case metrics do
            {:error, :not_found} -> "unknown"
            {:ok, m} when is_map(m) -> Map.get(m, :language, "unknown")
          end

        all_metrics =
          case metrics do
            {:error, :not_found} -> %{}
            {:ok, m} when is_map(m) -> format_metrics(Map.put(m, :path, path))
          end

        %{
          path: path,
          metric_value: value,
          metric_type: Atom.to_string(metric),
          language: language,
          all_metrics: all_metrics
        }
      end)

    {:ok,
     %{
       status: "success",
       metric: Atom.to_string(metric),
       threshold: threshold,
       comparison: Atom.to_string(comparison),
       results_count: length(formatted_results),
       results: formatted_results
     }}
  end

  # Helper functions for quality analysis

  defp parse_quality_metrics(metrics) when is_list(metrics) do
    Enum.map(metrics, &String.to_atom/1)
  end

  defp parse_quality_metrics(_), do: []

  defp format_metrics(result) do
    base = %{
      cyclomatic: Map.get(result, :cyclomatic),
      cognitive: Map.get(result, :cognitive),
      max_nesting: Map.get(result, :max_nesting),
      loc: Map.get(result, :loc),
      halstead_difficulty: Map.get(result, :halstead_difficulty),
      halstead_effort: Map.get(result, :halstead_effort)
    }

    # Add purity if available
    base =
      if Map.has_key?(result, :purity_pure?) do
        Map.merge(base, %{
          purity_pure: result.purity_pure?,
          purity_score: Map.get(result, :purity_score),
          side_effects_count: Map.get(result, :side_effects_count)
        })
      else
        base
      end

    # Add warnings if present
    base =
      if warnings = Map.get(result, :warnings) do
        Map.put(base, :warnings, warnings)
      else
        base
      end

    # Remove nil values
    Enum.reject(base, fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp list_all_files_with_metrics do
    Store.list_nodes(:quality_metrics, :infinity)
    |> Enum.map(fn node ->
      %{
        path: node.data.path,
        language: node.data.language,
        metrics: format_metrics(node.data)
      }
    end)
  end

  defp format_summary_report(stats, "json") do
    {:ok, Jason.encode!(stats, pretty: true)}
  end

  defp format_summary_report(stats, "markdown") do
    content = """
    # Code Quality Summary Report

    ## Overview
    - Total Files: #{stats.total_files}
    - Files with Warnings: #{stats.files_with_warnings}
    - Impure Files: #{stats.impure_files}

    ## Complexity Metrics
    - Average Cyclomatic Complexity: #{stats.avg_cyclomatic}
    - Average Cognitive Complexity: #{stats.avg_cognitive}
    - Average Nesting Depth: #{stats.avg_nesting}

    ## Ranges
    - Cyclomatic: #{stats.min_cyclomatic} - #{stats.max_cyclomatic}
    - Cognitive: #{stats.min_cognitive} - #{stats.max_cognitive}
    - Nesting: #{stats.min_nesting} - #{stats.max_nesting}

    ## Languages
    #{format_language_list(stats.languages)}
    """

    {:ok, content}
  end

  defp format_summary_report(stats, "text") do
    content = """
    Code Quality Summary
    ===================
    Total Files: #{stats.total_files}
    Files with Warnings: #{stats.files_with_warnings}
    Impure Files: #{stats.impure_files}

    Complexity Metrics:
      Avg Cyclomatic: #{stats.avg_cyclomatic} (Range: #{stats.min_cyclomatic}-#{stats.max_cyclomatic})
      Avg Cognitive: #{stats.avg_cognitive} (Range: #{stats.min_cognitive}-#{stats.max_cognitive})
      Avg Nesting: #{stats.avg_nesting} (Range: #{stats.min_nesting}-#{stats.max_nesting})

    Languages: #{format_language_list_text(stats.languages)}
    """

    {:ok, content}
  end

  defp format_detailed_report(stats, files, "json") do
    {:ok, Jason.encode!(%{summary: stats, files: files}, pretty: true)}
  end

  defp format_detailed_report(stats, files, format) do
    # For text/markdown, show summary + top complex files
    {:ok, summary_content} = format_summary_report(stats, format)

    files_section =
      if files != [] do
        top_files =
          files
          |> Enum.sort_by(fn f -> -(f.metrics[:cyclomatic] || 0) end)
          |> Enum.take(10)

        files_text =
          Enum.map_join(top_files, "\n", fn f ->
            "  - #{f.path} (#{f.language}): cyclomatic=#{f.metrics[:cyclomatic] || 0}"
          end)

        "\nTop 10 Most Complex Files:\n" <> files_text
      else
        ""
      end

    {:ok, summary_content <> files_section}
  end

  defp format_language_report(by_lang, "json") do
    {:ok, Jason.encode!(by_lang, pretty: true)}
  end

  defp format_language_report(by_lang, "markdown") do
    content =
      "# Code Quality by Language\n\n" <>
        Enum.map_join(by_lang, "\n\n", fn {lang, stats} ->
          """
          ## #{lang |> Atom.to_string() |> String.capitalize()}
          - Files: #{stats.total_files}
          - Avg Cyclomatic: #{stats.avg_cyclomatic}
          - Avg Cognitive: #{stats.avg_cognitive}
          - Files with Warnings: #{stats.files_with_warnings}
          """
        end)

    {:ok, content}
  end

  defp format_language_report(by_lang, "text") do
    content =
      "Code Quality by Language\n" <>
        String.duplicate("=", 25) <>
        "\n\n" <>
        Enum.map_join(by_lang, "\n\n", fn {lang, stats} ->
          """
          #{lang |> Atom.to_string() |> String.upcase()}:
            Files: #{stats.total_files}
            Avg Cyclomatic: #{stats.avg_cyclomatic}
            Avg Cognitive: #{stats.avg_cognitive}
            Warnings: #{stats.files_with_warnings}
          """
        end)

    {:ok, content}
  end

  defp format_trends_report(stats, "json") do
    # For now, just return current stats as a single data point
    trend_data = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      metrics: stats
    }

    {:ok, Jason.encode!(trend_data, pretty: true)}
  end

  defp format_trends_report(stats, format) do
    # For text/markdown, note that this is a snapshot
    {:ok, content} = format_summary_report(stats, format)
    note = "\n\nNote: Trends require historical data. This is a current snapshot.\n"
    {:ok, content <> note}
  end

  defp format_language_list(languages) when is_map(languages) do
    Enum.map_join(languages, "\n    ", fn {lang, count} -> "- #{lang}: #{count} files" end)
  end

  defp format_language_list(_), do: "None"

  defp format_language_list_text(languages) when is_map(languages) do
    Enum.map_join(languages, ", ", fn {lang, count} -> "#{lang}(#{count})" end)
  end

  defp format_language_list_text(_), do: "None"

  # Dependency and dead code analysis tool implementations (Phase 11 Week 2)

  defp analyze_dependencies_tool(params) do
    module_str = Map.get(params, "module")
    include_transitive = Map.get(params, "include_transitive", false)
    format = Map.get(params, "format", "summary")

    case module_str do
      nil ->
        # Analyze all modules
        case DependencyGraph.all_coupling_metrics(include_transitive: include_transitive) do
          {:ok, all_metrics} ->
            format_dependencies_all(all_metrics, format, include_transitive)

          {:error, reason} ->
            {:error, "Failed to analyze dependencies: #{inspect(reason)}"}
        end

      mod_str ->
        # Analyze specific module
        module = String.to_atom(mod_str)

        case DependencyGraph.coupling_metrics(module, include_transitive: include_transitive) do
          {:ok, metrics} ->
            format_dependencies_single(module, metrics, format, include_transitive)

          {:error, {:module_not_found, ^module}} ->
            {:error, "Module not found: #{module}"}

          {:error, reason} ->
            {:error, "Failed to analyze module: #{inspect(reason)}"}
        end
    end
  end

  defp find_circular_dependencies_tool(params) do
    scope_str = Map.get(params, "scope", "module")
    min_cycle_length = Map.get(params, "min_cycle_length", 2)
    limit = Map.get(params, "limit", 100)

    scope = String.to_atom(scope_str)

    case DependencyGraph.find_cycles(
           scope: scope,
           min_cycle_length: min_cycle_length,
           limit: limit
         ) do
      {:ok, cycles} ->
        formatted_cycles =
          Enum.map(cycles, fn cycle ->
            formatted = Enum.map_join(cycle, " -> ", &format_cycle_entity/1)

            %{
              length: length(cycle),
              cycle: formatted,
              entities: cycle
            }
          end)

        {:ok,
         %{
           status: "success",
           scope: scope_str,
           cycles_found: length(cycles),
           cycles: formatted_cycles
         }}

      {:error, reason} ->
        {:error, "Failed to find circular dependencies: #{inspect(reason)}"}
    end
  end

  defp find_dead_code_tool(params) do
    scope = Map.get(params, "scope", "all")
    min_confidence = Map.get(params, "min_confidence", 0.5)
    exclude_tests = Map.get(params, "exclude_tests", true)
    include_callbacks = Map.get(params, "include_callbacks", false)
    format = Map.get(params, "format", "summary")

    opts = [
      min_confidence: min_confidence,
      exclude_tests: exclude_tests,
      include_callbacks: include_callbacks
    ]

    result =
      case scope do
        "exports" ->
          DeadCode.find_unused_exports(opts)

        "private" ->
          DeadCode.find_unused_private(opts)

        "all" ->
          DeadCode.find_all_unused(opts)

        "modules" ->
          DeadCode.find_unused_modules(opts)

        _ ->
          {:error, "Unknown scope: #{scope}"}
      end

    case result do
      {:ok, dead_functions} when scope == "modules" ->
        # Modules scope returns list of module names
        {:ok,
         %{
           status: "success",
           scope: scope,
           unused_modules: length(dead_functions),
           modules: dead_functions
         }}

      {:ok, dead_functions} ->
        # Function scopes return dead_function structs
        case format do
          "summary" ->
            format_dead_code_summary(dead_functions, scope)

          "detailed" ->
            format_dead_code_detailed(dead_functions, scope)

          "suggestions" ->
            format_dead_code_suggestions(dead_functions, scope, opts)

          _ ->
            {:error, "Unknown format: #{format}"}
        end

      {:error, reason} ->
        {:error, "Failed to find dead code: #{inspect(reason)}"}
    end
  end

  defp analyze_dead_code_patterns_tool(%{"path" => path} = params) do
    min_confidence_str = Map.get(params, "min_confidence", "low")
    format = Map.get(params, "format", "summary")

    min_confidence = String.to_atom(min_confidence_str)
    opts = [min_confidence: min_confidence]

    # Check if path is a file or directory
    cond do
      File.regular?(path) ->
        # Single file analysis
        case DeadCode.analyze_file(path, opts) do
          {:ok, result} ->
            format_dead_code_patterns_result(path, result, format)

          {:error, reason} ->
            {:error, "Failed to analyze file: #{inspect(reason)}"}
        end

      File.dir?(path) ->
        # Directory analysis - find all supported files
        case find_supported_files(path) do
          [] ->
            {:error, "No supported files found in directory: #{path}"}

          files ->
            case DeadCode.analyze_files(files, opts) do
              {:ok, results} ->
                format_dead_code_patterns_results(results, format)

              {:error, reason} ->
                {:error, "Failed to analyze files: #{inspect(reason)}"}
            end
        end

      true ->
        {:error, "Path not found or not accessible: #{path}"}
    end
  end

  defp analyze_dead_code_patterns_tool(_),
    do: {:error, "Invalid parameters for analyze_dead_code_patterns"}

  defp coupling_report_tool(params) do
    format = Map.get(params, "format", "text")
    sort_by_str = Map.get(params, "sort_by", "instability")
    include_transitive = Map.get(params, "include_transitive", false)
    threshold = Map.get(params, "threshold", 0)

    sort_by = String.to_atom(sort_by_str)

    case DependencyGraph.all_coupling_metrics(
           sort_by: sort_by,
           include_transitive: include_transitive
         ) do
      {:ok, all_metrics} ->
        # Filter by threshold
        filtered =
          if threshold > 0 do
            Enum.filter(all_metrics, fn {_module, metrics} ->
              metrics.afferent + metrics.afferent >= threshold
            end)
          else
            all_metrics
          end

        format_coupling_report(filtered, format, sort_by_str, include_transitive)

      {:error, reason} ->
        {:error, "Failed to generate coupling report: #{inspect(reason)}"}
    end
  end

  defp find_duplicates_tool(%{"path" => path} = params) do
    threshold = Map.get(params, "threshold", 0.8)
    recursive = Map.get(params, "recursive", true)
    format = Map.get(params, "format", "summary")
    exclude_patterns = Map.get(params, "exclude_patterns", ["_build", "deps", ".git"])

    opts = [
      threshold: threshold,
      recursive: recursive,
      exclude_patterns: exclude_patterns
    ]

    # Check if comparing two specific files (comma-separated)
    case String.split(path, ",") do
      [file1, file2] ->
        # Compare two files
        file1 = String.trim(file1)
        file2 = String.trim(file2)

        case Duplication.detect_between_files(file1, file2, opts) do
          {:ok, result} ->
            format_duplicate_result(file1, file2, result, format)

          {:error, reason} ->
            {:error, "Failed to detect duplicates: #{inspect(reason)}"}
        end

      [single_path] ->
        # Analyze directory or single file context
        single_path = String.trim(single_path)

        cond do
          File.dir?(single_path) ->
            case Duplication.detect_in_directory(single_path, opts) do
              {:ok, clones} ->
                format_duplicates_result(clones, format)

              {:error, reason} ->
                {:error, "Failed to detect duplicates: #{inspect(reason)}"}
            end

          File.regular?(single_path) ->
            {:error,
             "Single file provided. Please provide a directory or two files separated by comma."}

          true ->
            {:error, "Path not found: #{single_path}"}
        end

      _ ->
        {:error, "Invalid path format. Use a directory or two files separated by comma."}
    end
  end

  defp find_duplicates_tool(_), do: {:error, "Invalid parameters for find_duplicates"}

  defp find_similar_code_tool(params) do
    threshold = Map.get(params, "threshold", 0.95)
    limit = Map.get(params, "limit", 100)
    node_type_str = Map.get(params, "node_type", "function")
    format = Map.get(params, "format", "summary")

    node_type = String.to_atom(node_type_str)

    opts = [
      threshold: threshold,
      limit: limit,
      node_type: node_type
    ]

    case Duplication.find_similar_functions(opts) do
      {:ok, similar_pairs} ->
        format_similar_code_result(similar_pairs, format)

      {:error, reason} ->
        {:error, "Failed to find similar code: #{inspect(reason)}"}
    end
  end

  # Impact analysis tool implementations (Phase 11 Week 4)

  defp analyze_impact_tool(%{"target" => target_str} = params) do
    depth = Map.get(params, "depth", 5)
    include_tests = Map.get(params, "include_tests", true)
    format = Map.get(params, "format", "summary")

    # Parse target string: "Module.function/arity" or "Module"
    case parse_target_string(target_str) do
      {:ok, target} ->
        opts = [
          depth: depth,
          include_tests: include_tests
        ]

        case Impact.analyze_change(target, opts) do
          {:ok, analysis} ->
            format_impact_analysis(analysis, format)

          {:error, reason} ->
            {:error, "Impact analysis failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Invalid target format: #{reason}. Use 'Module.function/arity' or 'Module'"}
    end
  end

  defp analyze_impact_tool(_), do: {:error, "Missing required 'target' parameter"}

  defp estimate_refactoring_effort_tool(
         %{"operation" => operation_str, "target" => target_str} = params
       ) do
    format = Map.get(params, "format", "summary")

    operation = String.to_atom(operation_str)

    # Parse target string
    case parse_target_string(target_str) do
      {:ok, target} ->
        case Impact.estimate_effort(operation, target, []) do
          {:ok, estimate} ->
            format_effort_estimate(estimate, format)

          {:error, reason} ->
            {:error, "Effort estimation failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Invalid target format: #{reason}. Use 'Module.function/arity' or 'Module'"}
    end
  end

  defp estimate_refactoring_effort_tool(_), do: {:error, "Missing required parameters"}

  defp risk_assessment_tool(%{"target" => target_str} = params) do
    format = Map.get(params, "format", "summary")

    # Parse target string
    case parse_target_string(target_str) do
      {:ok, target} ->
        case Impact.risk_score(target) do
          {:ok, risk} ->
            format_risk_assessment(risk, format)

          {:error, reason} ->
            {:error, "Risk assessment failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Invalid target format: #{reason}. Use 'Module.function/arity' or 'Module'"}
    end
  end

  defp risk_assessment_tool(_), do: {:error, "Missing required 'target' parameter"}

  # Helper functions for impact analysis tools

  defp parse_target_string(target_str) do
    # Module.function/arity format
    if String.contains?(target_str, "/") and String.contains?(target_str, ".") do
      case String.split(target_str, ".", parts: 2) do
        [module_str, func_arity] ->
          case String.split(func_arity, "/") do
            [func_str, arity_str] ->
              case Integer.parse(arity_str) do
                {arity, ""} ->
                  module = String.to_existing_atom("Elixir." <> module_str)
                  function = String.to_atom(func_str)
                  {:ok, {:function, module, function, arity}}

                _ ->
                  {:error, "Invalid arity: #{arity_str}"}
              end

            _ ->
              {:error, "Invalid function/arity format"}
          end

        _ ->
          {:error, "Invalid module.function format"}
      end

      # Module format
    else
      try do
        module = String.to_existing_atom("Elixir." <> target_str)
        {:ok, {:module, module}}
      rescue
        ArgumentError ->
          {:error, "Module not found: #{target_str}"}
      end
    end
  end

  defp format_impact_analysis(analysis, "json") do
    {:ok,
     %{
       status: "success",
       target: format_node_id(analysis.target),
       direct_callers_count: length(analysis.direct_callers),
       affected_count: analysis.affected_count,
       depth: analysis.depth,
       risk_score: Float.round(analysis.risk_score, 4),
       importance: Float.round(analysis.importance, 4),
       direct_callers: Enum.map(analysis.direct_callers, &format_node_id/1),
       all_affected: Enum.map(analysis.all_affected, &format_node_id/1),
       recommendations: analysis.recommendations
     }}
  end

  defp format_impact_analysis(analysis, "detailed") do
    content = """
    Impact Analysis
    ==============
    Target: #{format_node_id(analysis.target)}
    Risk Score: #{Float.round(analysis.risk_score, 4)}
    Importance: #{Float.round(analysis.importance, 4)}

    Direct Callers: #{length(analysis.direct_callers)}
    #{Enum.map_join(analysis.direct_callers, "\n", fn caller -> "  - #{format_node_id(caller)}" end)}

    All Affected: #{analysis.affected_count}
    #{Enum.map_join(Enum.take(analysis.all_affected, 10), "\n", fn node -> "  - #{format_node_id(node)}" end)}
    #{if analysis.affected_count > 10, do: "  ... and #{analysis.affected_count - 10} more", else: ""}

    Recommendations:
    #{Enum.map_join(analysis.recommendations, "\n", fn rec -> "  - #{rec}" end)}
    """

    {:ok, %{status: "success", content: String.trim(content)}}
  end

  defp format_impact_analysis(analysis, "summary") do
    content = """
    Impact: #{format_node_id(analysis.target)}
    Risk: #{Float.round(analysis.risk_score, 2)} | Importance: #{Float.round(analysis.importance, 2)}
    Direct Callers: #{length(analysis.direct_callers)} | Total Affected: #{analysis.affected_count}
    """

    {:ok, %{status: "success", summary: String.trim(content)}}
  end

  defp format_effort_estimate(estimate, "json") do
    {:ok,
     %{
       status: "success",
       operation: Atom.to_string(estimate.operation),
       target: format_node_id(estimate.target),
       estimated_changes: estimate.estimated_changes,
       complexity: Atom.to_string(estimate.complexity),
       estimated_time: estimate.estimated_time,
       risks: estimate.risks,
       recommendations: estimate.recommendations
     }}
  end

  defp format_effort_estimate(estimate, "detailed") do
    content = """
    Refactoring Effort Estimate
    =========================
    Operation: #{estimate.operation}
    Target: #{format_node_id(estimate.target)}

    Estimated Changes: #{estimate.estimated_changes} locations
    Complexity: #{estimate.complexity}
    Estimated Time: #{estimate.estimated_time}

    Risks:
    #{Enum.map_join(estimate.risks, "\n", fn risk -> "  - #{risk}" end)}

    Recommendations:
    #{Enum.map_join(estimate.recommendations, "\n", fn rec -> "  - #{rec}" end)}
    """

    {:ok, %{status: "success", content: String.trim(content)}}
  end

  defp format_effort_estimate(estimate, "summary") do
    content = """
    Effort: #{estimate.operation} on #{format_node_id(estimate.target)}
    Changes: #{estimate.estimated_changes} | Complexity: #{estimate.complexity} | Time: #{estimate.estimated_time}
    """

    {:ok, %{status: "success", summary: String.trim(content)}}
  end

  defp format_risk_assessment(risk, "json") do
    {:ok,
     %{
       status: "success",
       target: format_node_id(risk.target),
       importance: Float.round(risk.importance, 4),
       coupling: Float.round(risk.coupling, 4),
       complexity: Float.round(risk.complexity, 4),
       overall: Float.round(risk.overall, 4),
       level: Atom.to_string(risk.level),
       factors: risk.factors
     }}
  end

  defp format_risk_assessment(risk, "detailed") do
    content = """
    Risk Assessment
    ==============
    Target: #{format_node_id(risk.target)}
    Overall Risk: #{Float.round(risk.overall, 4)} (#{risk.level})

    Components:
      - Importance: #{Float.round(risk.importance, 4)} (PageRank-based)
      - Coupling: #{Float.round(risk.coupling, 4)} (incoming/outgoing edges)
      - Complexity: #{Float.round(risk.complexity, 4)} (code metrics)

    Factors:
    #{format_risk_factors(risk.factors)}
    """

    {:ok, %{status: "success", content: String.trim(content)}}
  end

  defp format_risk_assessment(risk, "summary") do
    content = """
    Risk: #{format_node_id(risk.target)}
    Overall: #{Float.round(risk.overall, 2)} (#{risk.level})
    Importance: #{Float.round(risk.importance, 2)} | Coupling: #{Float.round(risk.coupling, 2)} | Complexity: #{Float.round(risk.complexity, 2)}
    """

    {:ok, %{status: "success", summary: String.trim(content)}}
  end

  defp format_risk_factors(factors) when is_map(factors) do
    Enum.map_join(factors, "\n", fn {key, value} ->
      "  - #{key}: #{format_risk_factor_value(value)}"
    end)
  end

  defp format_risk_factors(_), do: "None"

  defp format_risk_factor_value(value) when is_float(value), do: Float.round(value, 4)
  defp format_risk_factor_value(value) when is_integer(value), do: value
  defp format_risk_factor_value(value), do: inspect(value)

  # Formatting helpers for dependency tools

  defp format_dependencies_all(all_metrics, "json", _transitive) do
    data =
      Enum.map(all_metrics, fn {module, metrics} ->
        %{
          module: inspect(module),
          afferent: metrics.afferent,
          efferent: metrics.efferent,
          instability: metrics.instability
        }
      end)

    {:ok,
     %{
       status: "success",
       modules_analyzed: length(all_metrics),
       metrics: data
     }}
  end

  defp format_dependencies_all(all_metrics, _format, transitive) do
    total = length(all_metrics)

    avg_instability =
      Enum.sum(Enum.map(all_metrics, fn {_, m} -> m.instability end)) / max(total, 1)

    top_unstable =
      all_metrics
      |> Enum.take(5)
      |> Enum.map_join("\n", fn {module, metrics} ->
        "  - #{inspect(module)}: I=#{Float.round(metrics.instability, 2)} (Ca=#{metrics.afferent}, Ce=#{metrics.efferent})"
      end)

    content = """
    Dependency Analysis Summary
    ==========================
    Modules Analyzed: #{total}
    Average Instability: #{Float.round(avg_instability, 2)}
    Analysis Type: #{if transitive, do: "Transitive", else: "Direct"}

    Top 5 Most Unstable Modules:
    #{top_unstable}
    """

    {:ok, %{status: "success", modules_analyzed: total, summary: content}}
  end

  defp format_dependencies_single(module, metrics, "json", _transitive) do
    {:ok,
     %{
       status: "success",
       module: inspect(module),
       metrics: %{
         afferent: metrics.afferent,
         efferent: metrics.efferent,
         instability: metrics.instability
       }
     }}
  end

  defp format_dependencies_single(module, metrics, _format, transitive) do
    content = """
    Module: #{inspect(module)}
    Analysis Type: #{if transitive, do: "Transitive", else: "Direct"}

    Coupling Metrics:
      Afferent (Ca):  #{metrics.afferent} (modules depending on this)
      Efferent (Ce):  #{metrics.efferent} (modules this depends on)
      Instability (I): #{Float.round(metrics.instability, 2)}

    Interpretation:
      I = 0.0: Maximally stable (many dependents, few dependencies)
      I = 1.0: Maximally unstable (few dependents, many dependencies)
    """

    {:ok, %{status: "success", module: inspect(module), summary: content}}
  end

  defp format_cycle_entity({:function, module, name, arity}), do: "#{module}.#{name}/#{arity}"
  defp format_cycle_entity(module) when is_atom(module), do: inspect(module)
  defp format_cycle_entity(other), do: inspect(other)

  defp format_dead_code_patterns_result(path, result, "json") do
    {:ok,
     %{
       status: "success",
       path: path,
       has_dead_code: result.has_dead_code?,
       total_dead_statements: result.total_dead_statements,
       by_type: result.by_type,
       locations: result.dead_locations
     }}
  end

  defp format_dead_code_patterns_result(path, result, "detailed") do
    locations_formatted =
      Enum.map(result.dead_locations, fn loc ->
        %{
          type: loc.type,
          reason: loc.reason,
          confidence: loc.confidence,
          suggestion: loc.suggestion
        }
      end)

    content = """
    Dead Code Patterns Analysis
    ==========================
    File: #{path}
    Has Dead Code: #{result.has_dead_code?}
    Total Dead Statements: #{result.total_dead_statements}

    #{if result.has_dead_code?, do: "Dead Code Locations:", else: "No dead code found."}
    #{if result.has_dead_code?, do: Enum.map_join(result.dead_locations, "\n", fn loc -> "  - #{loc.type}: #{loc.reason}" end), else: ""}
    """

    {:ok,
     %{
       status: "success",
       path: path,
       has_dead_code: result.has_dead_code?,
       total_dead_statements: result.total_dead_statements,
       locations: locations_formatted,
       summary: content
     }}
  end

  defp format_dead_code_patterns_result(path, result, "summary") do
    content = """
    Dead Code Patterns: #{path}
    ----------------------------
    Status: #{if result.has_dead_code?, do: "Dead code found", else: "Clean"}
    Dead Statements: #{result.total_dead_statements}
    #{if map_size(result.by_type) > 0, do: "Types: " <> Enum.map_join(result.by_type, ", ", fn {type, count} -> "#{type}(#{count})" end), else: ""}
    """

    {:ok,
     %{
       status: "success",
       path: path,
       has_dead_code: result.has_dead_code?,
       total_dead_statements: result.total_dead_statements,
       summary: String.trim(content)
     }}
  end

  defp format_dead_code_patterns_results(results, "json") do
    total_files = map_size(results)
    files_with_issues = Enum.count(results, fn {_, r} -> match?(%{has_dead_code?: true}, r) end)

    total_dead =
      Enum.sum(
        Enum.map(results, fn
          {_, %{total_dead_statements: count}} -> count
          {_, _} -> 0
        end)
      )

    files_data =
      Enum.map(results, fn {path, result} ->
        case result do
          %{has_dead_code?: _} = r ->
            %{
              path: path,
              has_dead_code: r.has_dead_code?,
              total_dead_statements: r.total_dead_statements,
              by_type: r.by_type
            }

          {:error, reason} ->
            %{path: path, error: inspect(reason)}
        end
      end)

    {:ok,
     %{
       status: "success",
       total_files: total_files,
       files_with_issues: files_with_issues,
       total_dead_statements: total_dead,
       files: files_data
     }}
  end

  defp format_dead_code_patterns_results(results, format)
       when format in ["summary", "detailed"] do
    total_files = map_size(results)
    files_with_issues = Enum.count(results, fn {_, r} -> match?(%{has_dead_code?: true}, r) end)

    total_dead =
      Enum.sum(
        Enum.map(results, fn
          {_, %{total_dead_statements: count}} -> count
          {_, _} -> 0
        end)
      )

    files_summary =
      results
      |> Enum.filter(fn {_, r} -> match?(%{has_dead_code?: true}, r) end)
      |> Enum.map_join("\n", fn {path, result} ->
        types_str =
          if map_size(result.by_type) > 0 do
            Enum.map_join(result.by_type, ", ", fn {type, count} -> "#{type}(#{count})" end)
          else
            "none"
          end

        "  - #{path}: #{result.total_dead_statements} statements [#{types_str}]"
      end)

    content = """
    Dead Code Patterns Analysis Summary
    ==================================
    Total Files Analyzed: #{total_files}
    Files with Dead Code: #{files_with_issues}
    Total Dead Statements: #{total_dead}

    #{if files_with_issues > 0, do: "Files with Issues:\n" <> files_summary, else: "No dead code found in any files."}
    """

    {:ok,
     %{
       status: "success",
       total_files: total_files,
       files_with_issues: files_with_issues,
       total_dead_statements: total_dead,
       summary: String.trim(content)
     }}
  end

  defp find_supported_files(dir) do
    # Extensions supported by Metastatic
    extensions = [".ex", ".exs", ".erl", ".hrl", ".py", ".rb", ".hs"]

    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.filter(fn path ->
      File.regular?(path) && Enum.any?(extensions, fn ext -> String.ends_with?(path, ext) end)
    end)
  end

  defp format_dead_code_summary(dead_functions, scope) do
    total = length(dead_functions)
    high_confidence = Enum.count(dead_functions, fn f -> f.confidence > 0.8 end)

    medium_confidence =
      Enum.count(dead_functions, fn f -> f.confidence > 0.5 && f.confidence <= 0.8 end)

    low_confidence = Enum.count(dead_functions, fn f -> f.confidence <= 0.5 end)

    avg_confidence =
      if total > 0 do
        Enum.sum(Enum.map(dead_functions, & &1.confidence)) / total
      else
        0.0
      end

    top_candidates =
      dead_functions
      |> Enum.take(10)
      |> Enum.map_join("\n", fn df ->
        {mod, name, arity} = extract_function_parts(df.function)
        "  - #{mod}.#{name}/#{arity} (confidence: #{Float.round(df.confidence, 2)})"
      end)

    content = """
    Dead Code Analysis (#{scope})
    ===========================
    Total Potentially Dead Functions: #{total}
    Average Confidence: #{Float.round(avg_confidence, 2)}

    Confidence Breakdown:
      High (>0.8):    #{high_confidence} (likely safe to remove)
      Medium (0.5-0.8): #{medium_confidence} (review recommended)
      Low (<0.5):     #{low_confidence} (likely callbacks/entry points)

    Top Candidates for Removal:
    #{if total > 0, do: top_candidates, else: "  (none)"}
    """

    {:ok, %{status: "success", scope: scope, total_found: total, summary: content}}
  end

  defp format_dead_code_detailed(dead_functions, scope) do
    detailed =
      Enum.map(dead_functions, fn df ->
        {mod, name, arity} = extract_function_parts(df.function)

        %{
          function: "#{mod}.#{name}/#{arity}",
          module: inspect(mod),
          confidence: df.confidence,
          reason: df.reason,
          visibility: df.visibility
        }
      end)

    {:ok,
     %{
       status: "success",
       scope: scope,
       total_found: length(dead_functions),
       functions: detailed
     }}
  end

  defp format_dead_code_suggestions(dead_functions, scope, opts) do
    case DeadCode.removal_suggestions(opts) do
      {:ok, suggestions} ->
        formatted_suggestions =
          Enum.map(suggestions, fn s ->
            target_str =
              case s.target do
                {:function, mod, name, arity} -> "#{mod}.#{name}/#{arity}"
                {:module, mod} -> inspect(mod)
                other -> inspect(other)
              end

            %{
              type: s.type,
              confidence: s.confidence,
              target: target_str,
              description: s.description
            }
          end)

        {:ok,
         %{
           status: "success",
           scope: scope,
           total_functions: length(dead_functions),
           suggestions: formatted_suggestions
         }}

      {:error, reason} ->
        {:error, "Failed to generate suggestions: #{inspect(reason)}"}
    end
  end

  defp format_coupling_report(metrics, "json", _sort_by, _transitive) do
    data =
      Enum.map(metrics, fn {module, m} ->
        %{
          module: inspect(module),
          afferent: m.afferent,
          efferent: m.efferent,
          instability: m.instability
        }
      end)

    {:ok, %{status: "success", modules: length(metrics), report: data}}
  end

  defp format_coupling_report(metrics, "markdown", sort_by, transitive) do
    header = """
    # Module Coupling Report

    **Analysis Type:** #{if transitive, do: "Transitive", else: "Direct"}
    **Sort By:** #{sort_by}
    **Modules:** #{length(metrics)}

    | Module | Afferent (Ca) | Efferent (Ce) | Instability (I) |
    |--------|---------------|---------------|------------------|
    """

    rows =
      Enum.map_join(metrics, "\n    ", fn {module, m} ->
        "| #{inspect(module)} | #{m.afferent} | #{m.efferent} | #{Float.round(m.instability, 2)} |"
      end)

    content = header <> rows

    {:ok, %{status: "success", modules: length(metrics), report: content}}
  end

  defp format_coupling_report(metrics, "text", sort_by, transitive) do
    header = """
    Module Coupling Report
    =====================
    Analysis Type: #{if transitive, do: "Transitive", else: "Direct"}
    Sort By: #{sort_by}
    Modules: #{length(metrics)}

    """

    rows =
      Enum.map_join(metrics, "\n", fn {module, m} ->
        """
        #{inspect(module)}
          Afferent (Ca):  #{m.afferent}
          Efferent (Ce):  #{m.efferent}
          Instability (I): #{Float.round(m.instability, 2)}
        """
      end)

    content = header <> rows

    {:ok, %{status: "success", modules: length(metrics), report: content}}
  end

  defp extract_function_parts({:function, module, name, arity}), do: {module, name, arity}

  # Duplication formatting helpers

  defp format_duplicate_result(file1, file2, result, "json") do
    {:ok,
     %{
       status: "success",
       file1: file1,
       file2: file2,
       duplicate: result.duplicate?,
       clone_type: result.clone_type,
       similarity: result.similarity_score,
       summary: result.summary || ""
     }}
  end

  defp format_duplicate_result(file1, file2, result, "detailed") do
    content = """
    Duplicate Detection Result
    =========================
    File 1: #{file1}
    File 2: #{file2}

    Duplicate: #{if result.duplicate?, do: "YES", else: "NO"}
    #{if result.duplicate? do
      "Clone Type: #{format_clone_type(result.clone_type)}\nSimilarity: #{Float.round(result.similarity_score, 3)}\n\nSummary:\n#{result.summary || ""}"
    else
      "These files are not duplicates."
    end}
    """

    {:ok, %{status: "success", duplicate: result.duplicate?, summary: String.trim(content)}}
  end

  defp format_duplicate_result(_file1, _file2, result, "summary") do
    if result.duplicate? do
      {:ok,
       %{
         status: "success",
         duplicate: true,
         summary:
           "Duplicate detected: #{format_clone_type(result.clone_type)} (similarity: #{Float.round(result.similarity_score, 2)})"
       }}
    else
      {:ok, %{status: "success", duplicate: false, summary: "No duplication detected."}}
    end
  end

  defp format_duplicates_result(clones, "json") do
    {:ok,
     %{
       status: "success",
       total_clones: length(clones),
       clones:
         Enum.map(clones, fn clone ->
           %{
             file1: clone.file1,
             file2: clone.file2,
             clone_type: clone.clone_type,
             similarity: clone.similarity
           }
         end)
     }}
  end

  defp format_duplicates_result(clones, "detailed") do
    content =
      case clones do
        [_ | _] ->
          by_type =
            Enum.group_by(clones, & &1.clone_type)
            |> Enum.map_join("\n", fn {type, group} ->
              "  #{format_clone_type(type)}: #{length(group)}"
            end)

          pairs =
            Enum.map_join(clones, "\n\n", fn clone ->
              """
              #{clone.file1} <-> #{clone.file2}
                Type: #{format_clone_type(clone.clone_type)}
                Similarity: #{Float.round(clone.similarity, 3)}
              """
            end)

          """
          Code Duplication Report
          ======================
          Total Duplicate Pairs: #{length(clones)}

          By Clone Type:
          #{by_type}

          Duplicate Pairs:
          #{pairs}
          """

        _ ->
          "No duplicates found."
      end

    {:ok, %{status: "success", total_clones: length(clones), summary: String.trim(content)}}
  end

  defp format_duplicates_result(clones, "summary") do
    case clones do
      [_ | _] ->
        by_type =
          Enum.group_by(clones, & &1.clone_type)
          |> Enum.map_join(", ", fn {type, group} ->
            "#{length(group)} #{format_clone_type(type)}"
          end)

        {:ok,
         %{
           status: "success",
           total_clones: length(clones),
           summary: "Found #{length(clones)} duplicate pairs: #{by_type}"
         }}

      _ ->
        {:ok, %{status: "success", total_clones: 0, summary: "No duplicates found."}}
    end
  end

  defp format_similar_code_result(pairs, "json") do
    {:ok,
     %{
       status: "success",
       total_pairs: length(pairs),
       pairs:
         Enum.map(pairs, fn pair ->
           %{
             function1: format_function_ref(pair.function1),
             function2: format_function_ref(pair.function2),
             similarity: pair.similarity,
             method: pair.method
           }
         end)
     }}
  end

  defp format_similar_code_result(pairs, "detailed") do
    content =
      case pairs do
        [_ | _] ->
          avg_sim =
            (Enum.sum(Enum.map(pairs, & &1.similarity)) / length(pairs))
            |> Float.round(3)

          pairs_text =
            Enum.map_join(pairs, "\n\n", fn pair ->
              """
              #{format_function_ref(pair.function1)} ~ #{format_function_ref(pair.function2)}
                Similarity: #{Float.round(pair.similarity, 3)}
                Method: #{pair.method}
              """
            end)

          """
          Similar Code Report
          ==================
          Total Similar Pairs: #{length(pairs)}
          Average Similarity: #{avg_sim}

          Similar Pairs:
          #{pairs_text}
          """

        _ ->
          "No similar code found."
      end

    {:ok, %{status: "success", total_pairs: length(pairs), summary: String.trim(content)}}
  end

  defp format_similar_code_result(pairs, "summary") do
    case pairs do
      [_ | _] ->
        avg_sim =
          (Enum.sum(Enum.map(pairs, & &1.similarity)) / length(pairs))
          |> Float.round(2)

        {:ok,
         %{
           status: "success",
           total_pairs: length(pairs),
           summary: "Found #{length(pairs)} similar pairs (avg similarity: #{avg_sim})"
         }}

      _ ->
        {:ok, %{status: "success", total_pairs: 0, summary: "No similar code found."}}
    end
  end

  defp format_clone_type(:type_i), do: "Type I (Exact)"
  defp format_clone_type(:type_ii), do: "Type II (Renamed)"
  defp format_clone_type(:type_iii), do: "Type III (Near-miss)"
  defp format_clone_type(:type_iv), do: "Type IV (Semantic)"
  defp format_clone_type(other), do: to_string(other)

  defp format_function_ref({:function, module, name, arity}), do: "#{module}.#{name}/#{arity}"
  defp format_function_ref(other), do: inspect(other)

  # Suggestion tools implementations (Phase 11G)

  defp suggest_refactorings_tool(%{"target" => target_str} = params) do
    patterns = Map.get(params, "patterns", [])
    min_priority = Map.get(params, "min_priority", "low") |> String.to_atom()
    include_actions = Map.get(params, "include_actions", true)
    use_rag = Map.get(params, "use_rag", false)
    format = Map.get(params, "format", "summary")

    # Parse target (can be file path, directory, or module reference)
    target = parse_suggestion_target(target_str)

    opts = [
      patterns: if(patterns == [], do: :all, else: Enum.map(patterns, &String.to_atom/1)),
      min_priority: min_priority,
      include_actions: include_actions,
      use_rag: use_rag
    ]

    case Suggestions.analyze_target(target, opts) do
      {:ok, result} ->
        format_suggestions_result(result, format)

      {:error, reason} ->
        {:error, "Suggestion analysis failed: #{inspect(reason)}"}
    end
  end

  defp suggest_refactorings_tool(_), do: {:error, "Missing required 'target' parameter"}

  defp explain_suggestion_tool(%{"suggestion_id" => _suggestion_id} = _params) do
    # [TODO] This is a simplified implementation - in production, you'd need to
    # maintain a cache of suggestions by ID to look them up
    {:error,
     "explain_suggestion requires maintaining suggestion state - use detailed format in suggest_refactorings instead"}
  end

  defp explain_suggestion_tool(_), do: {:error, "Missing required 'suggestion_id' parameter"}

  # Validation AI tool implementation (Phase B)

  defp validate_with_ai_tool(%{"content" => content} = params) do
    opts = []

    # Add optional path parameter
    opts =
      if Map.has_key?(params, "path") do
        Keyword.put(opts, :path, params["path"])
      else
        opts
      end

    # Add optional language parameter
    opts =
      if Map.has_key?(params, "language") do
        Keyword.put(opts, :language, String.to_atom(params["language"]))
      else
        opts
      end

    # Add optional ai_explain parameter
    opts =
      if Map.has_key?(params, "ai_explain") do
        Keyword.put(opts, :ai_explain, params["ai_explain"])
      else
        opts
      end

    # Add optional surrounding_lines parameter
    opts =
      if Map.has_key?(params, "surrounding_lines") do
        Keyword.put(opts, :surrounding_lines, params["surrounding_lines"])
      else
        opts
      end

    case ValidationAI.validate_with_explanation(content, opts) do
      {:ok, :valid} ->
        {:ok, %{status: "valid", message: "Code is syntactically correct"}}

      {:ok, :no_validator} ->
        {:ok,
         %{
           status: "no_validator",
           message: "No validator available for this language",
           path: opts[:path]
         }}

      {:error, errors} ->
        formatted_errors =
          Enum.map(errors, fn error ->
            base = %{
              message: error[:message],
              line: error[:line],
              column: error[:column]
            }

            # Add AI fields if present
            base
            |> maybe_add_field(:ai_explanation, error[:ai_explanation])
            |> maybe_add_field(:ai_suggestion, error[:ai_suggestion])
            |> maybe_add_field(:ai_generated_at, error[:ai_generated_at])
          end)

        {:ok,
         %{
           status: "invalid",
           error_count: length(errors),
           errors: formatted_errors,
           ai_enabled: ValidationAI.enabled?(opts)
         }}
    end
  end

  defp validate_with_ai_tool(_), do: {:error, "Missing required 'content' parameter"}

  defp maybe_add_field(map, _key, nil), do: map
  defp maybe_add_field(map, key, value), do: Map.put(map, key, value)

  defp parse_suggestion_target(target_str) do
    cond do
      # File path
      String.ends_with?(target_str, [".ex", ".exs", ".erl", ".py", ".js", ".ts"]) ->
        target_str

      # Directory path (contains /)
      String.contains?(target_str, "/") ->
        target_str

      # Module or function reference
      String.contains?(target_str, ".") or String.contains?(target_str, "/") ->
        case parse_target_string(target_str) do
          {:ok, parsed} -> parsed
          _ -> target_str
        end

      # Module name
      true ->
        try do
          module = String.to_existing_atom("Elixir." <> target_str)
          {:module, module}
        rescue
          ArgumentError -> target_str
        end
    end
  end

  defp format_suggestions_result(result, "json") do
    {:ok,
     %{
       status: "success",
       target: inspect(result.target),
       analyzed_at: DateTime.to_iso8601(result.analyzed_at),
       summary: result.summary,
       suggestions:
         Enum.map(result.suggestions, fn sugg ->
           %{
             id: sugg.id,
             pattern: Atom.to_string(sugg.pattern),
             priority: Atom.to_string(sugg.priority),
             priority_score: sugg.priority_score,
             confidence: sugg.confidence,
             target: sugg.target,
             reason: sugg.reason,
             metrics: sugg.metrics,
             impact: sugg.impact,
             effort: sugg.effort,
             benefit: sugg.benefit,
             rag_advice: sugg.rag_advice,
             action_plan: sugg.action_plan
           }
         end)
     }}
  end

  defp format_suggestions_result(result, "detailed") do
    suggestions_text =
      Enum.map_join(result.suggestions, "\n", fn sugg ->
        action_text =
          if sugg.action_plan do
            steps =
              sugg.action_plan.steps
              |> Enum.map_join("\n", fn step ->
                "      #{step.order}. #{step.action} (#{step.estimated_time})"
              end)

            "\n    Action Plan (#{sugg.action_plan.total_steps} steps):\n#{steps}"
          else
            ""
          end

        rag_text =
          if sugg.rag_advice do
            "\n    AI Advice:\n      #{sugg.rag_advice}"
          else
            ""
          end

        """
        #{sugg.id}
          Pattern: #{sugg.pattern}
          Priority: #{sugg.priority} (score: #{sugg.priority_score})
          Confidence: #{Float.round(sugg.confidence, 2)}
          Reason: #{sugg.reason}
          Benefit: #{sugg.benefit}#{action_text}#{rag_text}
        """
      end)

    content = """
    Refactoring Suggestions
    ======================
    Target: #{inspect(result.target)}
    Total Suggestions: #{result.summary.total}
    Average Score: #{result.summary.average_score}

    By Priority:
    #{format_priority_counts(result.summary.by_priority)}

    By Pattern:
    #{format_pattern_counts(result.summary.by_pattern)}

    Suggestions:
    #{suggestions_text}
    """

    {:ok, %{status: "success", content: String.trim(content)}}
  end

  defp format_suggestions_result(result, "summary") do
    top_suggestions =
      result.suggestions
      |> Enum.take(5)
      |> Enum.map_join("\n", fn sugg ->
        "  - [#{sugg.priority}] #{sugg.pattern}: #{sugg.reason}"
      end)

    content = """
    Suggestions for #{inspect(result.target)}
    Total: #{result.summary.total} | Avg Score: #{result.summary.average_score}
    High Priority: #{Map.get(result.summary.by_priority, :critical, 0) + Map.get(result.summary.by_priority, :high, 0)}

    Top Suggestions:
    #{top_suggestions}
    """

    {:ok, %{status: "success", summary: String.trim(content)}}
  end

  defp format_priority_counts(counts) do
    [:critical, :high, :medium, :low, :info]
    |> Enum.map_join("\n", fn priority ->
      count = Map.get(counts, priority, 0)
      "  #{priority}: #{count}"
    end)
  end

  defp format_pattern_counts(counts) do
    counts
    |> Enum.map_join("\n", fn {pattern, count} ->
      "  #{pattern}: #{count}"
    end)
  end

  # Security Analysis Tools - Phase 1

  defp scan_security_tool(%{"path" => path} = params) do
    recursive = Map.get(params, "recursive", true)
    min_severity = Map.get(params, "min_severity", "low") |> String.to_atom()
    categories = Map.get(params, "categories", [])

    opts = [
      recursive: recursive,
      min_severity: min_severity
    ]

    opts =
      if categories != [] do
        Keyword.put(opts, :categories, Enum.map(categories, &String.to_atom/1))
      else
        opts
      end

    result =
      if File.dir?(path) do
        case Security.analyze_directory(path, opts) do
          {:ok, results} ->
            total_vulns = Enum.sum(Enum.map(results, & &1.total_vulnerabilities))
            files_with_vulns = Enum.count(results, & &1.has_vulnerabilities?)

            severity_counts =
              results
              |> Enum.flat_map(& &1.vulnerabilities)
              |> Enum.reduce(%{}, fn vuln, acc ->
                Map.update(acc, vuln.severity, 1, &(&1 + 1))
              end)

            all_vulns = Enum.flat_map(results, & &1.vulnerabilities)

            %{
              status: "success",
              scan_type: "directory",
              path: path,
              total_files: length(results),
              files_with_vulnerabilities: files_with_vulns,
              total_vulnerabilities: total_vulns,
              severity_counts: severity_counts,
              vulnerabilities:
                Enum.map(all_vulns, fn vuln ->
                  %{
                    file: vuln.file,
                    category: vuln.category,
                    severity: vuln.severity,
                    description: vuln.description,
                    recommendation: vuln.recommendation,
                    cwe: vuln.cwe,
                    context: vuln.context
                  }
                end)
            }

          {:error, reason} ->
            %{status: "error", error: inspect(reason)}
        end
      else
        case Security.analyze_file(path, opts) do
          {:ok, result} ->
            %{
              status: "success",
              scan_type: "file",
              path: path,
              has_vulnerabilities: result.has_vulnerabilities?,
              total_vulnerabilities: result.total_vulnerabilities,
              severity_counts: %{
                critical: result.critical_count,
                high: result.high_count,
                medium: result.medium_count,
                low: result.low_count
              },
              vulnerabilities:
                Enum.map(result.vulnerabilities, fn vuln ->
                  %{
                    category: vuln.category,
                    severity: vuln.severity,
                    description: vuln.description,
                    recommendation: vuln.recommendation,
                    cwe: vuln.cwe,
                    context: vuln.context
                  }
                end)
            }

          {:error, reason} ->
            %{status: "error", error: inspect(reason)}
        end
      end

    {:ok, result}
  end

  defp security_audit_tool(%{"path" => path} = params) do
    format = Map.get(params, "format", "text")
    min_severity = Map.get(params, "min_severity", "low") |> String.to_atom()

    opts = [
      recursive: true,
      min_severity: min_severity
    ]

    case Security.analyze_directory(path, opts) do
      {:ok, results} ->
        report = Security.audit_report(results)

        result =
          case format do
            "json" ->
              %{
                status: "success",
                format: "json",
                report: %{
                  total_files: report.total_files,
                  files_with_vulnerabilities: report.files_with_vulnerabilities,
                  by_severity: format_severity_groups(report.by_severity),
                  by_category: format_category_groups(report.by_category),
                  by_file:
                    Enum.map(report.by_file, fn {file, vulns} ->
                      {file, length(vulns)}
                    end)
                    |> Map.new(),
                  recommendations:
                    Enum.map(report.recommendations, fn rec ->
                      %{
                        category: rec.category,
                        count: rec.count,
                        severity: rec.severity,
                        recommendation: rec.recommendation
                      }
                    end)
                }
              }

            "markdown" ->
              md_content = format_audit_markdown(report)
              %{status: "success", format: "markdown", content: md_content}

            _ ->
              # text format
              %{status: "success", format: "text", content: report.summary}
          end

        {:ok, result}

      {:error, reason} ->
        {:ok, %{status: "error", error: inspect(reason)}}
    end
  end

  defp check_secrets_tool(%{"path" => path} = params) do
    recursive = Map.get(params, "recursive", true)

    opts = [
      recursive: recursive,
      categories: [:hardcoded_secret]
    ]

    result =
      if File.dir?(path) do
        case Security.analyze_directory(path, opts) do
          {:ok, results} ->
            secrets =
              results
              |> Enum.flat_map(fn result ->
                Enum.map(result.vulnerabilities, fn vuln ->
                  %{
                    file: vuln.file,
                    description: vuln.description,
                    context: vuln.context
                  }
                end)
              end)

            %{
              status: "success",
              path: path,
              total_secrets: length(secrets),
              secrets: secrets
            }

          {:error, reason} ->
            %{status: "error", error: inspect(reason)}
        end
      else
        case Security.analyze_file(path, opts) do
          {:ok, result} ->
            secrets =
              Enum.map(result.vulnerabilities, fn vuln ->
                %{
                  description: vuln.description,
                  context: vuln.context
                }
              end)

            %{
              status: "success",
              path: path,
              total_secrets: length(secrets),
              secrets: secrets
            }

          {:error, reason} ->
            %{status: "error", error: inspect(reason)}
        end
      end

    {:ok, result}
  end

  # Code Smells Analysis Tool - Phase 3

  defp detect_smells_tool(%{"path" => path} = params) do
    recursive = Map.get(params, "recursive", true)
    min_severity = Map.get(params, "min_severity", "low") |> String.to_atom()
    thresholds = Map.get(params, "thresholds", %{})
    smell_types = Map.get(params, "smell_types", [])

    # Convert string keys to atoms for thresholds
    thresholds =
      thresholds
      |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
      |> Map.new()

    opts = [
      recursive: recursive,
      min_severity: min_severity,
      thresholds: thresholds
    ]

    result =
      if File.dir?(path) do
        case Smells.analyze_directory(path, opts) do
          {:ok, dir_result} ->
            # Filter by smell types if specified
            filtered_results =
              if smell_types != [] do
                smell_types_atoms = Enum.map(smell_types, &String.to_atom/1)

                dir_result.results
                |> Enum.map(fn result ->
                  filtered_smells =
                    Enum.filter(result.smells, &(&1.type in smell_types_atoms))

                  %{result | smells: filtered_smells, total_smells: length(filtered_smells)}
                end)
                |> Enum.reject(&(&1.total_smells == 0))
              else
                dir_result.results
              end

            total_smells = Enum.sum(Enum.map(filtered_results, & &1.total_smells))

            by_severity =
              filtered_results
              |> Enum.flat_map(& &1.smells)
              |> Enum.reduce(%{}, fn smell, acc ->
                Map.update(acc, smell.severity, 1, &(&1 + 1))
              end)

            by_type =
              filtered_results
              |> Enum.flat_map(& &1.smells)
              |> Enum.reduce(%{}, fn smell, acc ->
                Map.update(acc, smell.type, 1, &(&1 + 1))
              end)

            all_smells =
              filtered_results
              |> Enum.flat_map(fn result ->
                Enum.map(result.smells, fn smell ->
                  %{
                    file: result.path,
                    type: smell.type,
                    severity: smell.severity,
                    description: smell.description,
                    suggestion: smell.suggestion,
                    context: smell.context
                  }
                end)
              end)

            %{
              status: "success",
              scan_type: "directory",
              path: path,
              total_files: length(filtered_results),
              files_with_smells: length(filtered_results),
              total_smells: total_smells,
              by_severity: by_severity,
              by_type: by_type,
              smells: all_smells,
              summary: dir_result.summary
            }

          {:error, reason} ->
            %{status: "error", error: inspect(reason)}
        end
      else
        case Smells.analyze_file(path, opts) do
          {:ok, result} ->
            # Filter by smell types if specified
            filtered_smells =
              if smell_types != [] do
                smell_types_atoms = Enum.map(smell_types, &String.to_atom/1)
                Enum.filter(result.smells, &(&1.type in smell_types_atoms))
              else
                result.smells
              end

            filtered_smells_len = length(filtered_smells)

            %{
              status: "success",
              scan_type: "file",
              path: path,
              has_smells: filtered_smells_len > 0,
              total_smells: filtered_smells_len,
              by_severity: result.by_severity,
              by_type: result.by_type,
              smells:
                Enum.map(filtered_smells, fn smell ->
                  %{
                    type: smell.type,
                    severity: smell.severity,
                    description: smell.description,
                    suggestion: smell.suggestion,
                    context: smell.context
                  }
                end),
              summary: result.summary
            }

          {:error, reason} ->
            %{status: "error", error: inspect(reason)}
        end
      end

    {:ok, result}
  end

  defp format_severity_groups(by_severity) do
    Enum.map(by_severity, fn {severity, vulns} ->
      {severity, length(vulns)}
    end)
    |> Map.new()
  end

  defp format_category_groups(by_category) do
    Enum.map(by_category, fn {category, vulns} ->
      {category, length(vulns)}
    end)
    |> Map.new()
  end

  defp format_audit_markdown(report) do
    """
    # Security Audit Report

    **Generated**: #{DateTime.to_iso8601(report.timestamp)}

    ## Summary

    - **Total Files Analyzed**: #{report.total_files}
    - **Files with Vulnerabilities**: #{report.files_with_vulnerabilities}

    #{report.summary}

    ## Vulnerabilities by Category

    #{format_category_markdown(report.by_category)}

    ## Recommendations

    #{format_recommendations_markdown(report.recommendations)}
    """
  end

  defp format_category_markdown(by_category) do
    by_category
    |> Enum.map_join("\n", fn {category, vulns} ->
      "### #{category} (#{length(vulns)})"
    end)
  end

  defp format_recommendations_markdown(recommendations) do
    recommendations
    |> Enum.map_join("\n", fn rec ->
      "- **[#{rec.severity}]** #{rec.recommendation}"
    end)
  end
end
