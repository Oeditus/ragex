defmodule Ragex.Graph.Persistence do
  @moduledoc """
  Persistence layer for the knowledge graph (nodes and edges).

  Saves and loads graph structure to/from disk using ETS serialization,
  complementing the embedding persistence in `Ragex.Embeddings.Persistence`.

  Graph data is stored at `~/.cache/ragex/<project_hash>/graph.ets`.

  ## Usage

      # Save graph (called automatically on shutdown)
      {:ok, path} = Graph.Persistence.save()

      # Load graph (called automatically on startup)
      {:ok, %{nodes: 500, edges: 2000}} = Graph.Persistence.load()

      # Check if cache exists and is valid
      Graph.Persistence.cache_valid?()
  """

  require Logger

  alias Ragex.Embeddings.Persistence, as: EmbeddingsPersistence

  @version 1
  @cache_file_name "graph.ets"

  @nodes_table :ragex_nodes
  @edges_table :ragex_edges

  @doc """
  Saves graph nodes and edges to disk.

  ## Returns

  - `{:ok, path}` - Cache file path
  - `{:error, reason}` - Failure
  """
  @spec save() :: {:ok, Path.t()} | {:error, term()}
  def save do
    cache_path = get_cache_path()
    cache_dir = Path.dirname(cache_path)

    File.mkdir_p!(cache_dir)

    nodes = :ets.tab2list(@nodes_table)
    edges = :ets.tab2list(@edges_table)

    metadata = %{
      version: @version,
      timestamp: System.system_time(:second),
      node_count: length(nodes),
      edge_count: length(edges)
    }

    data = %{
      metadata: metadata,
      nodes: nodes,
      edges: edges
    }

    binary = :erlang.term_to_binary(data, [:compressed])
    File.write!(cache_path, binary)

    Logger.info(
      "Saved graph to cache: #{length(nodes)} nodes, #{length(edges)} edges (#{cache_path})"
    )

    {:ok, cache_path}
  rescue
    e ->
      Logger.error("Failed to save graph cache: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  @doc """
  Loads graph nodes and edges from disk.

  ## Returns

  - `{:ok, %{nodes: count, edges: count}}` - Loaded successfully
  - `{:error, :not_found}` - No cache file
  - `{:error, reason}` - Failure
  """
  @spec load() :: {:ok, map()} | {:error, term()}
  def load do
    cache_path = get_cache_path()

    if File.exists?(cache_path) do
      do_load(cache_path)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Checks if a valid graph cache exists.
  """
  @spec cache_valid?() :: boolean()
  def cache_valid? do
    cache_path = get_cache_path()

    if File.exists?(cache_path) do
      case read_metadata(cache_path) do
        {:ok, %{version: @version}} -> true
        _ -> false
      end
    else
      false
    end
  end

  @doc """
  Returns statistics about the graph cache.
  """
  @spec stats() :: {:ok, map()} | {:error, term()}
  def stats do
    cache_path = get_cache_path()

    if File.exists?(cache_path) do
      stat = File.stat!(cache_path)

      case read_metadata(cache_path) do
        {:ok, metadata} ->
          {:ok,
           %{
             cache_path: cache_path,
             file_size: stat.size,
             metadata: metadata
           }}

        error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Clears the graph cache for the current project.
  """
  @spec clear() :: :ok
  def clear do
    cache_path = get_cache_path()

    if File.exists?(cache_path) do
      File.rm!(cache_path)
      Logger.info("Cleared graph cache: #{cache_path}")
    end

    :ok
  end

  # Private functions

  defp do_load(cache_path) do
    binary = File.read!(cache_path)
    data = :erlang.binary_to_term(binary)

    case data do
      %{metadata: %{version: @version}, nodes: nodes, edges: edges} ->
        # Restore nodes
        Enum.each(nodes, fn entry ->
          :ets.insert(@nodes_table, entry)
        end)

        # Restore edges
        Enum.each(edges, fn entry ->
          :ets.insert(@edges_table, entry)
        end)

        node_count = length(nodes)
        edge_count = length(edges)

        Logger.info("Loaded graph from cache: #{node_count} nodes, #{edge_count} edges")
        {:ok, %{nodes: node_count, edges: edge_count}}

      %{metadata: %{version: version}} ->
        Logger.warning("Graph cache version mismatch: expected #{@version}, got #{version}")
        {:error, :version_mismatch}

      _ ->
        Logger.warning("Invalid graph cache format")
        {:error, :invalid_format}
    end
  rescue
    e ->
      Logger.error("Failed to load graph cache: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp read_metadata(cache_path) do
    binary = File.read!(cache_path)

    case :erlang.binary_to_term(binary) do
      %{metadata: metadata} -> {:ok, metadata}
      _ -> {:error, :no_metadata}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp get_cache_path do
    cache_dir =
      Application.get_env(:ragex, :cache_root, EmbeddingsPersistence.default_cache_root())

    project_hash = EmbeddingsPersistence.generate_project_hash()

    Path.join([cache_dir, project_hash, @cache_file_name])
  end
end
