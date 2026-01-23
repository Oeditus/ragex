defmodule Mix.Tasks.Ragex.Ai.Cache.Stats do
  @moduledoc """
  Display AI response cache statistics.

  ## Usage

      mix ragex.ai.cache.stats

  Shows cache hit rates, size, and usage by operation.
  """

  use Mix.Task
  require Logger
  alias Ragex.AI.Cache
  alias Ragex.CLI.{Colors, Output}

  @shortdoc "Display AI cache statistics"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    stats = Cache.stats()

    Output.section("AI Cache Statistics")

    Output.key_value(
      [
        {"Enabled", if(stats.enabled, do: Colors.success("yes"), else: Colors.error("no"))},
        {"Total entries", Colors.highlight(to_string(stats.size))},
        {"Max size", stats.max_size},
        {"Default TTL", "#{stats.ttl}s"}
      ],
      indent: 2
    )

    IO.puts("\n" <> Colors.bold("Overall Performance"))

    hit_rate = Float.round(stats.hit_rate * 100, 2)

    hit_rate_color =
      cond do
        hit_rate >= 80 -> Colors.success("#{hit_rate}%")
        hit_rate >= 50 -> Colors.warning("#{hit_rate}%")
        true -> Colors.error("#{hit_rate}%")
      end

    Output.key_value(
      [
        {"Hits", Colors.success(to_string(stats.hits))},
        {"Misses", Colors.error(to_string(stats.misses))},
        {"Puts", stats.puts},
        {"Evictions", stats.evictions},
        {"Hit rate", hit_rate_color}
      ],
      indent: 2
    )

    if map_size(stats.by_operation) > 0 do
      IO.puts("\n" <> Colors.bold("By Operation"))

      Enum.each(stats.by_operation, fn {operation, op_stats} ->
        IO.puts("\n" <> Colors.info(to_string(operation)) <> ":")

        op_hit_rate = Float.round(op_stats.hit_rate * 100, 2)

        op_hit_rate_color =
          cond do
            op_hit_rate >= 80 -> Colors.success("#{op_hit_rate}%")
            op_hit_rate >= 50 -> Colors.warning("#{op_hit_rate}%")
            true -> Colors.error("#{op_hit_rate}%")
          end

        Output.key_value(
          [
            {"Entries", op_stats.size},
            {"TTL", "#{op_stats.ttl}s"},
            {"Max size", op_stats.max_size},
            {"Hits", Colors.success(to_string(op_stats.hits))},
            {"Misses", Colors.error(to_string(op_stats.misses))},
            {"Hit rate", op_hit_rate_color}
          ],
          indent: 2
        )
      end)
    end

    IO.puts("\n")
  end
end
