defmodule Ragex.VectorStore do
  @moduledoc """
  Vector similarity search for code embeddings.

  Provides efficient cosine similarity search over code entity embeddings
  stored in the graph store. Supports filtering by entity type, similarity
  thresholds, and result limits.
  """

  use GenServer
  require Logger

  alias Ragex.Embeddings.Chunker
  alias Ragex.Graph.Store
  alias Ragex.Store.Backend

  @timeout :ragex
           |> Application.compile_env(:timeouts, [])
           |> Keyword.get(:store, :infinity)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Searches for similar code entities based on a query embedding.

  ## Parameters

  - `query_embedding`: List of floats representing the query vector
  - `opts`: Keyword list of options:
    - `:limit` - Maximum results to return (default: 10)
    - `:threshold` - Minimum similarity score 0.0-1.0 (default: 0.0)
    - `:node_type` - Filter by node type (:module, :function, etc.)
    - `:include_chunks` - Include `:chunk` embeddings in search (default: false).
      When true, chunk results include a `:chunk_parent` key with
      `{parent_type, parent_id}` so callers can group by source entity.

  ## Returns

  List of results sorted by similarity (highest first), each containing:
  - `:node_type` - Type of the entity (`:module`, `:function`, or `:chunk`)
  - `:node_id` - ID of the entity (chunk keys are `{parent_type, parent_id, index}`)
  - `:score` - Similarity score (0.0 to 1.0)
  - `:text` - Original text description (chunk text for `:chunk` results)
  - `:embedding` - The embedding vector
  - `:chunk_parent` - `{parent_type, parent_id}` tuple, present only for `:chunk` results

  ## Example

      {:ok, query_emb} = Bumblebee.embed("function to calculate sum")
      results = VectorStore.search(query_emb, limit: 5, threshold: 0.7)

      # Include fine-grained chunk results:
      results = VectorStore.search(query_emb, limit: 10, include_chunks: true)
  """
  def search(query_embedding, opts \\ []) do
    GenServer.call(__MODULE__, {:search, query_embedding, opts}, @timeout)
  catch
    :exit, {:timeout, {GenServer, :call, [_pid, {:search, ^query_embedding, ^opts}, @timeout]}} ->
      {:error, :timeout}
  end

  @doc """
  Finds the k nearest neighbors to a query embedding.

  Similar to `search/2` but always returns exactly k results (or fewer if
  not enough embeddings exist).
  """
  def nearest_neighbors(query_embedding, k, opts \\ []) do
    opts = Keyword.put(opts, :limit, k)
    search(query_embedding, opts)
  end

  @doc """
  Calculates cosine similarity between two embedding vectors.

  Returns a float between -1.0 and 1.0, where 1.0 means identical direction.
  For normalized embeddings (like ours), this is equivalent to dot product.
  """
  def cosine_similarity(vec1, vec2) do
    dot_product = dot_product(vec1, vec2)
    magnitude1 = magnitude(vec1)
    magnitude2 = magnitude(vec2)

    if magnitude1 == 0.0 or magnitude2 == 0.0 do
      0.0
    else
      dot_product / (magnitude1 * magnitude2)
    end
  end

  @doc """
  Returns statistics about the vector store.
  """
  def stats do
    GenServer.call(__MODULE__, :stats, @timeout)
  catch
    :exit, {:timeout, {GenServer, :call, [_pid, :stats, @timeout]}} ->
      {:error, :timeout}
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("Vector store initialized")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:search, query_embedding, opts}, _from, state) do
    result = perform_search(query_embedding, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    # Total vectors come from a backend count (server-side COUNT on dllb),
    # which works even when listing embeddings is not supported by the backend.
    total = Store.count_embeddings()

    # Dimensions are still derived from a sample embedding; backends that do
    # not list embeddings report 0 here (handled separately).
    embeddings = Store.list_embeddings()

    stats = %{
      total_embeddings: total,
      dimensions: if(embeddings != [], do: length(elem(hd(embeddings), 2)), else: 0)
    }

    {:reply, stats, state}
  end

  # Private Functions

  defp perform_search(query_embedding, opts) do
    include_chunks = Keyword.get(opts, :include_chunks, false)
    backend = Backend.module()

    if include_chunks do
      # Run two passes: entity embeddings (excluding chunks) + chunk-only pass.
      limit = Keyword.get(opts, :limit, 10)

      entity_opts =
        opts |> Keyword.delete(:include_chunks) |> Keyword.put(:exclude_node_type, :chunk)

      chunk_opts =
        opts
        |> Keyword.delete(:include_chunks)
        |> Keyword.put(:node_type, :chunk)
        |> Keyword.put(:limit, limit * 2)

      entity_results = backend.search_vectors(query_embedding, entity_opts)

      chunk_results =
        backend.search_vectors(query_embedding, chunk_opts)
        |> Enum.map(&annotate_chunk_parent/1)

      (entity_results ++ chunk_results)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)
    else
      # Default: exclude :chunk node_type so callers don't see raw chunk keys
      # unless they explicitly filtered to a specific type (e.g. :function).
      node_type = Keyword.get(opts, :node_type)

      if node_type == nil do
        opts_no_chunks = Keyword.put(opts, :exclude_node_type, :chunk)
        backend.search_vectors(query_embedding, opts_no_chunks)
      else
        backend.search_vectors(query_embedding, opts)
      end
    end
  end

  defp annotate_chunk_parent(%{node_type: :chunk, node_id: chunk_key} = result) do
    parent = Chunker.parent_of(chunk_key)
    Map.put(result, :chunk_parent, parent)
  end

  defp annotate_chunk_parent(result), do: result

  # Vector math helpers

  defp dot_product(vec1, vec2) do
    Enum.zip(vec1, vec2)
    |> Enum.map(fn {a, b} -> a * b end)
    |> Enum.sum()
  end

  defp magnitude(vec) do
    vec
    |> Enum.map(fn x -> x * x end)
    |> Enum.sum()
    |> :math.sqrt()
  end
end
