defmodule Ragex.Graph.Store do
  @moduledoc """
  Knowledge graph storage using ETS tables.

  Manages nodes (modules, functions, types, etc.) and edges (calls, imports, etc.)
  representing relationships in the codebase.
  """

  use GenServer
  require Logger

  alias Ragex.Embeddings.{FileTracker, Persistence}
  alias Ragex.Graph.Persistence, as: GraphPersistence

  @nodes_table :ragex_nodes
  @edges_table :ragex_edges
  @embeddings_table :ragex_embeddings

  _timeout =
    :ragex
    |> Application.compile_env(:timeouts, [])
    |> Keyword.get(:store, :infinity)

  @functions_limit Application.compile_env(:ragex, :functions_limit, 1_000)
  @nodes_limit Application.compile_env(:ragex, :nodes_limit, 1_000)
  @edges_limit Application.compile_env(:ragex, :edges_limit, 1_000)
  @embeddings_limit Application.compile_env(:ragex, :embeddings_limit, 1_000)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a node to the graph.

  Node types: :module, :function, :type, :variable, :file
  """
  def add_node(node_type, node_id, data) do
    GenServer.cast(__MODULE__, {:add_node, node_type, node_id, data})
  end

  @doc """
  Retrieves a node by its composite key.

  ## Parameters
  - `node_key` - Tuple of `{node_type, node_id}`

  ## Returns
  - Node data map if found
  - `nil` if not found

  ## Examples

      iex> Store.add_node(:module, MyModule, %{name: MyModule})
      iex> Store.get_node({:module, MyModule})
      %{name: MyModule}

      iex> Store.get_node({:module, NonExistent})
      nil
  """
  def get_node({node_type, node_id}) do
    find_node(node_type, node_id)
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
  Retrieves a function node by module, name, and arity.

  Returns the function data or nil if not found.

  ## Parameters
  - `module` - The module containing the function
  - `name` - The function name (atom)
  - `arity` - The function arity (non-negative integer)

  ## Examples

      iex> Store.add_node(:function, {MyModule, :test, 2}, %{name: :test, arity: 2})
      iex> Store.get_function(MyModule, :test, 2)
      %{name: :test, arity: 2}

      iex> Store.get_function(MyModule, :nonexistent, 1)
      nil
  """
  def get_function(module, name, arity) do
    find_node(:function, {module, name, arity})
  end

  @doc """
  Retrieves a module node by name.

  Returns the module data or nil if not found.

  ## Examples

      iex> Store.add_node(:module, MyModule, %{name: MyModule, file: "lib/my_module.ex"})
      iex> Store.get_module(MyModule)
      %{name: MyModule, file: "lib/my_module.ex"}

      iex> Store.get_module(NonExistentModule)
      nil
  """
  def get_module(module) do
    find_node(:module, module)
  end

  @doc """
  Lists all module nodes.

  ## Returns
  List of module maps with keys:
  - `:id` - Module identifier (atom)
  - `:data` - Module data

  ## Examples

      iex> Store.add_node(:module, ModuleA, %{name: ModuleA, file: "lib/a.ex"})
      iex> Store.add_node(:module, ModuleB, %{name: ModuleB, file: "lib/b.ex"})
      iex> Store.list_modules()
      [%{id: ModuleA, data: %{name: ModuleA, file: "lib/a.ex"}}, ...]
  """
  def list_modules do
    :module
    |> list_nodes(:infinity)
    |> Enum.map(&%{id: &1.id, data: &1.data})
  end

  @doc """
  Lists function nodes with optional filtering by module.

  ## Parameters
  - `opts` - Keyword list with options:
    - `:module` - Filter by module (optional)
    - `:limit` - Maximum number of functions to return (default: 1000)

  ## Returns
  List of function maps with keys:
  - `:id` - Function identifier tuple `{module, name, arity}`
  - `:data` - Function data

  ## Examples

      iex> Store.add_node(:function, {MyModule, :test, 2}, %{name: :test, arity: 2})
      iex> Store.list_functions()
      [%{id: {MyModule, :test, 2}, data: %{name: :test, arity: 2}}]

      iex> Store.list_functions(module: MyModule, limit: 50)
      [%{id: {MyModule, :test, 2}, data: ...}, ...]
  """
  def list_functions(opts \\ []) do
    module_filter = Keyword.get(opts, :module)
    limit = Keyword.get(opts, :limit, @functions_limit)

    pattern =
      case module_filter do
        nil -> {{:function, {:"$1", :"$2", :"$3"}}, :"$4"}
        mod -> {{:function, {mod, :"$1", :"$2"}}, :"$3"}
      end

    @nodes_table
    |> :ets.match(pattern)
    |> Enum.take(limit)
    |> Enum.map(fn
      [module, name, arity, data] ->
        %{id: {module, name, arity}, data: data}

      [name, arity, data] ->
        %{id: {module_filter, name, arity}, data: data}
    end)
  end

  @doc """
  Lists nodes with optional filtering by type.
  """
  def list_nodes(node_type \\ nil, limit \\ @nodes_limit) do
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

    @nodes_table
    |> :ets.match(pattern)
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
    GenServer.cast(__MODULE__, {:add_edge, from_node, to_node, edge_type, opts})
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
  Lists all edges with optional filtering by type and limit.

  ## Parameters
  - `opts` - Keyword list with options:
    - `:edge_type` - Filter by edge type (optional)
    - `:limit` - Maximum number of edges to return (default: 1000)

  ## Returns
  List of edge maps with keys:
  - `:from` - Source node
  - `:to` - Target node
  - `:type` - Edge type
  - `:metadata` - Edge metadata including weight

  ## Examples

      iex> Store.list_edges(limit: 100)
      [%{from: node1, to: node2, type: :calls, metadata: %{weight: 1.0}}, ...]

      iex> Store.list_edges(edge_type: :imports)
      [%{from: mod1, to: mod2, type: :imports, metadata: %{weight: 1.0}}, ...]
  """
  def list_edges(opts \\ []) do
    edge_type = Keyword.get(opts, :edge_type)
    limit = Keyword.get(opts, :limit, @edges_limit)

    pattern =
      case edge_type do
        nil -> {{:"$1", :"$2", :"$3"}, :"$4"}
        type -> {{:"$1", :"$2", type}, :"$3"}
      end

    @edges_table
    |> :ets.match(pattern)
    |> Enum.take(limit)
    |> Enum.map(fn
      [from_node, to_node, edge_type, metadata] ->
        %{from: from_node, to: to_node, type: edge_type, metadata: metadata}

      [from_node, to_node, metadata] ->
        %{from: from_node, to: to_node, type: edge_type, metadata: metadata}
    end)
  end

  @doc """
  Removes a node from the graph.

  Also removes all edges connected to this node (both incoming and outgoing)
  and any embedding associated with the node.

  Returns `:ok` if successful, `{:error, :timeout}` on timeout.
  """
  def remove_node(node_type, node_id) do
    GenServer.cast(__MODULE__, {:remove_node, node_type, node_id})
  end

  @doc """
  Clears all data from the graph.
  """
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  @doc """
  Stores an embedding vector for a node.
  """
  def store_embedding(node_type, node_id, embedding, text) do
    GenServer.cast(__MODULE__, {:store_embedding, node_type, node_id, embedding, text})
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
  def list_embeddings(node_type \\ nil, limit \\ @embeddings_limit) do
    pattern =
      case node_type do
        nil -> {{:"$1", :"$2"}, :"$3", :"$4"}
        type -> {{type, :"$1"}, :"$2", :"$3"}
      end

    @embeddings_table
    |> :ets.match(pattern)
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
        Logger.info("Graph store initialized (no embedding cache found)")

      {:error, :incompatible} ->
        Logger.warning("Graph store initialized (cache incompatible with current model)")

      {:error, reason} ->
        Logger.warning("Graph store initialized (failed to load cache: #{inspect(reason)})")
    end

    # Attempt to load cached graph nodes/edges
    case GraphPersistence.load() do
      {:ok, %{nodes: n, edges: e}} ->
        Logger.info("Loaded graph from cache: #{n} nodes, #{e} edges")

      {:error, :not_found} ->
        Logger.debug("No graph cache found")

      {:error, reason} ->
        Logger.warning("Failed to load graph cache: #{inspect(reason)}")
    end

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:add_node, node_type, node_id, data}, state) do
    key = {node_type, node_id}
    :ets.insert(@nodes_table, {key, data})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:add_edge, from_node, to_node, edge_type, opts}, state) do
    key = {from_node, to_node, edge_type}
    weight = Keyword.get(opts, :weight, 1.0)
    metadata = Keyword.get(opts, :metadata, %{})
    metadata_with_weight = Map.put(metadata, :weight, weight)
    :ets.insert(@edges_table, {key, metadata_with_weight})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:store_embedding, node_type, node_id, embedding, text}, state) do
    key = {node_type, node_id}
    :ets.insert(@embeddings_table, {key, embedding, text})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:remove_node, node_type, node_id}, state) do
    node_key = {node_type, node_id}

    # Build edge identifier: edges use tuples like {:module, id} or {:function, mod, name, arity}
    # Node storage uses {node_type, node_id}, but edges flatten function tuples
    edge_identifier =
      case {node_type, node_id} do
        {:function, {mod, name, arity}} -> {:function, mod, name, arity}
        {type, id} -> {type, id}
      end

    # Remove the node itself
    :ets.delete(@nodes_table, node_key)

    # Remove all outgoing edges from this node
    # Pattern: {{edge_identifier, to_node, edge_type}, metadata}
    outgoing_pattern = {{edge_identifier, :"$1", :"$2"}, :"$3"}
    outgoing_matches = :ets.match(@edges_table, outgoing_pattern)

    Enum.each(outgoing_matches, fn [to_node, edge_type, _metadata] ->
      :ets.delete(@edges_table, {edge_identifier, to_node, edge_type})
    end)

    # Remove all incoming edges to this node
    # Pattern: {{from_node, edge_identifier, edge_type}, metadata}
    incoming_pattern = {{:"$1", edge_identifier, :"$2"}, :"$3"}
    incoming_matches = :ets.match(@edges_table, incoming_pattern)

    Enum.each(incoming_matches, fn [from_node, edge_type, _metadata] ->
      :ets.delete(@edges_table, {from_node, edge_identifier, edge_type})
    end)

    # Remove embedding if exists
    :ets.delete(@embeddings_table, node_key)

    {:noreply, state}
  end

  @impl true
  def handle_cast(:clear, state) do
    :ets.delete_all_objects(@nodes_table)
    :ets.delete_all_objects(@edges_table)
    :ets.delete_all_objects(@embeddings_table)
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    # Save to disk on normal shutdown
    if reason == :shutdown or reason == :normal do
      case Persistence.save(@embeddings_table) do
        {:ok, path} ->
          Logger.info("Embeddings saved to #{path}")

        {:error, err} ->
          Logger.error("Failed to save embeddings: #{inspect(err)}")
      end

      case GraphPersistence.save() do
        {:ok, path} ->
          Logger.info("Graph saved to #{path}")

        {:error, err} ->
          Logger.error("Failed to save graph: #{inspect(err)}")
      end
    else
      Logger.warning("Graph store terminating abnormally: #{inspect(reason)}, skipping save")
    end

    # ETS tables are automatically cleaned up
    :ok
  end
end
