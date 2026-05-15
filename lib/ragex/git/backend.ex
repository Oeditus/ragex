defmodule Ragex.Git.Backend do
  @moduledoc """
  Behaviour defining the contract for git backend implementations.

  Two implementations exist:

  - `Ragex.Git.Backend.CLI` -- shells out to the `git` binary. Universal fallback
    that works everywhere `git` is installed. Also the only path for operations
    that `libgit2` doesn't support (e.g. `git log -L` for function evolution).

  - `Ragex.Git.Backend.Egit` -- NIF bindings to `libgit2` via the `egit` package.
    Faster (no process spawn, no text parsing) but requires `libgit2-dev` at build
    time and is an optional dependency.

  Backend selection is automatic: if `:git` (egit) is loaded, prefer it; otherwise
  fall back to CLI. Override via `config :ragex, git_backend: :egit | :cli | :auto`.
  """

  alias Ragex.Git.{BlameEntry, Commit}

  @type path :: String.t()
  @type sha :: String.t()
  @type line :: pos_integer()

  @doc "Return the repository root for the given working directory."
  @callback repo_root(path()) :: {:ok, path()} | {:error, term()}

  @doc """
  Blame a file, returning per-line authorship.

  ## Options
  - `:start_line` -- first line (1-indexed, default 1)
  - `:end_line` -- last line (default: end of file)
  """
  @callback blame(path(), path(), keyword()) ::
              {:ok, [BlameEntry.t()]} | {:error, term()}

  @doc """
  List commits touching a path.

  ## Options
  - `:max_count` -- limit results (default 50)
  - `:since` -- ISO-8601 date string or `~D` date
  - `:author` -- filter by author substring
  """
  @callback log(path(), path(), keyword()) ::
              {:ok, [Commit.t()]} | {:error, term()}

  @doc """
  List files changed between two revisions.

  Returns `{:ok, [{path, status}]}` where status is `:added | :modified | :deleted | :renamed`.
  """
  @callback diff(path(), sha(), sha()) ::
              {:ok, [{path(), atom()}]} | {:error, term()}

  @doc """
  List commit SHAs reachable from `rev`, newest first.

  ## Options
  - `:max_count` -- limit results (default 500)
  """
  @callback rev_list(path(), sha(), keyword()) ::
              {:ok, [sha()]} | {:error, term()}

  @doc """
  Look up a single commit by SHA.
  """
  @callback commit_info(path(), sha()) ::
              {:ok, Commit.t()} | {:error, term()}

  # ── Backend resolution ───────────────────────────────────────────────

  @doc """
  Returns the active backend module based on configuration and availability.

  Resolution order:
  1. Explicit config `:ragex, :git_backend` (`:egit` or `:cli`)
  2. Auto-detect: egit if loaded, otherwise CLI
  """
  @spec active() :: module()
  def active do
    case Application.get_env(:ragex, :git_backend, :auto) do
      :egit -> Ragex.Git.Backend.Egit
      :cli -> Ragex.Git.Backend.CLI
      :auto -> if egit_available?(), do: Ragex.Git.Backend.Egit, else: Ragex.Git.Backend.CLI
    end
  end

  @doc "Returns `true` when the egit NIF module is compiled and loadable."
  @spec egit_available?() :: boolean()
  def egit_available? do
    Code.ensure_loaded?(:git)
  end
end
