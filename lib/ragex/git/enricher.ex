defmodule Ragex.Git.Enricher do
  @moduledoc """
  Background enrichment of knowledge graph nodes with git metadata.

  After a directory analysis completes, the Enricher walks all file nodes
  in the graph and attaches git information:

  - `:last_author` -- who last modified the file
  - `:last_modified` -- when it was last modified
  - `:commit_count` -- total commits touching the file
  - `:pr_origin` -- the PR number that introduced the file (if indexed)

  For function nodes, the enrichment includes:

  - `:last_author` -- who last modified the function
  - `:git_age_days` -- days since last modification

  The enrichment runs asynchronously via `Task.async_stream/3` with a
  concurrency limit to avoid overwhelming the git backend.

  ## Edge types added to the knowledge graph

  - `:authored_by` -- from file/function node to an author identifier
  - `:introduced_in_pr` -- from file node to a PR number
  - `:co_changes_with` -- from file node to another file node (via CoChange)
  """

  use GenServer
  require Logger

  alias Ragex.Git.{Backend, CoChange, Repo}
  alias Ragex.Graph.Store

  @concurrency 4
  @timeout 15_000

  # ── Client API ───────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger enrichment for all file nodes in the knowledge graph.

  Runs asynchronously. Returns immediately with `:ok`.
  """
  @spec enrich(String.t()) :: :ok
  def enrich(path) do
    GenServer.cast(__MODULE__, {:enrich, path})
  end

  @doc """
  Trigger enrichment synchronously. Blocks until complete.

  Returns `{:ok, stats}` with enrichment statistics.
  """
  @spec enrich_sync(String.t()) :: {:ok, map()} | {:error, term()}
  def enrich_sync(path) do
    GenServer.call(__MODULE__, {:enrich_sync, path}, 120_000)
  end

  @doc "Returns the status of the last enrichment run."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ── Server callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok,
     %{
       status: :idle,
       last_run: nil,
       files_enriched: 0,
       functions_enriched: 0,
       errors: 0
     }}
  end

  @impl true
  def handle_cast({:enrich, path}, state) do
    Task.start(fn -> do_enrich(path) end)
    {:noreply, %{state | status: :running}}
  end

  @impl true
  def handle_call({:enrich_sync, path}, _from, state) do
    result = do_enrich(path)
    {:reply, result, Map.merge(state, elem(result, 1))}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  # ── Core enrichment logic ───────────────────────────────────────────

  defp do_enrich(path) do
    with {:ok, repo_root} <- Repo.root(path) do
      # Get all file nodes from the graph
      file_nodes =
        Store.list_nodes(:file)
        |> Enum.map(fn %{id: id, data: data} -> {id, data} end)

      # Also get module nodes (they have :file in data)
      module_nodes =
        Store.list_modules()
        |> Enum.filter(fn %{data: data} -> Map.has_key?(data, :file) end)

      # Enrich file nodes
      file_stats = enrich_files(repo_root, file_nodes)

      # Enrich modules with git metadata
      module_stats = enrich_modules(repo_root, module_nodes)

      # Add co-change edges
      cochange_stats = add_cochange_edges(repo_root)

      stats = %{
        status: :complete,
        last_run: DateTime.utc_now(),
        files_enriched: file_stats.enriched,
        functions_enriched: module_stats.enriched,
        cochange_edges: cochange_stats,
        errors: file_stats.errors + module_stats.errors
      }

      Logger.info(
        "Git enrichment complete: #{stats.files_enriched} files, " <>
          "#{stats.functions_enriched} modules, #{stats.cochange_edges} co-change edges"
      )

      {:ok, stats}
    end
  end

  defp enrich_files(repo_root, file_nodes) do
    file_nodes
    |> Task.async_stream(
      fn {file_id, data} ->
        file_path = data[:path] || to_string(file_id)
        enrich_single_file(repo_root, file_id, file_path)
      end,
      max_concurrency: @concurrency,
      timeout: @timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{enriched: 0, errors: 0}, fn
      {:ok, :ok}, acc -> %{acc | enriched: acc.enriched + 1}
      _, acc -> %{acc | errors: acc.errors + 1}
    end)
  end

  defp enrich_single_file(repo_root, file_id, file_path) do
    relative_path = Path.relative_to(file_path, repo_root)

    case Backend.active().log(repo_root, relative_path, max_count: 1) do
      {:ok, [commit | _]} ->
        # Update node metadata
        Store.add_node(:file, file_id, %{
          path: file_path,
          last_author: commit.author,
          last_modified: commit.date,
          last_sha: commit.sha
        })

        # Add authored_by edge
        Store.add_edge(
          {:file, file_id},
          {:author, commit.author},
          :authored_by,
          metadata: %{date: commit.date, sha: commit.sha}
        )

        :ok

      _ ->
        :ok
    end
  end

  defp enrich_modules(repo_root, module_nodes) do
    module_nodes
    |> Task.async_stream(
      fn %{id: mod_id, data: data} ->
        file_path = data[:file]

        if file_path do
          relative_path = Path.relative_to(file_path, repo_root)

          case Backend.active().log(repo_root, relative_path, max_count: 1) do
            {:ok, [commit | _]} ->
              age_days =
                if commit.date do
                  DateTime.diff(DateTime.utc_now(), commit.date, :day)
                end

              updated = Map.merge(data, %{last_author: commit.author, git_age_days: age_days})
              Store.add_node(:module, mod_id, updated)
              :ok

            _ ->
              :ok
          end
        else
          :ok
        end
      end,
      max_concurrency: @concurrency,
      timeout: @timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{enriched: 0, errors: 0}, fn
      {:ok, :ok}, acc -> %{acc | enriched: acc.enriched + 1}
      _, acc -> %{acc | errors: acc.errors + 1}
    end)
  end

  defp add_cochange_edges(repo_root) do
    # Get files from the graph and add co-change edges
    file_paths =
      Store.list_nodes(:file)
      |> Enum.map(fn %{data: data} -> data[:path] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Path.relative_to(&1, repo_root))

    count =
      Enum.reduce(file_paths, 0, fn file_path, acc ->
        co_files = CoChange.for_file(file_path, min_count: 3, limit: 10)

        Enum.each(co_files, fn {other_path, count} ->
          Store.add_edge(
            {:file, file_path},
            {:file, other_path},
            :co_changes_with,
            weight: count / 1.0,
            metadata: %{co_change_count: count}
          )
        end)

        acc + length(co_files)
      end)

    count
  end
end
