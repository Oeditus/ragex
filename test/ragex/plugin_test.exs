defmodule Ragex.PluginTest do
  use ExUnit.Case, async: false

  alias Ragex.MCP.Handlers.Tools, as: MCPTools
  alias Ragex.Plugin.Registry, as: PluginRegistry
  alias Ragex.Plugins.URLAnalyzer, as: URLAnalyzerPlugin

  defmodule DummyTestPlugin do
    @behaviour Ragex.Plugin

    @impl true
    def info do
      %{
        id: :dummy_test_plugin,
        name: "Dummy Test Plugin",
        version: "1.0.0",
        description: "A dummy plugin for unit testing.",
        category: :tool,
        dependencies: [],
        priority: 50,
        capabilities: [:dummy]
      }
    end

    @impl true
    def tools do
      [
        %{
          name: "dummy_ping",
          description: "Returns pong.",
          inputSchema: %{type: "object", properties: %{}}
        }
      ]
    end

    @impl true
    def execute("dummy_ping", _args) do
      {:ok, %{"pong" => true}}
    end

    def execute(tool_name, _args) do
      {:error, "Unknown tool #{tool_name}"}
    end
  end

  defmodule DepBasePlugin do
    @behaviour Ragex.Plugin
    @impl true
    def info do
      %{
        id: :dep_base,
        name: "Dependency Base Plugin",
        version: "1.0.0",
        description: "Base plugin",
        category: :analyzer,
        dependencies: [],
        priority: 100,
        capabilities: [:base]
      }
    end

    @impl true
    def tools, do: []
    @impl true
    def execute(_, _), do: {:error, :not_implemented}
  end

  defmodule DepChildPlugin do
    @behaviour Ragex.Plugin
    @impl true
    def info do
      %{
        id: :dep_child,
        name: "Dependency Child Plugin",
        version: "1.0.0",
        description: "Child plugin depending on base",
        category: :security,
        dependencies: [:dep_base],
        priority: 10,
        capabilities: [:child]
      }
    end

    @impl true
    def tools, do: []
    @impl true
    def execute(_, _), do: {:error, :not_implemented}
  end

  setup do
    case GenServer.whereis(PluginRegistry) do
      nil ->
        start_supervised!(PluginRegistry)
        :ok

      _pid ->
        PluginRegistry.register_plugin(URLAnalyzerPlugin)
        :ok
    end
  end

  describe "Plugin Registry" do
    test "lists default loaded plugins" do
      plugins = PluginRegistry.list_plugins()
      assert Enum.any?(plugins, &(&1.id == :url_analyzer))
    end

    test "registers and executes custom plugins dynamically" do
      assert :ok == PluginRegistry.register_plugin(DummyTestPlugin)

      plugins = PluginRegistry.list_plugins()
      assert Enum.any?(plugins, &(&1.id == :dummy_test_plugin))

      tools = PluginRegistry.list_tools()
      assert Enum.any?(tools, &(&1.name == "dummy_ping"))

      assert {:ok, %{"pong" => true}} = PluginRegistry.dispatch_tool("dummy_ping", %{})
    end

    test "orders plugins topologically based on dependencies" do
      PluginRegistry.register_plugin(DepChildPlugin)
      PluginRegistry.register_plugin(DepBasePlugin)

      plugins = PluginRegistry.list_plugins()
      ids = Enum.map(plugins, & &1.id)

      base_index = Enum.find_index(ids, &(&1 == :dep_base))
      child_index = Enum.find_index(ids, &(&1 == :dep_child))

      assert base_index < child_index
    end

    test "lists plugin dependencies map" do
      PluginRegistry.register_plugin(DepChildPlugin)
      deps = PluginRegistry.list_plugin_dependencies()
      assert deps[:dep_child] == [:dep_base]
    end

    test "supports hot enabling and disabling of plugins" do
      PluginRegistry.register_plugin(DummyTestPlugin)

      assert :ok == PluginRegistry.disable_plugin(:dummy_test_plugin)

      assert {:error, "Plugin for tool 'dummy_ping' is currently disabled"} =
               PluginRegistry.dispatch_tool("dummy_ping", %{})

      assert :ok == PluginRegistry.enable_plugin(:dummy_test_plugin)
      assert {:ok, %{"pong" => true}} = PluginRegistry.dispatch_tool("dummy_ping", %{})
    end

    test "returns :unhandled_by_plugins for unregistered tools" do
      assert {:error, :unhandled_by_plugins} ==
               PluginRegistry.dispatch_tool("nonexistent_tool_12345", %{})
    end
  end

  describe "MCP Integration via Plugins" do
    test "MCP list_tools includes plugin tools" do
      %{tools: tools} = MCPTools.list_tools()
      assert Enum.any?(tools, &(&1.name == "analyze_url"))
    end

    test "MCP call_tool routes analyze_url to URLAnalyzerPlugin" do
      assert {:error, _reason} = MCPTools.call_tool("analyze_url", %{"url" => "invalid_url"})
    end
  end
end
