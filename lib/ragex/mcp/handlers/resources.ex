defmodule Ragex.MCP.Handlers.Resources do
  @moduledoc """
  Handles MCP resource-related requests.

  Implements the resources/list and resources/read methods.
  Resources provide read-only access to Ragex's internal state.
  """

  alias Ragex.Embeddings.{Bumblebee, FileTracker, Persistence}
  alias Ragex.Graph.{Algorithms, Store}

  @doc """
  Lists all available resources.

  Returns resource definitions with URIs, names, descriptions, and MIME types.
  """
  def list_resources do
    %{
      resources: [
        %{
          uri: "ragex://graph/stats",
          name: "Graph Statistics",
          description:
            "Comprehensive knowledge graph statistics including node/edge counts, PageRank scores, and centrality metrics",
          mimeType: "application/json"
        },
        %{
          uri: "ragex://cache/status",
          name: "Cache Status",
          description:
            "Embedding cache statistics including hit rates, file tracking status, and disk usage",
          mimeType: "application/json"
        },
        %{
          uri: "ragex://model/config",
          name: "Model Configuration",
          description:
            "Active embedding model configuration including name, dimensions, capabilities, and readiness",
          mimeType: "application/json"
        },
        %{
          uri: "ragex://project/index",
          name: "Project Index",
          description:
            "Index of all tracked files with metadata, language distribution, and LOC statistics",
          mimeType: "application/json"
        },
        %{
          uri: "ragex://algorithms/catalog",
          name: "Algorithm Catalog",
          description:
            "Catalog of available graph algorithms with parameters, complexity, and use cases",
          mimeType: "application/json"
        },
        %{
          uri: "ragex://analysis/summary",
          name: "Analysis Summary",
          description:
            "Pre-computed analysis summary including key modules, architectural insights, and community structure",
          mimeType: "application/json"
        }
      ]
    }
  end

  @doc """
  Reads a resource by URI.

  Returns `{:ok, contents}` on success or `{:error, reason}` on failure.
  """
  def read_resource(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "ragex", host: category, path: "/" <> resource} ->
        read_resource_by_category(category, resource)

      %URI{scheme: "ragex", host: category, path: nil} ->
        {:error, "Resource path required. Use format: ragex://#{category}/<resource>"}

      %URI{scheme: "ragex"} ->
        {:error, "Invalid resource URI format. Expected: ragex://<category>/<resource>"}

      _ ->
        {:error, "Invalid URI scheme. Expected 'ragex://'"}
    end
  end

  def read_resource(_), do: {:error, "URI must be a string"}

  # Private functions

  defp read_resource_by_category(category, resource) do
    case {category, resource} do
      {"graph", "stats"} -> read_graph_stats()
      {"cache", "status"} -> read_cache_status()
      {"model", "config"} -> read_model_config()
      {"project", "index"} -> read_project_index()
      {"algorithms", "catalog"} -> read_algorithms_catalog()
      {"analysis", "summary"} -> read_analysis_summary()
      _ -> {:error, "Unknown resource: #{category}/#{resource}"}
    end
  end

  defp read_graph_stats do
    stats = Algorithms.graph_stats()
    centrality = Algorithms.degree_centrality()

    # Get top nodes by centrality
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

    result = %{
      node_count: stats.node_count,
      node_counts_by_type: stats.node_counts_by_type,
      edge_count: stats.edge_count,
      average_degree: stats.average_degree,
      density: stats.density,
      top_by_pagerank: top_by_pagerank,
      top_by_degree: top_by_degree
    }

    {:ok, result}
  end

  defp read_cache_status do
    # Get persistence stats
    persistence_result = Persistence.stats()

    # Get file tracker stats
    tracker_stats = FileTracker.stats()

    # Get stale entities (changed files)
    stale_entities = FileTracker.get_stale_entities()

    result =
      case persistence_result do
        {:ok, cache_info} ->
          %{
            cache_enabled: true,
            cache_file: cache_info.cache_path,
            cache_size_bytes: cache_info.file_size,
            cache_valid: cache_info.valid?,
            embeddings_count:
              if(cache_info.metadata, do: cache_info.metadata.entity_count, else: 0),
            model_name:
              if(cache_info.metadata, do: Atom.to_string(cache_info.metadata.model_id), else: nil),
            last_saved: if(cache_info.metadata, do: cache_info.metadata.timestamp, else: nil),
            tracked_files: tracker_stats.total_files,
            changed_files: tracker_stats.changed_files,
            unchanged_files: tracker_stats.unchanged_files,
            stale_entities_count: length(stale_entities)
          }

        {:error, :not_found} ->
          %{
            cache_enabled: false,
            cache_file: nil,
            cache_size_bytes: 0,
            cache_valid: false,
            embeddings_count: 0,
            model_name: nil,
            last_saved: nil,
            tracked_files: tracker_stats.total_files,
            changed_files: tracker_stats.changed_files,
            unchanged_files: tracker_stats.unchanged_files,
            stale_entities_count: length(stale_entities)
          }

        _ ->
          %{
            cache_enabled: false,
            error: "Unable to retrieve cache status",
            tracked_files: tracker_stats.total_files
          }
      end

    {:ok, result}
  end

  defp read_model_config do
    model_info = Bumblebee.model_info()

    result = %{
      model_name: model_info.name,
      dimensions: model_info.dimensions,
      ready: Bumblebee.ready?(),
      memory_usage_mb: estimate_memory_usage(model_info),
      capabilities: %{
        supports_batch: true,
        supports_normalization: true,
        local_inference: true
      },
      parameters: %{
        max_sequence_length: model_info.max_length || 512,
        pooling: model_info.pooling || "mean"
      }
    }

    {:ok, result}
  end

  defp read_project_index do
    # Get all tracked files from FileTracker
    tracked_files = FileTracker.list_tracked_files()

    # Calculate language distribution
    language_distribution =
      tracked_files
      |> Enum.map(fn {path, _meta} -> detect_language(path) end)
      |> Enum.frequencies()

    # Get recently changed files (files that are stale)
    tracker_stats = FileTracker.stats()

    changed_files_list =
      tracked_files
      |> Enum.filter(fn {file_path, _metadata} ->
        case FileTracker.has_changed?(file_path) do
          {:changed, _} -> true
          _ -> false
        end
      end)
      |> Enum.take(10)
      |> Enum.map(fn {path, _} -> path end)

    # Calculate total nodes in graph
    graph_stats = Store.stats()

    result = %{
      total_files: length(tracked_files),
      tracked_files: Enum.take(tracked_files, 100) |> Enum.map(&format_file_info/1),
      language_distribution: language_distribution,
      recently_changed: changed_files_list,
      changed_files_count: tracker_stats.changed_files,
      total_entities: graph_stats.nodes,
      entities_by_type: calculate_entity_counts()
    }

    {:ok, result}
  end

  defp read_algorithms_catalog do
    result = %{
      algorithms: [
        %{
          name: "pagerank",
          category: "centrality",
          description: "Importance scoring based on call relationships",
          parameters: %{
            damping: %{type: "float", default: 0.85, description: "Damping factor"},
            max_iterations: %{type: "integer", default: 100, description: "Maximum iterations"}
          },
          complexity: "O(k * (n + m)) where k is iterations, n is nodes, m is edges",
          use_cases: [
            "Identify most important functions in codebase",
            "Find architectural entry points",
            "Prioritize refactoring efforts"
          ]
        },
        %{
          name: "betweenness_centrality",
          category: "centrality",
          description: "Identify bridge/bottleneck functions using Brandes' algorithm",
          parameters: %{
            max_nodes: %{type: "integer", default: 1000, description: "Limit computation nodes"},
            normalize: %{type: "boolean", default: true, description: "Normalize scores"}
          },
          complexity: "O(nm) for unweighted graphs",
          use_cases: [
            "Find critical functions that many paths pass through",
            "Identify refactoring bottlenecks",
            "Discover architectural bridges"
          ]
        },
        %{
          name: "closeness_centrality",
          category: "centrality",
          description: "Identify central functions based on average distance",
          parameters: %{
            normalize: %{type: "boolean", default: true, description: "Normalize scores"}
          },
          complexity: "O(nm) for unweighted graphs",
          use_cases: [
            "Find functions with shortest average path to all others",
            "Identify architectural hubs",
            "Discover utility functions"
          ]
        },
        %{
          name: "degree_centrality",
          category: "centrality",
          description: "Count incoming/outgoing edges per node",
          parameters: %{},
          complexity: "O(m) where m is edges",
          use_cases: [
            "Find most-called functions (in-degree)",
            "Find functions that call many others (out-degree)",
            "Simple complexity metric"
          ]
        },
        %{
          name: "find_paths",
          category: "traversal",
          description: "Find all paths between two functions using DFS",
          parameters: %{
            from: %{type: "string", required: true, description: "Source node ID"},
            to: %{type: "string", required: true, description: "Target node ID"},
            max_depth: %{type: "integer", default: 10, description: "Maximum path length"},
            max_paths: %{type: "integer", default: 100, description: "Maximum paths to return"}
          },
          complexity: "O(n!) worst case, early stopping with max_paths",
          use_cases: [
            "Understand call chains between functions",
            "Trace execution flow",
            "Impact analysis"
          ]
        },
        %{
          name: "detect_communities",
          category: "clustering",
          description: "Detect communities using Louvain or Label Propagation",
          parameters: %{
            algorithm: %{
              type: "string",
              default: "louvain",
              enum: ["louvain", "label_propagation"],
              description: "Algorithm choice"
            },
            max_iterations: %{type: "integer", default: 10, description: "Maximum iterations"},
            resolution: %{
              type: "float",
              default: 1.0,
              description: "Resolution parameter (Louvain)"
            },
            hierarchical: %{
              type: "boolean",
              default: false,
              description: "Return hierarchy (Louvain)"
            }
          },
          complexity: "O(m log n) for Louvain, O(m) per iteration for Label Propagation",
          use_cases: [
            "Discover architectural modules",
            "Identify tightly-coupled code clusters",
            "Guide refactoring into separate modules"
          ]
        }
      ]
    }

    {:ok, result}
  end

  defp read_analysis_summary do
    # Get graph stats
    stats = Algorithms.graph_stats()

    # Detect communities
    communities = Algorithms.detect_communities(max_iterations: 5)

    # Get betweenness for bottlenecks
    betweenness =
      Algorithms.betweenness_centrality(max_nodes: 100, normalize: true)
      |> Enum.sort_by(fn {_node, score} -> -score end)
      |> Enum.take(5)
      |> Enum.map(fn {node, score} ->
        %{node_id: format_node_id(node), betweenness_score: Float.round(score, 6)}
      end)

    # Format communities summary
    community_summary =
      communities
      |> Enum.map(fn {comm_id, nodes} ->
        %{
          community_id: inspect(comm_id),
          size: length(nodes),
          sample_members: Enum.take(nodes, 5) |> Enum.map(&format_node_id/1)
        }
      end)
      |> Enum.sort_by(& &1.size, :desc)
      |> Enum.take(10)

    result = %{
      overview: %{
        total_nodes: stats.node_count,
        total_edges: stats.edge_count,
        average_degree: stats.average_degree,
        density: stats.density
      },
      key_modules:
        Enum.map(stats.top_nodes, fn {node, score} ->
          %{node_id: format_node_id(node), importance: Float.round(score, 6)}
        end),
      bottlenecks: betweenness,
      communities: community_summary,
      community_count: length(communities)
    }

    {:ok, result}
  end

  # Helper functions

  defp format_node_id(id) when is_atom(id), do: Atom.to_string(id)

  defp format_node_id({module, name, arity}) when is_atom(module) and is_atom(name) do
    "#{Atom.to_string(module)}.#{Atom.to_string(name)}/#{arity}"
  end

  defp format_node_id({:module, id}), do: "module:#{format_node_id(id)}"
  defp format_node_id({:function, mod, name, arity}), do: format_node_id({mod, name, arity})
  defp format_node_id(id), do: inspect(id)

  defp estimate_memory_usage(model_info) do
    # Rough estimate: ~400MB for all-MiniLM-L6-v2
    name = model_info.name

    cond do
      String.contains?(name, "MiniLM") -> 400
      String.contains?(name, "base") -> 500
      String.contains?(name, "large") -> 1200
      true -> 400
    end
  end

  defp detect_language(file_path) do
    case Path.extname(file_path) do
      ext when ext in [".ex", ".exs"] -> "elixir"
      ext when ext in [".erl", ".hrl"] -> "erlang"
      ".py" -> "python"
      ext when ext in [".js", ".jsx", ".mjs"] -> "javascript"
      ext when ext in [".ts", ".tsx"] -> "typescript"
      _ -> "unknown"
    end
  end

  defp format_file_info({path, metadata}) do
    %{
      path: path,
      content_hash: Base.encode16(metadata.content_hash, case: :lower),
      analyzed_at: metadata.analyzed_at,
      size_bytes: metadata.size,
      language: detect_language(path)
    }
  end

  defp calculate_entity_counts do
    # Get counts by node type
    module_count = Store.count_nodes_by_type(:module)
    function_count = Store.count_nodes_by_type(:function)

    %{
      modules: module_count,
      functions: function_count
    }
  end
end
