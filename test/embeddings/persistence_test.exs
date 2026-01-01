defmodule Ragex.Embeddings.PersistenceTest do
  use ExUnit.Case, async: false
  alias Ragex.Embeddings.Persistence
  alias Ragex.Graph.Store

  @test_cache_root Path.join(System.tmp_dir!(), "ragex_test_cache")

  setup do
    # Override cache root for tests
    Application.put_env(:ragex, :cache_root, @test_cache_root)

    # Enable cache for tests
    Application.put_env(:ragex, :cache, enabled: true)

    # Clear test cache
    File.rm_rf!(@test_cache_root)

    # Clear the in-memory store
    Store.clear()

    on_exit(fn ->
      File.rm_rf!(@test_cache_root)
      Application.delete_env(:ragex, :cache_root)
      Application.delete_env(:ragex, :cache)
      Store.clear()
    end)

    :ok
  end

  describe "generate_project_hash/0" do
    test "generates consistent hash for same directory" do
      hash1 = Persistence.generate_project_hash()
      hash2 = Persistence.generate_project_hash()

      assert hash1 == hash2
      assert String.length(hash1) == 16
      assert String.match?(hash1, ~r/^[a-f0-9]{16}$/)
    end

    test "generates different hashes for different directories" do
      hash1 = Persistence.generate_project_hash()

      # Change directory temporarily
      original_dir = File.cwd!()
      tmp_dir = System.tmp_dir!()

      try do
        File.cd!(tmp_dir)
        hash2 = Persistence.generate_project_hash()

        assert hash1 != hash2
      after
        File.cd!(original_dir)
      end
    end
  end

  describe "save/1 and load/0" do
    test "saves and loads embeddings successfully" do
      # Store some embeddings
      Store.store_embedding(:function, "foo", [0.1, 0.2, 0.3], "def foo()")
      Store.store_embedding(:function, "bar", [0.4, 0.5, 0.6], "def bar()")
      Store.store_embedding(:module, "Baz", [0.7, 0.8, 0.9], "module Baz")

      # Save
      {:ok, path} = Persistence.save(Store.embeddings_table())
      assert File.exists?(path)

      # Clear the store
      Store.clear()
      assert Store.get_embedding(:function, "foo") == nil

      # Load
      {:ok, count} = Persistence.load()
      assert count == 3

      # Verify embeddings are restored
      assert {[0.1, 0.2, 0.3], "def foo()"} == Store.get_embedding(:function, "foo")
      assert {[0.4, 0.5, 0.6], "def bar()"} == Store.get_embedding(:function, "bar")
      assert {[0.7, 0.8, 0.9], "module Baz"} == Store.get_embedding(:module, "Baz")
    end

    test "returns error when loading non-existent cache" do
      assert {:error, :not_found} = Persistence.load()
    end

    test "saves metadata correctly" do
      Store.store_embedding(:function, "test", [0.1, 0.2], "test")

      {:ok, _} = Persistence.save(Store.embeddings_table())
      {:ok, stats} = Persistence.stats()

      metadata = stats.metadata
      assert metadata.version == 1
      assert metadata.model_id == :all_minilm_l6_v2
      assert metadata.dimensions == 384
      assert metadata.entity_count == 1
      assert is_integer(metadata.timestamp)
    end

    test "handles empty embeddings table" do
      {:ok, _} = Persistence.save(Store.embeddings_table())
      {:ok, count} = Persistence.load()
      assert count == 0
    end

    test "overwrites existing cache on save" do
      # Save first set
      Store.store_embedding(:function, "v1", [0.1], "v1")
      {:ok, path} = Persistence.save(Store.embeddings_table())

      # Save second set
      Store.clear()
      Store.store_embedding(:function, "v2", [0.2], "v2")
      {:ok, ^path} = Persistence.save(Store.embeddings_table())

      # Load should get v2
      Store.clear()
      {:ok, 1} = Persistence.load()
      assert {[0.2], "v2"} == Store.get_embedding(:function, "v2")
      assert Store.get_embedding(:function, "v1") == nil
    end
  end

  describe "cache_valid?/0" do
    test "returns true for compatible cache" do
      Store.store_embedding(:function, "test", [0.1], "test")
      {:ok, _} = Persistence.save(Store.embeddings_table())

      assert Persistence.cache_valid?() == true
    end

    test "returns false for non-existent cache" do
      assert Persistence.cache_valid?() == false
    end

    test "returns false for incompatible model" do
      # Save with current model
      Store.store_embedding(:function, "test", [0.1], "test")
      {:ok, path} = Persistence.save(Store.embeddings_table())

      # Manually modify metadata to simulate different model
      {:ok, table} = :ets.file2tab(String.to_charlist(path))
      [{:__metadata__, metadata}] = :ets.lookup(table, :__metadata__)

      # Change to incompatible model (different dimensions)
      modified_metadata = %{metadata | model_id: :all_mpnet_base_v2}
      :ets.insert(table, {:__metadata__, modified_metadata})
      :ets.tab2file(table, String.to_charlist(path))
      :ets.delete(table)

      # Should be invalid now
      assert Persistence.cache_valid?() == false
    end

    test "returns true for compatible model with same dimensions" do
      # Save with all-MiniLM-L6-v2 (384 dims)
      Store.store_embedding(:function, "test", [0.1], "test")
      {:ok, path} = Persistence.save(Store.embeddings_table())

      # Manually change to paraphrase-multilingual (also 384 dims)
      {:ok, table} = :ets.file2tab(String.to_charlist(path))
      [{:__metadata__, metadata}] = :ets.lookup(table, :__metadata__)

      modified_metadata = %{
        metadata
        | model_id: :paraphrase_multilingual
      }

      :ets.insert(table, {:__metadata__, modified_metadata})
      :ets.tab2file(table, String.to_charlist(path))
      :ets.delete(table)

      # Should still be valid (compatible dimensions)
      assert Persistence.cache_valid?() == true
    end
  end

  describe "stats/0" do
    test "returns stats for existing cache" do
      Store.store_embedding(:function, "foo", [0.1], "foo")
      Store.store_embedding(:module, "Bar", [0.2], "Bar")

      {:ok, path} = Persistence.save(Store.embeddings_table())
      {:ok, stats} = Persistence.stats()

      assert stats.cache_path == path
      assert stats.valid? == true
      assert stats.file_size > 0
      assert stats.metadata.entity_count == 2
      assert stats.metadata.model_id == :all_minilm_l6_v2
    end

    test "returns error for non-existent cache" do
      assert {:error, :not_found} = Persistence.stats()
    end

    test "marks incompatible cache as invalid in stats" do
      Store.store_embedding(:function, "test", [0.1], "test")
      {:ok, path} = Persistence.save(Store.embeddings_table())

      # Modify metadata to incompatible model
      {:ok, table} = :ets.file2tab(String.to_charlist(path))
      [{:__metadata__, metadata}] = :ets.lookup(table, :__metadata__)

      modified_metadata = %{
        metadata
        | model_id: :different_model,
          dimensions: 768
      }

      :ets.insert(table, {:__metadata__, modified_metadata})
      :ets.tab2file(table, String.to_charlist(path))
      :ets.delete(table)

      {:ok, stats} = Persistence.stats()
      assert stats.valid? == false
      assert stats.metadata.model_id == :different_model
    end
  end

  describe "clear/1" do
    test "clears current project cache" do
      Store.store_embedding(:function, "test", [0.1], "test")
      {:ok, path} = Persistence.save(Store.embeddings_table())
      assert File.exists?(path)

      :ok = Persistence.clear(:current)
      refute File.exists?(path)
    end

    test "clears all caches" do
      # Create cache for current project
      Store.store_embedding(:function, "test1", [0.1], "test1")
      {:ok, path1} = Persistence.save(Store.embeddings_table())

      # Create fake cache for another project
      cache_root = Application.get_env(:ragex, :cache_root, Persistence.default_cache_root())
      fake_dir = Path.join(cache_root, "fake_project_hash")
      File.mkdir_p!(fake_dir)
      fake_cache = Path.join(fake_dir, "embeddings.ets")
      File.write!(fake_cache, "fake cache")

      assert File.exists?(path1)
      assert File.exists?(fake_cache)

      :ok = Persistence.clear(:all)
      refute File.exists?(path1)
      refute File.exists?(fake_cache)
    end

    test "clears caches older than N days" do
      Store.store_embedding(:function, "test", [0.1], "test")
      {:ok, path} = Persistence.save(Store.embeddings_table())

      # File is fresh, should not be cleared
      :ok = Persistence.clear({:older_than, 1})
      assert File.exists?(path)

      # Manually set old mtime (10 days ago)
      old_date =
        :calendar.universal_time()
        |> :calendar.datetime_to_gregorian_seconds()
        |> Kernel.-(10 * 86_400)
        |> :calendar.gregorian_seconds_to_datetime()

      File.touch!(path, old_date)

      # Now should be cleared
      :ok = Persistence.clear({:older_than, 1})
      refute File.exists?(path)
    end

    test "handles clearing non-existent cache gracefully" do
      assert :ok = Persistence.clear(:current)
      assert :ok = Persistence.clear(:all)
      assert :ok = Persistence.clear({:older_than, 30})
    end
  end

  describe "integration with Graph.Store" do
    test "Store loads cache automatically" do
      # Create embeddings and save
      Store.store_embedding(:function, "auto_load", [0.1, 0.2], "auto load test")
      {:ok, _} = Persistence.save(Store.embeddings_table())

      # Clear store
      Store.clear()
      assert Store.get_embedding(:function, "auto_load") == nil

      # Load from cache
      {:ok, count} = Persistence.load()
      assert count == 1

      # Embeddings should be loaded
      assert {[0.1, 0.2], "auto load test"} == Store.get_embedding(:function, "auto_load")
    end

    test "Store saves cache" do
      Store.store_embedding(:function, "auto_save", [0.3, 0.4], "auto save test")

      # Save cache
      {:ok, _path} = Persistence.save(Store.embeddings_table())

      # Cache should exist and be valid
      assert Persistence.cache_valid?() == true
      {:ok, stats} = Persistence.stats()
      assert stats.metadata.entity_count == 1
    end

    test "Store skips loading incompatible cache" do
      # Create cache with modified metadata
      Store.store_embedding(:function, "test", [0.1], "test")
      {:ok, path} = Persistence.save(Store.embeddings_table())

      # Modify to incompatible model
      {:ok, table} = :ets.file2tab(String.to_charlist(path))
      [{:__metadata__, metadata}] = :ets.lookup(table, :__metadata__)
      modified = %{metadata | model_id: :incompatible, dimensions: 768}
      :ets.insert(table, {:__metadata__, modified})
      :ets.tab2file(table, String.to_charlist(path))
      :ets.delete(table)

      # Clear and try to load incompatible cache
      Store.clear()
      result = Persistence.load()

      # Should fail to load incompatible cache
      assert {:error, :incompatible} = result
      assert Store.get_embedding(:function, "test") == nil
    end
  end

  describe "concurrent access" do
    test "handles concurrent saves safely" do
      # Create multiple tasks that save simultaneously
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Store.store_embedding(:function, "test_#{i}", [i * 0.1], "test")
            Persistence.save(Store.embeddings_table())
          end)
        end

      # Wait for all tasks
      results = Task.await_many(tasks, 5000)

      # At least one should succeed
      assert Enum.any?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      # Cache should exist and be valid
      assert Persistence.cache_valid?() == true
    end

    test "handles concurrent loads safely" do
      Store.store_embedding(:function, "concurrent", [0.5], "test")
      {:ok, _} = Persistence.save(Store.embeddings_table())

      Store.clear()

      # Multiple tasks try to load simultaneously
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            Persistence.load()
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should either succeed or get a reasonable error
      assert Enum.all?(results, fn
               {:ok, _} -> true
               {:error, _} -> true
               _ -> false
             end)
    end
  end

  describe "edge cases" do
    test "handles very large embeddings" do
      # Create large embedding (10,000 dimensions)
      large_embedding = Enum.map(1..10_000, fn i -> i * 0.001 end)
      Store.store_embedding(:function, "large", large_embedding, "large test")

      {:ok, _} = Persistence.save(Store.embeddings_table())
      Store.clear()
      {:ok, 1} = Persistence.load()

      {loaded_embedding, _} = Store.get_embedding(:function, "large")
      assert length(loaded_embedding) == 10_000
      assert Enum.at(loaded_embedding, 0) == 0.001
      assert Enum.at(loaded_embedding, 9999) == 10.0
    end

    test "handles special characters in node IDs" do
      special_ids = [
        "foo/bar/baz.ex",
        "module::function",
        "test@example.com",
        "emoji_😀",
        "unicode_ñ_ü"
      ]

      for id <- special_ids do
        Store.store_embedding(:function, id, [0.1], "test")
      end

      {:ok, _} = Persistence.save(Store.embeddings_table())
      Store.clear()
      {:ok, count} = Persistence.load()

      assert count == length(special_ids)

      for id <- special_ids do
        assert {[0.1], "test"} == Store.get_embedding(:function, id)
      end
    end

    test "handles nil and empty text" do
      Store.store_embedding(:function, "no_text", [0.1], nil)
      Store.store_embedding(:function, "empty_text", [0.2], "")

      {:ok, _} = Persistence.save(Store.embeddings_table())
      Store.clear()
      {:ok, 2} = Persistence.load()

      assert {[0.1], nil} == Store.get_embedding(:function, "no_text")
      assert {[0.2], ""} == Store.get_embedding(:function, "empty_text")
    end

    test "handles corrupted cache file" do
      # Create valid cache
      Store.store_embedding(:function, "test", [0.1], "test")
      {:ok, path} = Persistence.save(Store.embeddings_table())

      # Corrupt the file
      File.write!(path, "corrupted data")

      # Load should fail gracefully
      assert {:error, _} = Persistence.load()
    end

    test "handles missing metadata in cache" do
      # Create cache without metadata
      table = :ets.new(:test_table, [:set])
      :ets.insert(table, {{:function, "test"}, [0.1], "test"})

      cache_dir = Persistence.cache_path() |> Path.dirname()
      File.mkdir_p!(cache_dir)
      path = Persistence.cache_path()

      :ets.tab2file(table, String.to_charlist(path))
      :ets.delete(table)

      # Load should fail gracefully when metadata is missing
      assert {:error, :no_metadata} = Persistence.load()
    end
  end

  describe "cache path generation" do
    test "generates unique paths for different projects" do
      path1 = Persistence.cache_path()

      original_dir = File.cwd!()
      tmp_dir = System.tmp_dir!()

      try do
        File.cd!(tmp_dir)
        path2 = Persistence.cache_path()

        assert path1 != path2
        assert String.contains?(path1, "ragex")
        assert String.contains?(path2, "ragex")
        # Both should contain different project hashes
        hash1 = Path.basename(Path.dirname(path1))
        hash2 = Path.basename(Path.dirname(path2))
        assert hash1 != hash2
      after
        File.cd!(original_dir)
      end
    end

    test "respects XDG_CACHE_HOME when set" do
      xdg_cache = Path.join(System.tmp_dir!(), "xdg_test_cache")

      # Temporarily remove cache_root override to test XDG
      Application.delete_env(:ragex, :cache_root)
      System.put_env("XDG_CACHE_HOME", xdg_cache)

      try do
        # Force recalculation by using default_cache_root
        path = Persistence.cache_path()
        assert String.starts_with?(path, xdg_cache)
      after
        System.delete_env("XDG_CACHE_HOME")
        Application.put_env(:ragex, :cache_root, @test_cache_root)
      end
    end
  end
end
