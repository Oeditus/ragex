defmodule Ragex.Dllb.Adapter do
  @moduledoc """
  Facade for the dllb storage backend.

  Checks `Application.get_env(:dllb, :enabled, false)` before delegating
  to `Ragex.Store.Backend.Dllb`. When dllb is disabled:

  - Write operations (`store_node`, `store_edge`, `store_embedding`) silently
    return `:ok` (no-op) so callers are not disrupted.
  - Read/query operations (`query`, `bootstrap`, `vector_search`) return
    `{:error, :dllb_disabled}`.
  """

  alias Ragex.Store.Backend.Dllb, as: Backend

  @doc "Returns `true` when the dllb backend is enabled in application config."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:dllb, :enabled, false)

  # ---------------------------------------------------------------------------
  # Read / query operations -- return error when disabled
  # ---------------------------------------------------------------------------

  @spec query(String.t()) :: {:ok, any()} | {:error, atom()}
  def query(statement) do
    if enabled?() do
      Dllb.query(statement)
    else
      {:error, :dllb_disabled}
    end
  end

  @spec bootstrap() :: :ok | {:error, atom()}
  def bootstrap do
    if enabled?() do
      Backend.bootstrap()
    else
      {:error, :dllb_disabled}
    end
  end

  @spec vector_search(list(), keyword()) :: {:ok, list()} | {:error, atom()}
  def vector_search(embedding, opts \\ []) do
    if enabled?() do
      {:ok, Backend.search_vectors(embedding, opts)}
    else
      {:error, :dllb_disabled}
    end
  end

  # ---------------------------------------------------------------------------
  # Write operations -- no-op when disabled
  # ---------------------------------------------------------------------------

  @spec store_node(atom(), any(), map()) :: :ok
  def store_node(node_type, node_id, data) do
    if enabled?(), do: Backend.store_node(node_type, node_id, data)
    :ok
  end

  @spec store_edge(tuple(), tuple(), atom(), map()) :: :ok
  def store_edge(from_node, to_node, edge_type, metadata \\ %{}) do
    if enabled?(), do: Backend.store_edge(from_node, to_node, edge_type, metadata: metadata)
    :ok
  end

  @spec store_embedding(atom(), any(), list(), String.t()) :: :ok
  def store_embedding(node_type, node_id, embedding, text) do
    if enabled?(), do: Backend.store_embedding(node_type, node_id, embedding, text)
    :ok
  end
end
