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
  alias Ragex.Dllb.ProjectManager
  alias Ragex.Embeddings.Registry

  defp query_fn, do: fn stmt -> query(stmt) end

  @doc "Executes a query statement against the active dllb instance (per-project or global)."
  @spec query(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def query(statement, opts \\ []) do
    if ProjectManager.per_project_enabled?() do
      ProjectManager.query(statement, opts)
    else
      Dllb.query(statement, opts)
    end
  end

  @doc "Executes a batch transaction against the active dllb instance."
  @spec batch_transaction([String.t()], keyword()) :: {:ok, term()} | {:error, term()}
  def batch_transaction(query_strings, opts \\ []) do
    if ProjectManager.per_project_enabled?() do
      ProjectManager.batch_transaction(query_strings, opts)
    else
      Dllb.batch_transaction(query_strings, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def bootstrap do
    bootstrap_with(&query/1)
  end

  @doc "Bootstraps schema statements on a specific named pool connection."
  @spec bootstrap_instance(atom()) :: :ok | {:error, term()}
  def bootstrap_instance(pool_name) do
    bootstrap_with(&Dllb.query(&1, pool: pool_name))
  end

  defp bootstrap_with(query_fn) do
    schema_statements()
    |> Enum.reduce_while(:ok, fn stmt, :ok ->
      case query_fn.(stmt) do
        {:ok, %Dllb.Result.Error{} = error} ->
          # TABLE/FIELD declarations are unsupported by the engine. Index
          # errors, including conflicting definitions, must not be swallowed.
          if String.starts_with?(stmt, ["DEFINE TABLE ", "DEFINE FIELD "]) do
            {:cont, :ok}
          else
            {:halt, {:error, error}}
          end

        {:ok, _} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Returns the ordered list of schema statements executed by `bootstrap/0`.

  The table, secondary-index, and edge-index definitions come from
  `Dllb.Schema`. The full-text and vector search indexes are built here so the
  vector index dimension can be resolved dynamically from the configured
  embedding model (see the `:embedding_model` config and
  `Ragex.Embeddings.Registry`). A static dimension that does not match the
  model's output makes the engine silently skip indexing every row.
  """
  @spec schema_statements() :: [String.t()]
  def schema_statements do
    Dllb.Schema.ast_node_table() ++
      Dllb.Schema.ast_node_indexes() ++
      search_index_statements() ++
      Dllb.Schema.edge_idx_table()
  end

  @impl true
  def clear do
    # Unconditionally wipe every row from the active project's tables.
    #
    # `MQ.exec_delete_by_project/2` was used here previously, but it filters
    # on the `project_path` column (`DELETE ast_node WHERE project_path =
    # '...'`). `prepare_node_fields/3` never populates `:project_path` on
    # stored nodes, so that WHERE clause never matched any row and this
    # function was a permanent no-op -- data from every test (and every
    # analyzed project, in :global mode) accumulated forever in the
    # underlying `.ragex/dllb.redb` file. Isolation between projects is
    # already provided by `Ragex.Dllb.ProjectManager` (a dedicated dllb
    # instance/database per project in :per_project mode), so clearing the
    # active project's tables unconditionally is the correct behavior here.
    query(Dllb.Query.delete_where("ast_node"))
    query(Dllb.Query.delete_where("_edge_idx"))
    :ok
  end

  @edge_types [:calls, :imports, :defines, :inherits, :implements, :contains]

  @impl true
  def stats do
    stats_result =
      case MQ.exec_stats(query_fn()) do
        {:ok, %{total: total} = res} when is_integer(total) and total > 0 ->
          res

        _ ->
          case query("COUNT ast_node;") do
            {:ok, %Dllb.Result.Count{count: count}} ->
              %{total: count, by_kind: %{}}

            {:ok, %Dllb.Result.Rows{data: [%{"count" => count} | _]}} ->
              %{total: unwrap_typed(count), by_kind: %{}}

            _ ->
              %{total: 0, by_kind: %{}}
          end
      end

    total = Map.get(stats_result, :total, 0)
    by_kind = Map.get(stats_result, :by_kind, %{})
    edge_count = count_all_edges()
    embedding_count = count_embeddings()

    Map.merge(
      %{
        nodes: total,
        total: total,
        edges: edge_count,
        embeddings: embedding_count,
        by_kind: by_kind
      },
      stats_result
    )
  end

  @impl true
  def load_project(project_path) do
    if ProjectManager.per_project_enabled?() and not is_nil(project_path) do
      # Attachment initializes the schema once. Reactivation only selects the
      # existing instance; it must not redefine every index.
      ProjectManager.set_active_project(project_path)
    else
      bootstrap()
    end
  end

  # ---------------------------------------------------------------------------
  # Nodes
  # ---------------------------------------------------------------------------

  @schema_fields MapSet.new([
                   :kind,
                   :name,
                   :language,
                   :file_path,
                   :module,
                   :arity,
                   :visibility,
                   :project_path,
                   :line_start,
                   :line_end,
                   :source_text,
                   :signature,
                   :docstring,
                   :source_embedding,
                   :structure_embedding,
                   :docstring_embedding,
                   :ast_serialized
                 ])

  defp filter_schema_fields(data) when is_map(data) do
    data
    |> to_plain_map()
    |> Enum.filter(fn {k, v} ->
      k_atom =
        try do
          if is_binary(k), do: String.to_existing_atom(k), else: k
        rescue
          _ -> nil
        end

      (k_atom && MapSet.member?(@schema_fields, k_atom)) and not is_nil(v)
    end)
    |> Map.new()
  end

  defp to_plain_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp to_plain_map(map) when is_map(map), do: map
  defp to_plain_map(_), do: %{}

  @impl true
  def store_node(node_type, node_id, data) do
    fields = prepare_node_fields(node_type, node_id, data)
    id = node_to_dllb_id({node_type, node_id})
    query_string = Dllb.Query.upsert("ast_node", id, fields)

    case query(query_string) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("dllb store_node failed: #{inspect(reason)}")
    end

    :ok
  end

  @impl true
  def store_nodes(nodes) when is_list(nodes) do
    queries =
      Enum.map(nodes, fn {node_type, node_id, data} ->
        fields = prepare_node_fields(node_type, node_id, data)
        id = node_to_dllb_id({node_type, node_id})
        Dllb.Query.upsert("ast_node", id, fields)
      end)

    exec_batch_queries(queries)
  end

  defp prepare_node_fields(node_type, node_id, data) do
    plain_data = to_plain_map(data)

    normalized_data =
      plain_data
      |> map_key(:file, :file_path)
      |> map_key(:line, :line_start)
      |> map_key(:doc, :docstring)

    ast_serialized =
      case Map.get(normalized_data, :ast_serialized) || Map.get(normalized_data, "ast_serialized") do
        nil ->
          try do
            Jason.encode!(plain_data)
          rescue
            _ -> nil
          end

        existing ->
          existing
      end

    extra_fields =
      case {node_type, node_id} do
        {:function, {mod, _name, arity}} ->
          %{
            module: Map.get(normalized_data, :module, mod),
            arity: Map.get(normalized_data, :arity, arity)
          }

        {:module, mod} ->
          %{module: Map.get(normalized_data, :module, mod)}

        _ ->
          %{}
      end

    normalized_data
    |> Map.put(:ast_serialized, ast_serialized)
    |> Map.merge(extra_fields)
    |> Map.merge(%{
      kind: to_string(node_type),
      name: extract_name(node_type, node_id),
      language: Map.get(normalized_data, :language, "elixir")
    })
    |> filter_schema_fields()
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
    rows =
      case node_type do
        nil ->
          case MQ.exec(Dllb.Query.select("ast_node", limit: effective_limit(limit)), query_fn()) do
            {:ok, rows} -> rows
            {:error, _} -> []
          end

        type ->
          list_rows_by_type(type, limit)
      end

    Enum.map(rows, fn row ->
      data = dllb_row_to_node_data(row)
      {normalized_type, node_id} = row_to_node_entry(row, data)
      %{type: normalized_type, id: node_id, data: data}
    end)
  end

  defp list_rows_by_type(type, limit) do
    kinds =
      case type do
        :function -> ["function", "function_def"]
        :module -> ["module", "container"]
        other -> [to_string(other)]
      end

    eff_limit = effective_limit(limit)

    rows =
      Enum.flat_map(kinds, fn kind ->
        case MQ.exec(MQ.nodes_by_kind(kind, limit: eff_limit), query_fn()) do
          {:ok, found} -> found
          {:error, _} -> []
        end
      end)

    case eff_limit do
      nil -> rows
      n -> Enum.take(rows, n)
    end
  end

  @impl true
  def count_nodes_by_type(node_type) do
    kinds =
      case node_type do
        :function -> ["function", "function_def"]
        :module -> ["module", "container"]
        other -> [to_string(other)]
      end

    Enum.reduce(kinds, 0, fn kind, acc ->
      query_string = Dllb.Query.count("ast_node", where: "kind = '#{kind}'")

      count =
        case query(query_string) do
          {:ok, %Dllb.Result.Count{count: c}} ->
            c

          _ ->
            case MQ.exec(MQ.nodes_by_kind(kind), query_fn()) do
              {:ok, rows} -> length(rows)
              {:error, _} -> 0
            end
        end

      acc + count
    end)
  end

  @impl true
  def find_function(module_name, func_name) do
    target_mod = module_string(module_name)
    target_name = to_string(func_name)

    query_string =
      Dllb.Query.select("ast_node",
        where: "name = #{escape_value(target_name)}"
      )

    case MQ.exec(query_string, query_fn()) do
      {:ok, rows} ->
        Enum.find_value(rows, fn row ->
          kind = normalize_kind(row[:kind])
          row_mod = row[:module] && module_string(row[:module])

          if kind == :function and row_mod == target_mod do
            dllb_row_to_node_data(row)
          end
        end)

      {:error, _} ->
        nil
    end
  end

  @impl true
  def remove_node(node_type, node_id) do
    id = node_to_dllb_id({node_type, node_id})
    query(Dllb.Query.delete("ast_node:#{id}"))
    :ok
  end

  @impl true
  def update_node_metadata(node_type, node_id, new_metadata) when is_map(new_metadata) do
    id = node_to_dllb_id({node_type, node_id})

    case find_node(node_type, node_id) do
      existing when is_map(existing) ->
        existing_meta = Map.get(existing, :metadata, %{})

        merged_meta =
          if is_map(existing_meta), do: Map.merge(existing_meta, new_metadata), else: new_metadata

        updated_data = Map.put(existing, :metadata, merged_meta)

        case encode_ast_serialized(updated_data) do
          nil ->
            :ok

          serialized ->
            query(Dllb.Query.update("ast_node:#{id}", %{ast_serialized: serialized}))
            :ok
        end

      _ ->
        :ok
    end
  end

  defp encode_ast_serialized(map) when is_map(map) do
    map
    |> Map.drop([
      :ast_serialized,
      "ast_serialized",
      :source_embedding,
      :structure_embedding,
      :docstring_embedding
    ])
    |> Jason.encode!()
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # Edges
  # ---------------------------------------------------------------------------

  @impl true
  def store_edge(from_node, to_node, edge_type, opts \\ []) do
    query_string = build_relate_query(from_node, to_node, edge_type, opts)
    query(query_string)
    :ok
  end

  @impl true
  def store_edges(edges) when is_list(edges) do
    queries =
      Enum.map(edges, fn {from_node, to_node, edge_type, opts} ->
        build_relate_query(from_node, to_node, edge_type, opts)
      end)

    exec_batch_queries(queries)
  end

  defp build_relate_query(from_node, to_node, edge_type, opts) do
    from_id = node_to_dllb_id(from_node)
    to_id = node_to_dllb_id(to_node)
    weight = Keyword.get(opts, :weight, 1.0)
    metadata = Keyword.get(opts, :metadata, %{})

    props =
      metadata
      |> Map.put(:weight, weight)
      |> Map.put(:from_node, encode_edge_node(from_node))
      |> Map.put(:to_node, encode_edge_node(to_node))

    Dllb.Query.relate("ast_node:#{from_id}", to_string(edge_type), "ast_node:#{to_id}", props)
  end

  defp exec_batch_queries([]), do: :ok

  defp exec_batch_queries(queries) when is_list(queries) do
    queries
    |> Enum.chunk_every(250)
    |> Enum.each(fn chunk ->
      case batch_transaction(chunk) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.debug("dllb batch execution failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  @impl true
  def get_outgoing_edges(from_node, edge_type) do
    edge_str = to_string(edge_type)
    from_id = node_to_dllb_id(from_node)

    rows =
      query_graph_edges_by_endpoint(edge_str, "src", from_id, legacy_node_to_dllb_id(from_node))

    Enum.map(rows, fn row ->
      %{
        to: decode_edge_node(row["to_node"], row["dst"]),
        type: edge_type,
        metadata: extract_edge_metadata(row)
      }
    end)
  end

  @impl true
  def get_incoming_edges(to_node, edge_type) do
    edge_str = to_string(edge_type)
    to_id = node_to_dllb_id(to_node)

    rows =
      query_graph_edges_by_endpoint(edge_str, "dst", to_id, legacy_node_to_dllb_id(to_node))

    Enum.map(rows, fn row ->
      %{
        from: decode_edge_node(row["from_node"], row["src"]),
        type: edge_type,
        metadata: extract_edge_metadata(row)
      }
    end)
  end

  @impl true
  def get_edge_weight(from_node, to_node, edge_type) do
    edge_str = to_string(edge_type)
    from_id = node_to_dllb_id(from_node)
    to_id = node_to_dllb_id(to_node)

    where = "src = #{escape_value(from_id)} AND dst = #{escape_value(to_id)}"

    case query(Dllb.Query.graph_edges(edge_str, where: where)) do
      {:ok, %Dllb.Result.Rows{data: [row | _]}} ->
        unwrap_typed(row["weight"]) || 1.0

      _ ->
        legacy_from = legacy_node_to_dllb_id(from_node)
        legacy_to = legacy_node_to_dllb_id(to_node)

        if legacy_from && legacy_to && (legacy_from != from_id or legacy_to != to_id) do
          legacy_where = "src = #{escape_value(legacy_from)} AND dst = #{escape_value(legacy_to)}"

          case query(Dllb.Query.graph_edges(edge_str, where: legacy_where)) do
            {:ok, %Dllb.Result.Rows{data: [row | _]}} -> unwrap_typed(row["weight"]) || 1.0
            _ -> nil
          end
        else
          nil
        end
    end
  end

  @impl true
  def list_edges(opts \\ []) do
    edge_type = Keyword.get(opts, :edge_type)
    limit = Keyword.get(opts, :limit)

    edges =
      if edge_type do
        fetch_graph_edges_for_type(edge_type)
      else
        Enum.flat_map(@edge_types, &fetch_graph_edges_for_type/1)
      end

    edges =
      if edges == [] do
        list_edges_fallback(opts)
      else
        edges
      end

    case limit do
      n when is_integer(n) and n >= 0 -> Enum.take(edges, n)
      _ -> edges
    end
  end

  defp fetch_graph_edges_for_type(edge_type) do
    query_string = Dllb.Query.graph_edges(to_string(edge_type))

    case query(query_string) do
      {:ok, %Dllb.Result.Rows{data: data}} ->
        Enum.map(data, fn row ->
          %{
            from: decode_edge_node(row["from_node"], row["src"] || row["from_id"]),
            to: decode_edge_node(row["to_node"], row["dst"] || row["to_id"]),
            type: safe_to_edge_atom(unwrap_typed(row["edge_type"] || edge_type)),
            metadata: extract_edge_metadata(row)
          }
        end)

      _ ->
        []
    end
  end

  defp query_graph_edges_by_endpoint(edge_str, field, canonical_id, legacy_id) do
    canonical_rows =
      case query(
             Dllb.Query.graph_edges(edge_str, where: "#{field} = #{escape_value(canonical_id)}")
           ) do
        {:ok, %Dllb.Result.Rows{data: data}} -> data
        _ -> []
      end

    if canonical_rows == [] and is_binary(legacy_id) and legacy_id != canonical_id do
      case query(Dllb.Query.graph_edges(edge_str, where: "#{field} = #{escape_value(legacy_id)}")) do
        {:ok, %Dllb.Result.Rows{data: data}} -> data
        _ -> []
      end
    else
      canonical_rows
    end
  end

  defp count_all_edges do
    Enum.reduce(@edge_types, 0, fn edge_type, acc ->
      case query(Dllb.Query.graph_edges(to_string(edge_type))) do
        {:ok, %Dllb.Result.Rows{count: count}} when is_integer(count) -> acc + count
        {:ok, %Dllb.Result.Rows{data: data}} when is_list(data) -> acc + length(data)
        _ -> acc
      end
    end)
  end

  defp list_edges_fallback(opts) do
    edge_type = Keyword.get(opts, :edge_type)

    where =
      case edge_type do
        nil -> nil
        type -> "edge_type = '#{type}'"
      end

    query_string = Dllb.Query.select("_edge_idx", where: where)

    case query(query_string) do
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
  def store_embedding(node_type, node_id, embedding, text) when is_list(embedding) do
    fields = build_embedding_fields(embedding, text)
    id = node_to_dllb_id({node_type, node_id})

    case query(Dllb.Query.update("ast_node:#{id}", fields)) do
      {:ok, %Dllb.Result.Update{matched: matched}} when matched > 0 ->
        :ok

      _ ->
        case embedding_match_attrs({node_type, node_id}) do
          attrs when map_size(attrs) == 0 ->
            :ok

          attrs ->
            attrs
            |> MQ.set_source_embedding(embedding)
            |> query()

            :ok
        end
    end
  end

  def store_embedding(_node_type, _node_id, _embedding, _text), do: :ok

  @impl true
  def store_embeddings(embeddings) when is_list(embeddings) do
    queries =
      Enum.flat_map(embeddings, fn
        {node_type, node_id, embedding, text} when is_list(embedding) ->
          id = node_to_dllb_id({node_type, node_id})
          fields = build_embedding_fields(embedding, text)
          [Dllb.Query.update("ast_node:#{id}", fields)]

        _ ->
          []
      end)

    exec_batch_queries(queries)
  end

  defp build_embedding_fields(embedding, text) when is_binary(text) and text != "" do
    %{source_embedding: embedding, source_text: text}
  end

  defp build_embedding_fields(embedding, _text) do
    %{source_embedding: embedding}
  end

  @impl true
  def get_embedding(node_type, node_id) do
    id = node_to_dllb_id({node_type, node_id})

    case MQ.exec(Dllb.Query.select("ast_node:#{id}", []), query_fn()) do
      {:ok, [row | _]} ->
        extract_embedding_tuple(row)

      _ ->
        get_embedding_by_attrs({node_type, node_id})
    end
  end

  defp get_embedding_by_attrs(node) do
    case embedding_match_attrs(node) do
      attrs when map_size(attrs) == 0 ->
        nil

      attrs ->
        where =
          attrs
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
          |> Enum.map_join(" AND ", fn {k, v} -> "#{k} = #{escape_value(v)}" end)

        query_string = Dllb.Query.select("ast_node", where: where, limit: 1)

        case MQ.exec(query_string, query_fn()) do
          {:ok, [row | _]} -> extract_embedding_tuple(row)
          _ -> nil
        end
    end
  end

  defp extract_embedding_tuple(row) do
    embedding = unwrap_embedding(row[:source_embedding])
    text = row[:source_text] || row[:signature] || to_string(row[:name])
    if is_list(embedding) and embedding != [], do: {embedding, text}, else: nil
  end

  @impl true
  def list_embeddings(node_type \\ nil, limit \\ 1_000) do
    eff_limit = effective_limit(limit)

    rows =
      case node_type do
        nil ->
          query_string =
            Dllb.Query.select("ast_node",
              where: "source_embedding IS NOT NONE",
              limit: eff_limit
            )

          case MQ.exec(query_string, query_fn()) do
            {:ok, found} -> found
            {:error, _} -> []
          end

        type ->
          kinds =
            case type do
              :function -> ["function", "function_def"]
              :module -> ["module", "container"]
              other -> [to_string(other)]
            end

          Enum.flat_map(kinds, fn kind ->
            q =
              Dllb.Query.select("ast_node",
                where: "kind = '#{kind}' AND source_embedding IS NOT NONE",
                limit: eff_limit
              )

            case MQ.exec(q, query_fn()) do
              {:ok, found} -> found
              {:error, _} -> []
            end
          end)
      end

    results =
      rows
      |> Enum.map(fn row ->
        data = dllb_row_to_node_data(row)
        {nt, nid} = row_to_node_entry(row, data)
        text = row[:source_text] || row[:signature] || to_string(row[:name])
        {nt, nid, unwrap_embedding(row[:source_embedding]), text}
      end)
      |> Enum.reject(fn {_, _, emb, _} -> is_nil(emb) or emb == [] end)

    case eff_limit do
      nil -> results
      n -> Enum.take(results, n)
    end
  end

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
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.0)
    node_type_filter = Keyword.get(opts, :node_type)
    exclude_type = Keyword.get(opts, :exclude_node_type)

    # Fetch extra candidates when filtering client-side so we can still return
    # up to `limit` results after threshold/type filters.
    k =
      if node_type_filter != nil or exclude_type != nil or threshold > 0.0 do
        max(limit * 3, 20)
      else
        limit
      end

    query_string = MQ.similar_to(query_embedding, Keyword.put(opts, :limit, k))

    case query(query_string) do
      {:ok, %Dllb.Result.Rows{data: raw_rows}} ->
        raw_rows
        |> Enum.map(&raw_vector_row_to_result/1)
        |> Enum.filter(fn result -> result.score >= threshold end)
        |> Enum.filter(fn result ->
          node_type_filter == nil or result.node_type == node_type_filter
        end)
        |> Enum.reject(fn result ->
          exclude_type != nil and result.node_type == exclude_type
        end)
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  defp raw_vector_row_to_result(raw_row) do
    row = Dllb.MetaAST.from_dllb_row(raw_row)
    data = dllb_row_to_node_data(row)
    {nt, nid} = row_to_node_entry(row, data)

    score =
      case {unwrap_typed(raw_row["score"]), unwrap_typed(raw_row["distance"])} do
        {s, _} when is_number(s) -> s / 1
        {_, d} when is_number(d) -> max(0.0, 1.0 - d / 1)
        _ -> 0.0
      end

    %{
      node_type: nt,
      node_id: nid,
      score: score,
      text: row[:source_text] || row[:signature] || to_string(row[:name] || ""),
      embedding: unwrap_embedding(row[:source_embedding])
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Full-text indexes are model-independent; the vector index dimension is
  # derived from the active embedding model so it matches the vectors ragex
  # actually produces. `structure_embedding` has no producer yet, so no index
  # is defined for it.
  defp search_index_statements do
    [
      Dllb.Query.define_fulltext_index("ast_node", "idx_source_text", "source_text"),
      Dllb.Query.define_fulltext_index("ast_node", "idx_docstring", "docstring"),
      Dllb.Query.define_vector_index(
        "ast_node",
        "idx_source_embedding",
        "source_embedding",
        source_embedding_dim(),
        metric: "cosine"
      ),
      Dllb.Query.define_vector_index(
        "ast_node",
        "idx_structure_embedding",
        "structure_embedding",
        384,
        metric: "cosine"
      )
    ]
  end

  # Resolves the embedding dimension from the configured model via the
  # registry, falling back to the default model's dimension for an unknown id.
  defp source_embedding_dim do
    :ragex
    |> Application.get_env(:embedding_model, Registry.default())
    |> Registry.dimensions()
    |> case do
      {:ok, dim} -> dim
      {:error, _} -> default_embedding_dim()
    end
  end

  defp default_embedding_dim do
    {:ok, dim} = Registry.dimensions(Registry.default())
    dim
  end

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

  @doc false
  @spec node_to_dllb_id(term()) :: String.t()
  def node_to_dllb_id({:function, {mod, name, arity}}) do
    "#{module_string(mod)}_#{name}_#{arity}" |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  def node_to_dllb_id({:function, mod, name, arity}) do
    node_to_dllb_id({:function, {mod, name, arity}})
  end

  def node_to_dllb_id({:module, name}) do
    module_string(name) |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  def node_to_dllb_id({type, id}) do
    "#{type}_#{inspect(id)}" |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  def node_to_dllb_id(other) do
    inspect(other) |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  # Legacy ID form emitted by Ragex <= 0.46.0 when 4-tuple function edge
  # endpoints fell through to the catch-all `inspect(other)` clause.
  defp legacy_node_to_dllb_id({:function, _mod, _name, _arity} = tuple) do
    inspect(tuple) |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  defp legacy_node_to_dllb_id(_), do: nil

  defp encode_edge_node({:function, mod, name, arity}) do
    Jason.encode!(%{
      "type" => "function",
      "module" => atom_or_string(mod),
      "name" => atom_or_string(name),
      "arity" => arity
    })
  end

  defp encode_edge_node({:function, {mod, name, arity}}) do
    encode_edge_node({:function, mod, name, arity})
  end

  defp encode_edge_node({:module, name}) do
    Jason.encode!(%{"type" => "module", "name" => atom_or_string(name)})
  end

  defp encode_edge_node({type, id}) when is_atom(type) do
    Jason.encode!(%{"type" => Atom.to_string(type), "id" => atom_or_string(id)})
  end

  defp encode_edge_node(other), do: inspect(other)

  defp atom_or_string(v) when is_atom(v), do: Atom.to_string(v)
  defp atom_or_string(v) when is_binary(v), do: v
  defp atom_or_string(v), do: to_string(v)

  defp decode_edge_node(encoded_raw, fallback_raw) do
    encoded = unwrap_typed(encoded_raw)

    with json when is_binary(json) and json != "" <- encoded,
         {:ok, decoded} <- Jason.decode(json),
         {:ok, node} <- decode_edge_node_map(decoded) do
      node
    else
      _ ->
        resolve_fallback_edge_node(unwrap_typed(fallback_raw))
    end
  end

  defp decode_edge_node_map(%{
         "type" => "function",
         "module" => mod,
         "name" => name,
         "arity" => arity
       })
       when is_binary(mod) and is_binary(name) and is_integer(arity) do
    {:ok, {:function, String.to_atom(mod), String.to_atom(name), arity}}
  end

  defp decode_edge_node_map(%{"type" => "module", "name" => name}) when is_binary(name) do
    {:ok, {:module, String.to_atom(name)}}
  end

  defp decode_edge_node_map(%{"type" => type, "id" => id})
       when is_binary(type) and is_binary(id) do
    {:ok, {String.to_atom(type), id}}
  end

  defp decode_edge_node_map(_), do: :error

  defp resolve_fallback_edge_node(nil), do: nil

  defp resolve_fallback_edge_node(raw_id) when is_binary(raw_id) do
    bare = String.replace_prefix(raw_id, "ast_node:", "")

    case MQ.exec(Dllb.Query.select("ast_node:#{bare}", []), query_fn()) do
      {:ok, [row | _]} ->
        data = dllb_row_to_node_data(row)

        case row_to_node_entry(row, data) do
          {:function, {mod, name, arity}} -> {:function, mod, name, arity}
          {type, id} -> {type, id}
        end

      _ ->
        raw_id
    end
  end

  defp resolve_fallback_edge_node(other), do: other

  defp extract_edge_metadata(row) when is_map(row) do
    weight = unwrap_typed(row["weight"]) || 1.0
    %{weight: weight}
  end

  defp row_to_node_entry(row, data) do
    kind = normalize_kind(row[:kind])

    case kind do
      :function ->
        mod_raw = data[:module] || row[:module]
        name_raw = data[:name] || row[:name]
        arity = data[:arity] || row[:arity]
        mod_atom = to_module_atom(mod_raw)
        name_atom = to_name_atom(name_raw)
        {:function, {mod_atom, name_atom, arity}}

      :module ->
        mod_raw = row[:module] || data[:module] || data[:name] || row[:name]
        {:module, to_module_atom(mod_raw)}

      other ->
        {other, row[:name]}
    end
  end

  defp normalize_kind(:function), do: :function
  defp normalize_kind(:function_def), do: :function
  defp normalize_kind("function"), do: :function
  defp normalize_kind("function_def"), do: :function
  defp normalize_kind(:module), do: :module
  defp normalize_kind(:container), do: :module
  defp normalize_kind("module"), do: :module
  defp normalize_kind("container"), do: :module
  defp normalize_kind(other) when is_atom(other), do: other
  defp normalize_kind(other) when is_binary(other), do: String.to_atom(other)
  defp normalize_kind(_), do: :unknown

  defp to_module_atom(nil), do: nil
  defp to_module_atom(atom) when is_atom(atom), do: atom

  defp to_module_atom(":" <> rest), do: String.to_atom(rest)

  defp to_module_atom(str) when is_binary(str) do
    cond do
      String.starts_with?(str, "Elixir.") ->
        String.to_atom(str)

      String.contains?(str, ".") ->
        String.to_atom("Elixir." <> str)

      true ->
        String.to_atom(str)
    end
  end

  defp to_name_atom(nil), do: nil
  defp to_name_atom(atom) when is_atom(atom), do: atom
  defp to_name_atom(str) when is_binary(str), do: String.to_atom(str)

  defp dllb_row_to_node_data(row) do
    data =
      row
      |> Map.drop([:id])
      |> add_backwards_compatible_keys()

    case Map.get(row, :ast_serialized) || Map.get(row, "ast_serialized") do
      json when is_binary(json) and json != "" ->
        decoded =
          try do
            Jason.decode!(json, keys: :atoms)
          rescue
            _ ->
              try do
                Jason.decode!(json)
              rescue
                _ -> %{}
              end
          end

        if is_map(decoded) do
          Map.merge(decoded, data)
        else
          data
        end

      _ ->
        data
    end
  end

  defp add_backwards_compatible_keys(row) do
    row
    |> maybe_copy_key(:file_path, :file)
    |> maybe_copy_key(:line_start, :line)
    |> maybe_copy_key(:docstring, :doc)
  end

  defp maybe_copy_key(map, src, dst) do
    case Map.get(map, src) do
      nil -> map
      val -> Map.put(map, dst, val)
    end
  end

  defp map_key(map, old_key, new_key) do
    case Map.pop(map, old_key) do
      {nil, _} -> map
      {value, updated_map} -> Map.put(updated_map, new_key, value)
    end
  end

  defp effective_limit(:infinity), do: nil
  defp effective_limit(n) when is_integer(n), do: n

  # dllb JSON wraps typed values as %{"String" => "value"}, %{"Int" => 42}, etc.
  defp unwrap_typed(%{"String" => v}), do: v
  defp unwrap_typed(%{"Int" => v}), do: v
  defp unwrap_typed(%{"Float" => v}), do: v
  defp unwrap_typed(%{"Bool" => v}), do: v
  defp unwrap_typed(v), do: v

  # dllb returns embedding vectors as %{"Array" => [%{"Float" => v}, ...]}.
  # Unwrap to a plain list of floats so callers can use Enum functions and length/1.
  defp unwrap_embedding(%{"Array" => items}) when is_list(items) do
    Enum.map(items, fn
      %{"Float" => f} -> f
      %{"Int" => i} -> i / 1
      v when is_float(v) -> v
      v when is_integer(v) -> v / 1
      _ -> 0.0
    end)
  end

  defp unwrap_embedding(v) when is_list(v), do: v
  defp unwrap_embedding(_), do: nil

  defp safe_to_edge_atom("calls"), do: :calls
  defp safe_to_edge_atom("contains"), do: :contains
  defp safe_to_edge_atom("imports"), do: :imports
  defp safe_to_edge_atom(other) when is_binary(other), do: String.to_atom(other)
  defp safe_to_edge_atom(other), do: other

  defp escape_value(v) when is_binary(v), do: "'#{String.replace(v, "'", "''")}'"
  defp escape_value(v) when is_integer(v), do: Integer.to_string(v)
  defp escape_value(v) when is_float(v), do: Float.to_string(v)
  defp escape_value(v) when is_atom(v), do: "'#{Atom.to_string(v)}'"
  defp escape_value(v), do: "'#{inspect(v)}'"
end
