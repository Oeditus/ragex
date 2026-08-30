defmodule Ragex.Dllb.ProjectManager do
  @moduledoc """
  Manages per-project `dllb` database instances and connection pools.

  When `:dllb_mode` is set to `:per_project` (or `:dllb_instance_per_project` is true),
  Ragex automatically spawns and manages a dedicated `dllb-server` OS process
  and client connection pool for each project directory.

  The internal project info (documents, graphs, vector embeddings, code metrics)
  is stored inside `<project_path>/.ragex/dllb.redb`.

  ## Configuration

      config :ragex,
        store_backend: :dllb,
        dllb_mode: :per_project,   # :global (default) or :per_project
        dllb_server_bin: nil       # Path to dllb-server executable (optional)

  """

  use GenServer
  require Logger

  alias Ragex.Store.Backend.Dllb, as: DllbBackend

  @default_base_port 3010

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc "Starts the ProjectManager GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the active dllb mode: `:per_project` or `:global`.
  """
  @spec mode() :: :per_project | :global
  def mode do
    case Application.get_env(:ragex, :dllb_mode, nil) do
      :per_project ->
        :per_project

      :global ->
        :global

      _ ->
        if Application.get_env(:ragex, :dllb_instance_per_project, false) do
          :per_project
        else
          :global
        end
    end
  end

  @doc "Returns true if per-project dllb mode is enabled."
  @spec per_project_enabled?() :: boolean()
  def per_project_enabled?, do: mode() == :per_project

  @doc """
  Ensures a dllb-server process and connection pool exist for `project_path`.
  """
  @spec ensure_instance(String.t()) :: {:ok, map()} | {:error, term()}
  def ensure_instance(project_path) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:ensure_instance, project_path}, :infinity)
    else
      {:error, :manager_not_started}
    end
  end

  @doc """
  Sets the active project, spawning or activating its dllb instance.
  """
  @spec set_active_project(String.t()) :: :ok | {:error, term()}
  def set_active_project(project_path) do
    if per_project_enabled?() do
      case ensure_instance(project_path) do
        {:ok, _info} ->
          GenServer.call(__MODULE__, {:set_active_project, project_path})

        {:error, reason} ->
          Logger.warning(
            "Failed to initialize per-project dllb instance for #{project_path}: #{inspect(reason)}"
          )

          {:error, reason}
      end
    else
      GenServer.call(__MODULE__, {:set_active_project, project_path})
    end
  end

  @doc "Returns the active project path."
  @spec active_project() :: String.t() | nil
  def active_project do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :get_active_project)
    else
      nil
    end
  end

  @doc "Returns the pool name or pid for the active project (or default Dllb.Pool)."
  @spec active_pool() :: atom() | pid()
  def active_pool do
    if per_project_enabled?() and Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :get_active_pool)
    else
      Dllb.Pool
    end
  end

  @doc "Executes a query against the active project's pool."
  @spec query(String.t(), Keyword.t()) :: {:ok, Dllb.Result.t()} | {:error, term()}
  def query(statement, opts \\ []) do
    pool = active_pool()
    Dllb.query(statement, Keyword.put_new(opts, :pool, pool))
  end

  @doc "Executes batch queries against the active project's pool."
  @spec batch([String.t()], Keyword.t()) :: [{:ok, Dllb.Result.t()} | {:error, term()}]
  def batch(statements, opts \\ []) when is_list(statements) do
    pool = active_pool()
    Dllb.batch(statements, Keyword.put_new(opts, :pool, pool))
  end

  @doc "Executes batch transaction against the active project's pool."
  @spec batch_transaction([String.t()], Keyword.t()) :: {:ok, Dllb.Result.t()} | {:error, term()}
  def batch_transaction(statements, opts \\ []) when is_list(statements) do
    pool = active_pool()
    Dllb.batch_transaction(statements, Keyword.put_new(opts, :pool, pool))
  end

  @doc "Stops the per-project dllb instance for a given path."
  @spec stop_instance(String.t()) :: :ok
  def stop_instance(project_path) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:stop_instance, project_path})
    else
      :ok
    end
  end

  @doc "Stops all managed per-project dllb instances."
  @spec stop_all_instances() :: :ok
  def stop_all_instances do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :stop_all_instances)
    else
      :ok
    end
  end

  @doc """
  Locates the `dllb-server` executable binary path.
  """
  @spec find_dllb_binary() :: String.t() | nil
  def find_dllb_binary do
    custom = Application.get_env(:ragex, :dllb_server_bin) || System.get_env("DLLB_SERVER_BIN")

    cond do
      custom && File.exists?(custom) ->
        custom

      exec = System.find_executable("dllb-server") ->
        exec

      true ->
        cwd = File.cwd!()
        release_bin = Path.expand("../dllb/target/release/dllb-server", cwd)
        debug_bin = Path.expand("../dllb/target/debug/dllb-server", cwd)

        cond do
          File.exists?(release_bin) ->
            release_bin

          File.exists?(debug_bin) ->
            Logger.warning(
              "Using debug build of dllb-server at #{debug_bin}. For optimal performance and low memory footprint, compile with: `cargo build --release -p dllb-server`"
            )

            debug_bin

          true ->
            nil
        end
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      active_project: nil,
      instances: %{},
      next_port: Application.get_env(:ragex, :dllb_base_port, @default_base_port)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:ensure_instance, project_path}, _from, state) do
    abs_path = Path.expand(project_path)

    case Map.fetch(state.instances, abs_path) do
      {:ok, info} ->
        {:reply, {:ok, info}, state}

      :error ->
        {port, next_port} = select_available_port(state.next_port)

        case do_start_instance(abs_path, port) do
          {:ok, info} ->
            new_instances = Map.put(state.instances, abs_path, info)
            new_state = %{state | instances: new_instances, next_port: next_port}
            {:reply, {:ok, info}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:set_active_project, project_path}, _from, state) do
    abs_path = Path.expand(project_path)

    case Map.fetch(state.instances, abs_path) do
      {:ok, _info} ->
        {:reply, :ok, %{state | active_project: abs_path}}

      :error ->
        {port, next_port} = select_available_port(state.next_port)

        case do_start_instance(abs_path, port) do
          {:ok, info} ->
            new_instances = Map.put(state.instances, abs_path, info)

            new_state = %{
              state
              | instances: new_instances,
                active_project: abs_path,
                next_port: next_port
            }

            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call(:get_active_project, _from, state) do
    {:reply, state.active_project, state}
  end

  @impl true
  def handle_call(:get_active_pool, _from, state) do
    {pool, new_state} =
      case state.active_project && Map.get(state.instances, state.active_project) do
        %{pool: pool_name} when not is_nil(pool_name) ->
          {pool_name, state}

        _ ->
          cwd_path = Path.expand(File.cwd!())

          case Map.fetch(state.instances, cwd_path) do
            {:ok, %{pool: pool_name}} ->
              {pool_name, %{state | active_project: cwd_path}}

            _ ->
              {port, next_port} = select_available_port(state.next_port)

              case do_start_instance(cwd_path, port) do
                {:ok, info} ->
                  new_instances = Map.put(state.instances, cwd_path, info)

                  s = %{
                    state
                    | instances: new_instances,
                      active_project: cwd_path,
                      next_port: next_port
                  }

                  {info.pool, s}

                _ ->
                  {Dllb.Pool, state}
              end
          end
      end

    {:reply, pool, new_state}
  end

  @impl true
  def handle_call({:stop_instance, project_path}, _from, state) do
    abs_path = Path.expand(project_path)

    case Map.fetch(state.instances, abs_path) do
      {:ok, info} ->
        do_stop_instance(info)
        new_instances = Map.delete(state.instances, abs_path)
        active = if state.active_project == abs_path, do: nil, else: state.active_project
        {:reply, :ok, %{state | instances: new_instances, active_project: active}}

      :error ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:stop_all_instances, _from, state) do
    Enum.each(state.instances, fn {_path, info} ->
      do_stop_instance(info)
    end)

    {:reply, :ok, %{state | instances: %{}, active_project: nil}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.instances, fn {_path, info} ->
      do_stop_instance(info)
    end)

    :ok
  end

  @impl true
  def handle_info({:EXIT, port_proc, reason}, state) do
    Logger.debug("dllb-server port process exited: #{inspect(reason)}")

    {exited, remaining} =
      Enum.split_with(state.instances, fn {_path, info} -> info[:proc] == port_proc end)

    # Only owned instances ever have a non-nil :proc, so it's always safe to
    # drop their instance-state file here -- the process that backed it is
    # gone.
    Enum.each(exited, fn {_path, info} -> remove_instance_file(info.project_path) end)

    new_instances = Map.new(remaining)

    active =
      if state.active_project && !Map.has_key?(new_instances, state.active_project),
        do: nil,
        else: state.active_project

    {:noreply, %{state | instances: new_instances, active_project: active}}
  end

  @impl true
  def handle_info({port_proc, {:data, data}}, state) do
    # Surface dllb-server's stdout/stderr (redirected here via
    # :stderr_to_stdout) instead of silently discarding it -- this is where
    # diagnostics like a redb lock conflict on startup would otherwise
    # vanish without a trace.
    log_dllb_output(port_proc, data, :info)
    {:noreply, state}
  end

  @impl true
  def handle_info({port_proc, {:exit_status, status}}, state) do
    if status != 0 do
      Logger.warning(
        "dllb-server process exited with status #{status} (port: #{inspect(port_proc)})"
      )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("ProjectManager unhandled info message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp select_available_port(port) do
    if port_available?(port) do
      {port, port + 1}
    else
      select_available_port(port + 1)
    end
  end

  defp port_available?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp do_start_instance(project_path, port) do
    db_dir = Path.join(project_path, ".ragex")
    File.mkdir_p!(db_dir)
    db_path = Path.join(db_dir, "dllb.redb")
    instance_file = instance_state_path(project_path)

    case adopt_if_alive(project_path, db_path, instance_file) do
      {:ok, info} -> {:ok, info}
      :none -> spawn_and_attach(project_path, port, db_path, instance_file)
    end
  end

  # If a previous (possibly orphaned, e.g. after a VM crash or restart)
  # dllb-server is still alive for this project, reattach to it instead of
  # spawning a second one against the same redb file -- that second attempt
  # would fail with a "Database already open" lock error, since the OS-level
  # exclusive lock is still held by the still-running orphan.
  defp adopt_if_alive(project_path, db_path, instance_file) do
    case read_instance_file(instance_file) do
      {:ok, port} ->
        if server_reachable?(port) do
          Logger.info(
            "Found already-running dllb-server for #{project_path} on port #{port} " <>
              "(#{instance_file}); reattaching instead of spawning a new instance."
          )

          case attach_pool(project_path, port, db_path, owned?: false, proc: nil) do
            {:ok, info} ->
              {:ok, info}

            {:error, reason} ->
              Logger.warning(
                "Failed to attach to existing dllb-server on port #{port}: #{inspect(reason)}"
              )

              :none
          end
        else
          Logger.debug(
            "Stale dllb instance file for #{project_path} (port #{port} unreachable); removing."
          )

          File.rm(instance_file)
          :none
        end

      :error ->
        :none
    end
  end

  defp spawn_and_attach(project_path, port, db_path, instance_file) do
    binary = find_dllb_binary()

    if is_nil(binary) do
      Logger.warning("Cannot start per-project dllb server: binary not found")
      {:error, :dllb_binary_not_found}
    else
      Logger.info(
        "Starting per-project dllb server for #{project_path} on port #{port} (db: #{db_path})"
      )

      env = [
        {~c"DLLB_PATH", to_charlist(db_path)},
        {~c"DLLB_BIND", to_charlist("127.0.0.1:#{port}")},
        {~c"DLLB_DB", ~c"default"},
        {~c"DLLB_NS", ~c"default"},
        {~c"DLLB_WATCH_STDIN", ~c"1"}
      ]

      port_proc =
        Port.open(
          {:spawn_executable, binary},
          [:binary, :exit_status, :stderr_to_stdout, env: env, args: []]
        )

      case wait_for_server(port, port_proc, 30, []) do
        :ok ->
          case attach_pool(project_path, port, db_path, owned?: true, proc: port_proc) do
            {:ok, info} ->
              write_instance_file(instance_file, port, port_proc)
              {:ok, info}

            {:error, reason} ->
              safe_close_port(port_proc)
              {:error, reason}
          end

        {:error, reason} ->
          safe_close_port(port_proc)
          {:error, reason}
      end
    end
  end

  # Starts (or reuses, for adoption) the connection pool for a dllb-server
  # already listening on `host:port`, bootstraps its schema, and builds the
  # instance info map tracked in GenServer state.
  defp attach_pool(project_path, port, db_path, opts) do
    pool_name = :"dllb_pool_#{port}"
    pool_opts = [name: pool_name, host: "127.0.0.1", port: port, pool_size: 5]

    case NimblePool.start_link(worker: {Dllb.Pool, pool_opts}, pool_size: 5, name: pool_name) do
      {:ok, pool_pid} ->
        build_attach_info(project_path, port, db_path, pool_name, pool_pid, opts)

      {:error, {:already_started, pool_pid}} ->
        # A pool is already registered under this name (e.g. a prior adopt
        # for the same port raced us, or the name hasn't unregistered yet
        # after a very recent stop). Reuse it rather than failing.
        build_attach_info(project_path, port, db_path, pool_name, pool_pid, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_attach_info(project_path, port, db_path, pool_name, pool_pid, opts) do
    # Bootstrap is idempotent -- safe to re-run against an adopted,
    # already-bootstrapped instance.
    DllbBackend.bootstrap_instance(pool_name)

    info = %{
      project_path: project_path,
      port: port,
      proc: Keyword.get(opts, :proc),
      pool: pool_name,
      pool_pid: pool_pid,
      db_path: db_path,
      owned?: Keyword.get(opts, :owned?, true)
    }

    {:ok, info}
  end

  defp safe_close_port(port_proc) do
    Port.close(port_proc)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp do_stop_instance(info) do
    if info[:pool_pid] && Process.alive?(info[:pool_pid]) do
      Process.exit(info[:pool_pid], :shutdown)
    end

    owned? = Map.get(info, :owned?, true)

    if owned? && info[:proc] do
      try do
        case Port.info(info[:proc], :os_pid) do
          {:os_pid, os_pid} ->
            Port.close(info[:proc])
            System.cmd("kill", ["-15", to_string(os_pid)], stderr_to_stdout: true)

          _ ->
            Port.close(info[:proc])
        end
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    # Only the owning instance may delete the state file: an adopted
    # instance doesn't know if some other, still-running consumer depends on
    # it, so removing it here could cause a future reattach attempt to miss
    # a perfectly healthy server and try to double-spawn against its db.
    if owned? do
      remove_instance_file(info.project_path)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Per-project instance-state persistence (port/pid), used to reattach to an
  # already-running dllb-server after a VM restart instead of colliding with
  # its exclusive redb lock.
  # ---------------------------------------------------------------------------

  defp instance_state_path(project_path) do
    Path.join([project_path, ".ragex", "dllb.instance.json"])
  end

  defp write_instance_file(path, port, port_proc) do
    os_pid =
      case Port.info(port_proc, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    payload = %{
      "port" => port,
      "os_pid" => os_pid,
      "started_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    File.write(path, IO.iodata_to_binary(:json.encode(payload)))
  rescue
    e -> Logger.debug("Could not write dllb instance state file #{path}: #{inspect(e)}")
  end

  defp read_instance_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, %{"port" => port}} when is_integer(port) <- safe_json_decode(content) do
      {:ok, port}
    else
      _ -> :error
    end
  end

  defp safe_json_decode(content) do
    {:ok, :json.decode(content)}
  rescue
    _ -> :error
  end

  defp remove_instance_file(project_path) do
    project_path
    |> instance_state_path()
    |> File.rm()

    :ok
  end

  # ---------------------------------------------------------------------------
  # Liveness / output helpers
  # ---------------------------------------------------------------------------

  defp server_reachable?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 300) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp wait_for_server(_port, port_proc, 0, acc) do
    log_dllb_output(port_proc, Enum.reverse(acc), :error)
    {:error, :server_timeout}
  end

  defp wait_for_server(port, port_proc, attempts, acc) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 200) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        acc = drain_port_data(port_proc, acc, 100)
        wait_for_server(port, port_proc, attempts - 1, acc)
    end
  end

  # Drains any pending port output for up to `timeout` ms, so the diagnostic
  # dllb-server prints on a failed startup (e.g. a redb lock conflict) is
  # captured instead of sitting unread in the mailbox while we poll.
  defp drain_port_data(port_proc, acc, timeout) do
    receive do
      {^port_proc, {:data, data}} -> drain_port_data(port_proc, [data | acc], 0)
    after
      timeout -> acc
    end
  end

  @dialyzer {:nowarn_function, log_dllb_output: 3}
  defp log_dllb_output(_port_proc, [], _level), do: :ok

  defp log_dllb_output(port_proc, iodata, level) when is_list(iodata) do
    log_dllb_output(port_proc, IO.iodata_to_binary(iodata), level)
  end

  defp log_dllb_output(port_proc, output, level) when is_binary(output) do
    case String.trim(output) do
      "" ->
        :ok

      trimmed ->
        message = "dllb-server (#{inspect(port_proc)}) output:\n#{trimmed}"

        case level do
          :error -> Logger.error(message)
          :warning -> Logger.warning(message)
          _ -> Logger.info(message)
        end
    end
  end
end
