defmodule Ragex.Watcher do
  @moduledoc """
  Watches directories for file changes and automatically re-analyzes modified files.

  Uses FileSystem to monitor for changes and triggers re-analysis on supported files.
  By default, only monitors directories containing source files (such as `lib` and `test`)
  and ignores non-source directories like `.git`, `_build`, and `deps`.

  ## Configuration

  Directories to watch can be configured in your application configuration:

      config :ragex, watcher: [dirs: ["lib", "test"]]

  Or:

      config :ragex, :watcher,
        dirs: ["lib", "test"]
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

  @default_source_dirs [
    "lib",
    "test",
    "tests",
    "src",
    "app",
    "spec",
    "apps",
    "web",
    "cmd",
    "pkg",
    "internal"
  ]

  @default_exclude_dirs [
    ".git",
    ".hg",
    ".svn",
    "_build",
    "deps",
    "node_modules",
    ".elixir_ls",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".bundle",
    "vendor",
    "target",
    "dist",
    "build",
    "coverage",
    "tmp",
    "temp",
    ".cache"
  ]

  @timeout :ragex
           |> Application.compile_env(:timeouts, [])
           |> Keyword.get(:watcher, :infinity)

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts watching a directory for changes.

  By default, if `path` contains source directories (like `lib` and `test`),
  only those source directories are watched, preventing directories like `.git`
  from being monitored.

  ## Options

  - `:dirs` - Explicit list of subdirectories or paths to watch.
  - `:only_source_dirs` (or `:source_only`) - When `true` (default), only source
    directories like `lib` and `test` are monitored. When `false`, watches `path`
    directly without filtering.
  """
  @spec watch_directory(String.t(), keyword()) :: :ok | {:error, term()}
  def watch_directory(path, opts \\ []) do
    GenServer.call(__MODULE__, {:watch, path, opts}, @timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, :timeout}
  end

  @doc """
  Stops watching a directory (and any of its watched subdirectories).
  """
  @spec unwatch_directory(String.t()) :: :ok | {:error, term()}
  def unwatch_directory(path) do
    GenServer.call(__MODULE__, {:unwatch, path}, @timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, :timeout}
  end

  @doc """
  Lists all currently watched directories.
  """
  @spec list_watched() :: [String.t()] | {:error, term()}
  def list_watched do
    GenServer.call(__MODULE__, :list_watched, @timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, :timeout}
  end

  @doc """
  Checks if a directory or any of its subdirectories is currently watched.
  """
  @spec watching?(String.t()) :: boolean()
  def watching?(path) do
    case list_watched() do
      {:error, _} ->
        false

      watched when is_list(watched) ->
        expanded = Path.expand(path)
        prefix = expanded <> "/"

        Enum.any?(watched, fn dir ->
          dir == expanded or dir == path or String.starts_with?(dir, prefix)
        end)
    end
  end

  @spec default_source_dirs() :: [String.t()]
  def default_source_dirs do
    watcher_cfg = Application.get_env(:ragex, :watcher, [])

    Keyword.get(watcher_cfg, :dirs) ||
      Keyword.get(watcher_cfg, :source_dirs, @default_source_dirs)
  end

  @spec default_exclude_dirs() :: [String.t()]
  def default_exclude_dirs do
    Application.get_env(:ragex, :watcher, [])
    |> Keyword.get(:exclude_dirs, @default_exclude_dirs)
  end

  @doc """
  Resolves the directories that should be watched for a given path.

  Accepts `:dirs` via options, or falls back to `:ragex, watcher: [dirs: [...]]`
  configuration, or standard source directories (like `lib` and `test`).
  """
  @spec resolve_watch_directories(String.t(), keyword()) :: [String.t()]
  def resolve_watch_directories(path, opts \\ []) do
    path = Path.expand(path)
    only_source_dirs = Keyword.get(opts, :only_source_dirs, Keyword.get(opts, :source_only, true))

    cond do
      not only_source_dirs ->
        [path]

      Keyword.has_key?(opts, :dirs) and is_list(opts[:dirs]) and opts[:dirs] != [] ->
        resolve_explicit_dirs(path, opts[:dirs])

      true ->
        watcher_cfg = Application.get_env(:ragex, :watcher, [])

        configured_dirs =
          Keyword.get(watcher_cfg, :dirs) || Keyword.get(watcher_cfg, :source_dirs)

        if is_list(configured_dirs) and configured_dirs != [] do
          resolve_explicit_dirs(path, configured_dirs)
        else
          find_default_source_dirs(path)
        end
    end
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
  def handle_call({:watch, path}, from, state) do
    handle_call({:watch, path, []}, from, state)
  end

  @impl true
  def handle_call({:watch, path, opts}, _from, state) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        dirs_to_watch = resolve_watch_directories(path, opts)
        dirs_set = MapSet.new(dirs_to_watch)

        if MapSet.subset?(dirs_set, state.watched_dirs) and state.watcher_pid != nil do
          {:reply, :ok, state}
        else
          new_watched = MapSet.union(state.watched_dirs, dirs_set)
          new_state = restart_watcher(state, new_watched)

          Logger.info("Now watching directories: #{inspect(dirs_to_watch)}")
          {:reply, :ok, new_state}
        end

      {:ok, %File.Stat{type: :regular}} ->
        {:reply, {:error, :not_a_directory}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:unwatch, path}, _from, state) do
    expanded_path = Path.expand(path)
    prefix = expanded_path <> "/"

    new_watched =
      state.watched_dirs
      |> Enum.reject(fn dir ->
        dir == expanded_path or dir == path or String.starts_with?(dir, prefix)
      end)
      |> MapSet.new()

    if MapSet.equal?(new_watched, state.watched_dirs) do
      {:reply, :ok, state}
    else
      new_state = restart_watcher(state, new_watched)
      Logger.info("Stopped watching directory: #{path}")
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:list_watched, _from, state) do
    {:reply, state.watched_dirs |> MapSet.to_list() |> Enum.sort(), state}
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

  defp resolve_explicit_dirs(path, dirs) do
    basename = Path.basename(path)

    if basename in dirs do
      [path]
    else
      matched =
        dirs
        |> Enum.map(fn d ->
          if Path.type(d) == :absolute, do: Path.expand(d), else: Path.expand(Path.join(path, d))
        end)
        |> Enum.filter(&File.dir?/1)

      if matched != [], do: matched, else: [path]
    end
  end

  defp find_default_source_dirs(path) do
    basename = Path.basename(path)
    standard_names = default_source_dirs()

    if basename in standard_names do
      [path]
    else
      existing_standard =
        standard_names
        |> Enum.map(&Path.join(path, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&Path.expand/1)

      if existing_standard != [] do
        existing_standard
      else
        # Fallback: check if other non-excluded subdirectories contain source files
        subdirs_with_source =
          case File.ls(path) do
            {:ok, entries} ->
              entries
              |> Enum.reject(&excluded_dir_name?/1)
              |> Enum.map(&Path.join(path, &1))
              |> Enum.filter(&File.dir?/1)
              |> Enum.filter(&contains_source_files?/1)
              |> Enum.map(&Path.expand/1)

            _ ->
              []
          end

        if subdirs_with_source != [], do: subdirs_with_source, else: [path]
      end
    end
  end

  @spec contains_source_files?(String.t(), integer()) :: boolean()
  def contains_source_files?(dir, max_depth \\ 3) do
    find_first_source_file(dir, 0, max_depth)
  end

  defp find_first_source_file(_dir, depth, max_depth) when depth > max_depth, do: false

  defp find_first_source_file(dir, depth, max_depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.any?(entries, fn entry ->
          if excluded_dir_name?(entry) do
            false
          else
            full_path = Path.join(dir, entry)

            if File.regular?(full_path) do
              supported_file?(full_path)
            else
              if File.dir?(full_path) do
                find_first_source_file(full_path, depth + 1, max_depth)
              else
                false
              end
            end
          end
        end)

      _ ->
        false
    end
  end

  defp excluded_dir_name?(name) do
    name in default_exclude_dirs() or
      (String.starts_with?(name, ".") and name not in [".", ".."])
  end

  defp restart_watcher(state, new_watched) do
    # Stop existing watcher if any
    if state.watcher_pid && Process.alive?(state.watcher_pid) do
      try do
        GenServer.stop(state.watcher_pid, :normal, 1000)
      catch
        :exit, _ -> Process.exit(state.watcher_pid, :kill)
      end
    end

    # Start new watcher with updated directory list
    new_watcher_pid =
      with size when size > 0 <- MapSet.size(new_watched),
           dirs <- MapSet.to_list(new_watched),
           {:ok, pid} <- FileSystem.start_link(dirs: dirs),
           do: tap(pid, &FileSystem.subscribe/1),
           else: (_ -> nil)

    %{state | watcher_pid: new_watcher_pid, watched_dirs: new_watched}
  end

  defp should_process_event?(path, events) do
    # Only process :modified or :created events for supported files
    # Ignore :removed and :renamed for now
    has_relevant_event = Enum.any?(events, &(&1 in [:modified, :created]))

    has_relevant_event and supported_file?(path) and not excluded_path?(path)
  end

  defp excluded_path?(path) do
    segments = Path.split(path)
    exclude_dirs = default_exclude_dirs()

    Enum.any?(segments, fn segment ->
      segment in exclude_dirs or
        (String.starts_with?(segment, ".") and segment not in [".", ".."])
    end)
  end

  defp supported_file?(path) do
    Path.extname(path) in Ragex.LanguageSupport.supported_extensions()
  end
end
