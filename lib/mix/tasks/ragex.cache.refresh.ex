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
  alias Ragex.CLI.{Colors, Output, Progress}
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

    Output.section("Refreshing Embeddings Cache")

    Output.key_value([
      {"Mode", Colors.info(mode)},
      {"Path", path}
    ])

    IO.puts("")

    # Get initial stats
    initial_stats = get_stats()

    # Show spinner for analysis
    spinner = Progress.spinner(label: "Analyzing files...")

    # Perform refresh
    start_time = System.monotonic_time(:millisecond)

    result =
      Directory.analyze_directory(path,
        incremental: incremental and not force_refresh,
        force_refresh: force_refresh
      )

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    # Stop spinner
    Progress.stop_spinner(spinner)

    case result do
      {:ok, summary} ->
        display_summary(summary, duration_ms, mode)

        # Save cache
        save_spinner = Progress.spinner(label: "Saving cache...")

        case Persistence.save(nil, path) do
          {:ok, cache_path} ->
            Progress.stop_spinner(save_spinner, Colors.success("✓ Cache saved to #{cache_path}"))

          {:error, reason} ->
            Progress.stop_spinner(
              save_spinner,
              Colors.error("✗ Failed to save cache: #{inspect(reason)}")
            )
        end

        # Show detailed stats if requested
        if show_stats do
          final_stats = get_stats()
          display_detailed_stats(initial_stats, final_stats)
        end

        IO.puts(Colors.success("\n✓ Refresh complete!"))

      {:error, reason} ->
        Progress.stop_spinner(spinner, Colors.error("✗ Failed"))
        IO.puts(Colors.error("Failed to refresh cache: #{inspect(reason)}"))
    end
  end

  defp display_summary(summary, duration_ms, mode) do
    IO.puts("\n" <> Colors.bold("Results:"))

    result_pairs = [{"Total files", summary.total}]

    result_pairs =
      if mode == "incremental" do
        result_pairs ++
          [
            {"Analyzed", Colors.highlight(to_string(summary.analyzed))},
            {"Skipped", Colors.muted(to_string(summary.skipped))}
          ]
      else
        result_pairs
      end

    regeneration_pct =
      if mode == "incremental" and summary.analyzed > 0 do
        (summary.analyzed / summary.total * 100) |> Float.round(1)
      else
        nil
      end

    result_pairs =
      result_pairs ++
        [
          {"Success", Colors.success(to_string(summary.success))},
          {"Errors",
           if(summary.errors > 0, do: Colors.error(to_string(summary.errors)), else: "0")}
        ]

    result_pairs =
      if regeneration_pct do
        result_pairs ++ [{"Regeneration", "#{regeneration_pct}%"}]
      else
        result_pairs
      end

    duration_sec = duration_ms / 1000
    result_pairs = result_pairs ++ [{"Duration", "#{Float.round(duration_sec, 2)}s"}]

    Output.key_value(result_pairs, indent: 2)

    if summary.errors > 0 do
      IO.puts("\n" <> Colors.error("Errors:"))

      Enum.each(summary.error_details, fn error ->
        IO.puts("  #{Colors.error("✗")} #{error.file}: #{Colors.muted(inspect(error.reason))}")
      end)
    end

    IO.puts("")
  end

  defp get_stats do
    %{
      graph: Store.stats(),
      file_tracker: FileTracker.stats()
    }
  end

  defp display_detailed_stats(initial, final) do
    Output.section("Detailed Statistics")

    # Graph stats
    IO.puts(Colors.bold("Graph Store:"))

    Output.key_value(
      [
        {"Nodes", "#{initial.graph.nodes} → #{Colors.highlight(to_string(final.graph.nodes))}"},
        {"Edges", "#{initial.graph.edges} → #{Colors.highlight(to_string(final.graph.edges))}"},
        {"Embeddings",
         "#{initial.graph.embeddings} → #{Colors.highlight(to_string(final.graph.embeddings))}"}
      ],
      indent: 2
    )

    IO.puts("")

    # File tracker stats
    IO.puts(Colors.bold("File Tracker:"))

    Output.key_value(
      [
        {"Total files", final.file_tracker.total_files},
        {"Changed", Colors.info(to_string(final.file_tracker.changed_files))},
        {"Unchanged", Colors.muted(to_string(final.file_tracker.unchanged_files))},
        {"Deleted", final.file_tracker.deleted_files},
        {"Total entities", final.file_tracker.total_entities},
        {"Stale entities", final.file_tracker.stale_entities}
      ],
      indent: 2
    )

    IO.puts("")

    # Cache info
    case Persistence.stats() do
      {:ok, cache_stats} ->
        IO.puts(Colors.bold("Cache:"))

        Output.key_value(
          [
            {"Size", format_bytes(cache_stats.file_size)},
            {"Valid",
             if(cache_stats.valid?, do: Colors.success("Yes"), else: Colors.error("No"))},
            {"Model", cache_stats.metadata.model_id},
            {"Dimensions", cache_stats.metadata.dimensions}
          ],
          indent: 2
        )

      {:error, :not_found} ->
        IO.puts(Colors.warning("Cache: Not found"))

      {:error, _} ->
        IO.puts(Colors.error("Cache: Error reading cache"))
    end

    IO.puts("")
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"
end
