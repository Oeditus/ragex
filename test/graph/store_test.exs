defmodule Ragex.Graph.StoreTest do
  use ExUnit.Case

  alias Ragex.Graph.Store

  setup do
    # Clear the graph before each test
    Store.clear()
    :ok
  end

  describe "add_node/3 and find_node/2" do
    test "adds and retrieves a module node" do
      module_data = %{name: TestModule, file: "test.ex", line: 1}
      assert :ok = Store.add_node(:module, TestModule, module_data)

      retrieved = Store.find_node(:module, TestModule)
      assert retrieved == module_data
    end

    test "adds and retrieves a function node" do
      func_data = %{name: :test, arity: 2, module: TestModule}
      func_id = {TestModule, :test, 2}
      assert :ok = Store.add_node(:function, func_id, func_data)

      retrieved = Store.find_node(:function, func_id)
      assert retrieved == func_data
    end

    test "returns nil for non-existent node" do
      assert Store.find_node(:module, NonExistent) == nil
    end
  end

  describe "list_nodes/2" do
    test "lists all nodes" do
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:module, ModuleB, %{name: ModuleB})
      Store.add_node(:function, {:test, 0}, %{name: :test})

      nodes = Store.list_nodes()
      assert length(nodes) == 3
    end

    test "filters nodes by type" do
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:module, ModuleB, %{name: ModuleB})
      Store.add_node(:function, {:test, 0}, %{name: :test})

      modules = Store.list_nodes(:module)
      assert length(modules) == 2
      assert Enum.all?(modules, &(&1.type == :module))
    end

    test "respects limit parameter" do
      for i <- 1..10 do
        Store.add_node(:module, :"Module#{i}", %{name: :"Module#{i}"})
      end

      nodes = Store.list_nodes(nil, 5)
      assert length(nodes) == 5
    end
  end

  describe "add_edge/3 and get_outgoing_edges/2" do
    test "adds and retrieves edges" do
      from = {:module, TestModule}
      to = {:function, TestModule, :test, 0}

      assert :ok = Store.add_edge(from, to, :defines)

      edges = Store.get_outgoing_edges(from, :defines)
      assert length(edges) == 1
      assert [%{to: ^to, type: :defines}] = edges
    end

    test "returns empty list for node with no edges" do
      from = {:module, TestModule}
      assert Store.get_outgoing_edges(from, :defines) == []
    end
  end

  describe "get_incoming_edges/2" do
    test "retrieves incoming edges" do
      from = {:module, TestModule}
      to = {:function, TestModule, :test, 0}

      Store.add_edge(from, to, :defines)

      edges = Store.get_incoming_edges(to, :defines)
      assert length(edges) == 1
      assert [%{from: ^from, type: :defines}] = edges
    end
  end

  describe "clear/0" do
    test "removes all nodes and edges" do
      Store.add_node(:module, TestModule, %{name: TestModule})
      Store.add_edge({:module, TestModule}, {:module, OtherModule}, :imports)

      assert Store.stats().nodes > 0

      Store.clear()

      assert Store.stats().nodes == 0
      assert Store.stats().edges == 0
    end
  end

  describe "stats/0" do
    test "returns accurate statistics" do
      initial_stats = Store.stats()
      assert initial_stats.nodes == 0
      assert initial_stats.edges == 0

      Store.add_node(:module, TestModule, %{})
      Store.add_node(:function, {:test, 0}, %{})
      Store.add_edge({:module, TestModule}, {:function, {:test, 0}}, :defines)

      stats = Store.stats()
      assert stats.nodes == 2
      assert stats.edges == 1
    end
  end
end
