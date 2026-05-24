defmodule Ragex.Store.Backend do
  @moduledoc """
  Behaviour defining the storage contract for Ragex's knowledge graph,
  embeddings, and vector search.

  Two implementations exist:

    - `Ragex.Store.Backend.ETS` -- in-memory ETS tables (default, backward-compatible)
    - `Ragex.Store.Backend.Dllb` -- delegates to the dllb multi-model database

  The active backend is selected at startup via:

      config :ragex, :store_backend, :ets   # or :dllb
  """

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc "One-time schema bootstrap (e.g. DEFINE TABLE for dllb). ETS is a no-op."
  @callback bootstrap() :: :ok | {:error, term()}

  @doc "Clear all data."
  @callback clear() :: :ok

  @doc "Return aggregate stats about the store."
  @callback stats() :: map()

  @doc "Switch the store to a specific project path."
  @callback load_project(project_path :: String.t() | nil) :: :ok

  # ---------------------------------------------------------------------------
  # Nodes
  # ---------------------------------------------------------------------------

  @callback store_node(node_type :: atom(), node_id :: term(), data :: map()) :: :ok
  @callback get_node(node_key :: {atom(), term()}) :: map() | nil
  @callback find_node(node_type :: atom(), node_id :: term()) :: map() | nil
  @callback list_nodes(node_type :: atom() | nil, limit :: non_neg_integer() | :infinity) :: [
              map()
            ]
  @callback count_nodes_by_type(node_type :: atom()) :: non_neg_integer()
  @callback remove_node(node_type :: atom(), node_id :: term()) :: :ok
  @callback update_node_metadata(node_type :: atom(), node_id :: term(), metadata :: map()) :: :ok

  # ---------------------------------------------------------------------------
  # Edges
  # ---------------------------------------------------------------------------

  @callback store_edge(
              from_node :: term(),
              to_node :: term(),
              edge_type :: atom(),
              opts :: keyword()
            ) :: :ok
  @callback get_outgoing_edges(from_node :: term(), edge_type :: atom()) :: [map()]
  @callback get_incoming_edges(to_node :: term(), edge_type :: atom()) :: [map()]
  @callback get_edge_weight(from_node :: term(), to_node :: term(), edge_type :: atom()) ::
              float() | nil
  @callback list_edges(opts :: keyword()) :: [map()]

  # ---------------------------------------------------------------------------
  # Embeddings
  # ---------------------------------------------------------------------------

  @callback store_embedding(
              node_type :: atom(),
              node_id :: term(),
              embedding :: [float()],
              text :: String.t()
            ) :: :ok
  @callback get_embedding(node_type :: atom(), node_id :: term()) :: {[float()], String.t()} | nil
  @callback list_embeddings(node_type :: atom() | nil, limit :: non_neg_integer() | :infinity) ::
              [tuple()]

  # ---------------------------------------------------------------------------
  # Vector search
  # ---------------------------------------------------------------------------

  @callback search_vectors(query_embedding :: [float()], opts :: keyword()) :: [map()]

  @doc """
  Returns the module implementing this behaviour for the configured backend.
  """
  @spec module() :: module()
  def module do
    case Application.get_env(:ragex, :store_backend, :ets) do
      :ets -> Ragex.Store.Backend.ETS
      :dllb -> Ragex.Store.Backend.Dllb
    end
  end
end
