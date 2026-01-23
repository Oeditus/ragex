defmodule Mix.Tasks.Ragex.Ai.Cache.Clear do
  @moduledoc """
  Clear AI response cache.

  ## Usage

      # Clear all cache
      mix ragex.ai.cache.clear
      
      # Clear specific operation
      mix ragex.ai.cache.clear --operation query
      mix ragex.ai.cache.clear --operation explain

  Removes cached AI responses. Useful after configuration changes or for testing.
  """

  use Mix.Task
  require Logger
  alias Ragex.AI.Cache
  alias Ragex.CLI.{Colors, Output, Progress, Prompt}

  @shortdoc "Clear AI cache"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} = OptionParser.parse!(args, strict: [operation: :string])

    case Keyword.get(opts, :operation) do
      nil ->
        Output.section("Clear AI Cache")

        stats = Cache.stats()
        IO.puts(Colors.info("Current cache size: #{stats.size} entries"))
        IO.puts("")

        if stats.size == 0 do
          IO.puts(Colors.muted("Cache is already empty"))
          IO.puts("")
        else
          if Prompt.confirm("Clear entire AI cache?", default: :no) do
            spinner = Progress.spinner("Clearing cache...")
            :ok = Cache.clear()
            Progress.stop_spinner(spinner, Colors.success("✓ Cache cleared successfully"))
          else
            IO.puts(Colors.muted("Cancelled."))
            IO.puts("")
          end
        end

      operation_str ->
        Output.section("Clear AI Cache for Operation")

        operation = String.to_atom(operation_str)
        stats = Cache.stats()

        op_size =
          if Map.has_key?(stats.by_operation, operation) do
            stats.by_operation[operation].size
          else
            0
          end

        IO.puts(Colors.info("Operation: #{operation}"))
        IO.puts(Colors.info("Current size: #{op_size} entries"))
        IO.puts("")

        if op_size == 0 do
          IO.puts(Colors.muted("No cache entries for this operation"))
          IO.puts("")
        else
          if Prompt.confirm("Clear cache for operation '#{operation}'?", default: :no) do
            spinner = Progress.spinner("Clearing cache for #{operation}...")
            :ok = Cache.clear(operation)
            Progress.stop_spinner(spinner, Colors.success("✓ Cache cleared for #{operation}"))
          else
            IO.puts(Colors.muted("Cancelled."))
            IO.puts("")
          end
        end
    end
  end
end
