defmodule Ragex.Store.Backend.ETS do
  @moduledoc """
  ETS-backed storage implementation for Ragex's knowledge graph.

  This is the default backend, providing backward-compatible in-memory
  storage using three ETS tables: nodes, edges, and embeddings.
  """

  @behaviour Ragex.Store.Backend

  @nodes_table :ragex_nodes
  @edges_table :ragex_edges
  @embeddings_table :ragex_embeddings

  @functions_limit Application.compile_env(:ragex, :functions_limit, 1_000)
  @nodes_limit Application.compile_env(:ragex, :nodes_limit, 1_000)
  @edges_limit Application.compile_env(:ragex, :edges_limit, 1_000)
  @embeddings_limit Application.compile_env(:ragex, :embeddings_limit, 1_000)

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def bootstrap, do: :ok

  @impl true
  def clear do
    :ets.delete_all_objects(@nodes_table)
    :ets.delete_all_objects(@edges_table)
    :ets.delete_all_objects(@embeddings_table)
    :ok
  end

  @impl true
  def stats do
    %{
      nodes: :ets.info(@nodes_table, :size),
      edges: :ets.info(@edges_table, :size),
      embeddings: :ets.info(@embeddings_table, :size)
    }
  end

  @impl true
  def load_project(_project_path), do: :ok

  # ---------------------------------------------------------------------------
  # Nodes
  # ---------------------------------------------------------------------------

  @impl true
  def store_node(node_type, node_id, data) do
    :ets.insert(@nodes_table, {{node_type, node_id}, data})
    :ok
  end

  @impl true
  def get_node({node_type, node_id}), do: find_node(node_type, node_id)

  @impl true
  def find_node(node_type, node_id) do
    case :ets.lookup(@nodes_table, {node_type, node_id}) do
      [{_key, data}] -> data
      [] -> nil
    end
  end

  @impl true
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
      [node_type_val, node_id, data] -> %{type: node_type_val, id: node_id, data: data}
      [node_id, data] -> %{type: node_type, id: node_id, data: data}
    end)
  end

  @impl true
  def count_nodes_by_type(node_type) do
    pattern = {{node_type, :"$1"}, :"$2"}

    @nodes_table
    |> :ets.match(pattern)
    |> length()
  end

  @impl true
  def find_function(module, name) do
    pattern = {{:function, {module, name, :_}}, :"$1"}

    case :ets.match(@nodes_table, pattern) do
      [[data] | _] -> data
      [] -> nil
    end
  end

  @impl true
  def remove_node(node_type, node_id) do
    node_key = {node_type, node_id}

    edge_identifier =
      case {node_type, node_id} do
        {:function, {mod, name, arity}} -> {:function, mod, name, arity}
        {type, id} -> {type, id}
      end

    :ets.delete(@nodes_table, node_key)

    # Remove outgoing edges
    outgoing_pattern = {{edge_identifier, :"$1", :"$2"}, :"$3"}

    @edges_table
    |> :ets.match(outgoing_pattern)
    |> Enum.each(fn [to_node, edge_type, _metadata] ->
      :ets.delete(@edges_table, {edge_identifier, to_node, edge_type})
    end)

    # Remove incoming edges
    incoming_pattern = {{:"$1", edge_identifier, :"$2"}, :"$3"}

    @edges_table
    |> :ets.match(incoming_pattern)
    |> Enum.each(fn [from_node, edge_type, _metadata] ->
      :ets.delete(@edges_table, {from_node, edge_identifier, edge_type})
    end)

    # Remove embedding
    :ets.delete(@embeddings_table, node_key)
    :ok
  end

  @impl true
  def update_node_metadata(node_type, node_id, new_metadata) when is_map(new_metadata) do
    key = {node_type, node_id}

    case :ets.lookup(@nodes_table, key) do
      [{^key, data}] when is_map(data) ->
        existing_meta = Map.get(data, :metadata, %{})
        merged_meta = Map.merge(existing_meta, new_metadata)
        updated_data = Map.put(data, :metadata, merged_meta)
        :ets.insert(@nodes_table, {key, updated_data})
        :ok

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Edges
  # ---------------------------------------------------------------------------

  @impl true
  def store_edge(from_node, to_node, edge_type, opts \\ []) do
    key = {from_node, to_node, edge_type}
    weight = Keyword.get(opts, :weight, 1.0)
    metadata = Keyword.get(opts, :metadata, %{})
    metadata_with_weight = Map.put(metadata, :weight, weight)
    :ets.insert(@edges_table, {key, metadata_with_weight})
    :ok
  end

  @impl true
  def get_outgoing_edges(from_node, edge_type) do
    pattern = {{from_node, :"$1", edge_type}, :"$2"}

    :ets.match(@edges_table, pattern)
    |> Enum.map(fn [to_node, metadata] ->
      %{to: to_node, type: edge_type, metadata: metadata}
    end)
  end

  @impl true
  def get_incoming_edges(to_node, edge_type) do
    pattern = {{:"$1", to_node, edge_type}, :"$2"}

    :ets.match(@edges_table, pattern)
    |> Enum.map(fn [from_node, metadata] ->
      %{from: from_node, type: edge_type, metadata: metadata}
    end)
  end

  @impl true
  def get_edge_weight(from_node, to_node, edge_type) do
    case :ets.lookup(@edges_table, {from_node, to_node, edge_type}) do
      [{_key, metadata}] -> Map.get(metadata, :weight, 1.0)
      [] -> nil
    end
  end

  @impl true
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
      [from_node, to_node, et, metadata] ->
        %{from: from_node, to: to_node, type: et, metadata: metadata}

      [from_node, to_node, metadata] ->
        %{from: from_node, to: to_node, type: edge_type, metadata: metadata}
    end)
  end

  # ---------------------------------------------------------------------------
  # Embeddings
  # ---------------------------------------------------------------------------

  @impl true
  def store_embedding(node_type, node_id, embedding, text) do
    key = {node_type, node_id}
    :ets.insert(@embeddings_table, {key, embedding, text})
    :ok
  end

  @impl true
  def get_embedding(node_type, node_id) do
    case :ets.lookup(@embeddings_table, {node_type, node_id}) do
      [{_key, embedding, text}] -> {embedding, text}
      [] -> nil
    end
  end

  @impl true
  def count_embeddings do
    case :ets.info(@embeddings_table, :size) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  @impl true
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
      [node_type_val, node_id, embedding, text] -> {node_type_val, node_id, embedding, text}
      [node_id, embedding, text] -> {node_type, node_id, embedding, text}
    end)
  end

  # ---------------------------------------------------------------------------
  # Vector search (brute-force cosine similarity)
  # ---------------------------------------------------------------------------

  @impl true
  def search_vectors(query_embedding, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.0)
    node_type_filter = Keyword.get(opts, :node_type)

    embeddings =
      case node_type_filter do
        nil -> list_embeddings()
        type -> list_embeddings(type)
      end

    embeddings
    |> Task.async_stream(
      fn {nt, nid, embedding, text} ->
        score = cosine_similarity(query_embedding, embedding)
        %{node_type: nt, node_id: nid, score: score, text: text, embedding: embedding}
      end,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
    |> Enum.filter(fn result -> result.score >= threshold end)
    |> Enum.sort_by(fn result -> result.score end, :desc)
    |> Enum.take(limit)
  end

  # ---------------------------------------------------------------------------
  # Table accessors (for persistence modules)
  # ---------------------------------------------------------------------------

  @doc false
  def nodes_table, do: @nodes_table
  @doc false
  def edges_table, do: @edges_table
  @doc false
  def embeddings_table, do: @embeddings_table
  @doc false
  def functions_limit, do: @functions_limit

  # ---------------------------------------------------------------------------
  # Vector math
  # ---------------------------------------------------------------------------

  defp cosine_similarity(vec1, vec2) do
    dot = dot_product(vec1, vec2)
    mag1 = magnitude(vec1)
    mag2 = magnitude(vec2)

    if mag1 == 0.0 or mag2 == 0.0 do
      0.0
    else
      dot / (mag1 * mag2)
    end
  end

  defp dot_product(vec1, vec2) do
    Enum.zip(vec1, vec2) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
  end

  defp magnitude(vec) do
    vec |> Enum.map(fn x -> x * x end) |> Enum.sum() |> :math.sqrt()
  end
end
