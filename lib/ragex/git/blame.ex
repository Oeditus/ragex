defmodule Ragex.Git.Blame do
  @moduledoc """
  High-level git blame API.

  Provides line-level authorship information with optional PR enrichment.
  Delegates to the active backend (`Egit` or `CLI`).

  ## Examples

      # Blame an entire file
      {:ok, entries} = Ragex.Git.Blame.file("/opt/project", "lib/user.ex")

      # Blame a specific line range
      {:ok, entries} = Ragex.Git.Blame.file("/opt/project", "lib/user.ex",
        start_line: 10, end_line: 20)

      # Blame with PR enrichment
      {:ok, entries} = Ragex.Git.Blame.file("/opt/project", "lib/user.ex",
        start_line: 42, enrich_pr: true)
  """

  alias Ragex.Git.{Backend, BlameEntry, PR, Repo}

  @doc """
  Blame a file (or line range) and return per-line authorship.

  ## Options
  - `:start_line` -- first line (1-indexed)
  - `:end_line` -- last line (default: same as start_line if start given)
  - `:enrich_pr` -- if `true`, attempt to find the PR for each blame SHA

  ## Returns
  `{:ok, entries}` where each entry is a `%BlameEntry{}`,
  optionally enriched with `:pr_number` and `:pr_title` in a wrapper map.
  """
  @spec file(String.t(), String.t(), keyword()) ::
          {:ok, [BlameEntry.t() | map()]} | {:error, term()}
  def file(path, file_path, opts \\ []) do
    enrich_pr = Keyword.get(opts, :enrich_pr, false)
    blame_opts = Keyword.take(opts, [:start_line, :end_line])

    with {:ok, repo_root} <- Repo.root(path) do
      case Backend.active().blame(repo_root, file_path, blame_opts) do
        {:ok, entries} when enrich_pr ->
          enriched = Enum.map(entries, &enrich_with_pr(repo_root, &1))
          {:ok, enriched}

        result ->
          result
      end
    end
  end

  @doc """
  Group consecutive blame entries by commit SHA for compact display.

  Returns a list of `%{sha, author, email, date, summary, start_line, end_line, line_count}`.
  """
  @spec group_by_commit([BlameEntry.t()]) :: [map()]
  def group_by_commit(entries) do
    entries
    |> Enum.chunk_by(& &1.sha)
    |> Enum.map(fn chunk ->
      first = hd(chunk)

      %{
        sha: first.sha,
        author: first.author,
        email: first.email,
        date: first.date,
        summary: first.summary,
        start_line: first.line,
        end_line: List.last(chunk).line,
        line_count: length(chunk)
      }
    end)
  end

  # Private

  defp enrich_with_pr(repo_root, %BlameEntry{sha: sha} = entry) do
    case PR.find_pr_for_commit(repo_root, sha) do
      {:ok, pr_info} ->
        Map.merge(
          Map.from_struct(entry),
          %{pr_number: pr_info.number, pr_title: pr_info.title}
        )

      _ ->
        entry
    end
  end
end
