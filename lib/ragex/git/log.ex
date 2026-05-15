defmodule Ragex.Git.Log do
  @moduledoc """
  High-level git log API.

  Provides file-level and function-level history. Function evolution
  tracking uses `git log -L` which always goes through the CLI backend
  since `libgit2` does not support it.

  ## Examples

      # File history
      {:ok, commits} = Ragex.Git.Log.file_history("/opt/project", "lib/user.ex")

      # Function evolution
      {:ok, commits} = Ragex.Git.Log.function_history("/opt/project",
        "create_user", "lib/user.ex")

      # Filtered by author and time
      {:ok, commits} = Ragex.Git.Log.file_history("/opt/project", "lib/user.ex",
        author: "alice", since: "2025-01-01")
  """

  alias Ragex.Git.{Backend, Commit, Repo}

  @doc """
  Get commit history for a file.

  ## Options
  - `:max_count` -- maximum commits to return (default 50)
  - `:since` -- ISO-8601 date or `~D` date
  - `:author` -- author name substring filter

  ## Returns
  `{:ok, [%Commit{}]}`
  """
  @spec file_history(String.t(), String.t(), keyword()) ::
          {:ok, [Commit.t()]} | {:error, term()}
  def file_history(path, file_path, opts \\ []) do
    with {:ok, repo_root} <- Repo.root(path) do
      Backend.active().log(repo_root, file_path, opts)
    end
  end

  @doc """
  Track a function's evolution through history using `git log -L`.

  This **always** uses the CLI backend because `libgit2` does not
  support the `-L` flag.

  ## Parameters
  - `path` -- any path inside the repository
  - `function_name` -- the function name to track
  - `file_path` -- file path relative to the repo root
  - `opts` -- `:max_count` (default 20)

  ## Returns
  `{:ok, [%Commit{}]}` -- commits that modified the function, newest first.
  Returns `{:ok, []}` if git can't find the function pattern.
  """
  @spec function_history(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [Commit.t()]} | {:error, term()}
  def function_history(path, function_name, file_path, opts \\ []) do
    with {:ok, repo_root} <- Repo.root(path) do
      Backend.CLI.function_log(repo_root, function_name, file_path, opts)
    end
  end

  @doc """
  Get details for a single commit.
  """
  @spec commit_info(String.t(), String.t()) ::
          {:ok, Commit.t()} | {:error, term()}
  def commit_info(path, sha) do
    with {:ok, repo_root} <- Repo.root(path) do
      Backend.active().commit_info(repo_root, sha)
    end
  end
end
