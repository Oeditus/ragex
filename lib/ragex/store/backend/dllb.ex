defmodule Ragex.Store.Backend.Dllb do
  @moduledoc """
  dllb-backed storage implementation for Ragex's knowledge graph.

  Delegates all operations to `Dllb.MetaAST.Query` and the dllb connection
  pool. Provides native HNSW vector search, graph traversal, and full-text
  search capabilities that are orders of magnitude faster than the ETS
  brute-force equivalents on large datasets.

  ## Requirements

  The dllb server must be running and configured:

      config :dllb,
        enabled: true,
        host: "127.0.0.1",
        port: 3009,
        pool_size: 5
  """

  @behaviour Ragex.Store.Backend

  require Logger

  alias Dllb.MetaAST.Query, as: MQ

  defp query_fn, do: &Dllb.query/1

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def bootstrap do
    case Dllb.Schema.bootstrap(query_fn()) do
      {:ok, :bootstrapped} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def clear do
    # Delete all ast_node records (full table scan + point deletes)
    case MQ.exec_delete_by_project("", query_fn()) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  @impl true
  def stats do
    case MQ.exec_stats(query_fn()) do
      {:ok, stats} -> stats
      {:error, _} -> %{total: 0, by_kind: %{}}
    end
  end

  @impl true
  def load_project(_project_path) do
    # dllb is persistent -- no cache loading needed.
    # Bootstrap schema in case it's a fresh database.
    bootstrap()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Nodes
  # ---------------------------------------------------------------------------

  @impl true
  def store_node(node_type, node_id, data) do
    fields =
      Map.merge(data, %{kind: to_string(node_type), name: extract_name(node_type, node_id)})

    id = node_to_dllb_id({node_type, node_id})
    query_string = Dllb.Query.upsert("ast_node", id, fields)

    case Dllb.query(query_string) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("dllb store_node failed: #{inspect(reason)}")
    end

    :ok
  end

  @impl true
  def get_node({node_type, node_id}), do: find_node(node_type, node_id)

  @impl true
  def find_node(node_type, node_id) do
    id = node_to_dllb_id({node_type, node_id})
    query_string = Dllb.Query.select("ast_node:#{id}", [])

    case MQ.exec(query_string, query_fn()) do
      {:ok, [row | _]} -> dllb_row_to_node_data(row)
      _ -> nil
    end
  end

  @impl true
  def list_nodes(node_type \\ nil, limit \\ 1_000) do
    query_string =
      case node_type do
        nil -> Dllb.Query.select("ast_node", limit: effective_limit(limit))
        type -> MQ.nodes_by_kind(to_string(type), limit: effective_limit(limit))
      end

    case MQ.exec(query_string, query_fn()) do
      {:ok, rows} ->
        Enum.map(rows, fn row ->
          %{type: row[:kind], id: row[:name], data: row}
        end)

      {:error, _} ->
        []
    end
  end

  @impl true
  def count_nodes_by_type(node_type) do
    query_string = MQ.nodes_by_kind(to_string(node_type))

    case MQ.exec(query_string, query_fn()) do
      {:ok, rows} -> length(rows)
      {:error, _} -> 0
    end
  end

  @impl true
  def find_function(module_name, func_name) do
    query_string = MQ.functions_of_module(inspect(module_name))

    case MQ.exec(query_string, query_fn()) do
      {:ok, rows} ->
        Enum.find_value(rows, fn row ->
          if row[:name] == to_string(func_name), do: row
        end)

      {:error, _} ->
        nil
    end
  end

  @impl true
  def remove_node(node_type, node_id) do
    id = node_to_dllb_id({node_type, node_id})
    Dllb.query(Dllb.Query.delete("ast_node:#{id}"))
    :ok
  end

  @impl true
  def update_node_metadata(node_type, node_id, new_metadata) when is_map(new_metadata) do
    id = node_to_dllb_id({node_type, node_id})
    Dllb.query(Dllb.Query.update("ast_node:#{id}", new_metadata))
    :ok
  end

  # ---------------------------------------------------------------------------
  # Edges
  # ---------------------------------------------------------------------------

  @impl true
  def store_edge(from_node, to_node, edge_type, opts \\ []) do
    from_id = node_to_dllb_id(from_node)
    to_id = node_to_dllb_id(to_node)
    weight = Keyword.get(opts, :weight, 1.0)
    metadata = Keyword.get(opts, :metadata, %{})
    props = Map.put(metadata, :weight, weight)

    query_string =
      Dllb.Query.relate("ast_node:#{from_id}", to_string(edge_type), "ast_node:#{to_id}", props)

    Dllb.query(query_string)
    :ok
  end

  @impl true
  def get_outgoing_edges(from_node, edge_type) do
    from_id = node_to_dllb_id(from_node)
    query_string = MQ.callees_of("ast_node:#{from_id}")

    case MQ.exec(query_string, query_fn()) do
      {:ok, rows} ->
        Enum.map(rows, fn row ->
          %{to: row[:id], type: edge_type, metadata: %{}}
        end)

      {:error, _} ->
        []
    end
  end

  @impl true
  def get_incoming_edges(to_node, edge_type) do
    to_id = node_to_dllb_id(to_node)
    query_string = MQ.callers_of("ast_node:#{to_id}")

    case MQ.exec(query_string, query_fn()) do
      {:ok, rows} ->
        Enum.map(rows, fn row ->
          %{from: row[:id], type: edge_type, metadata: %{}}
        end)

      {:error, _} ->
        []
    end
  end

  @impl true
  def get_edge_weight(_from_node, _to_node, _edge_type), do: 1.0

  @impl true
  def list_edges(opts \\ []) do
    edge_type = Keyword.get(opts, :edge_type)

    where =
      case edge_type do
        nil -> nil
        type -> "edge_type = '#{type}'"
      end

    query_string = Dllb.Query.select("_edge_idx", where: where)

    case Dllb.query(query_string) do
      {:ok, %Dllb.Result.Rows{data: data}} ->
        Enum.map(data, fn row ->
          %{
            from: unwrap_typed(row["from_id"]),
            to: unwrap_typed(row["to_id"]),
            type: safe_to_edge_atom(unwrap_typed(row["edge_type"])),
            metadata: %{}
          }
        end)

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Embeddings
  # ---------------------------------------------------------------------------

  @impl true
  def store_embedding(node_type, node_id, embedding, _text) when is_list(embedding) do
    # Attach the embedding to the matching ast_node row(s) by their stable
    # attributes (kind/module/name/arity) rather than a reconstructed record
    # id, via a server-side `UPDATE ... WHERE`.
    case embedding_match_attrs({node_type, node_id}) do
      attrs when map_size(attrs) == 0 ->
        :ok

      attrs ->
        attrs
        |> MQ.set_source_embedding(embedding)
        |> Dllb.query()

        :ok
    end
  end

  def store_embedding(_node_type, _node_id, _embedding, _text), do: :ok

  @impl true
  def get_embedding(_node_type, _node_id), do: nil

  @impl true
  def list_embeddings(_node_type \\ nil, _limit \\ 1_000), do: []

  @impl true
  def count_embeddings do
    case MQ.exec_count_embeddings(query_fn()) do
      {:ok, count} -> count
      {:error, _} -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Vector search
  # ---------------------------------------------------------------------------

  @impl true
  def search_vectors(query_embedding, opts \\ []) do
    query_string = MQ.similar_to(query_embedding, opts)

    case MQ.exec(query_string, query_fn()) do
      {:ok, rows} ->
        Enum.map(rows, fn row ->
          %{
            node_type: row[:kind] || :unknown,
            node_id: row[:name] || "",
            score: Map.get(row, :score, 0.0),
            text: row[:source_text] || "",
            embedding: []
          }
        end)

      {:error, _} ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp extract_name(:function, {_mod, name, _arity}), do: to_string(name)
  defp extract_name(:module, name), do: inspect(name)
  defp extract_name(_type, id), do: inspect(id)

  # Builds the attribute filter used to locate the ast_node row(s) an embedding
  # belongs to. Mirrors the values written during ingestion by
  # `Dllb.MetaAST.to_dllb_document/2` (module/name/arity/kind). Returns an empty
  # map for node shapes we cannot match, so the caller can skip the write.
  defp embedding_match_attrs({:function, {mod, name, arity}}) do
    %{kind: "function_def", module: module_string(mod), name: to_string(name), arity: arity}
  end

  defp embedding_match_attrs({:module, name}) do
    %{kind: "container", name: module_string(name)}
  end

  defp embedding_match_attrs(_), do: %{}

  # Module names are stored without the "Elixir." prefix (matching `inspect/1`
  # of a module atom and the analyzer-provided container name).
  defp module_string(mod) when is_atom(mod), do: inspect(mod)
  defp module_string(mod) when is_binary(mod), do: String.replace_prefix(mod, "Elixir.", "")
  defp module_string(mod), do: mod |> to_string() |> String.replace_prefix("Elixir.", "")

  defp node_to_dllb_id({:function, {mod, name, arity}}) do
    "#{inspect(mod)}_#{name}_#{arity}" |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  defp node_to_dllb_id({:module, name}) do
    inspect(name) |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  defp node_to_dllb_id({type, id}) do
    "#{type}_#{inspect(id)}" |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  defp node_to_dllb_id(other) do
    inspect(other) |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  defp dllb_row_to_node_data(row) do
    Map.drop(row, [:id])
  end

  defp effective_limit(:infinity), do: nil
  defp effective_limit(n) when is_integer(n), do: n

  # dllb JSON wraps typed values as %{"String" => "value"}, %{"Int" => 42}, etc.
  defp unwrap_typed(%{"String" => v}), do: v
  defp unwrap_typed(%{"Int" => v}), do: v
  defp unwrap_typed(%{"Float" => v}), do: v
  defp unwrap_typed(%{"Bool" => v}), do: v
  defp unwrap_typed(v), do: v

  defp safe_to_edge_atom("calls"), do: :calls
  defp safe_to_edge_atom("contains"), do: :contains
  defp safe_to_edge_atom("imports"), do: :imports
  defp safe_to_edge_atom(other) when is_binary(other), do: String.to_atom(other)
  defp safe_to_edge_atom(other), do: other
end
