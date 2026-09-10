defmodule Ragex.CacheRestartAndWatcherTest do
  use ExUnit.Case, async: false

  alias Ragex.Analysis.Cache
  alias Ragex.Analyzers.Directory
  alias Ragex.Embeddings.FileTracker
  alias Ragex.Embeddings.Persistence, as: EmbeddingsPersistence
  alias Ragex.Graph.Persistence, as: GraphPersistence
  alias Ragex.Graph.Store
  alias Ragex.Watcher

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "ragex_cache_watcher_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    test_file1 = Path.join(tmp_dir, "file1.ex")

    File.write!(
      test_file1,
      """
      defmodule TestModuleOne do
        def hello, do: :world
      end
      """
    )

    Store.clear()
    Store.sync()

    on_exit(fn ->
      Watcher.unwatch_directory(tmp_dir)
      File.rm_rf!(tmp_dir)
      Cache.clear(tmp_dir)
      GraphPersistence.clear(tmp_dir)
      EmbeddingsPersistence.clear({:project, tmp_dir})
    end)

    {:ok, tmp_dir: tmp_dir, file1: test_file1}
  end

  describe "cache persistence and restart reuse" do
    test "saves cache on directory analysis and reuses it on restart", %{
      tmp_dir: tmp_dir,
      file1: file1
    } do
      # 1. First analysis - should analyze file1
      {:ok, result1} = Directory.analyze_directory(tmp_dir, watch: false)
      assert result1.analyzed == 1
      assert result1.skipped == 0

      # Verify node was created in store
      assert Store.get_module(TestModuleOne) != nil

      # Explicitly save cache
      Store.save_cache(tmp_dir)

      # 2. Simulate process restart by clearing in-memory store and file tracker
      Store.clear()
      Store.sync()
      FileTracker.clear_all()
      assert Store.get_module(TestModuleOne) == nil

      # 3. Reload project from disk cache
      Store.load_project(tmp_dir)
      assert Store.get_module(TestModuleOne) != nil

      # 4. Analyze directory again after restart - should skip unchanged file1
      {:ok, result2} = Directory.analyze_directory(tmp_dir, watch: false)
      assert result2.analyzed == 0
      assert result2.skipped == 1

      # 5. Modify file1 and add file2
      File.write!(
        file1,
        """
        defmodule TestModuleOne do
          def hello, do: :updated_world
        end
        """
      )

      file2 = Path.join(tmp_dir, "file2.ex")

      File.write!(
        file2,
        """
        defmodule TestModuleTwo do
          def foo, do: :bar
        end
        """
      )

      # 6. Re-analyze - should only analyze modified file1 and new file2
      {:ok, result3} = Directory.analyze_directory(tmp_dir, watch: false)
      assert result3.analyzed == 2
      assert Store.get_module(TestModuleTwo) != nil
    end
  end

  describe "directory watcher and file monitoring" do
    test "automatically starts watching directory on analyze_directory and handles file changes",
         %{
           tmp_dir: tmp_dir,
           file1: file1
         } do
      # Analyze directory with watch: true
      {:ok, _} = Directory.analyze_directory(tmp_dir, watch: true)

      # Verify directory is registered in Watcher
      watched = Watcher.list_watched()
      assert tmp_dir in watched

      # Send a file modification event to Watcher
      send(Watcher, {:file_event, self(), {file1, [:modified]}})

      # Wait for debounce and processing
      Process.sleep(400)

      # Verify cache was updated and node still present
      assert Store.get_module(TestModuleOne) != nil
    end
  end
end
