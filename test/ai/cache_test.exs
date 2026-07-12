defmodule Ragex.AI.CacheTest do
  use ExUnit.Case, async: false

  alias Ragex.AI.Cache

  setup do
    orig_ai_cache = Application.get_env(:ragex, :ai_cache)
    orig_cache = Application.get_env(:ragex, :cache)

    # Ensure cache is enabled for testing
    Application.put_env(:ragex, :ai_cache, enabled: true)

    # Configure a test cache directory
    test_cache_dir = Path.join(System.tmp_dir!(), "ragex_cache_test_#{:rand.uniform(100_000)}")
    Application.put_env(:ragex, :cache, dir: test_cache_dir, enabled: true)

    # Clear cache before starting
    Cache.clear()

    on_exit(fn ->
      # Restore original config
      if orig_ai_cache,
        do: Application.put_env(:ragex, :ai_cache, orig_ai_cache),
        else: Application.delete_env(:ragex, :ai_cache)

      if orig_cache,
        do: Application.put_env(:ragex, :cache, orig_cache),
        else: Application.delete_env(:ragex, :cache)

      # Restart the Cache supervisor child to pick up the restored config
      Supervisor.terminate_child(Ragex.Supervisor, Ragex.AI.Cache)
      Supervisor.restart_child(Ragex.Supervisor, Ragex.AI.Cache)

      File.rm_rf!(test_cache_dir)
    end)

    {:ok, cache_dir: test_cache_dir}
  end

  describe "AI Response Cache operations" do
    test "cache put and get" do
      assert {:error, :not_found} = Cache.get(:query, "what is elixir?", nil)

      assert :ok = Cache.put(:query, "what is elixir?", nil, "Elixir is functional")
      assert {:ok, "Elixir is functional"} = Cache.get(:query, "what is elixir?", nil)
    end

    test "disk persistence (save and load)" do
      # Add entry to cache
      assert :ok = Cache.put(:query, "why elixir?", nil, "Concurrency and fault tolerance")

      # Call private function save_cache_to_disk via GenServer state trigger or directly
      # Since save_cache_to_disk is private, we can trigger it by sending :cleanup or terminate
      # Or we can just call the GenServer terminate callback directly!
      assert :ok = Cache.terminate(:normal, %{})

      # Verify file was written to disk
      cache_file = Path.join(Application.get_env(:ragex, :cache)[:dir], "ai_cache.tab")
      assert File.exists?(cache_file)

      # Clear the in-memory ETS table and simulate full restart via Supervisor
      Supervisor.terminate_child(Ragex.Supervisor, Ragex.AI.Cache)

      # Verify table does not exist
      assert :ets.info(:ragex_ai_cache) == :undefined

      # Restart the child
      assert {:ok, _pid} = Supervisor.restart_child(Ragex.Supervisor, Ragex.AI.Cache)

      # Entry should be restored!
      assert {:ok, "Concurrency and fault tolerance"} = Cache.get(:query, "why elixir?", nil)
    end
  end
end
