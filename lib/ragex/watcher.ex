defmodule Ragex.Watcher do
  @moduledoc """
  Watches directories for file changes and automatically re-analyzes modified files.

  Uses FileSystem to monitor for changes and triggers re-analysis on supported files.
  """

  use GenServer
  require Logger

  alias Ragex.Analyzers.Directory

  defmodule State do
    @moduledoc false
    defstruct [
      :watcher_pid,
      :watched_dirs,
      :debounce_timer,
      :pending_files
    ]
  end

  @timeout :ragex
           |> Application.compile_env(:timeouts, [])
           |> Keyword.get(:watcher, :infinity)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts watching a directory for changes.
  """
  def watch_directory(path) do
    GenServer.call(__MODULE__, {:watch, path}, @timeout)
  catch
    :exit, {:timeout, {GenServer, :call, [_pid, {:watch, ^path}, @timeout]}} ->
      {:error, :timeout}
  end

  @doc """
  Stops watching a directory.
  """
  def unwatch_directory(path) do
    GenServer.call(__MODULE__, {:unwatch, path}, @timeout)
  catch
    :exit, {:timeout, {GenServer, :call, [_pid, {:unwatch, ^path}, @timeout]}} ->
      {:error, :timeout}
  end

  @doc """
  Lists all currently watched directories.
  """
  def list_watched do
    GenServer.call(__MODULE__, :list_watched, @timeout)
  catch
    :exit, {:timeout, {GenServer, :call, [_pid, :list_watched, @timeout]}} ->
      {:error, :timeout}
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %State{
      watcher_pid: nil,
      watched_dirs: MapSet.new(),
      debounce_timer: nil,
      pending_files: MapSet.new()
    }

    Logger.info("File watcher initialized")
    {:ok, state}
  end

  @impl true
  def handle_call({:watch, path}, _from, state) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        # Add directory to watched set
        new_watched = MapSet.put(state.watched_dirs, path)

        # Restart FileSystem with updated directory list
        new_state = restart_watcher(state, new_watched)

        Logger.info("Now watching directory: #{path}")
        {:reply, :ok, new_state}

      {:ok, %File.Stat{type: :regular}} ->
        {:reply, {:error, :not_a_directory}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:unwatch, path}, _from, state) do
    new_watched = MapSet.delete(state.watched_dirs, path)

    # Restart FileSystem with updated directory list
    new_state = restart_watcher(state, new_watched)

    Logger.info("Stopped watching directory: #{path}")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:list_watched, _from, state) do
    {:reply, MapSet.to_list(state.watched_dirs), state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    # Handle file system events
    if should_process_event?(path, events) do
      # Add to pending files and set/reset debounce timer
      pending = MapSet.put(state.pending_files, path)

      # Cancel existing timer if any
      if state.debounce_timer do
        Process.cancel_timer(state.debounce_timer)
      end

      # Set new timer (300ms debounce)
      timer = Process.send_after(self(), :process_pending, 300)

      {:noreply, %{state | pending_files: pending, debounce_timer: timer}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("File watcher stopped")
    {:noreply, state}
  end

  @impl true
  def handle_info(:process_pending, state) do
    # Process all pending files
    files = MapSet.to_list(state.pending_files)

    if files != [] do
      Logger.info("Re-analyzing #{length(files)} changed file(s)")

      Task.start(fn ->
        {:ok, summary} = Directory.analyze_files(files)

        Logger.info(
          "Re-analysis complete: #{summary.success} succeeded, #{summary.errors} failed"
        )
      end)
    end

    {:noreply, %{state | pending_files: MapSet.new(), debounce_timer: nil}}
  end

  # Private functions

  defp restart_watcher(state, new_watched) do
    # Stop existing watcher if any
    if state.watcher_pid do
      Process.exit(state.watcher_pid, :normal)
    end

    # Start new watcher with updated directory list
    new_watcher_pid =
      if MapSet.size(new_watched) > 0 do
        dirs = MapSet.to_list(new_watched)
        {:ok, pid} = FileSystem.start_link(dirs: dirs)
        FileSystem.subscribe(pid)
        pid
      else
        nil
      end

    %{state | watcher_pid: new_watcher_pid, watched_dirs: new_watched}
  end

  defp should_process_event?(path, events) do
    # Only process :modified or :created events for supported files
    # Ignore :removed and :renamed for now
    has_relevant_event = Enum.any?(events, &(&1 in [:modified, :created]))

    has_relevant_event and supported_file?(path)
  end

  defp supported_file?(path) do
    ext = Path.extname(path)

    # Check if it's a supported extension
    ext in [".ex", ".exs", ".erl", ".hrl", ".py", ".js", ".jsx", ".ts", ".tsx", ".mjs"]
  end
end
