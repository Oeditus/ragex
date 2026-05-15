defmodule Ragex.Git.CoChange do
  @moduledoc """
  Co-change analysis: discover files (and functions) that frequently
  change together.

  Walks the commit history and builds a co-occurrence matrix. If files A
  and B appear in the same commit N times, they have co-change weight N.
  The result is stored in an ETS table for fast querying.

  ## Algorithm

  1. Fetch the last `max_commits` commits with `--name-only`.
  2. For each commit, record every pair of changed files.
  3. Store `{file_a, file_b} => count` in ETS.
  4. Optionally persist to `~/.ragex/cochange/<project_hash>.etf`.

  ## Examples

      # Analyze co-change for the repo at /opt/project
      {:ok, _} = CoChange.analyze("/opt/project")

      # Query: what changes when lib/user.ex changes?
      CoChange.for_file("lib/user.ex")
      #=> [{"lib/user_test.exs", 42}, {"lib/accounts.ex", 18}, ...]
  """

  require Logger

  alias Ragex.Git.{Backend, Repo}

  @cochange_table :ragex_cochange
  @default_max_commits 500
  @default_min_count 2

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Analyze co-change patterns for the repository at `path`.

  ## Options
  - `:max_commits` -- how many commits to analyze (default #{@default_max_commits})
  - `:persist` -- write results to disk (default `true`)

  ## Returns
  `{:ok, %{pairs: non_neg_integer(), commits_analyzed: non_neg_integer()}}`
  """
  @spec analyze(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def analyze(path, opts \\ []) do
    max_commits = Keyword.get(opts, :max_commits, @default_max_commits)
    persist? = Keyword.get(opts, :persist, true)

    with {:ok, repo_root} <- Repo.root(path) do
      ensure_table()

      # Get commit SHAs
      case Backend.active().rev_list(repo_root, "HEAD", max_count: max_commits) do
        {:ok, shas} ->
          pair_count = build_cochange_matrix(repo_root, shas)

          if persist? do
            persist(repo_root)
          end

          {:ok, %{pairs: pair_count, commits_analyzed: length(shas)}}

        error ->
          error
      end
    end
  end

  @doc """
  Returns files that co-change with `file_path`, sorted by frequency.

  ## Options
  - `:min_count` -- minimum co-change count to include (default #{@default_min_count})
  - `:limit` -- max results (default 20)
  """
  @spec for_file(String.t(), keyword()) :: [{String.t(), pos_integer()}]
  def for_file(file_path, opts \\ []) do
    min_count = Keyword.get(opts, :min_count, @default_min_count)
    limit = Keyword.get(opts, :limit, 20)

    ensure_table()

    # Look up both orderings: {file_path, other} and {other, file_path}
    pattern_a = {{file_path, :"$1"}, :"$2"}
    pattern_b = {{:"$1", file_path}, :"$2"}

    matches_a = :ets.match(@cochange_table, pattern_a)
    matches_b = :ets.match(@cochange_table, pattern_b)

    (matches_a ++ matches_b)
    |> Enum.map(fn [other, count] -> {other, count} end)
    |> Enum.uniq_by(fn {path, _} -> path end)
    |> Enum.filter(fn {_, count} -> count >= min_count end)
    |> Enum.sort_by(fn {_, count} -> count end, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Load persisted co-change data for a repository, if available.
  """
  @spec load(String.t()) :: :ok | {:error, :not_found}
  def load(repo_root) do
    ensure_table()
    path = persistence_path(repo_root)

    if File.exists?(path) do
      data = path |> File.read!() |> :erlang.binary_to_term()

      Enum.each(data, fn {key, count} ->
        :ets.insert(@cochange_table, {key, count})
      end)

      :ok
    else
      {:error, :not_found}
    end
  end

  @doc "Clear all co-change data from memory."
  @spec clear() :: :ok
  def clear do
    ensure_table()
    :ets.delete_all_objects(@cochange_table)
    :ok
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp ensure_table do
    if :ets.whereis(@cochange_table) == :undefined do
      :ets.new(@cochange_table, [:named_table, :set, :public, read_concurrency: true])
    end
  end

  defp build_cochange_matrix(repo_root, shas) do
    # For each commit, get the list of changed files, then record pairs
    shas
    |> Task.async_stream(
      fn sha ->
        case Backend.active().commit_info(repo_root, sha) do
          {:ok, commit} -> commit.files_changed |> Enum.map(&elem(&1, 0))
          _ -> []
        end
      end,
      max_concurrency: 4,
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(0, fn
      {:ok, files}, count when length(files) > 1 and length(files) <= 50 ->
        # Skip commits touching too many files (merges, bulk changes)
        pairs = for a <- files, b <- files, a < b, do: {a, b}

        Enum.each(pairs, fn pair ->
          :ets.update_counter(@cochange_table, pair, {2, 1}, {pair, 0})
        end)

        count + length(pairs)

      _, count ->
        count
    end)
  end

  defp persist(repo_root) do
    path = persistence_path(repo_root)
    File.mkdir_p!(Path.dirname(path))

    data = :ets.tab2list(@cochange_table)
    File.write!(path, :erlang.term_to_binary(data))
  rescue
    e ->
      Logger.warning("Failed to persist co-change data: #{Exception.message(e)}")
  end

  defp persistence_path(repo_root) do
    hash = Repo.project_hash(repo_root)
    Path.join([System.user_home!(), ".ragex", "cochange", "#{hash}.etf"])
  end
end
