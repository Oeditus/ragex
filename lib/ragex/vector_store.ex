defmodule Ragex.VectorStore do
  @moduledoc """
  Vector similarity search for code embeddings.

  Provides efficient cosine similarity search over code entity embeddings
  stored in the graph store. Supports filtering by entity type, similarity
  thresholds, and result limits.
  """

  use GenServer
  require Logger

  alias Ragex.Graph.Store

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

  ## Returns

  List of results sorted by similarity (highest first), each containing:
  - `:node_type` - Type of the entity
  - `:node_id` - ID of the entity
  - `:score` - Similarity score (0.0 to 1.0)
  - `:text` - Original text description
  - `:embedding` - The embedding vector

  ## Example

      {:ok, query_emb} = Bumblebee.embed("function to calculate sum")
      results = VectorStore.search(query_emb, limit: 5, threshold: 0.7)
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
    # Get embeddings from graph store
    embeddings = Store.list_embeddings()

    stats = %{
      total_embeddings: length(embeddings),
      dimensions: if(embeddings != [], do: length(elem(hd(embeddings), 2)), else: 0)
    }

    {:reply, stats, state}
  end

  # Private Functions

  defp perform_search(query_embedding, opts) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.0)
    node_type_filter = Keyword.get(opts, :node_type)

    # Get all embeddings from graph store
    embeddings =
      case node_type_filter do
        nil -> Store.list_embeddings()
        type -> Store.list_embeddings(type)
      end

    # Calculate similarities in parallel
    results =
      embeddings
      |> Task.async_stream(
        fn {node_type, node_id, embedding, text} ->
          score = cosine_similarity(query_embedding, embedding)

          %{
            node_type: node_type,
            node_id: node_id,
            score: score,
            text: text,
            embedding: embedding
          }
        end,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.filter(fn result -> result.score >= threshold end)
      |> Enum.sort_by(fn result -> result.score end, :desc)
      |> Enum.take(limit)

    results
  end

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
