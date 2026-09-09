defmodule Ragex.Plugin.EventBus do
  @moduledoc """
  Inter-plugin event broadcasting system for Ragex.

  Allows plugins and core modules to publish lifecycle events (e.g. `:file_indexed`,
  `:code_edited`, `:security_alert`, `:graph_mutated`, `:url_analyzed`), which are
  automatically dispatched to registered plugins implementing the optional `handle_event/2` callback.
  """

  use GenServer
  require Logger

  alias Ragex.Plugin.Registry, as: PluginRegistry

  # Client API

  @doc "Starts the EventBus GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Broadcasts an event asynchronously to all active plugins implementing `handle_event/2`.
  """
  @spec broadcast(atom(), map()) :: :ok
  def broadcast(event_name, payload \\ %{}) when is_atom(event_name) and is_map(payload) do
    GenServer.cast(__MODULE__, {:broadcast, event_name, payload})
  end

  @doc """
  Broadcasts an event synchronously to active plugins.
  """
  @spec sync_broadcast(atom(), map()) :: {:ok, list()}
  def sync_broadcast(event_name, payload \\ %{}) when is_atom(event_name) and is_map(payload) do
    GenServer.call(__MODULE__, {:sync_broadcast, event_name, payload})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:broadcast, event_name, payload}, state) do
    do_broadcast_event(event_name, payload)
    {:noreply, state}
  end

  @impl true
  def handle_call({:sync_broadcast, event_name, payload}, _from, state) do
    results = do_broadcast_event(event_name, payload)
    {:reply, {:ok, results}, state}
  end

  defp do_broadcast_event(event_name, payload) do
    plugins =
      try do
        if Process.whereis(PluginRegistry) do
          PluginRegistry.list_plugins()
        else
          []
        end
      catch
        _, _ -> []
      end

    plugins
    |> Enum.filter(& &1.enabled)
    |> Enum.map(& &1.module)
    |> Enum.filter(&function_exported?(&1, :handle_event, 2))
    |> Enum.map(fn mod ->
      try do
        res = mod.handle_event(event_name, payload)
        {mod, {:ok, res}}
      catch
        kind, reason ->
          Logger.error(
            "Event handle failure in #{inspect(mod)} for #{event_name}: #{inspect({kind, reason})}"
          )

          {mod, {:error, reason}}
      end
    end)
  end
end
