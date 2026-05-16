defmodule Ragex.Git.Backend.Egit do
  @moduledoc """
  Git backend using the `egit` NIF library (libgit2 bindings).

  All calls are routed through `Ragex.Git.RepoServer` which owns the NIF
  repo reference, providing process isolation. If the NIF crashes, only the
  RepoServer dies and is restarted by the supervisor.

  This backend is only available when `{:egit, "~> 0.2"}` is compiled in.
  The `Ragex.Git.Backend.active/0` function auto-detects its presence.

  Operations not supported by libgit2 (e.g. `git log -L`) fall through
  to `Ragex.Git.Backend.CLI`.
  """

  @behaviour Ragex.Git.Backend

  alias Ragex.Git.Backend.CLI, as: CLIBackend
  alias Ragex.Git.{BlameEntry, Commit, RepoServer}

  # ── repo_root ────────────────────────────────────────────────────────

  @impl true
  def repo_root(work_dir) do
    # egit needs an already-known repo path; use CLI for discovery
    CLIBackend.repo_root(work_dir)
  end

  # ── blame ─────────────────────────────────────────────────────────────

  @impl true
  def blame(repo_root, file_path, opts \\ []) do
    ensure_open!(repo_root)

    case RepoServer.call(:blame, [file_path]) do
      entries when is_list(entries) ->
        blame_entries =
          entries
          |> maybe_filter_lines(opts)
          |> Enum.with_index(1)
          |> Enum.map(fn {raw, idx} ->
            to_blame_entry(raw, idx)
          end)

        {:ok, blame_entries}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_egit_result, other}}
    end
  end

  # ── log ───────────────────────────────────────────────────────────────

  @impl true
  def log(repo_root, file_path, opts \\ []) do
    # egit's rev_list doesn't support per-file filtering as elegantly as CLI.
    # Delegate to CLI for file-scoped log to get --name-status and --follow.
    CLIBackend.log(repo_root, file_path, opts)
  end

  # ── diff ──────────────────────────────────────────────────────────────

  @impl true
  def diff(repo_root, rev_a, rev_b) do
    ensure_open!(repo_root)

    case RepoServer.call(:diff, [rev_a, rev_b]) do
      entries when is_list(entries) ->
        parsed =
          Enum.map(entries, fn {path, status_str, _adds, _dels} ->
            {to_string(path), diff_status(status_str)}
          end)

        {:ok, parsed}

      {:error, _} = err ->
        err

      _other ->
        # Fallback to CLI if egit diff format is unexpected
        CLIBackend.diff(repo_root, rev_a, rev_b)
    end
  end

  # ── rev_list ──────────────────────────────────────────────────────────

  @impl true
  def rev_list(repo_root, rev, opts \\ []) do
    ensure_open!(repo_root)
    max_count = Keyword.get(opts, :max_count, 500)

    case RepoServer.call(:rev_list, [rev, [limit: max_count]]) do
      shas when is_list(shas) ->
        {:ok, Enum.map(shas, &to_string/1)}

      {:error, _} = err ->
        err

      _ ->
        CLIBackend.rev_list(repo_root, rev, opts)
    end
  end

  # ── commit_info ───────────────────────────────────────────────────────

  @impl true
  def commit_info(repo_root, sha) do
    ensure_open!(repo_root)

    case RepoServer.call(:commit_lookup, [sha, [:author, :message, :summary, :time]]) do
      %{} = info ->
        {:ok, egit_commit_to_struct(sha, info)}

      {:error, _} = err ->
        err

      _ ->
        CLIBackend.commit_info(repo_root, sha)
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp ensure_open!(repo_root) do
    unless Process.whereis(RepoServer) do
      raise RuntimeError,
            "Ragex.Git.RepoServer is not running; start the application first"
    end

    current = RepoServer.current_path()

    if current != repo_root do
      RepoServer.open(repo_root)
    end
  end

  defp to_blame_entry({_line_no, {author, email}, sha, timestamp}, idx) do
    %BlameEntry{
      sha: to_string(sha),
      author: to_string(author),
      email: to_string(email),
      date: DateTime.from_unix!(timestamp),
      line: idx,
      original_line: idx
    }
  end

  defp to_blame_entry(raw, idx) when is_tuple(raw) do
    # Handle varying egit blame tuple formats gracefully
    %BlameEntry{
      sha: "unknown",
      author: "Unknown",
      email: "",
      line: idx,
      original_line: idx
    }
  end

  defp maybe_filter_lines(entries, opts) do
    start_line = Keyword.get(opts, :start_line)
    end_line = Keyword.get(opts, :end_line)

    case {start_line, end_line} do
      {nil, _} ->
        entries

      {s, nil} ->
        Enum.drop(entries, s - 1) |> Enum.take(1)

      {s, e} ->
        Enum.drop(entries, s - 1) |> Enum.take(e - s + 1)
    end
  end

  defp diff_status(status) when is_binary(status) do
    case status do
      "modified" -> :modified
      "added" -> :added
      "deleted" -> :deleted
      "renamed" -> :renamed
      _ -> :unknown
    end
  end

  defp diff_status(_), do: :unknown

  defp egit_commit_to_struct(sha, info) do
    {author_name, author_email} =
      case Map.get(info, :author) do
        {name, email, _ts, _tz} -> {to_string(name), to_string(email)}
        {name, email} -> {to_string(name), to_string(email)}
        _ -> {"Unknown", ""}
      end

    timestamp = Map.get(info, :time)

    %Commit{
      sha: to_string(sha),
      short_sha: String.slice(to_string(sha), 0, 8),
      author: author_name,
      email: author_email,
      date: if(timestamp, do: DateTime.from_unix!(timestamp)),
      summary: to_string(Map.get(info, :summary, "")),
      message: to_string(Map.get(info, :message, ""))
    }
  end
end
