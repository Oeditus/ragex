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

    new_instances =
      state.instances
      |> Enum.reject(fn {_path, info} -> info[:proc] == port_proc end)
      |> Map.new()

    active =
      if state.active_project && !Map.has_key?(new_instances, state.active_project),
        do: nil,
        else: state.active_project

    {:noreply, %{state | instances: new_instances, active_project: active}}
  end

  @impl true
  def handle_info({_port, {:data, _data}}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({_port, {:exit_status, _status}}, state) do
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

    binary = find_dllb_binary()

    if is_nil(binary) do
      Logger.warning("Cannot start per-project dllb server: binary not found")
      {:error, :dllb_binary_not_found}
    else
      pool_name = :"dllb_pool_#{port}"

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
        Port.open({:spawn_executable, binary}, [:binary, :exit_status, env: env, args: []])

      case wait_for_server(port, 30) do
        :ok ->
          pool_opts = [name: pool_name, host: "127.0.0.1", port: port, pool_size: 5]

          {:ok, pool_pid} =
            NimblePool.start_link(worker: {Dllb.Pool, pool_opts}, pool_size: 5, name: pool_name)

          # Bootstrap database schema for this instance
          DllbBackend.bootstrap_instance(pool_name)

          info = %{
            project_path: project_path,
            port: port,
            proc: port_proc,
            pool: pool_name,
            pool_pid: pool_pid,
            db_path: db_path
          }

          {:ok, info}

        {:error, reason} ->
          try do
            Port.close(port_proc)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end

          {:error, reason}
      end
    end
  end

  defp do_stop_instance(info) do
    if info[:pool_pid] && Process.alive?(info[:pool_pid]) do
      Process.exit(info[:pool_pid], :shutdown)
    end

    if info[:proc] do
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
  end

  defp wait_for_server(_port, 0), do: {:error, :server_timeout}

  defp wait_for_server(port, attempts) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 200) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        Process.sleep(100)
        wait_for_server(port, attempts - 1)
    end
  end
end
