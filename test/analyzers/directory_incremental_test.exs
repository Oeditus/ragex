defmodule Ragex.Analyzers.DirectoryIncrementalTest do
  use ExUnit.Case, async: false

  alias Ragex.Analyzers.Directory

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ragex_incremental_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    old_cache_root = Application.get_env(:ragex, :cache_root)
    Application.put_env(:ragex, :cache_root, Path.join(tmp_dir, ".cache"))

    on_exit(fn ->
      if old_cache_root do
        Application.put_env(:ragex, :cache_root, old_cache_root)
      else
        Application.delete_env(:ragex, :cache_root)
      end

      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "saves once after changes and never for an unchanged scan", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "warm.ex")
    File.write!(file, "defmodule WarmDirectoryTest do\n  def value, do: :first\nend\n")
    store = Process.whereis(Ragex.Graph.Store)
    pattern = [{[{:save_cache, :_}, :_, :_], [], []}]
    :erlang.trace_pattern({Ragex.Graph.Store, :handle_call, 3}, pattern, [:local])
    :erlang.trace(store, true, [:call])
    opts = [notify: false, watch: false, generate_embeddings: false]

    try do
      assert {:ok, %{success: 1}} = Directory.analyze_directory(tmp_dir, opts)
      assert_cache_saves(store, 1)
      assert {:ok, %{success: 0, skipped: 1}} = Directory.analyze_directory(tmp_dir, opts)
      assert_cache_saves(store, 0)

      File.write!(file, "defmodule WarmDirectoryTest do\n  def value, do: :second\nend\n")
      assert {:ok, %{success: 1}} = Directory.analyze_directory(tmp_dir, opts)
      assert_cache_saves(store, 1)
    after
      :erlang.trace(store, false, [:call])
      :erlang.trace_pattern({Ragex.Graph.Store, :handle_call, 3}, false, [:local])
    end
  end

  test "forwards generate_embeddings for directories and individual files", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "no_embeddings.ex")
    File.write!(file, "defmodule NoEmbeddingDirectoryTest do\n  def value, do: :ok\nend\n")
    Code.ensure_loaded!(Ragex.Embeddings.Helper)
    Code.ensure_loaded!(Ragex.Embeddings.FileTracker)

    :erlang.trace_pattern({Ragex.Embeddings.Helper, :generate_and_store_embeddings, 2}, true, [
      :local
    ])

    :erlang.trace_pattern({Ragex.Embeddings.FileTracker, :stale_entities_for_file, 2}, true, [
      :local
    ])

    :erlang.trace(:all, true, [:call, :set_on_spawn])

    try do
      for path <- [tmp_dir, file] do
        assert {:ok, %{success: 1}} =
                 Directory.analyze_directory(path,
                   load_project: false,
                   notify: false,
                   watch: false,
                   force_refresh: true,
                   generate_embeddings: false
                 )
      end

      refute_received {:trace, _, :call,
                       {Ragex.Embeddings.Helper, :generate_and_store_embeddings, _}}

      refute_received {:trace, _, :call,
                       {Ragex.Embeddings.FileTracker, :stale_entities_for_file, _}}
    after
      :erlang.trace(:all, false, [:call, :set_on_spawn])

      :erlang.trace_pattern({Ragex.Embeddings.Helper, :generate_and_store_embeddings, 2}, false, [
        :local
      ])

      :erlang.trace_pattern({Ragex.Embeddings.FileTracker, :stale_entities_for_file, 2}, false, [
        :local
      ])
    end
  end

  defp assert_cache_saves(store, count) do
    delivery = :erlang.trace_delivered(store)
    assert_receive {:trace_delivered, ^store, ^delivery}

    for _ <- List.duplicate(:save, count) do
      assert_received {:trace, ^store, :call,
                       {Ragex.Graph.Store, :handle_call, [{:save_cache, _}, _, _]}}
    end

    refute_received {:trace, ^store, :call,
                     {Ragex.Graph.Store, :handle_call, [{:save_cache, _}, _, _]}}
  end
end
