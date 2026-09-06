defmodule Ragex.EventBusTest do
  use ExUnit.Case, async: false

  alias Ragex.Plugin.EventBus
  alias Ragex.Plugin.Registry, as: PluginRegistry

  defmodule EventSubscriberPlugin do
    @behaviour Ragex.Plugin

    @impl true
    def info do
      %{
        id: :event_subscriber_plugin,
        name: "Event Subscriber Plugin",
        version: "1.0.0",
        description: "Listens for system events.",
        category: :tool,
        dependencies: [],
        priority: 50,
        capabilities: [:event_listener]
      }
    end

    @impl true
    def tools, do: []

    @impl true
    def execute(_, _), do: {:error, :not_implemented}

    @impl true
    def handle_event(:file_indexed, %{"path" => path}) do
      send(:event_bus_test_pid, {:received_event, :file_indexed, path})
      :ok
    end

    def handle_event(_event, _payload), do: :ok
  end

  setup do
    Process.register(self(), :event_bus_test_pid)

    case GenServer.whereis(PluginRegistry) do
      nil -> start_supervised!(PluginRegistry)
      _ -> :ok
    end

    case GenServer.whereis(EventBus) do
      nil -> start_supervised!(EventBus)
      _ -> :ok
    end

    PluginRegistry.register_plugin(EventSubscriberPlugin)
    :ok
  end

  describe "Plugin EventBus" do
    test "broadcasts events to plugins implementing handle_event/2" do
      {:ok, _results} = EventBus.sync_broadcast(:file_indexed, %{"path" => "lib/app.ex"})
      assert_receive {:received_event, :file_indexed, "lib/app.ex"}, 1000
    end
  end
end
