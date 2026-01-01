defmodule Ragex.MCP.Handlers.ToolsTest do
  use ExUnit.Case

  alias Ragex.Graph.Store
  alias Ragex.MCP.Handlers.Tools

  setup do
    # Clear the graph before each test
    Store.clear()
    :ok
  end

  describe "list_nodes tool" do
    test "returns the correct total_count when a node_type is provided" do
      # Add various nodes
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:module, ModuleB, %{name: ModuleB})
      Store.add_node(:module, ModuleC, %{name: ModuleC})
      Store.add_node(:function, {ModuleA, :func1, 0}, %{name: :func1})
      Store.add_node(:function, {ModuleA, :func2, 1}, %{name: :func2})

      # Query for modules
      params = %{"node_type" => "module", "limit" => 100}
      {:ok, result} = Tools.call_tool("list_nodes", params)

      assert result.total_count == 3
      assert result.count == 3
    end

    test "returns the correct total_count when no node_type is provided" do
      # Add various nodes
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:module, ModuleB, %{name: ModuleB})
      Store.add_node(:function, {ModuleA, :func1, 0}, %{name: :func1})
      Store.add_node(:function, {ModuleA, :func2, 1}, %{name: :func2})
      Store.add_node(:function, {ModuleB, :func3, 0}, %{name: :func3})

      # Query all nodes
      params = %{"limit" => 100}
      {:ok, result} = Tools.call_tool("list_nodes", params)

      assert result.total_count == 5
      assert result.count == 5
    end

    test "returns a map containing nodes, count, and total_count" do
      # Add some nodes
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:function, {ModuleA, :func1, 0}, %{name: :func1})

      params = %{"limit" => 100}
      {:ok, result} = Tools.call_tool("list_nodes", params)

      # Verify map structure
      assert is_map(result)
      assert Map.has_key?(result, :nodes)
      assert Map.has_key?(result, :count)
      assert Map.has_key?(result, :total_count)

      # Verify types
      assert is_list(result.nodes)
      assert is_integer(result.count)
      assert is_integer(result.total_count)
    end

    test "returns correct counts when limit is less than total" do
      # Add more nodes than the limit
      for i <- 1..10 do
        Store.add_node(:module, :"Module#{i}", %{name: :"Module#{i}"})
      end

      params = %{"node_type" => "module", "limit" => 5}
      {:ok, result} = Tools.call_tool("list_nodes", params)

      # count should be the actual returned nodes (limited)
      assert result.count == 5
      # total_count should be all matching nodes
      assert result.total_count == 10
    end

    test "handles empty graph correctly" do
      params = %{"limit" => 100}
      {:ok, result} = Tools.call_tool("list_nodes", params)

      assert result.nodes == []
      assert result.count == 0
      assert result.total_count == 0
    end

    test "filters by specific node type correctly" do
      # Add multiple types
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:module, ModuleB, %{name: ModuleB})
      Store.add_node(:function, {ModuleA, :func1, 0}, %{name: :func1})
      Store.add_node(:function, {ModuleA, :func2, 1}, %{name: :func2})
      Store.add_node(:function, {ModuleA, :func3, 2}, %{name: :func3})

      # Query only functions
      params = %{"node_type" => "function", "limit" => 100}
      {:ok, result} = Tools.call_tool("list_nodes", params)

      assert result.count == 3
      assert result.total_count == 3
      # Note: Store.list_nodes returns type as atom, not string
      assert Enum.all?(result.nodes, fn node -> node.type == :function end)
    end
  end
end
