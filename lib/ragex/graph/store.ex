defmodule Ragex.Graph.Store do
  @moduledoc """
  Knowledge graph storage using ETS tables.

  Manages nodes (modules, functions, types, etc.) and edges (calls, imports, etc.)
  representing relationships in the codebase.
  """

  use GenServer
  require Logger

  alias Ragex.Embeddings.{FileTracker, Persistence}

  @nodes_table :ragex_nodes
  @edges_table :ragex_edges
  @embeddings_table :ragex_embeddings

  @timeout :ragex
           |> Application.compile_env(:timeouts, [])
           |> Keyword.get(:store, :infinity)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a node to the graph.

  Node types: :module, :function, :type, :variable, :file
  """
  def add_node(node_type, node_id, data) do
    GenServer.call(__MODULE__, {:add_node, node_type, node_id, data}, @timeout)
  catch
    :exit,
    {:timeout, {GenServer, :call, [_pid, {:add_node, ^node_type, ^node_id, ^data}, @timeout]}} ->
      {:error, :timeout}
  end

  @doc """
  Finds a node by type and id.
  """
  def find_node(node_type, node_id) do
    case :ets.lookup(@nodes_table, {node_type, node_id}) do
      [{_key, data}] -> data
      [] -> nil
    end
  end

  @doc """
  Finds a function node by module and name (any arity).
  """
  def find_function(module, name) do
    pattern = {{:function, {module, name, :_}}, :"$1"}

    case :ets.match(@nodes_table, pattern) do
      [[data] | _] -> data
      [] -> nil
    end
  end

  @doc """
  Lists nodes with optional filtering by type.
  """
  def list_nodes(node_type \\ nil, limit \\ 100) do
    pattern =
      case node_type do
        nil -> {{:"$1", :"$2"}, :"$3"}
        type -> {{type, :"$1"}, :"$2"}
      end

    matches = :ets.match(@nodes_table, pattern)

    matches =
      case limit do
        :infinity -> matches
        n when is_integer(n) -> Enum.take(matches, n)
      end

    Enum.map(matches, fn
      [node_type, node_id, data] -> %{type: node_type, id: node_id, data: data}
      [node_id, data] -> %{type: node_type, id: node_id, data: data}
    end)
  end

  @doc """
  Counts nodes of a specific type.
  """
  def count_nodes_by_type(node_type) do
    pattern = {{node_type, :"$1"}, :"$2"}

    :ets.match(@nodes_table, pattern)
    |> length()
  end

  @doc """
  Adds an edge between two nodes.

  Edge types: :calls, :imports, :defines, :inherits, :implements

  ## Options
  - `:weight` - Edge weight (default: 1.0) for weighted graph algorithms
  - `:metadata` - Additional metadata map
  """
  def add_edge(from_node, to_node, edge_type, opts \\ []) do
    GenServer.call(__MODULE__, {:add_edge, from_node, to_node, edge_type, opts}, @timeout)
  catch
    :exit,
    {:timeout,
     {GenServer, :call, [_pid, {:add_edge, ^from_node, ^to_node, ^edge_type, ^opts}, @timeout]}} ->
      {:error, :timeout}
  end

  @doc """
  Gets all outgoing edges from a node of a specific type.
  """
  def get_outgoing_edges(from_node, edge_type) do
    pattern = {{from_node, :"$1", edge_type}, :"$2"}

    :ets.match(@edges_table, pattern)
    |> Enum.map(fn [to_node, metadata] ->
      %{to: to_node, type: edge_type, metadata: metadata}
    end)
  end

  @doc """
  Gets all incoming edges to a node of a specific type.
  """
  def get_incoming_edges(to_node, edge_type) do
    pattern = {{:"$1", to_node, edge_type}, :"$2"}

    :ets.match(@edges_table, pattern)
    |> Enum.map(fn [from_node, metadata] ->
      %{from: from_node, type: edge_type, metadata: metadata}
    end)
  end

  @doc """
  Gets the weight of an edge between two nodes.

  Returns the weight (default: 1.0) if edge exists, nil otherwise.
  """
  def get_edge_weight(from_node, to_node, edge_type) do
    case :ets.lookup(@edges_table, {from_node, to_node, edge_type}) do
      [{_key, metadata}] -> Map.get(metadata, :weight, 1.0)
      [] -> nil
    end
  end

  @doc """
  Clears all data from the graph.
  """
  def clear do
    GenServer.call(__MODULE__, :clear, @timeout)
  catch
    :exit, {:timeout, {GenServer, :call, [_pid, :clear, @timeout]}} ->
      {:error, :timeout}
  end

  @doc """
  Stores an embedding vector for a node.
  """
  def store_embedding(node_type, node_id, embedding, text) do
    GenServer.call(__MODULE__, {:store_embedding, node_type, node_id, embedding, text}, @timeout)
  catch
    :exit,
    {:timeout,
     {GenServer, :call,
      [_pid, {:store_embedding, ^node_type, ^node_id, ^embedding, ^text}, @timeout]}} ->
      {:error, :timeout}
  end

  @doc """
  Retrieves the embedding for a node.

  Returns `{embedding, text}` tuple or `nil` if not found.
  """
  def get_embedding(node_type, node_id) do
    case :ets.lookup(@embeddings_table, {node_type, node_id}) do
      [{_key, embedding, text}] -> {embedding, text}
      [] -> nil
    end
  end

  @doc """
  Lists all embeddings with optional type filter.

  Returns list of `{node_type, node_id, embedding, text}` tuples.
  """
  def list_embeddings(node_type \\ nil, limit \\ 1000) do
    pattern =
      case node_type do
        nil -> {{:"$1", :"$2"}, :"$3", :"$4"}
        type -> {{type, :"$1"}, :"$2", :"$3"}
      end

    :ets.match(@embeddings_table, pattern)
    |> Enum.take(limit)
    |> Enum.map(fn
      [node_type, node_id, embedding, text] -> {node_type, node_id, embedding, text}
      [node_id, embedding, text] -> {node_type, node_id, embedding, text}
    end)
  end

  @doc """
  Returns statistics about the graph.
  """
  def stats do
    %{
      nodes: :ets.info(@nodes_table, :size),
      edges: :ets.info(@edges_table, :size),
      embeddings: :ets.info(@embeddings_table, :size)
    }
  end

  @doc """
  Returns the ETS table reference for embeddings.

  Useful for direct access or persistence operations.
  """
  def embeddings_table, do: @embeddings_table

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@nodes_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@edges_table, [:named_table, :bag, :public, read_concurrency: true])
    :ets.new(@embeddings_table, [:named_table, :set, :public, read_concurrency: true])

    # Initialize file tracker for incremental updates
    FileTracker.init()

    # Attempt to load cached embeddings
    case Persistence.load() do
      {:ok, count} ->
        Logger.info("Graph store initialized with #{count} cached embeddings")

      {:error, :not_found} ->
        Logger.info("Graph store initialized (no cache found)")

      {:error, :incompatible} ->
        Logger.warning("Graph store initialized (cache incompatible with current model)")

      {:error, reason} ->
        Logger.warning("Graph store initialized (failed to load cache: #{inspect(reason)})")
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_node, node_type, node_id, data}, _from, state) do
    key = {node_type, node_id}
    :ets.insert(@nodes_table, {key, data})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add_edge, from_node, to_node, edge_type, opts}, _from, state) do
    key = {from_node, to_node, edge_type}
    weight = Keyword.get(opts, :weight, 1.0)
    metadata = Keyword.get(opts, :metadata, %{})
    metadata_with_weight = Map.put(metadata, :weight, weight)
    :ets.insert(@edges_table, {key, metadata_with_weight})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:store_embedding, node_type, node_id, embedding, text}, _from, state) do
    key = {node_type, node_id}
    :ets.insert(@embeddings_table, {key, embedding, text})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@nodes_table)
    :ets.delete_all_objects(@edges_table)
    :ets.delete_all_objects(@embeddings_table)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(reason, _state) do
    # Save embeddings to disk on normal shutdown
    if reason == :shutdown or reason == :normal do
      case Persistence.save(@embeddings_table) do
        {:ok, path} ->
          Logger.info("Embeddings saved to #{path}")

        {:error, reason} ->
          Logger.error("Failed to save embeddings: #{inspect(reason)}")
      end
    else
      Logger.warning("Graph store terminating abnormally: #{inspect(reason)}, skipping save")
    end

    # ETS tables are automatically cleaned up
    :ok
  end
end
