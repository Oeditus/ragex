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
        description: "A dummy plugin for unit testing."
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

  setup do
    case GenServer.whereis(PluginRegistry) do
      nil ->
        start_supervised!(PluginRegistry)
        :ok

      _pid ->
        # Re-register default plugins if needed
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

    test "supports hot enabling and disabling of plugins" do
      PluginRegistry.register_plugin(DummyTestPlugin)

      assert :ok == PluginRegistry.disable_plugin(:dummy_test_plugin)
      assert {:error, "Plugin for tool 'dummy_ping' is currently disabled"} = PluginRegistry.dispatch_tool("dummy_ping", %{})

      assert :ok == PluginRegistry.enable_plugin(:dummy_test_plugin)
      assert {:ok, %{"pong" => true}} = PluginRegistry.dispatch_tool("dummy_ping", %{})
    end

    test "returns :unhandled_by_plugins for unregistered tools" do
      assert {:error, :unhandled_by_plugins} == PluginRegistry.dispatch_tool("nonexistent_tool_12345", %{})
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
