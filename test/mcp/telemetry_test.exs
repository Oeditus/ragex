defmodule Ragex.MCP.TelemetryTest do
  use ExUnit.Case, async: false

  alias Ragex.MCP.Telemetry

  setup do
    Telemetry.reset()
    :ok
  end

  describe "record_success/2" do
    test "records a successful invocation" do
      Telemetry.record_success("semantic_search", 5000)

      stat = Telemetry.get_tool_stats("semantic_search")
      assert stat.count == 1
      assert stat.total_time_us == 5000
      assert stat.error_count == 0
      assert stat.last_invoked != nil
    end

    test "accumulates across multiple calls" do
      Telemetry.record_success("query_graph", 1000)
      Telemetry.record_success("query_graph", 2000)
      Telemetry.record_success("query_graph", 3000)

      stat = Telemetry.get_tool_stats("query_graph")
      assert stat.count == 3
      assert stat.total_time_us == 6000
      assert stat.avg_time_us == 2000
    end
  end

  describe "record_error/2" do
    test "records an error invocation" do
      Telemetry.record_error("bad_tool", 100)

      stat = Telemetry.get_tool_stats("bad_tool")
      assert stat.count == 1
      assert stat.error_count == 1
    end

    test "mixed success and error" do
      Telemetry.record_success("mixed", 1000)
      Telemetry.record_success("mixed", 2000)
      Telemetry.record_error("mixed", 500)

      stat = Telemetry.get_tool_stats("mixed")
      assert stat.count == 3
      assert stat.error_count == 1
      assert stat.total_time_us == 3500
    end
  end

  describe "execute/2" do
    test "wraps a function and records timing" do
      result =
        Telemetry.execute("test_tool", fn ->
          Process.sleep(1)
          {:ok, 42}
        end)

      assert result == {:ok, 42}

      stat = Telemetry.get_tool_stats("test_tool")
      assert stat.count == 1
      assert stat.total_time_us >= 0
      assert stat.error_count == 0
    end

    test "records error on exception" do
      assert_raise RuntimeError, fn ->
        Telemetry.execute("crash_tool", fn -> raise "boom" end)
      end

      stat = Telemetry.get_tool_stats("crash_tool")
      assert stat.count == 1
      assert stat.error_count == 1
    end
  end

  describe "get_stats/1" do
    test "returns all tools sorted by count" do
      Telemetry.record_success("a", 100)
      Telemetry.record_success("b", 100)
      Telemetry.record_success("b", 100)
      Telemetry.record_success("c", 100)
      Telemetry.record_success("c", 100)
      Telemetry.record_success("c", 100)

      stats = Telemetry.get_stats(sort_by: :count)
      names = Enum.map(stats, & &1.tool)
      assert hd(names) == "c"
    end

    test "returns empty list when no data" do
      assert Telemetry.get_stats() == []
    end
  end

  describe "get_tool_stats/1" do
    test "returns nil for unknown tool" do
      assert Telemetry.get_tool_stats("nonexistent") == nil
    end
  end

  describe "total_invocations/0" do
    test "counts across all tools" do
      Telemetry.record_success("a", 100)
      Telemetry.record_success("b", 100)
      Telemetry.record_success("c", 100)

      assert Telemetry.total_invocations() == 3
    end
  end

  describe "reset/0" do
    test "clears all data" do
      Telemetry.record_success("tool", 100)
      assert Telemetry.total_invocations() == 1

      Telemetry.reset()
      assert Telemetry.total_invocations() == 0
      assert Telemetry.get_stats() == []
    end
  end
end
