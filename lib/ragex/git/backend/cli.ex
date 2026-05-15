defmodule Ragex.Git.Backend.CLI do
  @moduledoc """
  Git backend that shells out to the `git` CLI binary.

  This is the universal fallback -- it works on any system where `git` is
  installed. It is also the **only** path for operations that `libgit2`
  does not support, such as `git log -L` (function-level line tracking).

  All output is parsed from porcelain/machine-readable formats to avoid
  locale-dependent text issues.
  """

  @behaviour Ragex.Git.Backend

  alias Ragex.Git.{BlameEntry, Commit}

  # ── repo_root ────────────────────────────────────────────────────────

  @impl true
  def repo_root(work_dir) do
    case git(work_dir, ~w[rev-parse --show-toplevel]) do
      {:ok, root} -> {:ok, String.trim(root)}
      error -> error
    end
  end

  # ── blame ─────────────────────────────────────────────────────────────

  @impl true
  def blame(repo_root, file_path, opts \\ []) do
    start_line = Keyword.get(opts, :start_line)
    end_line = Keyword.get(opts, :end_line)

    line_args =
      if start_line do
        end_l = end_line || start_line
        ["-L", "#{start_line},#{end_l}"]
      else
        []
      end

    args = ["blame", "--porcelain"] ++ line_args ++ ["--", file_path]

    case git(repo_root, args) do
      {:ok, output} -> {:ok, parse_porcelain_blame(output)}
      error -> error
    end
  end

  # ── log ───────────────────────────────────────────────────────────────

  @impl true
  def log(repo_root, file_path, opts \\ []) do
    max_count = Keyword.get(opts, :max_count, 50)
    since = Keyword.get(opts, :since)
    author = Keyword.get(opts, :author)

    # Use a NUL-delimited format for unambiguous parsing
    format = "%H%n%h%n%an%n%ae%n%aI%n%s%n%B%x00"

    args =
      ["log", "--format=#{format}", "--name-status", "-n", to_string(max_count)] ++
        if(since, do: ["--since=#{since}"], else: []) ++
        if(author, do: ["--author=#{author}"], else: []) ++
        ["--", file_path]

    case git(repo_root, args) do
      {:ok, output} -> {:ok, parse_log_output(output)}
      error -> error
    end
  end

  # ── diff ──────────────────────────────────────────────────────────────

  @impl true
  def diff(repo_root, rev_a, rev_b) do
    args = ["diff", "--name-status", rev_a, rev_b]

    case git(repo_root, args) do
      {:ok, output} -> {:ok, parse_name_status(output)}
      error -> error
    end
  end

  # ── rev_list ──────────────────────────────────────────────────────────

  @impl true
  def rev_list(repo_root, rev, opts \\ []) do
    max_count = Keyword.get(opts, :max_count, 500)
    args = ["rev-list", "--max-count=#{max_count}", rev]

    case git(repo_root, args) do
      {:ok, output} ->
        shas =
          output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.trim/1)

        {:ok, shas}

      error ->
        error
    end
  end

  # ── commit_info ───────────────────────────────────────────────────────

  @impl true
  def commit_info(repo_root, sha) do
    format = "%H%n%h%n%an%n%ae%n%aI%n%s%n%B%x00"
    args = ["log", "--format=#{format}", "--name-status", "-n", "1", sha]

    case git(repo_root, args) do
      {:ok, output} ->
        case parse_log_output(output) do
          [commit | _] -> {:ok, commit}
          [] -> {:error, :not_found}
        end

      error ->
        error
    end
  end

  # ── Function evolution (git log -L) ──────────────────────────────────

  @doc """
  Track the evolution of a function through history using `git log -L`.

  This operation is **always** handled by the CLI backend because
  `libgit2` does not support the `-L` flag.

  ## Parameters
  - `repo_root` -- absolute path to the repository root
  - `function_name` -- the function name (used in the regex pattern)
  - `file_path` -- path relative to repo root
  - `opts` -- `:max_count` (default 20)

  ## Returns
  `{:ok, [Commit.t()]}` with the commits that modified the function.
  """
  @spec function_log(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [Commit.t()]} | {:error, term()}
  def function_log(repo_root, function_name, file_path, opts \\ []) do
    max_count = Keyword.get(opts, :max_count, 20)
    # -L uses a regex to find function boundaries
    pattern = ":#{function_name}:#{file_path}"
    format = "%H%n%h%n%an%n%ae%n%aI%n%s%n%B%x00"

    args = ["log", "--format=#{format}", "-n", to_string(max_count), "-L", pattern]

    case git(repo_root, args) do
      {:ok, output} -> {:ok, parse_log_output(output)}
      {:error, {_output, _code}} -> {:ok, []}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp git(work_dir, args) do
    full_args = ["--no-pager" | args]

    case System.cmd("git", full_args, cd: work_dir, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {output, code}}
    end
  rescue
    e in ErlangError -> {:error, {:system_cmd_failed, Exception.message(e)}}
  end

  # ── Porcelain blame parser ───────────────────────────────────────────

  defp parse_porcelain_blame(output) do
    output
    |> String.split("\n")
    |> parse_blame_lines(%{}, [])
    |> Enum.reverse()
  end

  defp parse_blame_lines([], _current, acc), do: acc

  defp parse_blame_lines([line | rest], current, acc) do
    cond do
      # Header line: <sha> <orig_line> <final_line> [<group_count>]
      Regex.match?(~r/^[0-9a-f]{40} /, line) ->
        parts = String.split(line, " ")
        sha = Enum.at(parts, 0)
        orig_line = Enum.at(parts, 1) |> String.to_integer()
        final_line = Enum.at(parts, 2) |> String.to_integer()

        current =
          current
          |> Map.put(:sha, sha)
          |> Map.put(:original_line, orig_line)
          |> Map.put(:line, final_line)

        parse_blame_lines(rest, current, acc)

      String.starts_with?(line, "author ") ->
        parse_blame_lines(
          rest,
          Map.put(current, :author, String.trim_leading(line, "author ")),
          acc
        )

      String.starts_with?(line, "author-mail ") ->
        email =
          line |> String.trim_leading("author-mail ") |> String.trim("<") |> String.trim(">")

        parse_blame_lines(rest, Map.put(current, :email, email), acc)

      String.starts_with?(line, "author-time ") ->
        ts = line |> String.trim_leading("author-time ") |> String.to_integer()
        dt = DateTime.from_unix!(ts)
        parse_blame_lines(rest, Map.put(current, :date, dt), acc)

      String.starts_with?(line, "summary ") ->
        parse_blame_lines(
          rest,
          Map.put(current, :summary, String.trim_leading(line, "summary ")),
          acc
        )

      # Content line starts with a TAB
      String.starts_with?(line, "\t") ->
        content = String.trim_leading(line, "\t")

        entry = %BlameEntry{
          sha: Map.get(current, :sha),
          author: Map.get(current, :author, "Unknown"),
          email: Map.get(current, :email, ""),
          date: Map.get(current, :date),
          line: Map.get(current, :line, 0),
          original_line: Map.get(current, :original_line, 0),
          content: content,
          summary: Map.get(current, :summary)
        }

        parse_blame_lines(rest, %{}, [entry | acc])

      true ->
        # Skip other porcelain fields (author-tz, committer-*, filename, etc.)
        parse_blame_lines(rest, current, acc)
    end
  end

  # ── Log output parser (NUL-delimited) ────────────────────────────────

  defp parse_log_output(output) do
    output
    |> String.split("\0", trim: true)
    |> Enum.map(&parse_single_commit/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_single_commit(chunk) do
    lines = String.split(chunk, "\n", trim: true)

    # The format is: sha, short_sha, author, email, date_iso, summary, full_body...
    # Followed by optional name-status lines
    case lines do
      [sha, short_sha, author, email, date_iso, summary | rest] ->
        {body_lines, file_lines} = split_body_and_files(rest)

        %Commit{
          sha: String.trim(sha),
          short_sha: String.trim(short_sha),
          author: author,
          email: email,
          date: parse_iso_date(date_iso),
          summary: summary,
          message: Enum.join(body_lines, "\n"),
          files_changed: parse_name_status_lines(file_lines)
        }

      _ ->
        nil
    end
  end

  defp split_body_and_files(lines) do
    # Name-status lines look like "M\tpath" or "A\tpath"
    # Body lines are everything else
    {body, files} =
      Enum.split_while(lines, fn line ->
        not Regex.match?(~r/^[AMDRT]\t/, line)
      end)

    {body, files}
  end

  # ── Name-status parser ───────────────────────────────────────────────

  defp parse_name_status(output) do
    output
    |> String.split("\n", trim: true)
    |> parse_name_status_lines()
  end

  defp parse_name_status_lines(lines) do
    Enum.flat_map(lines, fn line ->
      case String.split(line, "\t", parts: 2) do
        [status, path] ->
          [{String.trim(path), status_atom(String.at(status, 0))}]

        _ ->
          []
      end
    end)
  end

  defp status_atom("A"), do: :added
  defp status_atom("M"), do: :modified
  defp status_atom("D"), do: :deleted
  defp status_atom("R"), do: :renamed
  defp status_atom("T"), do: :type_changed
  defp status_atom(_), do: :unknown

  # ── Date parsing ─────────────────────────────────────────────────────

  defp parse_iso_date(str) do
    case DateTime.from_iso8601(String.trim(str)) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
