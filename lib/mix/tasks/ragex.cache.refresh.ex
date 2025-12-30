defmodule Mix.Tasks.Ragex.Cache.Refresh do
  @moduledoc """
  Refreshes the embeddings cache for the current project.

  ## Usage

      mix ragex.cache.refresh [options]

  ## Options

      --full          Perform full refresh (re-analyze all files)
      --incremental   Perform incremental refresh (default, only changed files)
      --path PATH     Directory to refresh (default: current directory)
      --stats         Show statistics after refresh

  ## Examples

      # Incremental refresh (default)
      $ mix ragex.cache.refresh

      # Full refresh (re-analyze everything)
      $ mix ragex.cache.refresh --full

      # Refresh specific directory
      $ mix ragex.cache.refresh --path lib/

      # Show statistics after refresh
      $ mix ragex.cache.refresh --stats

  ## Description

  This task refreshes the embeddings cache by analyzing files in the project.
  By default, it performs an incremental refresh, only re-analyzing files that
  have changed since the last analysis.

  ### Incremental Mode (default)

  - Checks file content hashes to detect changes
  - Skips unchanged files (reads from cache)
  - Only regenerates embeddings for changed entities
  - Typically <5% regeneration on single-file changes

  ### Full Mode (--full)

  - Re-analyzes all files from scratch
  - Regenerates all embeddings
  - Useful after model changes or cache corruption
  - Takes longer but ensures consistency

  """

  use Mix.Task
  alias Ragex.Analyzers.Directory
  alias Ragex.Embeddings.{FileTracker, Persistence}
  alias Ragex.Graph.Store

  require Logger

  @shortdoc "Refresh embeddings cache (incremental or full)"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [full: :boolean, incremental: :boolean, path: :string, stats: :boolean]
      )

    # Start the application
    Mix.Task.run("app.start")

    path = Keyword.get(opts, :path, File.cwd!())
    force_refresh = Keyword.get(opts, :full, false)
    incremental = Keyword.get(opts, :incremental, true)
    show_stats = Keyword.get(opts, :stats, false)

    mode = if force_refresh, do: "full", else: "incremental"

    IO.puts("\nRefreshing embeddings cache (#{mode} mode)...")
    IO.puts("Path: #{path}\n")

    # Get initial stats
    initial_stats = get_stats()

    # Perform refresh
    start_time = System.monotonic_time(:millisecond)

    result =
      Directory.analyze_directory(path,
        incremental: incremental and not force_refresh,
        force_refresh: force_refresh
      )

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    case result do
      {:ok, summary} ->
        display_summary(summary, duration_ms, mode)

        # Save cache
        IO.puts("\nSaving cache...")

        case Persistence.save() do
          {:ok, cache_path} ->
            IO.puts("✓ Cache saved to #{cache_path}")

          {:error, reason} ->
            IO.puts("✗ Failed to save cache: #{inspect(reason)}")
        end

        # Show detailed stats if requested
        if show_stats do
          final_stats = get_stats()
          display_detailed_stats(initial_stats, final_stats)
        end

        IO.puts("\n✓ Refresh complete!")

      {:error, reason} ->
        IO.puts("✗ Failed to refresh cache: #{inspect(reason)}")
    end
  end

  defp display_summary(summary, duration_ms, mode) do
    IO.puts("Results:")
    IO.puts("  Total files: #{summary.total}")

    if mode == "incremental" do
      IO.puts("  Analyzed: #{summary.analyzed}")
      IO.puts("  Skipped (unchanged): #{summary.skipped}")

      if summary.analyzed > 0 do
        regeneration_pct = (summary.analyzed / summary.total * 100) |> Float.round(1)
        IO.puts("  Regeneration: #{regeneration_pct}%")
      end
    end

    IO.puts("  Success: #{summary.success}")
    IO.puts("  Errors: #{summary.errors}")

    if summary.errors > 0 do
      IO.puts("\nErrors:")

      Enum.each(summary.error_details, fn error ->
        IO.puts("  - #{error.file}: #{inspect(error.reason)}")
      end)
    end

    duration_sec = duration_ms / 1000
    IO.puts("\nTime: #{Float.round(duration_sec, 2)}s")
  end

  defp get_stats do
    %{
      graph: Store.stats(),
      file_tracker: FileTracker.stats()
    }
  end

  defp display_detailed_stats(initial, final) do
    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("Detailed Statistics")
    IO.puts(String.duplicate("=", 50))

    # Graph stats
    IO.puts("\nGraph Store:")
    IO.puts("  Nodes: #{initial.graph.nodes} → #{final.graph.nodes}")
    IO.puts("  Edges: #{initial.graph.edges} → #{final.graph.edges}")
    IO.puts("  Embeddings: #{initial.graph.embeddings} → #{final.graph.embeddings}")

    # File tracker stats
    IO.puts("\nFile Tracker:")
    IO.puts("  Total files: #{final.file_tracker.total_files}")
    IO.puts("  Changed: #{final.file_tracker.changed_files}")
    IO.puts("  Unchanged: #{final.file_tracker.unchanged_files}")
    IO.puts("  Deleted: #{final.file_tracker.deleted_files}")
    IO.puts("  Total entities: #{final.file_tracker.total_entities}")
    IO.puts("  Stale entities: #{final.file_tracker.stale_entities}")

    # Cache info
    case Persistence.stats() do
      {:ok, cache_stats} ->
        IO.puts("\nCache:")
        IO.puts("  Size: #{format_bytes(cache_stats.file_size)}")
        IO.puts("  Valid: #{cache_stats.valid?}")
        IO.puts("  Model: #{cache_stats.metadata.model_id}")
        IO.puts("  Dimensions: #{cache_stats.metadata.dimensions}")

      {:error, :not_found} ->
        IO.puts("\nCache: Not found")

      {:error, _} ->
        IO.puts("\nCache: Error reading cache")
    end

    IO.puts(String.duplicate("=", 50))
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"
end
