defmodule Ragex.AI.Cache do
  @moduledoc """
  AI response cache for reducing costs and improving performance.

  Caches AI provider responses using ETS with TTL-based expiration and LRU eviction.

  ## Configuration

      config :ragex, :ai_cache,
        enabled: true,
        ttl: 3600,  # 1 hour in seconds
        max_size: 1000,  # maximum cache entries
        operation_caches: %{
          query: %{ttl: 3600, max_size: 500},
          explain: %{ttl: 7200, max_size: 300},
          suggest: %{ttl: 1800, max_size: 200}
        }

  ## Cache Key Generation

  Cache keys are SHA256 hashes of:
  - Query/prompt text
  - Context (if provided)
  - Model name
  - Provider
  - Relevant parameters (temperature, etc.)

  ## Features

  - TTL-based expiration
  - LRU eviction when max size exceeded
  - Separate caches per operation type
  - Cache hit/miss metrics
  - Thread-safe ETS operations
  """

  use GenServer
  require Logger

  @table_name :ragex_ai_cache
  @stats_table :ragex_ai_cache_stats

  # Client API

  @doc """
  Start the cache GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a cached response if it exists and hasn't expired.

  ## Returns

  - `{:ok, response}` - Cache hit with valid entry
  - `{:error, :not_found}` - Cache miss or expired entry
  """
  def get(operation, query, context, opts \\ []) do
    if enabled?() do
      provider = Keyword.get(opts, :provider, :unknown)
      model = Keyword.get(opts, :model, "unknown")
      key = generate_key(operation, query, context, provider, model, opts)

      case :ets.lookup(@table_name, key) do
        [{^key, response, expiry, _access_count}] ->
          now = System.system_time(:second)

          if now < expiry do
            # Update access count and timestamp for LRU
            :ets.update_counter(@table_name, key, {4, 1})
            increment_stat(:hits)
            {:ok, response}
          else
            # Expired entry
            :ets.delete(@table_name, key)
            increment_stat(:misses)
            {:error, :not_found}
          end

        [] ->
          increment_stat(:misses)
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Store a response in the cache.
  """
  def put(operation, query, context, response, opts \\ []) do
    if enabled?() do
      provider = Keyword.get(opts, :provider, :unknown)
      model = Keyword.get(opts, :model, "unknown")
      key = generate_key(operation, query, context, provider, model, opts)
      ttl = get_ttl(operation)
      expiry = System.system_time(:second) + ttl

      # Check if we need to evict before inserting
      check_and_evict()

      :ets.insert(@table_name, {key, response, expiry, 1})
      increment_stat(:puts)
      :ok
    else
      :ok
    end
  end

  @doc """
  Clear the entire cache.
  """
  def clear do
    :ets.delete_all_objects(@table_name)
    reset_stats()
    :ok
  end

  @doc """
  Clear cache for a specific operation.
  Note: Currently clears entire cache regardless of operation.
  """
  def clear(_operation) do
    clear()
  end

  @doc """
  Get cache statistics.
  """
  def stats do
    case :ets.lookup(@stats_table, :stats) do
      [{:stats, hits, misses, puts, evictions}] ->
        stats_map = %{hits: hits, misses: misses, puts: puts, evictions: evictions}
        size = :ets.info(@table_name, :size)
        max_size = get_max_size()
        ttl = Application.get_env(:ragex, :ai_cache, []) |> Keyword.get(:ttl, 3600)

        Map.merge(stats_map, %{
          enabled: enabled?(),
          size: size,
          max_size: max_size,
          ttl: ttl,
          utilization: if(max_size > 0, do: size / max_size, else: 0.0),
          hit_rate: calculate_hit_rate(stats_map),
          # [TODO]: implement per-operation tracking
          by_operation: %{}
        })

      [] ->
        %{
          enabled: enabled?(),
          hits: 0,
          misses: 0,
          puts: 0,
          evictions: 0,
          size: 0,
          max_size: 0,
          ttl: 3600,
          by_operation: %{}
        }
    end
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@stats_table, [:named_table, :public, :set])

    # Initialize stats
    :ets.insert(@stats_table, {:stats, 0, 0, 0, 0})

    # Load cache from disk if enabled
    if enabled?() do
      load_cache_from_disk()
    end

    # Schedule periodic cleanup of expired entries
    schedule_cleanup()

    Logger.info("AI Cache started (enabled: #{enabled?()}, max_size: #{get_max_size()})")

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    if enabled?() do
      save_cache_to_disk()
    end
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    if enabled?() do
      save_cache_to_disk()
    end
    :ok
  end

  # Private functions

  defp enabled? do
    Application.get_env(:ragex, :ai_cache, [])
    |> Keyword.get(:enabled, true)
  end

  defp get_ttl(operation) do
    cache_config = Application.get_env(:ragex, :ai_cache, [])

    # Check operation-specific TTL first
    operation_caches = Keyword.get(cache_config, :operation_caches, %{})
    operation_config = Map.get(operation_caches, operation, %{})

    Map.get(operation_config, :ttl) ||
      Keyword.get(cache_config, :ttl, 3600)
  end

  defp get_max_size do
    Application.get_env(:ragex, :ai_cache, [])
    |> Keyword.get(:max_size, 1000)
  end

  defp generate_key(operation, query, context, provider, model, opts) do
    # Create a deterministic key from all relevant parameters
    data = %{
      operation: operation,
      query: query,
      context: context,
      provider: provider,
      model: model,
      temperature: Keyword.get(opts, :temperature),
      max_tokens: Keyword.get(opts, :max_tokens)
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(data))
    |> Base.encode16(case: :lower)
  end

  defp check_and_evict do
    max_size = get_max_size()
    current_size = :ets.info(@table_name, :size)

    if current_size >= max_size do
      evict_lru()
    end
  end

  defp evict_lru do
    # Find entry with lowest access count (LRU)
    case :ets.select(@table_name, [{{:"$1", :"$2", :"$3", :"$4"}, [], [{{:"$1", :"$4"}}]}]) do
      [] ->
        :ok

      entries ->
        # Sort by access count and remove the least accessed
        {key, _count} = Enum.min_by(entries, fn {_k, count} -> count end)
        :ets.delete(@table_name, key)
        increment_stat(:evictions)
    end
  end

  defp cleanup_expired do
    now = System.system_time(:second)

    # Find and delete expired entries
    expired_keys =
      :ets.select(@table_name, [
        {{:"$1", :_, :"$2", :_}, [{:<, :"$2", now}], [:"$1"]}
      ])

    Enum.each(expired_keys, fn key ->
      :ets.delete(@table_name, key)
    end)

    if match?([_ | _], expired_keys) do
      Logger.debug("Cleaned up #{length(expired_keys)} expired cache entries")
    end
  end

  defp schedule_cleanup do
    # Clean up expired entries every 5 minutes
    Process.send_after(self(), :cleanup, 300_000)
  end

  defp increment_stat(stat_name) do
    :ets.update_counter(
      @stats_table,
      :stats,
      {Map.get(
         %{
           hits: 2,
           misses: 3,
           puts: 4,
           evictions: 5
         },
         stat_name,
         2
       ), 1},
      {:stats, 0, 0, 0, 0}
    )
  end

  defp reset_stats do
    :ets.insert(@stats_table, {:stats, 0, 0, 0, 0})
  end

  defp calculate_hit_rate(%{hits: hits, misses: misses}) do
    total = hits + misses

    if total > 0 do
      Float.round(hits / total, 3)
    else
      0.0
    end
  end

  defp cache_file_path do
    cache_config = Application.get_env(:ragex, :cache, [])
    cache_dir = Keyword.get(cache_config, :dir, Path.expand("~/.cache/ragex"))
    File.mkdir_p!(cache_dir)
    Path.join(cache_dir, "ai_cache.tab")
  end

  defp load_cache_from_disk do
    path = cache_file_path()

    if File.exists?(path) do
      :ets.delete(@table_name)

      case :ets.file2tab(String.to_charlist(path)) do
        {:ok, @table_name} ->
          Logger.info("AI Cache loaded from disk: #{path}")
          cleanup_expired()

        err ->
          Logger.warning("Failed to load AI Cache from disk: #{inspect(err)}")
          :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
      end
    end
  end

  defp save_cache_to_disk do
    path = cache_file_path()

    case :ets.tab2file(@table_name, String.to_charlist(path)) do
      :ok ->
        Logger.info("AI Cache saved to disk: #{path}")

      err ->
        Logger.warning("Failed to save AI Cache to disk: #{inspect(err)}")
    end
  end
end
