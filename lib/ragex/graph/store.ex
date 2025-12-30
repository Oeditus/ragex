defmodule Ragex.Graph.Store do
  @moduledoc """
  Knowledge graph storage using ETS tables.

  Manages nodes (modules, functions, types, etc.) and edges (calls, imports, etc.)
  representing relationships in the codebase.
  """

  use GenServer
  require Logger

  @nodes_table :ragex_nodes
  @edges_table :ragex_edges
  @embeddings_table :ragex_embeddings

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a node to the graph.

  Node types: :module, :function, :type, :variable, :file
  """
  def add_node(node_type, node_id, data) do
    GenServer.call(__MODULE__, {:add_node, node_type, node_id, data})
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

    :ets.match(@nodes_table, pattern)
    |> Enum.take(limit)
    |> Enum.map(fn
      [node_type, node_id, data] -> %{type: node_type, id: node_id, data: data}
      [node_id, data] -> %{type: node_type, id: node_id, data: data}
    end)
  end

  @doc """
  Adds an edge between two nodes.

  Edge types: :calls, :imports, :defines, :inherits, :implements
  """
  def add_edge(from_node, to_node, edge_type) do
    GenServer.call(__MODULE__, {:add_edge, from_node, to_node, edge_type})
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
  Clears all data from the graph.
  """
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Stores an embedding vector for a node.
  """
  def store_embedding(node_type, node_id, embedding, text) do
    GenServer.call(__MODULE__, {:store_embedding, node_type, node_id, embedding, text})
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
    Ragex.Embeddings.FileTracker.init()

    # Attempt to load cached embeddings
    case Ragex.Embeddings.Persistence.load() do
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
  def handle_call({:add_edge, from_node, to_node, edge_type}, _from, state) do
    key = {from_node, to_node, edge_type}
    :ets.insert(@edges_table, {key, %{}})
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
      case Ragex.Embeddings.Persistence.save(@embeddings_table) do
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
