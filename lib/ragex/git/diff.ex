defmodule Ragex.Git.Diff do
  @moduledoc """
  Resolves the set of files changed between two git refs.

  Used by `mix ragex.analyze --diff` and `mix ragex.ci` to scope analysis
  to only modified code (pull request / incremental CI workflows).

  Tries the active git backend (egit NIF when available) first, then
  falls back to shelling out to `git`.
  """

  alias Ragex.Git.{Backend, Repo}

  @type diff_opts :: [
          base: String.t(),
          head: String.t(),
          filter: String.t(),
          extensions: [String.t()]
        ]

  @doc """
  Returns the list of files changed between `base` and `head` refs.

  Only files that still exist on disk are included (added, copied,
  modified, renamed -- not deleted).

  ## Options

  - `:base` - Base git ref (default: `"origin/main"`)
  - `:head` - Head git ref (default: `"HEAD"`)
  - `:filter` - Git diff status filter, e.g. `"ACMR"` (default: `"ACMR"`)
  - `:extensions` - Optional list of extensions to keep (e.g. `[".ex", ".exs"]`)

  ## Examples

      iex> Ragex.Git.Diff.changed_files("/path/to/repo")
      {:ok, ["lib/foo.ex", "lib/bar.ex"]}
  """
  @spec changed_files(String.t(), diff_opts()) :: {:ok, [String.t()]} | {:error, term()}
  def changed_files(repo_root, opts \\ []) do
    base = Keyword.get(opts, :base, "origin/main")
    head = Keyword.get(opts, :head, "HEAD")
    filter = Keyword.get(opts, :filter, "ACMR")
    extensions = Keyword.get(opts, :extensions)

    # Try egit backend first (if available), fall back to CLI
    result =
      if Backend.egit_available?() do
        egit_changed_files(repo_root, base, head, filter)
      else
        cli_changed_files(repo_root, base, head, filter)
      end

    case result do
      {:ok, files} -> {:ok, maybe_filter_extensions(files, extensions)}
      error -> error
    end
  end

  @doc """
  Like `changed_files/2` but raises on error.
  """
  @spec changed_files!(String.t(), diff_opts()) :: [String.t()]
  def changed_files!(repo_root, opts \\ []) do
    case changed_files(repo_root, opts) do
      {:ok, files} -> files
      {:error, reason} -> raise "Failed to resolve git diff: #{inspect(reason)}"
    end
  end

  @doc """
  Convenience: resolves the repo root, then returns changed files.

  Accepts any path inside a repository.
  """
  @spec changed_files_for_path(String.t(), diff_opts()) ::
          {:ok, String.t(), [String.t()]} | {:error, term()}
  def changed_files_for_path(path, opts \\ []) do
    with {:ok, repo_root} <- Repo.root(path),
         {:ok, files} <- changed_files(repo_root, opts) do
      {:ok, repo_root, files}
    end
  end

  # -- egit path --------------------------------------------------------

  # Uses Backend.Egit.diff/3 which calls libgit2 directly.
  # Returns file paths only, filtering by diff status.
  defp egit_changed_files(repo_root, base, head, filter) do
    case Backend.Egit.diff(repo_root, base, head) do
      {:ok, entries} ->
        allowed_statuses = parse_filter(filter)

        files =
          entries
          |> Enum.filter(fn {_path, status} -> status in allowed_statuses end)
          |> Enum.map(fn {path, _status} -> path end)

        {:ok, files}

      {:error, _} ->
        # Fallback to CLI if egit fails (e.g. ref resolution issues)
        cli_changed_files(repo_root, base, head, filter)
    end
  rescue
    _ -> cli_changed_files(repo_root, base, head, filter)
  end

  # -- CLI path ---------------------------------------------------------

  defp cli_changed_files(repo_root, base, head, filter) do
    args = [
      "--no-pager",
      "diff",
      "--name-only",
      "--diff-filter=#{filter}",
      "#{base}...#{head}"
    ]

    case System.cmd("git", args, cd: repo_root, stderr_to_stdout: true) do
      {output, 0} ->
        files = String.split(output, "\n", trim: true)
        {:ok, files}

      {error, _code} ->
        {:error, String.trim(error)}
    end
  end

  # -- Helpers ----------------------------------------------------------

  @filter_map %{
    ?A => :added,
    ?C => :added,
    ?M => :modified,
    ?R => :renamed
  }

  defp parse_filter(filter) do
    filter
    |> String.to_charlist()
    |> Enum.map(&Map.get(@filter_map, &1))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp maybe_filter_extensions(files, nil), do: files
  defp maybe_filter_extensions(files, []), do: files

  defp maybe_filter_extensions(files, extensions) do
    Enum.filter(files, fn f -> Path.extname(f) in extensions end)
  end
end
