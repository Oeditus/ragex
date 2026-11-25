defmodule Ragex.Store.Backend.DllbGraphTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Ragex.Dllb.Adapter, as: DllbAdapter
  alias Ragex.Dllb.ProjectManager
  alias Ragex.Graph.{Algorithms, Store}
  alias Ragex.MCP.Handlers.Tools
  alias Ragex.Store.Backend.Dllb, as: DllbBackend

  @server_binary System.get_env("DLLB_TEST_SERVER_BIN") || ProjectManager.find_dllb_binary()
  if is_nil(@server_binary) do
    @moduletag skip: "dllb-server binary not found; skipping live DLLB graph tests"
  end

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ragex_dllb_graph_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    original =
      for {app, key} <- [
            {:ragex, :store_backend},
            {:ragex, :dllb_mode},
            {:ragex, :dllb_server_bin},
            {:ragex, :cache_root},
            {:dllb, :enabled}
          ] do
        {app, key, Application.fetch_env(app, key)}
      end

    Application.put_env(:ragex, :store_backend, :dllb)
    Application.put_env(:ragex, :dllb_mode, :per_project)
    Application.put_env(:ragex, :dllb_server_bin, @server_binary)
    Application.put_env(:ragex, :cache_root, Path.join(tmp_dir, "cache"))
    Application.put_env(:dllb, :enabled, true)

    assert :ok = Store.load_project(tmp_dir)

    on_exit(fn ->
      ProjectManager.stop_instance(tmp_dir)

      Enum.each(original, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)

      :sys.replace_state(Store, fn state ->
        %{state | project_path: File.cwd!(), cache_loaded: false, loaded_backend: nil}
      end)

      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "MCP graph_stats, find_callers, get_calls, and find_paths agree with native DLLB GRAPH EDGES",
       %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "ledger_live.ex")

    File.write!(file, """
    defmodule YokeBookkeeperWeb.LedgerLive do
      def mount(params, _session, socket) do
        YokeBookkeeperWeb.LedgerLive.load_ledger(socket, params)
      end

      def load_ledger(socket, params) do
        GenServer.cast(socket, params)
      end
    end
    """)

    assert {:ok, _} = Tools.call_tool("analyze_file", %{"path" => file})
    Store.sync()

    # Native DLLB GRAPH EDGES calls count
    assert {:ok, %Dllb.Result.Rows{count: native_call_count, data: native_rows}} =
             DllbBackend.query(Dllb.Query.graph_edges("calls"))

    assert native_call_count == 2
    assert length(native_rows) == 2

    # Store.stats() must report non-zero nodes and edges
    store_stats = Store.stats()
    assert store_stats.nodes >= 3
    assert store_stats.edges >= native_call_count

    # MCP graph_stats must agree with native call edges and have consistent in/out degrees
    assert {:ok, mcp_stats} = Tools.call_tool("graph_stats", %{})
    assert mcp_stats.node_count >= 3
    assert mcp_stats.edge_count == native_call_count
    assert mcp_stats.average_degree > 0.0
    assert mcp_stats.top_by_degree != []

    for entry <- mcp_stats.top_by_degree do
      assert entry.total_degree == entry.in_degree + entry.out_degree
    end

    # Algorithms.degree_centrality() must have exact in_degree and out_degree
    centrality = Algorithms.degree_centrality()

    load_ledger_deg =
      Map.get(centrality, {:function, YokeBookkeeperWeb.LedgerLive, :load_ledger, 2})

    assert load_ledger_deg == %{in_degree: 1, out_degree: 1, total_degree: 2}

    mount_deg = Map.get(centrality, {:function, YokeBookkeeperWeb.LedgerLive, :mount, 3})
    assert mount_deg == %{in_degree: 0, out_degree: 1, total_degree: 1}

    # MCP find_callers with and without arity, with both module spellings
    for module <- ["YokeBookkeeperWeb.LedgerLive", "Elixir.YokeBookkeeperWeb.LedgerLive"],
        arity <- [nil, 2] do
      args = %{"module" => module, "function_name" => "load_ledger"}
      args = if arity, do: Map.put(args, "arity", arity), else: args

      assert {:ok, %{count: 1, callers: [caller]}} = Tools.call_tool("find_callers", args)
      assert caller.id == "Elixir.YokeBookkeeperWeb.LedgerLive.mount/3"
      assert caller.file == file
      assert caller.line == 2
    end

    # MCP query_graph get_callers
    assert {:ok, %{count: 1, callers: [caller_edge]}} =
             Tools.call_tool("query_graph", %{
               "query_type" => "get_callers",
               "params" => %{
                 "module" => "YokeBookkeeperWeb.LedgerLive",
                 "function" => "load_ledger",
                 "arity" => 2
               }
             })

    assert caller_edge.caller_module == "Elixir.YokeBookkeeperWeb.LedgerLive"
    assert caller_edge.caller_function == "mount"
    assert caller_edge.caller_arity == 3

    # MCP query_graph get_calls must return both internal and external calls (e.g. GenServer.cast/2)
    assert {:ok, %{calls: [%{to: {:function, GenServer, :cast, 2}}]}} =
             Tools.call_tool("query_graph", %{
               "query_type" => "get_calls",
               "params" => %{
                 "module" => "YokeBookkeeperWeb.LedgerLive",
                 "function" => "load_ledger",
                 "arity" => 2
               }
             })

    assert {:ok, %{calls: [%{to: {:function, YokeBookkeeperWeb.LedgerLive, :load_ledger, 2}}]}} =
             Tools.call_tool("query_graph", %{
               "query_type" => "get_calls",
               "params" => %{
                 "module" => "YokeBookkeeperWeb.LedgerLive",
                 "function" => "mount"
               }
             })

    # MCP find_paths must traverse the stored call graph
    assert {:ok,
            %{
              count: 1,
              paths: [
                [
                  "Elixir.YokeBookkeeperWeb.LedgerLive.mount/3",
                  "Elixir.YokeBookkeeperWeb.LedgerLive.load_ledger/2"
                ]
              ]
            }} =
             Tools.call_tool("find_paths", %{
               "from" => "YokeBookkeeperWeb.LedgerLive.mount/3",
               "to" => "YokeBookkeeperWeb.LedgerLive.load_ledger/2"
             })
  end

  test "reads legacy DLLB call edges stored with inspected 4-tuple IDs without reindexing" do
    # Simulate an existing DB created by Ragex <= 0.46.0 where ast_node used
    # 2-tuple IDs while RELATE edges fell through to inspected 4-tuple IDs.
    Store.add_node(:function, {EdgeBatcher, :edge, 2}, %{
      module: EdgeBatcher,
      name: :edge,
      arity: 2,
      file: "lib/edge_batcher.ex",
      line: 10
    })

    Store.sync()

    legacy_from =
      inspect({:function, EdgeBatcher, :edge, 2}) |> String.replace(~r/[^a-zA-Z0-9_]/, "_")

    legacy_to =
      inspect({:function, GenServer, :cast, 2}) |> String.replace(~r/[^a-zA-Z0-9_]/, "_")

    assert {:ok, _} =
             DllbBackend.query(
               Dllb.Query.relate("ast_node:#{legacy_from}", "calls", "ast_node:#{legacy_to}", %{
                 weight: 1.0
               })
             )

    assert [%{to: ^legacy_to, type: :calls}] =
             Store.get_outgoing_edges({:function, EdgeBatcher, :edge, 2}, :calls)

    assert [%{from: ^legacy_from, type: :calls}] =
             Store.get_incoming_edges({:function, GenServer, :cast, 2}, :calls)

    assert {:ok, %{count: 1, callers: [%{id: ^legacy_from}]}} =
             Tools.call_tool("find_callers", %{
               "module" => "GenServer",
               "function_name" => "cast",
               "arity" => 2
             })

    assert {:ok, %{edge_count: 1, top_by_degree: top_by_degree}} =
             Tools.call_tool("graph_stats", %{})

    assert top_by_degree != []

    for entry <- top_by_degree do
      assert entry.total_degree == entry.in_degree + entry.out_degree
    end
  end

  test "MCP graph, metadata, embedding, vector search, FTS, and analysis tools all query DLLB", %{
    tmp_dir: tmp_dir
  } do
    file_a = Path.join(tmp_dir, "accounts.ex")
    file_b = Path.join(tmp_dir, "billing.ex")

    File.write!(file_a, """
    defmodule Demo.Accounts do
      def fetch_user(id) do
        "fetching_user_record"
        Demo.Billing.charge(id)
      end
    end
    """)

    File.write!(file_b, """
    defmodule Demo.Billing do
      import Demo.Accounts

      def charge(id) do
        "charging_credit_card"
        send_receipt(id)
      end

      def send_receipt(id) do
        {:ok, id}
      end
    end
    """)

    assert {:ok, _} =
             Tools.call_tool("analyze_file", %{"path" => file_a, "generate_embeddings" => false})

    assert {:ok, _} =
             Tools.call_tool("analyze_file", %{"path" => file_b, "generate_embeddings" => false})

    Store.sync()

    # Verify ETS tables are empty so all results below come strictly from DLLB.
    assert :ets.info(:ragex_nodes, :size) == 0
    assert :ets.info(:ragex_edges, :size) == 0
    assert :ets.info(:ragex_embeddings, :size) == 0

    # list_nodes (modules & functions)
    assert {:ok, %{nodes: mod_nodes, total_count: 2}} =
             Tools.call_tool("list_nodes", %{"node_type" => "module"})

    assert Enum.map(mod_nodes, & &1.id) |> MapSet.new() ==
             MapSet.new([Demo.Accounts, Demo.Billing])

    assert {:ok, %{total_count: 3}} =
             Tools.call_tool("list_nodes", %{"node_type" => "function"})

    # query_graph: find_module, find_function, get_dependencies
    assert {:ok, %{found: true, node: mod_node}} =
             Tools.call_tool("query_graph", %{
               "query_type" => "find_module",
               "params" => %{"name" => "Demo.Billing"}
             })

    assert mod_node[:file] == file_b

    assert {:ok, %{found: true, node: fn_node}} =
             Tools.call_tool("query_graph", %{
               "query_type" => "find_function",
               "params" => %{"module" => "Demo.Billing", "name" => "charge"}
             })

    assert fn_node[:arity] == 1

    assert {:ok, %{dependencies: [%{to: {:module, Demo.Accounts}}]}} =
             Tools.call_tool("query_graph", %{
               "query_type" => "get_dependencies",
               "params" => %{"module" => "Demo.Billing"}
             })

    # Graph analytics tools: betweenness, closeness, communities, export_graph
    assert {:ok,
            %{top_nodes: [%{node_id: "Elixir.Demo.Billing.charge/1", betweenness_score: 0.5} | _]}} =
             Tools.call_tool("betweenness_centrality", %{})

    assert {:ok, %{top_nodes: cc_nodes}} = Tools.call_tool("closeness_centrality", %{})
    assert cc_nodes != []

    assert {:ok, communities} = Tools.call_tool("detect_communities", %{})
    assert is_list(communities) and communities != []

    assert {:ok, dot} = Tools.call_tool("export_graph", %{"format" => "graphviz"})
    assert dot =~ "digraph"

    # search_strings (uses update_node_metadata persisted to DLLB)
    assert {:ok, %{count: 1, results: [str_hit]}} =
             Tools.call_tool("search_strings", %{"query" => "credit_card"})

    assert str_hit.function == "Elixir.Demo.Billing.charge/1"
    assert str_hit.string == "charging_credit_card"

    # Embeddings + HNSW VECTOR SEARCH + Tantivy FTS SEARCH via per-project DLLB
    {:ok, dim} =
      Ragex.Embeddings.Registry.dimensions(
        Application.get_env(:ragex, :embedding_model, Ragex.Embeddings.Registry.default())
      )

    emb_charge = [1.0 | List.duplicate(0.0, dim - 1)]
    emb_fetch = [0.0, 1.0 | List.duplicate(0.0, dim - 2)]

    Store.store_embedding(
      :function,
      {Demo.Billing, :charge, 1},
      emb_charge,
      "charge credit card payment billing"
    )

    Store.store_embedding(
      :function,
      {Demo.Accounts, :fetch_user, 1},
      emb_fetch,
      "fetch user account profile"
    )

    Store.sync()

    assert Store.count_embeddings() == 2

    assert {^emb_charge, "charge credit card payment billing"} =
             Store.get_embedding(:function, {Demo.Billing, :charge, 1})

    assert length(Store.list_embeddings(:function)) == 2

    # VectorStore.search uses native DLLB HNSW VECTOR SEARCH and returns cosine similarity ~1.0
    vector_hits =
      Ragex.VectorStore.search(emb_charge, limit: 5, threshold: 0.5, node_type: :function)

    assert [%{node_type: :function, node_id: {Demo.Billing, :charge, 1}, score: score}] =
             vector_hits

    assert score > 0.99

    # get_embeddings_stats reports real DLLB vector and graph counts
    assert {:ok,
            %{embeddings: %{total_embeddings: 2, dimensions: ^dim}, graph: %{nodes: n, edges: e}}} =
             Tools.call_tool("get_embeddings_stats", %{})

    assert n >= 5
    assert e >= 2

    # DllbAdapter.query routes to per-project DLLB for Tantivy FTS SEARCH
    assert {:ok, %Dllb.Result.Rows{count: 1, data: [fts_row]}} =
             DllbAdapter.query(Dllb.Query.search("ast_node", "source_text", "billing", limit: 5))

    assert fts_row["name"] == %{"String" => "charge"}

    # Dependency & impact analysis tools backed by DLLB
    assert {:ok, _} = Tools.call_tool("analyze_dependencies", %{})
    assert {:ok, _} = Tools.call_tool("coupling_report", %{})
    assert {:ok, _} = Tools.call_tool("find_circular_dependencies", %{})
  end
end
