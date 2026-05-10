defmodule Mix.Tasks.Ragex.Dashboard do
  @moduledoc """
  Live monitoring dashboard for Ragex metrics.

  ## Usage

      # Launch dashboard
      mix ragex.dashboard
      
      # With custom refresh interval
      mix ragex.dashboard --interval 2000

  Displays real-time statistics in a TUI:

  - Graph statistics (nodes, edges, modules, functions)
  - Embedding metrics (count, dimensions, cache status)
  - Cache performance (hit rates, size)
  - AI usage tracking (requests, tokens, costs)
  - Recent activity log

  Press 'q' or Ctrl+C to exit.
  """

  @shortdoc "Live monitoring dashboard"

  use Mix.Task

  alias Ragex.AI.{Cache, Usage}
  alias Ragex.CLI.Colors
  alias Ragex.Embeddings.Persistence
  alias Ragex.Graph.Store
  alias Ragex.MCP.Client

  @refresh_interval 1000

  @impl Mix.Task
  def run(args) do
    # Only start full app if no server is running
    unless Client.server_running?() do
      {:ok, _} = Application.ensure_all_started(:ragex)
    end

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [interval: :integer, help: :boolean],
        aliases: [i: :interval, h: :help]
      )

    if opts[:help] do
      show_help()
    else
      interval = opts[:interval] || @refresh_interval
      run_dashboard(interval)
    end
  end

  defp run_dashboard(interval) do
    IO.puts(Colors.bold("\n" <> "Ragex Dashboard"))
    IO.puts(Colors.muted("Press Ctrl+C to exit\n"))

    # Initial render
    render_dashboard()

    # Start refresh loop
    refresh_loop(interval)
  end

  defp refresh_loop(interval) do
    Process.sleep(interval)

    # Clear screen and move to top
    IO.write(IO.ANSI.clear() <> IO.ANSI.home())

    render_dashboard()
    refresh_loop(interval)
  end

  defp render_dashboard do
    timestamp = DateTime.utc_now() |> DateTime.to_string()

    IO.puts(Colors.bold("Ragex Dashboard") <> Colors.muted(" - #{timestamp}"))
    IO.puts(String.duplicate("=", 80))
    IO.puts("")

    # Row 1: Graph & Embeddings
    graph_stats = fetch_graph_stats()
    embedding_stats = fetch_embedding_stats()

    render_side_by_side(
      render_graph_panel(graph_stats),
      render_embeddings_panel(embedding_stats)
    )

    IO.puts("")

    # Row 2: Cache & AI Usage
    cache_stats = fetch_cache_stats()
    ai_stats = fetch_ai_stats()

    render_side_by_side(
      render_cache_panel(cache_stats),
      render_ai_panel(ai_stats)
    )

    IO.puts("")

    # Bottom: Activity log
    render_activity_panel()

    IO.puts("")
    IO.puts(Colors.muted("Press Ctrl+C to exit"))
  end

  defp render_side_by_side(left_lines, right_lines) do
    # Render two panels side by side
    max_lines = max(length(left_lines), length(right_lines))
    left_width = 38

    for i <- 0..(max_lines - 1) do
      left_line = Enum.at(left_lines, i, "")
      right_line = Enum.at(right_lines, i, "")

      # Pad left line to width
      left_padded = String.pad_trailing(left_line, left_width)

      IO.puts(left_padded <> "  " <> right_line)
    end
  end

  defp render_graph_panel(stats) do
    [
      Colors.bold("┌─ Graph Statistics ─────────────────┐"),
      "│ " <> format_stat_line("Modules", stats.modules),
      "│ " <> format_stat_line("Functions", stats.functions),
      "│ " <> format_stat_line("Total Nodes", stats.total_nodes),
      "│ " <> format_stat_line("Total Edges", stats.total_edges),
      "│ " <> format_stat_line("Avg Degree", stats.avg_degree),
      Colors.bold("└────────────────────────────────────┘")
    ]
  end

  defp render_embeddings_panel(stats) do
    status_color =
      if stats.count > 0 do
        Colors.success("Active")
      else
        Colors.muted("Empty")
      end

    [
      Colors.bold("┌─ Embeddings ───────────────────────┐"),
      "│ " <> format_stat_line("Status", status_color),
      "│ " <> format_stat_line("Count", stats.count),
      "│ " <> format_stat_line("Model", stats.model),
      "│ " <> format_stat_line("Dimensions", stats.dimensions),
      "│ " <> format_stat_line("Cache Size", stats.cache_size),
      Colors.bold("└────────────────────────────────────┘")
    ]
  end

  defp render_cache_panel(stats) do
    hit_rate = if stats.total > 0, do: Float.round(stats.hits / stats.total * 100, 1), else: 0.0

    hit_rate_color =
      cond do
        hit_rate >= 80 -> Colors.success("#{hit_rate}%")
        hit_rate >= 50 -> Colors.warning("#{hit_rate}%")
        true -> Colors.error("#{hit_rate}%")
      end

    [
      Colors.bold("┌─ Cache Performance ────────────────┐"),
      "│ " <> format_stat_line("Hit Rate", hit_rate_color),
      "│ " <> format_stat_line("Hits", Colors.success(to_string(stats.hits))),
      "│ " <> format_stat_line("Misses", Colors.error(to_string(stats.misses))),
      "│ " <> format_stat_line("Total Entries", stats.size),
      "│ " <> format_stat_line("Evictions", stats.evictions),
      Colors.bold("└────────────────────────────────────┘")
    ]
  end

  defp render_ai_panel(stats) do
    cost_display =
      if stats.total_cost > 0 do
        Colors.warning("$#{Float.round(stats.total_cost, 2)}")
      else
        Colors.muted("$0.00")
      end

    [
      Colors.bold("┌─ AI Usage ─────────────────────────┐"),
      "│ " <> format_stat_line("Requests", stats.requests),
      "│ " <> format_stat_line("Total Tokens", format_large_number(stats.tokens)),
      "│ " <> format_stat_line("Est. Cost", cost_display),
      "│ " <> format_stat_line("Active Providers", stats.active_providers),
      "│ " <> format_stat_line("Cache Hits", stats.cache_hits),
      Colors.bold("└────────────────────────────────────┘")
    ]
  end

  defp render_activity_panel do
    IO.puts(
      Colors.bold(
        "┌─ Recent Activity ──────────────────────────────────────────────────────────┐"
      )
    )

    # [TODO] Get recent activity (placeholder - would need actual activity tracking)
    activities = []
    # [
    #   {DateTime.utc_now() |> DateTime.add(-10, :second), "Analyzed 15 files in lib/"},
    #   {DateTime.utc_now() |> DateTime.add(-45, :second), "Generated 43 embeddings"},
    #   {DateTime.utc_now() |> DateTime.add(-120, :second), "Refactored MyModule.process/2"}
    # ]

    if activities == [] do
      IO.puts("│ " <> Colors.muted("No recent activity"))
    else
      for {time, message} <- Enum.take(activities, 5) do
        time_ago = format_time_ago(time)
        IO.puts("│ #{Colors.muted(time_ago)} #{message}")
      end
    end

    IO.puts(
      Colors.bold(
        "└────────────────────────────────────────────────────────────────────────────┘"
      )
    )
  end

  defp format_stat_line(label, value) do
    # Format: "Label........: Value" with proper padding
    label_padded = String.pad_trailing(label, 16)
    value_str = to_string(value) |> String.slice(0, 18)
    "#{label_padded}: #{value_str}" |> String.pad_trailing(34)
  end

  defp format_large_number(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 1)}M"
  end

  defp format_large_number(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 1)}K"
  end

  defp format_large_number(num), do: to_string(num)

  defp format_time_ago(time) do
    diff = DateTime.diff(DateTime.utc_now(), time, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
    |> String.pad_trailing(10)
  end

  defp fetch_graph_stats do
    modules = Store.list_nodes(:module)
    functions = Store.list_nodes(:function)
    all_nodes = Store.list_nodes()
    edges = Store.list_edges()

    avg_degree =
      case all_nodes do
        [_ | _] -> Float.round(length(edges) * 2 / length(all_nodes), 1)
        _ -> 0.0
      end

    %{
      modules: length(modules),
      functions: length(functions),
      total_nodes: length(all_nodes),
      total_edges: length(edges),
      avg_degree: avg_degree
    }
  end

  defp fetch_embedding_stats do
    embeddings = Store.list_embeddings()
    count = length(embeddings)

    {model, dimensions} =
      if count > 0 do
        {_type, _id, embedding, _text} = hd(embeddings)
        model_id = Application.get_env(:ragex, :embedding_model, :all_minilm_l6_v2)
        {model_id, length(embedding)}
      else
        {:none, 0}
      end

    cache_size =
      case Persistence.cache_stats() do
        {:ok, stats} -> format_bytes(stats.file_size)
        _ -> "N/A"
      end

    %{
      count: count,
      model: model,
      dimensions: dimensions,
      cache_size: cache_size
    }
  end

  defp fetch_cache_stats do
    stats = Cache.stats()

    %{
      hits: stats.hits,
      misses: stats.misses,
      total: stats.hits + stats.misses,
      size: stats.size,
      evictions: stats.evictions
    }
  end

  defp fetch_ai_stats do
    all_stats = Usage.get_stats(:all)

    {requests, tokens, cost, providers} =
      Enum.reduce(all_stats, {0, 0, 0.0, 0}, fn {_provider, provider_stats},
                                                {req, tok, cost_acc, prov} ->
        {
          req + provider_stats.total_requests,
          tok + provider_stats.total_tokens,
          cost_acc + provider_stats.estimated_cost,
          prov + 1
        }
      end)

    cache_stats = Cache.stats()

    %{
      requests: requests,
      tokens: tokens,
      total_cost: cost,
      active_providers: providers,
      cache_hits: cache_stats.hits
    }
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  end

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes), do: "#{bytes} B"

  defp show_help do
    IO.puts("""
    #{Colors.bold("Ragex Dashboard")}

    #{Colors.info("Launch dashboard:")}
      mix ragex.dashboard

    #{Colors.info("Custom refresh interval (milliseconds):")}
      mix ragex.dashboard --interval 2000

    #{Colors.info("What's displayed:")}
      • Graph statistics (nodes, edges, modules, functions)
      • Embedding metrics (count, model, dimensions, cache)
      • Cache performance (hit rate, evictions)
      • AI usage (requests, tokens, costs, providers)
      • Recent activity log

    #{Colors.muted("Press Ctrl+C to exit the dashboard.")}
    """)
  end
end
