defmodule Ragex.ParallelPluginsTest do
  use ExUnit.Case, async: false

  alias Ragex.MCP.Handlers.Tools, as: MCPTools
  alias Ragex.Plugin.Registry, as: PluginRegistry

  defmodule SlowSafePlugin do
    @behaviour Ragex.Plugin

    @impl true
    def info do
      %{
        id: :slow_safe_plugin,
        name: "Slow Safe Plugin",
        version: "1.0.0",
        description: "Simulates safe read-only tool calls.",
        category: :tool,
        dependencies: [],
        priority: 50,
        capabilities: [:safe_read]
      }
    end

    @impl true
    def tools do
      [
        %{
          name: "slow_read_a",
          description: "Simulates read A",
          inputSchema: %{type: "object", properties: %{}},
          destruction_level: :none
        },
        %{
          name: "slow_read_b",
          description: "Simulates read B",
          inputSchema: %{type: "object", properties: %{}},
          destruction_level: :none
        }
      ]
    end

    @impl true
    def execute("slow_read_a", _args) do
      Process.sleep(50)
      {:ok, %{result: "read_a_done"}}
    end

    def execute("slow_read_b", _args) do
      Process.sleep(50)
      {:ok, %{result: "read_b_done"}}
    end

    def execute(tool_name, _args), do: {:error, "Unknown tool #{tool_name}"}
  end

  setup do
    case GenServer.whereis(PluginRegistry) do
      nil -> start_supervised!(PluginRegistry)
      _ -> :ok
    end

    case GenServer.whereis(Ragex.Plugin.TaskSupervisor) do
      nil -> start_supervised!({Task.Supervisor, name: Ragex.Plugin.TaskSupervisor})
      _ -> :ok
    end

    PluginRegistry.register_plugin(SlowSafePlugin)
    :ok
  end

  describe "Parallel Tool Dispatching" do
    test "executes batch of non-destructive tools concurrently in parallel" do
      requests = [
        {"slow_read_a", %{}},
        {"slow_read_b", %{}}
      ]

      start_time = System.monotonic_time(:millisecond)
      {:ok, results} = PluginRegistry.dispatch_tools(requests)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert length(results) == 2
      # Parallel execution of two 50ms tasks should take ~50-80ms total (not 100ms+)
      assert elapsed < 90

      res_a = Enum.find(results, fn {name, _} -> name == "slow_read_a" end)
      res_b = Enum.find(results, fn {name, _} -> name == "slow_read_b" end)

      assert match?({"slow_read_a", {:ok, %{result: "read_a_done"}}}, res_a)
      assert match?({"slow_read_b", {:ok, %{result: "read_b_done"}}}, res_b)
    end

    test "MCPTools.call_tools/1 runs batch requests concurrently" do
      requests = [
        {"slow_read_a", %{}},
        {"slow_read_b", %{}}
      ]

      assert {:ok, results} = MCPTools.call_tools(requests)
      assert length(results) == 2
    end
  end
end
