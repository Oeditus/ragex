defmodule Mix.Tasks.Ragex.Cache.Clear do
  @moduledoc """
  Clears cached embeddings.

  ## Usage

      mix ragex.cache.clear [options]

  ## Options

      --current             Clear cache for the current project only
      --all                 Clear all cached projects
      --older-than DAYS     Clear caches older than N days
      --force               Skip confirmation prompt

  ## Examples

      # Clear current project cache (with confirmation)
      $ mix ragex.cache.clear --current

      # Clear all caches without confirmation
      $ mix ragex.cache.clear --all --force

      # Clear caches older than 30 days
      $ mix ragex.cache.clear --older-than 30

  """

  use Mix.Task
  alias Ragex.Embeddings.Persistence

  @shortdoc "Clear embedding caches"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [current: :boolean, all: :boolean, older_than: :integer, force: :boolean]
      )

    cond do
      opts[:current] ->
        clear_current(opts[:force])

      opts[:all] ->
        clear_all(opts[:force])

      opts[:older_than] ->
        clear_older_than(opts[:older_than], opts[:force])

      true ->
        IO.puts("Error: Please specify --current, --all, or --older-than")

        IO.puts(
          "\nUsage: mix ragex.cache.clear [--current | --all | --older-than DAYS] [--force]"
        )

        IO.puts("\nRun `mix help ragex.cache.clear` for more information.")
    end
  end

  defp clear_current(force) do
    IO.puts("\nClearing cache for current project...")

    case Persistence.stats() do
      {:ok, stats} ->
        if force or confirm_clear(stats) do
          :ok = Persistence.clear(:current)
          IO.puts("✓ Cache cleared successfully\n")
        else
          IO.puts("Cancelled.\n")
        end

      {:error, :not_found} ->
        IO.puts("No cache found for current project.\n")

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}\n")
    end
  end

  defp clear_all(force) do
    IO.puts("\nClearing all Ragex caches...")

    cache_root = Path.join(System.user_home!(), ".cache/ragex")

    if File.exists?(cache_root) do
      cache_dirs = File.ls!(cache_root)
      count = length(cache_dirs)

      if count == 0 do
        IO.puts("No caches found.\n")
      else
        {total_count, total_size} = calculate_all_cache_stats(cache_root, cache_dirs)

        IO.puts("\nFound #{total_count} cache(s):")
        IO.puts("  Total size: #{format_bytes(total_size)}")

        if force or confirm_clear_all(total_count, total_size) do
          :ok = Persistence.clear(:all)
          IO.puts("\n✓ All caches cleared successfully\n")
        else
          IO.puts("Cancelled.\n")
        end
      end
    else
      IO.puts("No cache directory found.\n")
    end
  end

  defp clear_older_than(days, force) when days > 0 do
    IO.puts("\nClearing caches older than #{days} day(s)...")

    cache_root = Path.join(System.user_home!(), ".cache/ragex")

    if File.exists?(cache_root) do
      cutoff_time = System.os_time(:second) - days * 24 * 60 * 60
      old_caches = find_old_caches(cache_root, cutoff_time)

      if Enum.empty?(old_caches) do
        IO.puts("No caches older than #{days} day(s) found.\n")
      else
        count = length(old_caches)
        total_size = Enum.reduce(old_caches, 0, fn {_, size, _}, acc -> acc + size end)

        IO.puts("\nFound #{count} old cache(s):")
        IO.puts("  Total size: #{format_bytes(total_size)}")

        if force or confirm_clear_old(count, total_size, days) do
          :ok = Persistence.clear({:older_than, days})
          IO.puts("\n✓ Old caches cleared successfully\n")
        else
          IO.puts("Cancelled.\n")
        end
      end
    else
      IO.puts("No cache directory found.\n")
    end
  end

  defp clear_older_than(_days, _force) do
    IO.puts("Error: --older-than requires a positive number of days\n")
  end

  defp calculate_all_cache_stats(cache_root, cache_dirs) do
    Enum.reduce(cache_dirs, {0, 0}, fn project_hash, {count, total_size} ->
      cache_file = Path.join([cache_root, project_hash, "embeddings.ets"])

      if File.exists?(cache_file) do
        stat = File.stat!(cache_file)
        {count + 1, total_size + stat.size}
      else
        {count, total_size}
      end
    end)
  end

  defp find_old_caches(cache_root, cutoff_time) do
    cache_root
    |> File.ls!()
    |> Enum.flat_map(fn project_hash ->
      cache_file = Path.join([cache_root, project_hash, "embeddings.ets"])

      if File.exists?(cache_file) do
        stat = File.stat!(cache_file)
        mtime = :calendar.datetime_to_gregorian_seconds(stat.mtime) - 62_167_219_200

        if mtime < cutoff_time do
          [{project_hash, stat.size, stat.mtime}]
        else
          []
        end
      else
        []
      end
    end)
  end

  defp confirm_clear(stats) do
    IO.puts("\nCache information:")
    IO.puts("  Model: #{stats.metadata[:model_id]}")
    IO.puts("  Entities: #{stats.metadata[:entity_count]}")
    IO.puts("  Size: #{format_bytes(stats.file_size)}")

    IO.gets("\nAre you sure you want to clear this cache? [y/N] ")
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("y")
  end

  defp confirm_clear_all(count, total_size) do
    IO.puts("")

    IO.gets(
      "Are you sure you want to clear all #{count} cache(s) (#{format_bytes(total_size)})? [y/N] "
    )
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("y")
  end

  defp confirm_clear_old(count, total_size, days) do
    IO.puts("")

    IO.gets(
      "Are you sure you want to clear #{count} cache(s) older than #{days} day(s) (#{format_bytes(total_size)})? [y/N] "
    )
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("y")
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"
end
