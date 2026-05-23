defmodule Ragex.Dllb.Adapter do
  @moduledoc """
  Adapter bridging Ragex to the dllb multi-model database.

  All public functions check whether dllb is enabled before touching the
  connection pool. When disabled, write helpers return `:ok` (no-op) and
  read helpers return `{:error, :dllb_disabled}` so callers can fall back
  to ETS gracefully.
  """

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Returns whether dllb is enabled in application config.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:dllb, :enabled, false)
  end

  @doc """
  Executes a raw dllb query string through the connection pool.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec query(String.t()) :: {:ok, Dllb.Result.t()} | {:error, term()}
  def query(query_string) do
    if enabled?() do
      Dllb.query(query_string)
    else
      {:error, :dllb_disabled}
    end
  end

  @doc """
  Bootstraps the dllb schema (tables, fields, indexes) on first use.

  Delegates to `Dllb.Schema.bootstrap/1` using `query/1` as the query
  function.
  """
  @spec bootstrap() :: {:ok, :bootstrapped} | {:error, term()}
  def bootstrap do
    if enabled?() do
      Dllb.Schema.bootstrap(&query/1)
    else
      {:error, :dllb_disabled}
    end
  end

  # ---------------------------------------------------------------------------
  # Dual-write helpers
  # ---------------------------------------------------------------------------

  @doc """
  Stores a node in dllb (dual-write helper).

  Converts the ragex node into a dllb CREATE statement targeting the
  `ast_node` table. Returns `:ok` when dllb is disabled so the caller
  can proceed without branching.
  """
  @spec store_node(atom(), term(), map()) :: {:ok, Dllb.Result.t()} | {:error, term()} | :ok
  def store_node(node_type, node_id, data) do
    if enabled?() do
      fields =
        Map.merge(data, %{
          kind: to_string(node_type),
          name: extract_name(node_type, node_id)
        })

      query_string = Dllb.Query.create("ast_node", fields)
      query(query_string)
    else
      :ok
    end
  end

  @doc """
  Stores an edge in dllb (dual-write helper).

  Creates a RELATE statement between two sanitised record ids.
  Returns `:ok` when dllb is disabled.
  """
  @spec store_edge(term(), term(), atom(), map()) ::
          {:ok, Dllb.Result.t()} | {:error, term()} | :ok
  def store_edge(from_node, to_node, edge_type, metadata \\ %{}) do
    if enabled?() do
      from_id = node_to_dllb_id(from_node)
      to_id = node_to_dllb_id(to_node)
      query_string = Dllb.Query.relate(from_id, to_string(edge_type), to_id, metadata)
      query(query_string)
    else
      :ok
    end
  end

  @doc """
  Stores an embedding vector for a node in dllb.

  Issues an UPDATE to set the `source_embedding` field on the
  corresponding `ast_node` record. Returns `:ok` when dllb is disabled.
  """
  @spec store_embedding(atom(), term(), list(float()), String.t()) ::
          {:ok, Dllb.Result.t()} | {:error, term()} | :ok
  def store_embedding(node_type, node_id, embedding, _text) do
    if enabled?() do
      record_id = node_to_dllb_id({node_type, node_id})
      query_string = Dllb.MetaAST.to_dllb_embeddings(record_id, %{source_embedding: embedding})
      query(query_string)
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Vector search
  # ---------------------------------------------------------------------------

  @doc """
  Performs a vector KNN search via the dllb HNSW index.

  ## Options

    * `:limit` - maximum number of results (default: 10)
    * `:ef`    - HNSW exploration factor (default: 100)
    * `:node_type` - optional filter by `kind` field

  Returns `{:ok, [map()]}` with atom-keyed result maps produced by
  `Dllb.MetaAST.from_dllb_row/1`, or `{:error, :dllb_disabled}`.
  """
  @spec vector_search(list(float()), keyword()) :: {:ok, [map()]} | {:error, term()}
  def vector_search(query_embedding, opts \\ []) do
    if enabled?() do
      k = Keyword.get(opts, :limit, 10)
      ef = Keyword.get(opts, :ef, 100)

      vec_str = "[" <> Enum.map_join(query_embedding, ", ", &to_string/1) <> "]"
      base_where = "source_embedding <|#{k},#{ef}|> #{vec_str}"

      where_clause =
        case Keyword.get(opts, :node_type) do
          nil -> base_where
          type -> "kind = '#{type}' AND #{base_where}"
        end

      query_string =
        Dllb.Query.select("ast_node",
          fields: [
            "id",
            "name",
            "kind",
            "file_path",
            "source_text",
            "vector::distance::knn() AS score"
          ],
          where: where_clause,
          order: "score",
          limit: k
        )

      case query(query_string) do
        {:ok, %Dllb.Result.Rows{data: rows}} ->
          {:ok, Enum.map(rows, &Dllb.MetaAST.from_dllb_row/1)}

        {:ok, _other} ->
          {:ok, []}

        error ->
          error
      end
    else
      {:error, :dllb_disabled}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec extract_name(atom(), term()) :: String.t()
  defp extract_name(:function, {_mod, name, _arity}), do: to_string(name)
  defp extract_name(:module, name), do: inspect(name)
  defp extract_name(_type, id), do: inspect(id)

  @spec node_to_dllb_id(term()) :: String.t()
  defp node_to_dllb_id({:function, {mod, name, arity}}) do
    sanitized = "#{inspect(mod)}_#{name}_#{arity}" |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    "ast_node:#{sanitized}"
  end

  defp node_to_dllb_id({:module, name}) do
    sanitized = inspect(name) |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    "ast_node:#{sanitized}"
  end

  defp node_to_dllb_id({type, id}) do
    sanitized = "#{type}_#{inspect(id)}" |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    "ast_node:#{sanitized}"
  end

  defp node_to_dllb_id(other) do
    sanitized = inspect(other) |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    "ast_node:#{sanitized}"
  end
end
