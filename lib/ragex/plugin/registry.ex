defmodule Ragex.Plugin.Registry do
  @moduledoc """
  Manages the lifecycle, discovery, tool aggregation, and execution routing for Ragex plugins.
  """

  use GenServer
  require Logger

  @default_plugins [
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

  @doc "Lists all registered plugins and their current status."
  def list_plugins do
    GenServer.call(__MODULE__, :list_plugins)
  end

  @doc "Returns aggregated tool schemas across all active plugins."
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc "Dispatches a tool call to the responsible plugin, if registered."
  def dispatch_tool(tool_name, args) when is_binary(tool_name) and is_map(args) do
    GenServer.call(__MODULE__, {:dispatch, tool_name, args})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    configured_plugins = Application.get_env(:ragex, :plugins, [])
    initial_plugins = Enum.uniq(@default_plugins ++ configured_plugins)

    state = %{
      plugins: %{},
      tool_map: %{}
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
    list =
      state.plugins
      |> Map.values()
      |> Enum.map(fn entry ->
        Map.take(entry, [:id, :name, :version, :description, :module, :enabled, :tools_count])
      end)

    {:reply, list, state}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    tools =
      state.plugins
      |> Map.values()
      |> Enum.filter(& &1.enabled)
      |> Enum.flat_map(& &1.tools)

    {:reply, tools, state}
  end

  @impl true
  def handle_call({:dispatch, tool_name, args}, _from, state) do
    case Map.fetch(state.tool_map, tool_name) do
      {:ok, %{module: mod, enabled: true}} ->
        try do
          result = mod.execute(tool_name, args)
          {:reply, result, state}
        catch
          kind, reason ->
            Logger.error("Plugin execution error in #{inspect(mod)} for #{tool_name}: #{inspect({kind, reason})}")
            {:reply, {:error, "Plugin execution failure: #{inspect(reason)}"}, state}
        end

      {:ok, %{enabled: false}} ->
        {:reply, {:error, "Plugin for tool '#{tool_name}' is currently disabled"}, state}

      :error ->
        {:reply, {:error, :unhandled_by_plugins}, state}
    end
  end

  defp do_register_plugin(plugin_module, opts, state) do
    if Code.ensure_loaded?(plugin_module) and function_exported?(plugin_module, :info, 0) and function_exported?(plugin_module, :tools, 0) do
      info = plugin_module.info()
      tools = plugin_module.tools()
      plugin_id = Map.get(info, :id) || plugin_module

      if function_exported?(plugin_module, :init, 1) do
        plugin_module.init(opts)
      end

      entry = %{
        id: plugin_id,
        name: Map.get(info, :name, to_string(plugin_id)),
        version: Map.get(info, :version, "1.0.0"),
        description: Map.get(info, :description, ""),
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
    |> Map.values()
    |> Enum.flat_map(fn entry ->
      Enum.map(entry.tools, fn tool ->
        {tool.name, %{module: entry.module, plugin_id: entry.id, enabled: entry.enabled}}
      end)
    end)
    |> Enum.into(%{})
  end
end
