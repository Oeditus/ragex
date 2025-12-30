defmodule Mix.Tasks.Ragex.Cache.Stats do
  @moduledoc """
  Displays statistics about cached embeddings.

  ## Usage

      mix ragex.cache.stats

  ## Examples

      $ mix ragex.cache.stats
      Ragex Embedding Cache Statistics
      ================================

      Cache Directory: /home/user/.cache/ragex/abc123def456/
      Status: Valid

      Metadata:
        Model: all_minilm_l6_v2
        Dimensions: 384
        Version: 1
        Created: 2024-01-15 10:30:45
        Entity Count: 1,234

      Disk Usage:
        Cache Size: 12.5 MB
        Total Ragex Caches: 3
        Total Disk Usage: 38.2 MB

  ## Options

      --all     Show information about all cached projects

  """

  use Mix.Task
  alias Ragex.Embeddings.Persistence

  @shortdoc "Display embedding cache statistics"

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [all: :boolean])

    if opts[:all] do
      show_all_caches()
    else
      show_current_cache()
    end
  end

  defp show_current_cache do
    IO.puts("\nRagex Embedding Cache Statistics")
    IO.puts("================================\n")

    case Persistence.stats() do
      {:ok, stats} ->
        display_stats(stats)

      {:error, :not_found} ->
        IO.puts("Status: No cache found")
        IO.puts("\nThe cache will be created after the first indexing operation.")

      {:error, reason} ->
        IO.puts("Status: Error - #{inspect(reason)}")
    end
  end

  defp show_all_caches do
    IO.puts("\nAll Ragex Embedding Caches")
    IO.puts("==========================\n")

    cache_root = Path.join(System.user_home!(), ".cache/ragex")

    if File.exists?(cache_root) do
      cache_root
      |> File.ls!()
      |> Enum.each(fn project_hash ->
        project_dir = Path.join(cache_root, project_hash)
        cache_file = Path.join(project_dir, "embeddings.ets")

        if File.exists?(cache_file) do
          display_cache_entry(project_hash, cache_file)
        end
      end)
    else
      IO.puts("No caches found. Cache directory does not exist yet.")
    end
  end

  defp display_cache_entry(project_hash, cache_file) do
    stat = File.stat!(cache_file)
    size = format_bytes(stat.size)
    modified = format_datetime(stat.mtime)

    # Try to read metadata without loading into ETS
    case :ets.file2tab(String.to_charlist(cache_file), verify: true) do
      {:ok, table} ->
        metadata =
          case :ets.lookup(table, :__metadata__) do
            [{:__metadata__, meta}] -> meta
            _ -> %{}
          end

        :ets.delete(table)

        IO.puts("Project Hash: #{project_hash}")
        IO.puts("  Model: #{metadata[:model_id] || "unknown"}")
        IO.puts("  Entities: #{metadata[:entity_count] || 0}")
        IO.puts("  Size: #{size}")
        IO.puts("  Modified: #{modified}\n")

      {:error, _} ->
        IO.puts("Project Hash: #{project_hash}")
        IO.puts("  Size: #{size}")
        IO.puts("  Modified: #{modified}")
        IO.puts("  Status: Corrupt or incompatible\n")
    end
  end

  defp display_stats(stats) do
    cache_dir = Path.dirname(stats.cache_path)
    status = if stats.valid?, do: "Valid", else: "Incompatible with current model"

    IO.puts("Cache Directory: #{cache_dir}")
    IO.puts("Status: #{status}\n")

    if stats.metadata do
      meta = stats.metadata
      IO.puts("Metadata:")
      IO.puts("  Model: #{meta[:model_id]}")
      IO.puts("  Dimensions: #{meta[:dimensions]}")
      IO.puts("  Version: #{meta[:version]}")
      IO.puts("  Created: #{format_datetime(meta[:timestamp])}")
      IO.puts("  Entity Count: #{format_number(meta[:entity_count])}\n")
    end

    if stats.file_size do
      IO.puts("Disk Usage:")
      IO.puts("  Cache Size: #{format_bytes(stats.file_size)}")

      # Calculate total disk usage across all caches
      cache_root = Path.join(System.user_home!(), ".cache/ragex")

      if File.exists?(cache_root) do
        {cache_count, total_size} = calculate_total_cache_usage(cache_root)
        IO.puts("  Total Ragex Caches: #{cache_count}")
        IO.puts("  Total Disk Usage: #{format_bytes(total_size)}")
      end

      IO.puts("")
    end

    unless stats.valid? do
      IO.puts(
        "⚠️  Cache is incompatible with the current embedding model (#{Ragex.Embeddings.Bumblebee.model_info().id})."
      )

      IO.puts(
        "   Run `mix ragex.cache.clear --current` to remove it, or change your model configuration."
      )
    end
  end

  defp calculate_total_cache_usage(cache_root) do
    cache_root
    |> File.ls!()
    |> Enum.reduce({0, 0}, fn project_hash, {count, total_size} ->
      cache_file = Path.join([cache_root, project_hash, "embeddings.ets"])

      if File.exists?(cache_file) do
        stat = File.stat!(cache_file)
        {count + 1, total_size + stat.size}
      else
        {count, total_size}
      end
    end)
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"

  defp format_number(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 1)}M"
  end

  defp format_number(num) when num >= 1_000 do
    num
    |> to_string()
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_number(num), do: to_string(num)

  defp format_datetime({{year, month, day}, {hour, minute, second}}) do
    "#{year}-#{pad(month)}-#{pad(day)} #{pad(hour)}:#{pad(minute)}:#{pad(second)}"
  end

  defp format_datetime(%DateTime{} = dt) do
    DateTime.to_string(dt)
  end

  defp format_datetime(timestamp) when is_integer(timestamp) do
    timestamp
    |> DateTime.from_unix!()
    |> DateTime.to_string()
  end

  defp pad(num), do: String.pad_leading(to_string(num), 2, "0")
end
