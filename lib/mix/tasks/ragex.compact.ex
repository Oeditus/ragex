defmodule Mix.Tasks.Ragex.Compact do
  @shortdoc "Compacts the underlying database store (.redb) to reclaim free space"
  @moduledoc """
  Compacts the underlying `.redb` database file to free unused space caused by
  Copy-on-Write page allocations and deletes.

  ## Usage

      mix ragex.compact

  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info("Compacting database storage...")

    case Ragex.compact() do
      :ok ->
        Mix.shell().info("Database compaction completed successfully.")

      {:error, reason} ->
        Mix.shell().error("Database compaction failed: #{inspect(reason)}")
    end
  end
end
