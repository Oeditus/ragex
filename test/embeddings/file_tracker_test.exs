defmodule Ragex.Embeddings.FileTrackerTest do
  use ExUnit.Case, async: false
  alias Ragex.Embeddings.FileTracker

  @test_dir Path.join(System.tmp_dir!(), "ragex_file_tracker_test")

  setup do
    # Clean up test directory
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    # Initialize tracker
    FileTracker.init()
    FileTracker.clear_all()

    on_exit(fn ->
      File.rm_rf!(@test_dir)
      FileTracker.clear_all()
    end)

    :ok
  end

  describe "track_file/2" do
    test "tracks a new file with its entities" do
      file_path = create_test_file("test.ex", "defmodule Test do\nend")

      analysis = %{
        modules: [%{name: "Test"}],
        functions: [%{module: "Test", name: "foo", arity: 0}],
        calls: [],
        imports: []
      }

      assert :ok = FileTracker.track_file(file_path, analysis)

      tracked = FileTracker.list_tracked_files()
      assert Enum.count(tracked) == 1

      {^file_path, metadata} = hd(tracked)
      assert metadata.path == file_path
      assert is_binary(metadata.content_hash)
      assert is_integer(metadata.mtime)
      assert is_integer(metadata.size)
      assert length(metadata.entities) == 2
      assert {:module, "Test"} in metadata.entities
      assert {:function, {"Test", "foo", 0}} in metadata.entities
    end

    test "updates tracking for existing file" do
      file_path = create_test_file("test.ex", "content v1")

      analysis = %{modules: [%{name: "Test"}], functions: [], calls: [], imports: []}

      FileTracker.track_file(file_path, analysis)

      # Update file
      File.write!(file_path, "content v2")

      analysis2 = %{
        modules: [%{name: "Test"}],
        functions: [%{module: "Test", name: "bar", arity: 1}],
        calls: [],
        imports: []
      }

      FileTracker.track_file(file_path, analysis2)

      # Should still have only one tracked file
      tracked = FileTracker.list_tracked_files()
      assert Enum.count(tracked) == 1

      {^file_path, metadata} = hd(tracked)
      assert length(metadata.entities) == 2
    end
  end

  describe "has_changed?/1" do
    test "returns {:new, nil} for untracked file" do
      file_path = create_test_file("new.ex", "content")
      assert {:new, nil} = FileTracker.has_changed?(file_path)
    end

    test "returns {:unchanged, metadata} for unchanged file" do
      file_path = create_test_file("unchanged.ex", "content")

      analysis = %{modules: [], functions: [], calls: [], imports: []}
      FileTracker.track_file(file_path, analysis)

      assert {:unchanged, metadata} = FileTracker.has_changed?(file_path)
      assert metadata.path == file_path
    end

    test "returns {:changed, old_metadata} for changed file" do
      file_path = create_test_file("changed.ex", "original content")

      analysis = %{modules: [], functions: [], calls: [], imports: []}
      FileTracker.track_file(file_path, analysis)

      # Change file content
      File.write!(file_path, "modified content")

      assert {:changed, old_metadata} = FileTracker.has_changed?(file_path)
      assert old_metadata.path == file_path
    end

    test "returns {:deleted, old_metadata} for deleted file" do
      file_path = create_test_file("deleted.ex", "content")

      analysis = %{modules: [], functions: [], calls: [], imports: []}
      FileTracker.track_file(file_path, analysis)

      # Delete file
      File.rm!(file_path)

      assert {:deleted, old_metadata} = FileTracker.has_changed?(file_path)
      assert old_metadata.path == file_path
    end
  end

  describe "get_stale_entities/0" do
    test "returns empty list when no files tracked" do
      assert [] = FileTracker.get_stale_entities()
    end

    test "returns empty list when all files unchanged" do
      file1 = create_test_file("file1.ex", "content1")
      file2 = create_test_file("file2.ex", "content2")

      analysis = %{modules: [%{name: "Test"}], functions: [], calls: [], imports: []}

      FileTracker.track_file(file1, analysis)
      FileTracker.track_file(file2, analysis)

      assert [] = FileTracker.get_stale_entities()
    end

    test "returns entities from changed files" do
      file1 = create_test_file("file1.ex", "content1")
      file2 = create_test_file("file2.ex", "content2")

      analysis1 = %{
        modules: [%{name: "Module1"}],
        functions: [%{module: "Module1", name: "func1", arity: 0}],
        calls: [],
        imports: []
      }

      analysis2 = %{
        modules: [%{name: "Module2"}],
        functions: [],
        calls: [],
        imports: []
      }

      FileTracker.track_file(file1, analysis1)
      FileTracker.track_file(file2, analysis2)

      # Change file1
      File.write!(file1, "modified content")

      stale = FileTracker.get_stale_entities()
      assert {:module, "Module1"} in stale
      assert {:function, {"Module1", "func1", 0}} in stale
      refute {:module, "Module2"} in stale
    end

    test "returns entities from deleted files" do
      file_path = create_test_file("deleted.ex", "content")

      analysis = %{
        modules: [%{name: "Deleted"}],
        functions: [],
        calls: [],
        imports: []
      }

      FileTracker.track_file(file_path, analysis)

      # Delete file
      File.rm!(file_path)

      stale = FileTracker.get_stale_entities()
      assert {:module, "Deleted"} in stale
    end

    test "deduplicates entities from multiple files" do
      file1 = create_test_file("file1.ex", "content1")
      file2 = create_test_file("file2.ex", "content2")

      # Both files reference the same module
      analysis = %{
        modules: [%{name: "Shared"}],
        functions: [],
        calls: [],
        imports: []
      }

      FileTracker.track_file(file1, analysis)
      FileTracker.track_file(file2, analysis)

      # Change both files
      File.write!(file1, "modified1")
      File.write!(file2, "modified2")

      stale = FileTracker.get_stale_entities()
      # Should only have one instance of {:module, "Shared"}
      assert Enum.count(stale, &(&1 == {:module, "Shared"})) == 1
    end
  end

  describe "untrack_file/1" do
    test "removes tracking for a file" do
      file_path = create_test_file("test.ex", "content")

      analysis = %{modules: [], functions: [], calls: [], imports: []}
      FileTracker.track_file(file_path, analysis)

      assert Enum.count(FileTracker.list_tracked_files()) == 1

      FileTracker.untrack_file(file_path)

      assert FileTracker.list_tracked_files() == []
    end

    test "handles untracking non-existent file" do
      assert :ok = FileTracker.untrack_file("/non/existent/file.ex")
    end
  end

  describe "clear_all/0" do
    test "clears all tracked files" do
      file1 = create_test_file("file1.ex", "content1")
      file2 = create_test_file("file2.ex", "content2")

      analysis = %{modules: [], functions: [], calls: [], imports: []}

      FileTracker.track_file(file1, analysis)
      FileTracker.track_file(file2, analysis)

      assert Enum.count(FileTracker.list_tracked_files()) == 2

      FileTracker.clear_all()

      assert FileTracker.list_tracked_files() == []
    end
  end

  describe "stats/0" do
    test "returns correct statistics" do
      file1 = create_test_file("file1.ex", "content1")
      file2 = create_test_file("file2.ex", "content2")
      file3 = create_test_file("file3.ex", "content3")

      analysis = %{
        modules: [%{name: "Test"}],
        functions: [%{module: "Test", name: "foo", arity: 0}],
        calls: [],
        imports: []
      }

      FileTracker.track_file(file1, analysis)
      FileTracker.track_file(file2, analysis)
      FileTracker.track_file(file3, analysis)

      # Modify file1
      File.write!(file1, "modified")

      # Delete file2
      File.rm!(file2)

      # file3 unchanged

      stats = FileTracker.stats()

      assert stats.total_files == 3
      assert stats.changed_files == 1
      assert stats.unchanged_files == 1
      assert stats.deleted_files == 1
      # 3 files * 2 entities each
      assert stats.total_entities == 6
      # Stale entities are deduplicated, so 2 unique entities (Test module + Test.foo function)
      assert stats.stale_entities == 2
    end

    test "returns zero stats when no files tracked" do
      stats = FileTracker.stats()

      assert stats.total_files == 0
      assert stats.changed_files == 0
      assert stats.unchanged_files == 0
      assert stats.deleted_files == 0
      assert stats.total_entities == 0
      assert stats.stale_entities == 0
    end
  end

  describe "export/0 and import/1" do
    test "exports and imports tracking data" do
      file1 = create_test_file("file1.ex", "content1")
      file2 = create_test_file("file2.ex", "content2")

      analysis = %{
        modules: [%{name: "Test"}],
        functions: [],
        calls: [],
        imports: []
      }

      FileTracker.track_file(file1, analysis)
      FileTracker.track_file(file2, analysis)

      # Export
      exported = FileTracker.export()

      assert exported.version == 1
      assert map_size(exported.tracked_files) == 2

      # Clear and import
      FileTracker.clear_all()
      assert FileTracker.list_tracked_files() == []

      assert :ok = FileTracker.import(exported)

      # Check imported data
      tracked = FileTracker.list_tracked_files()
      assert Enum.count(tracked) == 2

      paths = Enum.map(tracked, fn {path, _} -> path end)
      assert file1 in paths
      assert file2 in paths
    end

    test "handles invalid import data" do
      assert {:error, :invalid_format} = FileTracker.import(%{invalid: "data"})
      assert {:error, :invalid_format} = FileTracker.import(%{version: 999})
    end

    test "preserves metadata during export/import" do
      file_path = create_test_file("test.ex", "content")

      analysis = %{
        modules: [%{name: "Test"}],
        functions: [%{module: "Test", name: "foo", arity: 1}],
        calls: [],
        imports: []
      }

      FileTracker.track_file(file_path, analysis)

      exported = FileTracker.export()
      FileTracker.clear_all()
      FileTracker.import(exported)

      [{^file_path, metadata}] = FileTracker.list_tracked_files()

      assert metadata.path == file_path
      assert is_binary(metadata.content_hash)
      assert length(metadata.entities) == 2
      assert {:module, "Test"} in metadata.entities
      assert {:function, {"Test", "foo", 1}} in metadata.entities
    end
  end

  describe "edge cases" do
    test "handles files with special characters in path" do
      file_path = create_test_file("test file (1).ex", "content")

      analysis = %{modules: [%{name: "Test"}], functions: [], calls: [], imports: []}

      assert :ok = FileTracker.track_file(file_path, analysis)
      assert {:unchanged, _} = FileTracker.has_changed?(file_path)
    end

    test "handles empty analysis result" do
      file_path = create_test_file("empty.ex", "content")

      analysis = %{modules: [], functions: [], calls: [], imports: []}

      assert :ok = FileTracker.track_file(file_path, analysis)

      [{^file_path, metadata}] = FileTracker.list_tracked_files()
      assert metadata.entities == []
    end

    test "handles large number of entities" do
      file_path = create_test_file("large.ex", "content")

      # Generate many functions
      functions =
        Enum.map(1..1000, fn i ->
          %{module: "Test", name: "func_#{i}", arity: 0}
        end)

      analysis = %{
        modules: [%{name: "Test"}],
        functions: functions,
        calls: [],
        imports: []
      }

      assert :ok = FileTracker.track_file(file_path, analysis)

      [{^file_path, metadata}] = FileTracker.list_tracked_files()
      # 1 module + 1000 functions
      assert length(metadata.entities) == 1001
    end

    test "detects minimal content changes" do
      file_path = create_test_file("minimal.ex", "content")

      analysis = %{modules: [], functions: [], calls: [], imports: []}
      FileTracker.track_file(file_path, analysis)

      # Change just one character
      # lowercase c -> uppercase C
      File.write!(file_path, "Content")

      assert {:changed, _} = FileTracker.has_changed?(file_path)
    end

    test "handles concurrent tracking of different files" do
      files =
        Enum.map(1..10, fn i ->
          create_test_file("file_#{i}.ex", "content #{i}")
        end)

      analysis = %{modules: [%{name: "Test"}], functions: [], calls: [], imports: []}

      # Track files concurrently
      tasks =
        Enum.map(files, fn file ->
          Task.async(fn -> FileTracker.track_file(file, analysis) end)
        end)

      results = Task.await_many(tasks)

      assert Enum.all?(results, &(&1 == :ok))
      assert length(FileTracker.list_tracked_files()) == 10
    end
  end

  # Helper functions

  defp create_test_file(name, content) do
    file_path = Path.join(@test_dir, name)
    File.write!(file_path, content)
    file_path
  end
end
