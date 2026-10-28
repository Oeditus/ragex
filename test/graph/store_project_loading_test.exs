defmodule Ragex.Graph.StoreProjectLoadingTest do
  use ExUnit.Case, async: false

  alias Ragex.Analyzers.Directory
  alias Ragex.Embeddings.{FileTracker, Persistence}
  alias Ragex.Graph.Store

  setup do
    # Fixtures inside this repository would all canonicalize to its Git root.
    tmp_dir =
      Path.join(System.tmp_dir!(), "ragex_project_load_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    original_cache_root = Application.get_env(:ragex, :cache_root)
    Application.put_env(:ragex, :cache_root, Path.join(tmp_dir, "cache"))
    assert :ok = Store.load_project(tmp_dir)

    on_exit(fn ->
      Store.clear()
      Store.sync()
      FileTracker.clear_all()

      :sys.replace_state(Store, fn state ->
        %{state | project_path: File.cwd!(), cache_loaded: false, loaded_backend: nil}
      end)

      File.rm_rf!(tmp_dir)

      if original_cache_root do
        Application.put_env(:ragex, :cache_root, original_cache_root)
      else
        Application.delete_env(:ragex, :cache_root)
      end
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "repeated loading preserves an initialized project with no tracked files", %{
    tmp_dir: tmp_dir
  } do
    Store.add_node(:module, EmptyProjectMarker, %{name: EmptyProjectMarker})
    Store.sync()
    assert [] = FileTracker.list_tracked_files()

    assert :ok = Store.load_project(tmp_dir)
    assert %{name: EmptyProjectMarker} = Store.get_module(EmptyProjectMarker)
    assert %{cache_loaded: true, loaded_backend: Ragex.Store.Backend.ETS} = :sys.get_state(Store)
  end

  test "repeated loading does not compute file tracker statistics", %{tmp_dir: tmp_dir} do
    store = Process.whereis(Store)
    :erlang.trace_pattern({FileTracker, :stats, 0}, true, [:local])
    :erlang.trace(store, true, [:call])

    try do
      assert :ok = Store.load_project(tmp_dir)
      delivery = :erlang.trace_delivered(store)
      assert_receive {:trace_delivered, ^store, ^delivery}
      refute_received {:trace, ^store, :call, {FileTracker, :stats, []}}
    after
      :erlang.trace(store, false, [:call])
      :erlang.trace_pattern({FileTracker, :stats, 0}, false, [:local])
    end
  end

  test "switching projects still clears unsaved nodes and file tracking", %{tmp_dir: tmp_dir} do
    Store.add_node(:module, PreviousProjectMarker, %{name: PreviousProjectMarker})
    Store.sync()
    other = Path.join(tmp_dir, "other")
    File.mkdir_p!(other)

    assert :ok = Store.load_project(other)
    assert Store.get_module(PreviousProjectMarker) == nil
    assert [] = FileTracker.list_tracked_files()
  end

  test "a backend change invalidates the same-project fast path", %{tmp_dir: tmp_dir} do
    Store.add_node(:module, PreviousBackendMarker, %{name: PreviousBackendMarker})
    Store.sync()

    # Simulate a previous backend without starting a database in this ETS test.
    :sys.replace_state(Store, fn state ->
      %{state | loaded_backend: Ragex.Store.Backend.Dllb}
    end)

    assert :ok = Store.load_project(tmp_dir)
    assert Store.get_module(PreviousBackendMarker) == nil
    assert %{loaded_backend: Ragex.Store.Backend.ETS} = :sys.get_state(Store)
  end

  test "shutdown does not overwrite a valid cache with invalidated state", %{tmp_dir: tmp_dir} do
    Store.add_node(:module, CachedMarker, %{name: CachedMarker})
    Store.sync()
    assert :ok = Store.save_cache(tmp_dir)

    project_hash = Persistence.generate_project_hash(tmp_dir)
    path = Path.join([Application.fetch_env!(:ragex, :cache_root), project_hash, "graph.ets"])
    cached_graph = File.read!(path)

    Store.clear()
    Store.sync()
    assert :ok = Store.terminate(:shutdown, :sys.get_state(Store))
    assert File.read!(path) == cached_graph
  end

  test "warm cache skips unchanged files and analyzes only branch-style changes", %{
    tmp_dir: tmp_dir
  } do
    shared = Path.join(tmp_dir, "shared.ex")
    removed = Path.join(tmp_dir, "removed.ex")
    unchanged = Path.join(tmp_dir, "unchanged.ex")
    added = Path.join(tmp_dir, "added.ex")

    for {path, module} <- [
          {shared, StartupShared},
          {removed, StartupRemoved},
          {unchanged, StartupUnchanged}
        ] do
      File.write!(path, "defmodule #{inspect(module)} do\n  def value, do: :before\nend\n")
    end

    opts = [watch: false, notify: false]
    assert {:ok, %{success: 3, skipped: 0}} = Directory.analyze_directory(tmp_dir, opts)

    # Switch away and back so fingerprints are genuinely restored from disk.
    other = Path.join(tmp_dir, "other")
    File.mkdir_p!(other)
    assert :ok = Store.load_project(other)
    assert :ok = Store.load_project(tmp_dir)

    assert {:ok, %{success: 0, analyzed: 0, skipped: 3}} =
             Directory.analyze_directory(tmp_dir, opts)

    File.write!(shared, "defmodule StartupShared do\n  def value, do: :after\nend\n")
    File.rm!(removed)
    File.write!(added, "defmodule StartupAdded do\n  def value, do: :new\nend\n")

    assert {:ok, %{success: 2, analyzed: 2, skipped: 1, errors: 0}} =
             Directory.analyze_directory(tmp_dir, opts)

    assert {:unchanged, _} = FileTracker.has_changed?(shared)
    assert {:unchanged, _} = FileTracker.has_changed?(unchanged)
    assert {:deleted, _} = FileTracker.has_changed?(removed)
  end
end
