defmodule Ragex.Store.Backend.DllbLoadingTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Ragex.Analyzers.Directory
  alias Ragex.Dllb.ProjectManager
  alias Ragex.Graph.Store
  alias Ragex.Store.Backend.Dllb, as: DllbBackend

  @server_binary System.get_env("DLLB_TEST_SERVER_BIN")
  if is_nil(@server_binary) do
    @moduletag skip: "set DLLB_TEST_SERVER_BIN to run isolated database integration tests"
  end

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ragex_dllb_loading_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    original =
      for {app, key} <- [
            {:ragex, :store_backend},
            {:ragex, :dllb_mode},
            {:ragex, :dllb_server_bin},
            {:ragex, :cache_root},
            {:ragex, :embedding_model},
            {:dllb, :enabled}
          ] do
        {app, key, Application.fetch_env(app, key)}
      end

    Application.put_env(:ragex, :store_backend, :dllb)
    Application.put_env(:ragex, :dllb_mode, :per_project)
    Application.put_env(:ragex, :dllb_server_bin, @server_binary)
    Application.put_env(:ragex, :cache_root, Path.join(tmp_dir, "cache"))
    Application.put_env(:dllb, :enabled, true)

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

  test "failed schema initialization is returned and can be retried", %{tmp_dir: tmp_dir} do
    Application.put_env(:ragex, :embedding_model, :all_minilm_l6_v2)
    assert :ok = Store.load_project(tmp_dir)

    assert {:ok, %Dllb.Result.Ok{}} =
             DllbBackend.query("REMOVE INDEX idx_source_embedding ON ast_node")

    assert {:ok, %Dllb.Result.Ok{}} =
             DllbBackend.query(
               "DEFINE VECTOR INDEX idx_source_embedding ON ast_node " <>
                 "FIELDS source_embedding DIMENSION 768 METRIC cosine"
             )

    assert :ok = ProjectManager.stop_instance(tmp_dir)
    assert {:error, %Dllb.Result.Error{message: message}} = Store.load_project(tmp_dir)
    assert message =~ "REMOVE INDEX"
    assert %{cache_loaded: false} = :sys.get_state(Store)

    assert {:error, %Dllb.Result.Error{}} =
             Directory.analyze_directory(tmp_dir, watch: false, notify: false)

    # A failed attachment must not be remembered as initialized. Matching
    # the existing schema on the next attempt must allow initialization.
    Application.put_env(:ragex, :embedding_model, :all_mpnet_base_v2)
    assert :ok = Store.load_project(tmp_dir)
    assert %{cache_loaded: true} = :sys.get_state(Store)
  end

  test "repeated loads reuse the initialized instance without schema bootstrap", %{
    tmp_dir: tmp_dir
  } do
    manager = Process.whereis(ProjectManager)
    :erlang.trace_pattern({DllbBackend, :bootstrap_instance, 1}, true, [:local])
    :erlang.trace(manager, true, [:call])

    try do
      assert :ok = Store.load_project(tmp_dir)
      assert_receive {:trace, ^manager, :call, {DllbBackend, :bootstrap_instance, [_]}}
      pool = ProjectManager.active_pool()

      assert :ok = DllbBackend.load_project(tmp_dir)
      assert :ok = Store.load_project(tmp_dir)
      assert ProjectManager.active_pool() == pool

      delivery = :erlang.trace_delivered(manager)
      assert_receive {:trace_delivered, ^manager, ^delivery}
      refute_received {:trace, ^manager, :call, {DllbBackend, :bootstrap_instance, [_]}}

      # Stopping an instance must not make the same-project fast path pretend
      # it is still available. A subsequent load recreates it and its schema.
      assert :ok = ProjectManager.stop_instance(tmp_dir)
      assert :ok = Store.load_project(tmp_dir)
      assert_receive {:trace, ^manager, :call, {DllbBackend, :bootstrap_instance, [_]}}
      assert {:ok, %Dllb.Result.Count{count: 0}} = DllbBackend.query("COUNT ast_node")
    after
      :erlang.trace(manager, false, [:call])
      :erlang.trace_pattern({DllbBackend, :bootstrap_instance, 1}, false, [:local])
    end
  end
end
