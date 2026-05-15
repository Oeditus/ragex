defmodule Ragex.Git.Repo do
  @moduledoc """
  Repository detection and metadata.

  Discovers the git repository root for a given working directory and
  caches the result. All git operations in Ragex start by calling
  `Repo.root/1` to establish the repo context.

  ## Examples

      iex> Ragex.Git.Repo.root("/opt/my_project/lib")
      {:ok, "/opt/my_project"}

      iex> Ragex.Git.Repo.git_available?()
      true
  """

  alias Ragex.Git.Backend

  @root_cache :ragex_git_root_cache

  @doc """
  Returns the repository root for a working directory.

  Caches the result in the process dictionary to avoid repeated git calls
  within the same process (e.g. during a single MCP tool invocation).
  """
  @spec root(String.t()) :: {:ok, String.t()} | {:error, term()}
  def root(work_dir) do
    cache_key = {@root_cache, work_dir}

    case Process.get(cache_key) do
      nil ->
        result = Backend.active().repo_root(work_dir)

        case result do
          {:ok, root} -> Process.put(cache_key, root)
          _ -> :ok
        end

        result

      cached ->
        {:ok, cached}
    end
  end

  @doc """
  Returns `true` if the `git` binary is available on the system.
  """
  @spec git_available?() :: boolean()
  def git_available? do
    case System.find_executable("git") do
      nil -> false
      _ -> true
    end
  end

  @doc """
  Returns `true` if the given path is inside a git repository.
  """
  @spec in_repo?(String.t()) :: boolean()
  def in_repo?(path) do
    match?({:ok, _}, root(path))
  end

  @doc """
  Returns the current branch name for the repo containing `path`.
  """
  @spec current_branch(String.t()) :: {:ok, String.t()} | {:error, term()}
  def current_branch(path) do
    with {:ok, repo_root} <- root(path) do
      case System.cmd("git", ["--no-pager", "rev-parse", "--abbrev-ref", "HEAD"],
             cd: repo_root,
             stderr_to_stdout: true
           ) do
        {branch, 0} -> {:ok, String.trim(branch)}
        {err, _code} -> {:error, err}
      end
    end
  end

  @doc """
  Returns a project hash suitable for cache file paths.

  Uses the repo root path to generate a deterministic short hash.
  """
  @spec project_hash(String.t()) :: String.t()
  def project_hash(repo_root) do
    :crypto.hash(:sha256, repo_root)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 12)
  end
end
