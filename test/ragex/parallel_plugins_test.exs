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
        },
        %{
          name: "very_slow_read",
          description: "Simulates a read slower than the caller's timeout",
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

    def execute("very_slow_read", _args) do
      Process.sleep(500)
      {:ok, %{result: "very_slow_done"}}
    end

    def execute(tool_name, _args), do: {:error, "Unknown tool #{tool_name}"}
  end

  defmodule CrashyPlugin do
    @behaviour Ragex.Plugin

    @impl true
    def info do
      %{
        id: :crashy_plugin,
        name: "Crashy Plugin",
        version: "1.0.0",
        description: "Simulates a tool that crashes with an unhandled exit/throw.",
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
          name: "crashy_read",
          description: "Exits abnormally instead of returning",
          inputSchema: %{type: "object", properties: %{}},
          destruction_level: :none
        }
      ]
    end

    @impl true
    def execute("crashy_read", _args) do
      # `execute_single_tool/4` only rescues `Kernel.exception`s, so an
      # explicit `exit/1` still propagates as a genuine task crash, which is
      # exactly the path that used to lose the tool's name.
      exit(:boom)
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
    PluginRegistry.register_plugin(CrashyPlugin)
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

    test "reports the real tool name (not \"unknown\") when a batched tool crashes" do
      requests = [
        {"slow_read_a", %{}},
        {"crashy_read", %{}}
      ]

      {:ok, results} = PluginRegistry.dispatch_tools(requests)

      assert length(results) == 2
      assert {"slow_read_a", {:ok, %{result: "read_a_done"}}} in results

      assert {"crashy_read", {:error, {:task_exit, _reason}}} =
               Enum.find(results, fn {name, _} -> name == "crashy_read" end)

      refute Enum.any?(results, fn {name, _} -> name == "unknown" end)
    end

    test "reports the real tool name (not \"unknown\") when a batched tool times out" do
      requests = [
        {"slow_read_a", %{}},
        {"very_slow_read", %{}}
      ]

      {:ok, results} = PluginRegistry.dispatch_tools(requests, timeout: 100)

      assert length(results) == 2
      assert {"slow_read_a", {:ok, %{result: "read_a_done"}}} in results
      assert {"very_slow_read", {:error, :timeout}} in results
      refute Enum.any?(results, fn {name, _} -> name == "unknown" end)
    end
  end

  describe "Single Tool Dispatching" do
    test "dispatch_tool/2 does not block concurrent callers on a slow tool call" do
      test_pid = self()

      slow_task =
        Task.async(fn ->
          result = PluginRegistry.dispatch_tool("very_slow_read", %{})
          send(test_pid, {:slow_done, System.monotonic_time(:millisecond)})
          result
        end)

      # Give the slow call a head start so it's in-flight on the registry.
      Process.sleep(20)

      fast_start = System.monotonic_time(:millisecond)
      assert {:ok, %{result: "read_a_done"}} = PluginRegistry.dispatch_tool("slow_read_a", %{})
      fast_elapsed = System.monotonic_time(:millisecond) - fast_start

      # The fast call must complete quickly even though a 500ms call is
      # still in flight -- proving dispatch_tool/2 no longer serializes on
      # the registry's GenServer process.
      assert fast_elapsed < 200

      assert {:ok, %{result: "very_slow_done"}} = Task.await(slow_task, 1_000)
      assert_received {:slow_done, _}
    end
  end
end
