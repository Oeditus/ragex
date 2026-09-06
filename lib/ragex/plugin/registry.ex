defmodule Ragex.Plugin.Registry do
  @moduledoc """
  Manages the lifecycle, discovery, topological dependency sorting, tool aggregation,
  destruction-level safety checks, parallel execution scheduling, and execution routing for Ragex plugins.
  """

  use GenServer
  require Logger

  @default_plugins [
    Ragex.Plugins.GraphAnalytics,
    Ragex.Plugins.GitArchaeology,
    Ragex.Plugins.CodeQuality,
    Ragex.Plugins.SecurityAudit,
    Ragex.Plugins.URLAnalyzer
  ]

  # Client API

  @doc "Starts the plugin registry GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a plugin module dynamically."
  def register_plugin(plugin_module, opts \\ []) when is_atom(plugin_module) do
    GenServer.call(__MODULE__, {:register, plugin_module, opts})
  end

  @doc "Unregisters a plugin by its ID."
  def unregister_plugin(plugin_id) when is_atom(plugin_id) do
    GenServer.call(__MODULE__, {:unregister, plugin_id})
  end

  @doc "Enables a registered plugin."
  def enable_plugin(plugin_id) when is_atom(plugin_id) do
    GenServer.call(__MODULE__, {:enable, plugin_id})
  end

  @doc "Disables a registered plugin."
  def disable_plugin(plugin_id) when is_atom(plugin_id) do
    GenServer.call(__MODULE__, {:disable, plugin_id})
  end

  @doc "Lists all registered plugins ordered topologically by dependency and priority."
  def list_plugins do
    GenServer.call(__MODULE__, :list_plugins)
  end

  @doc "Returns aggregated tool schemas across all active plugins in priority order."
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc "Dispatches a single tool call."
  def dispatch_tool(tool_name, args) when is_binary(tool_name) and is_map(args) do
    GenServer.call(__MODULE__, {:dispatch_tool, tool_name, args})
  end

  @doc """
  Dispatches multiple tool calls in parallel for non-destructive tools (:destruction_level == :none).
  Accepts a list of tool calls: `[{"tool1", %{...}}, {"tool2", %{...}}]` or `[%{name: "tool1", args: %{...}}]`.
  """
  def dispatch_tools(tool_requests, opts \\ []) when is_list(tool_requests) do
    GenServer.call(__MODULE__, {:dispatch_tools, tool_requests, opts})
  end

  @doc "Lists currently running tools executing in parallel."
  def list_running_tools do
    GenServer.call(__MODULE__, :list_running_tools)
  end

  @doc "Returns dependency mapping for all registered plugins."
  def list_plugin_dependencies do
    GenServer.call(__MODULE__, :list_dependencies)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    configured_plugins = Application.get_env(:ragex, :plugins, [])
    initial_plugins = Enum.uniq(@default_plugins ++ configured_plugins)

    state = %{
      plugins: %{},
      tool_map: %{},
      running_tools: %{}
    }

    state =
      Enum.reduce(initial_plugins, state, fn mod, acc ->
        case do_register_plugin(mod, opts, acc) do
          {:ok, new_acc} -> new_acc
          {:error, _reason} -> acc
        end
      end)

    {:ok, state}
  end

  @impl true
  def handle_call({:register, plugin_module, opts}, _from, state) do
    case do_register_plugin(plugin_module, opts, state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:unregister, plugin_id}, _from, state) do
    case Map.fetch(state.plugins, plugin_id) do
      {:ok, %{tools: tools}} ->
        tool_names = Enum.map(tools, & &1.name)
        new_plugins = Map.delete(state.plugins, plugin_id)
        new_tool_map = Map.drop(state.tool_map, tool_names)
        {:reply, :ok, %{state | plugins: new_plugins, tool_map: new_tool_map}}

      :error ->
        {:reply, {:error, :plugin_not_found}, state}
    end
  end

  @impl true
  def handle_call({:enable, plugin_id}, _from, state) do
    case Map.fetch(state.plugins, plugin_id) do
      {:ok, plugin_entry} ->
        updated_entry = %{plugin_entry | enabled: true}
        new_plugins = Map.put(state.plugins, plugin_id, updated_entry)
        new_tool_map = rebuild_tool_map(new_plugins)
        {:reply, :ok, %{state | plugins: new_plugins, tool_map: new_tool_map}}

      :error ->
        {:reply, {:error, :plugin_not_found}, state}
    end
  end

  @impl true
  def handle_call({:disable, plugin_id}, _from, state) do
    case Map.fetch(state.plugins, plugin_id) do
      {:ok, plugin_entry} ->
        updated_entry = %{plugin_entry | enabled: false}
        new_plugins = Map.put(state.plugins, plugin_id, updated_entry)
        new_tool_map = rebuild_tool_map(new_plugins)
        {:reply, :ok, %{state | plugins: new_plugins, tool_map: new_tool_map}}

      :error ->
        {:reply, {:error, :plugin_not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_plugins, _from, state) do
    ordered_entries = get_topological_sorted_plugins(state.plugins)

    list =
      Enum.map(ordered_entries, fn entry ->
        Map.take(entry, [:id, :name, :version, :description, :category, :dependencies, :priority, :capabilities, :module, :enabled, :tools_count])
      end)

    {:reply, list, state}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    tools =
      state.plugins
      |> get_topological_sorted_plugins()
      |> Enum.filter(& &1.enabled)
      |> Enum.flat_map(& &1.tools)

    {:reply, tools, state}
  end

  @impl true
  def handle_call(:list_dependencies, _from, state) do
    deps_map =
      state.plugins
      |> Enum.map(fn {id, entry} -> {id, entry.dependencies} end)
      |> Enum.into(%{})

    {:reply, deps_map, state}
  end

  @impl true
  def handle_call(:list_running_tools, _from, state) do
    list = Map.values(state.running_tools)
    {:reply, list, state}
  end

  @impl true
  def handle_call({:dispatch_tool, tool_name, args}, _from, state) do
    case Map.fetch(state.tool_map, tool_name) do
      {:ok, %{module: mod, enabled: true, destruction_level: destruction_level}} ->
        result = execute_single_tool(mod, tool_name, args, destruction_level)
        {:reply, result, state}

      {:ok, %{enabled: false}} ->
        {:reply, {:error, "Plugin for tool '#{tool_name}' is currently disabled"}, state}

      :error ->
        {:reply, {:error, :unhandled_by_plugins}, state}
    end
  end

  @impl true
  def handle_call({:dispatch_tools, tool_requests, opts}, _from, state) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    # Normalize requests into [{tool_name, args}]
    normalized_requests =
      Enum.map(tool_requests, fn
        {name, args} when is_binary(name) and is_map(args) -> {name, args}
        %{"name" => name, "args" => args} -> {name, args}
        %{name: name, args: args} -> {name, args}
      end)

    results =
      normalized_requests
      |> Enum.map(fn {tool_name, args} ->
        case Map.fetch(state.tool_map, tool_name) do
          {:ok, %{module: mod, enabled: true, destruction_level: level}} ->
            {:valid, mod, tool_name, args, level}

          {:ok, %{enabled: false}} ->
            {:error, tool_name, "Plugin for tool '#{tool_name}' is currently disabled"}

          :error ->
            {:error, tool_name, :unhandled_by_plugins}
        end
      end)

    # Partition non-destructive tools (:none) for parallel execution
    {valid_tools, errors} =
      Enum.reduce(results, {[], []}, fn
        {:valid, mod, name, args, level}, {v, e} -> {[{mod, name, args, level} | v], e}
        {:error, name, reason}, {v, e} -> {v, [{name, {:error, reason}} | e]}
      end)

    valid_tools = Enum.reverse(valid_tools)

    # Execute non-destructive tools in parallel using Task.async
    parallel_results =
      if Process.whereis(Ragex.Plugin.TaskSupervisor) do
        valid_tools
        |> Enum.map(fn {mod, name, args, level} ->
          Task.Supervisor.async_nolink(Ragex.Plugin.TaskSupervisor, fn ->
            {name, execute_single_tool(mod, name, args, level)}
          end)
        end)
        |> Task.yield_many(timeout)
        |> Enum.map(fn {task, res} ->
          case res do
            {:ok, {name, tool_res}} -> {name, tool_res}
            {:exit, reason} -> Task.shutdown(task, :bruteforce); {"unknown", {:error, {:task_exit, reason}}}
            nil -> Task.shutdown(task, :bruteforce); {"unknown", {:error, :timeout}}
          end
        end)
      else
        # Fallback sequential execution
        Enum.map(valid_tools, fn {mod, name, args, level} ->
          {name, execute_single_tool(mod, name, args, level)}
        end)
      end

    combined_results = parallel_results ++ errors
    {:reply, {:ok, combined_results}, state}
  end

  defp execute_single_tool(mod, tool_name, args, destruction_level) do
    try do
      Logger.debug("Executing plugin tool '#{tool_name}' (destruction_level: #{destruction_level}) via #{inspect(mod)}")
      mod.execute(tool_name, args)
    catch
      kind, reason ->
        Logger.error("Plugin execution error in #{inspect(mod)} for #{tool_name}: #{inspect({kind, reason})}")
        {:error, "Plugin execution failure: #{inspect(reason)}"}
    end
  end

  defp do_register_plugin(plugin_module, opts, state) do
    if Code.ensure_loaded?(plugin_module) and function_exported?(plugin_module, :info, 0) and function_exported?(plugin_module, :tools, 0) do
      info = plugin_module.info()
      raw_tools = plugin_module.tools()
      plugin_id = Map.get(info, :id) || plugin_module

      if function_exported?(plugin_module, :init, 1) do
        plugin_module.init(opts)
      end

      # Enrich tools with destruction_level (defaults to :none)
      tools =
        Enum.map(raw_tools, fn tool ->
          Map.put_new(tool, :destruction_level, :none)
        end)

      entry = %{
        id: plugin_id,
        name: Map.get(info, :name, to_string(plugin_id)),
        version: Map.get(info, :version, "1.0.0"),
        description: Map.get(info, :description, ""),
        category: Map.get(info, :category, :tool),
        dependencies: Map.get(info, :dependencies, []),
        priority: Map.get(info, :priority, 50),
        capabilities: Map.get(info, :capabilities, []),
        module: plugin_module,
        enabled: true,
        tools: tools,
        tools_count: length(tools)
      }

      new_plugins = Map.put(state.plugins, plugin_id, entry)
      new_tool_map = rebuild_tool_map(new_plugins)

      Logger.info("Registered Ragex plugin: #{entry.name} (#{inspect(plugin_id)}) with #{entry.tools_count} tools")
      {:ok, %{state | plugins: new_plugins, tool_map: new_tool_map}}
    else
      {:error, :invalid_plugin_module}
    end
  end

  defp rebuild_tool_map(plugins) do
    plugins
    |> get_topological_sorted_plugins()
    |> Enum.flat_map(fn entry ->
      Enum.map(entry.tools, fn tool ->
        destruction_level = Map.get(tool, :destruction_level, :none)
        {tool.name, %{module: entry.module, plugin_id: entry.id, enabled: entry.enabled, destruction_level: destruction_level}}
      end)
    end)
    |> Enum.into(%{})
  end

  defp get_topological_sorted_plugins(plugins_map) when is_map(plugins_map) do
    graph = :digraph.new()

    try do
      Enum.each(plugins_map, fn {id, _entry} ->
        :digraph.add_vertex(graph, id)
      end)

      Enum.each(plugins_map, fn {id, entry} ->
        Enum.each(entry.dependencies, fn dep_id ->
          if Map.has_key?(plugins_map, dep_id) do
            :digraph.add_vertex(graph, dep_id)
            :digraph.add_edge(graph, dep_id, id)
          else
            Logger.warning("Plugin #{inspect(id)} has missing dependency: #{inspect(dep_id)}")
          end
        end)
      end)

      case :digraph_utils.topsort(graph) do
        sorted_ids when is_list(sorted_ids) ->
          sorted_ids
          |> Enum.filter(&Map.has_key?(plugins_map, &1))
          |> Enum.map(&Map.fetch!(plugins_map, &1))

        false ->
          Logger.warning("Cyclic plugin dependency detected! Falling back to priority sorting.")
          sort_by_priority(plugins_map)
      end
    after
      :digraph.delete(graph)
    end
  end

  defp sort_by_priority(plugins_map) do
    plugins_map
    |> Map.values()
    |> Enum.sort_by(& &1.priority)
  end
end
