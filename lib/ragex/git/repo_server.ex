defmodule Ragex.Git.RepoServer do
  @moduledoc """
  GenServer that owns the `egit` NIF repository reference.

  NIF resources are process-bound in the BEAM: the repo handle opened by
  `:git.open/1` is only valid in the process that created it. This GenServer
  holds that handle and serializes all NIF calls through it.

  If `libgit2` segfaults (unlikely but possible with a beta NIF), only
  this process dies. The supervisor restarts it and re-opens the repo.

  Started only when egit is available. When the `:git` module is not loaded,
  this GenServer is not added to the supervision tree.
  """

  use GenServer
  require Logger

  defmodule State do
    @moduledoc false
    defstruct [:repo_ref, :repo_path]
  end

  # ── Client API ───────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Open (or re-open) a repository at the given path."
  @spec open(String.t()) :: :ok | {:error, term()}
  def open(repo_path) do
    GenServer.call(__MODULE__, {:open, repo_path})
  end

  @doc "Execute an egit function against the held repo reference."
  @spec call(atom(), [term()]) :: term()
  def call(function, args) do
    GenServer.call(__MODULE__, {:egit_call, function, args}, 30_000)
  end

  @doc "Returns the currently opened repo path, or nil."
  @spec current_path() :: String.t() | nil
  def current_path do
    GenServer.call(__MODULE__, :current_path)
  end

  # ── Server callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:open, repo_path}, _from, state) do
    case do_open(repo_path) do
      {:ok, ref} ->
        {:reply, :ok, %State{repo_ref: ref, repo_path: repo_path}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:egit_call, _function, _args}, _from, %State{repo_ref: nil} = state) do
    {:reply, {:error, :no_repo_open}, state}
  end

  @impl true
  def handle_call({:egit_call, function, args}, _from, %State{repo_ref: ref} = state) do
    result =
      try do
        apply(:git, function, [ref | args])
      rescue
        e ->
          Logger.error("egit NIF call #{function} crashed: #{Exception.message(e)}")
          {:error, {:nif_crash, Exception.message(e)}}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:current_path, _from, state) do
    {:reply, state.repo_path, state}
  end

  # Private

  defp do_open(path) do
    ref = :git.open(path)
    {:ok, ref}
  rescue
    e -> {:error, {:egit_open_failed, Exception.message(e)}}
  end
end
