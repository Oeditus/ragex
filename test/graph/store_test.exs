defmodule Ragex.Graph.StoreTest do
  use ExUnit.Case

  alias Ragex.Graph.Store

  setup do
    # Clear the graph before each test
    Store.clear()
    Store.sync()
    :ok
  end

  describe "add_node/3 and find_node/2" do
    test "adds and retrieves a module node" do
      module_data = %{name: TestModule, file: "test.ex", line: 1}
      assert :ok = Store.add_node(:module, TestModule, module_data)
      Store.sync()

      retrieved = Store.find_node(:module, TestModule)
      assert retrieved == module_data
    end

    test "adds and retrieves a function node" do
      func_data = %{name: :test, arity: 2, module: TestModule}
      func_id = {TestModule, :test, 2}
      assert :ok = Store.add_node(:function, func_id, func_data)
      Store.sync()

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
      Store.sync()

      nodes = Store.list_nodes()
      assert length(nodes) == 3
    end

    test "filters nodes by type" do
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:module, ModuleB, %{name: ModuleB})
      Store.add_node(:function, {:test, 0}, %{name: :test})
      Store.sync()

      modules = Store.list_nodes(:module)
      assert length(modules) == 2
      assert Enum.all?(modules, &(&1.type == :module))
    end

    test "respects limit parameter" do
      for i <- 1..10 do
        Store.add_node(:module, :"Module#{i}", %{name: :"Module#{i}"})
      end

      Store.sync()
      nodes = Store.list_nodes(nil, 5)
      assert length(nodes) == 5
    end
  end

  describe "get_module/1" do
    test "retrieves a module node by name" do
      module_data = %{name: TestModule, file: "lib/test_module.ex", line: 1}
      Store.add_node(:module, TestModule, module_data)
      Store.sync()

      retrieved = Store.get_module(TestModule)
      assert retrieved == module_data
    end

    test "returns nil for non-existent module" do
      assert Store.get_module(NonExistentModule) == nil
    end

    test "retrieves correct module among multiple modules" do
      module_a_data = %{name: ModuleA, file: "lib/module_a.ex"}
      module_b_data = %{name: ModuleB, file: "lib/module_b.ex"}
      module_c_data = %{name: ModuleC, file: "lib/module_c.ex"}

      Store.add_node(:module, ModuleA, module_a_data)
      Store.add_node(:module, ModuleB, module_b_data)
      Store.add_node(:module, ModuleC, module_c_data)
      Store.sync()

      assert Store.get_module(ModuleA) == module_a_data
      assert Store.get_module(ModuleB) == module_b_data
      assert Store.get_module(ModuleC) == module_c_data
    end
  end

  describe "get_function/3" do
    test "retrieves a function node by module, name, and arity" do
      func_data = %{name: :test, arity: 2, line: 10}
      Store.add_node(:function, {ModuleA, :test, 2}, func_data)
      Store.sync()

      retrieved = Store.get_function(ModuleA, :test, 2)
      assert retrieved == func_data
    end

    test "returns nil for non-existent function" do
      assert Store.get_function(ModuleA, :nonexistent, 1) == nil
    end

    test "distinguishes functions by arity" do
      func_0_data = %{name: :test, arity: 0}
      func_1_data = %{name: :test, arity: 1}
      func_2_data = %{name: :test, arity: 2}

      Store.add_node(:function, {ModuleA, :test, 0}, func_0_data)
      Store.add_node(:function, {ModuleA, :test, 1}, func_1_data)
      Store.add_node(:function, {ModuleA, :test, 2}, func_2_data)
      Store.sync()

      assert Store.get_function(ModuleA, :test, 0) == func_0_data
      assert Store.get_function(ModuleA, :test, 1) == func_1_data
      assert Store.get_function(ModuleA, :test, 2) == func_2_data
    end

    test "distinguishes functions by module" do
      func_a_data = %{name: :process, arity: 1, module: ModuleA}
      func_b_data = %{name: :process, arity: 1, module: ModuleB}

      Store.add_node(:function, {ModuleA, :process, 1}, func_a_data)
      Store.add_node(:function, {ModuleB, :process, 1}, func_b_data)
      Store.sync()

      assert Store.get_function(ModuleA, :process, 1) == func_a_data
      assert Store.get_function(ModuleB, :process, 1) == func_b_data
    end

    test "distinguishes functions by name" do
      func_test_data = %{name: :test, arity: 1}
      func_helper_data = %{name: :helper, arity: 1}

      Store.add_node(:function, {ModuleA, :test, 1}, func_test_data)
      Store.add_node(:function, {ModuleA, :helper, 1}, func_helper_data)
      Store.sync()

      assert Store.get_function(ModuleA, :test, 1) == func_test_data
      assert Store.get_function(ModuleA, :helper, 1) == func_helper_data
    end

    test "retrieves correct function among many" do
      for module <- [ModuleA, ModuleB, ModuleC] do
        for name <- [:foo, :bar, :baz] do
          for arity <- 0..2 do
            func_data = %{module: module, name: name, arity: arity}
            Store.add_node(:function, {module, name, arity}, func_data)
          end
        end
      end

      Store.sync()
      # Verify we can retrieve specific function
      result = Store.get_function(ModuleB, :bar, 1)
      assert result.module == ModuleB
      assert result.name == :bar
      assert result.arity == 1
    end
  end

  describe "list_modules/0" do
    test "lists all module nodes" do
      module_a_data = %{name: ModuleA, file: "lib/a.ex"}
      module_b_data = %{name: ModuleB, file: "lib/b.ex"}
      module_c_data = %{name: ModuleC, file: "lib/c.ex"}

      Store.add_node(:module, ModuleA, module_a_data)
      Store.add_node(:module, ModuleB, module_b_data)
      Store.add_node(:module, ModuleC, module_c_data)
      Store.sync()

      modules = Store.list_modules()
      assert length(modules) == 3
    end

    test "returns empty list when no modules exist" do
      modules = Store.list_modules()
      assert modules == []
    end

    test "returns modules with correct structure" do
      module_data = %{name: TestModule, file: "lib/test.ex", line: 1}
      Store.add_node(:module, TestModule, module_data)
      Store.sync()

      [module] = Store.list_modules()
      assert module.id == TestModule
      assert module.data == module_data
    end

    test "lists modules ignoring non-module nodes" do
      module_a_data = %{name: ModuleA, file: "lib/a.ex"}
      module_b_data = %{name: ModuleB, file: "lib/b.ex"}
      func_data = %{name: :test, arity: 1}

      Store.add_node(:module, ModuleA, module_a_data)
      Store.add_node(:module, ModuleB, module_b_data)
      Store.add_node(:function, {ModuleA, :test, 1}, func_data)
      Store.sync()

      modules = Store.list_modules()
      assert length(modules) == 2
      assert Enum.all?(modules, fn m -> m.id in [ModuleA, ModuleB] end)
    end

    test "returns all modules regardless of limit on list_nodes" do
      for i <- 1..10 do
        Store.add_node(:module, :"Module#{i}", %{name: :"Module#{i}"})
      end

      Store.sync()
      modules = Store.list_modules()
      assert length(modules) == 10
    end

    test "returns modules with full data" do
      module_data = %{
        name: MyModule,
        file: "lib/my_module.ex",
        line: 5,
        doc: "This is a module",
        exports: [{:func1, 2}, {:func2, 1}]
      }

      Store.add_node(:module, MyModule, module_data)
      Store.sync()

      [module] = Store.list_modules()
      assert module.id == MyModule
      assert module.data == module_data
      assert module.data.exports == [{:func1, 2}, {:func2, 1}]
    end
  end

  describe "list_functions/1" do
    test "lists all functions without filter" do
      func1_data = %{name: :test, arity: 2}
      func2_data = %{name: :helper, arity: 1}
      func3_data = %{name: :process, arity: 3}

      Store.add_node(:function, {ModuleA, :test, 2}, func1_data)
      Store.add_node(:function, {ModuleB, :helper, 1}, func2_data)
      Store.add_node(:function, {ModuleA, :process, 3}, func3_data)
      Store.sync()

      functions = Store.list_functions()
      assert length(functions) == 3
    end

    test "filters functions by module" do
      func1_data = %{name: :test, arity: 2}
      func2_data = %{name: :helper, arity: 1}
      func3_data = %{name: :process, arity: 3}

      Store.add_node(:function, {ModuleA, :test, 2}, func1_data)
      Store.add_node(:function, {ModuleB, :helper, 1}, func2_data)
      Store.add_node(:function, {ModuleA, :process, 3}, func3_data)
      Store.sync()

      module_a_functions = Store.list_functions(module: ModuleA)
      assert length(module_a_functions) == 2
      assert Enum.all?(module_a_functions, fn f -> elem(f.id, 0) == ModuleA end)

      module_b_functions = Store.list_functions(module: ModuleB)
      assert length(module_b_functions) == 1
      assert [func] = module_b_functions
      assert func.id == {ModuleB, :helper, 1}
    end

    test "respects limit parameter" do
      for i <- 1..10 do
        Store.add_node(:function, {ModuleA, :"func#{i}", 0}, %{name: :"func#{i}", arity: 0})
      end

      Store.sync()
      functions = Store.list_functions(limit: 5)
      assert length(functions) == 5
    end

    test "returns empty list when no functions exist" do
      functions = Store.list_functions()
      assert functions == []
    end

    test "returns empty list when filtering by non-existent module" do
      Store.add_node(:function, {ModuleA, :test, 2}, %{name: :test, arity: 2})
      Store.add_node(:function, {ModuleB, :helper, 1}, %{name: :helper, arity: 1})
      Store.sync()

      functions = Store.list_functions(module: NonExistentModule)
      assert functions == []
    end

    test "returns correct function data with id" do
      func_data = %{name: :test, arity: 2, line: 10, file: "lib/module_a.ex"}
      Store.add_node(:function, {ModuleA, :test, 2}, func_data)
      Store.sync()

      [func] = Store.list_functions(module: ModuleA)
      assert func.id == {ModuleA, :test, 2}
      assert func.data == func_data
    end

    test "combines module filter with limit" do
      for i <- 1..5 do
        Store.add_node(:function, {ModuleA, :"func#{i}", 0}, %{name: :"func#{i}", arity: 0})
        Store.add_node(:function, {ModuleB, :"helper#{i}", 1}, %{name: :"helper#{i}", arity: 1})
      end

      Store.sync()
      functions = Store.list_functions(module: ModuleA, limit: 2)
      assert length(functions) == 2
      assert Enum.all?(functions, fn f -> elem(f.id, 0) == ModuleA end)
    end

    test "lists functions with different arities" do
      Store.add_node(:function, {ModuleA, :test, 0}, %{name: :test, arity: 0})
      Store.add_node(:function, {ModuleA, :test, 1}, %{name: :test, arity: 1})
      Store.add_node(:function, {ModuleA, :test, 2}, %{name: :test, arity: 2})
      Store.sync()

      functions = Store.list_functions(module: ModuleA)
      assert length(functions) == 3

      arities = functions |> Enum.map(& &1.id) |> Enum.map(&elem(&1, 2))
      assert Enum.sort(arities) == [0, 1, 2]
    end
  end

  describe "add_edge/3 and get_outgoing_edges/2" do
    test "adds and retrieves edges" do
      from = {:module, TestModule}
      to = {:function, TestModule, :test, 0}

      assert :ok = Store.add_edge(from, to, :defines)
      Store.sync()

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
      Store.sync()

      edges = Store.get_incoming_edges(to, :defines)
      assert length(edges) == 1
      assert [%{from: ^from, type: :defines}] = edges
    end
  end

  describe "remove_node/2" do
    test "removes a node" do
      Store.add_node(:module, TestModule, %{name: TestModule})
      Store.sync()
      assert Store.find_node(:module, TestModule) != nil

      assert :ok = Store.remove_node(:module, TestModule)
      Store.sync()
      assert Store.find_node(:module, TestModule) == nil
    end

    test "removes outgoing edges when node is removed" do
      from = {:module, TestModule}
      to = {:function, TestModule, :test, 0}

      Store.add_node(:module, TestModule, %{name: TestModule})
      Store.add_node(:function, {TestModule, :test, 0}, %{name: :test})
      Store.add_edge(from, to, :defines)
      Store.sync()

      # Verify edge exists
      assert length(Store.get_outgoing_edges(from, :defines)) == 1

      # Remove source node
      Store.remove_node(:module, TestModule)
      Store.sync()

      # Edge should be gone
      assert Store.get_outgoing_edges(from, :defines) == []
    end

    test "removes incoming edges when node is removed" do
      from = {:module, TestModule}
      to = {:function, TestModule, :test, 0}

      Store.add_node(:module, TestModule, %{name: TestModule})
      Store.add_node(:function, {TestModule, :test, 0}, %{name: :test})
      Store.add_edge(from, to, :defines)
      Store.sync()

      # Verify edge exists
      assert length(Store.get_incoming_edges(to, :defines)) == 1

      # Remove target node
      Store.remove_node(:function, {TestModule, :test, 0})
      Store.sync()

      # Edge should be gone
      assert Store.get_incoming_edges(to, :defines) == []
    end

    test "removes embedding when node is removed" do
      embedding = Enum.map(1..384, fn _ -> 0.1 end)
      Store.store_embedding(:module, TestModule, embedding, "test text")
      Store.sync()

      # Verify embedding exists
      assert Store.get_embedding(:module, TestModule) != nil

      # Remove node
      Store.remove_node(:module, TestModule)
      Store.sync()

      # Embedding should be gone
      assert Store.get_embedding(:module, TestModule) == nil
    end

    test "handles removal of non-existent node gracefully" do
      assert :ok = Store.remove_node(:module, NonExistentModule)
    end

    test "removes multiple edges of different types" do
      node_a = {:module, ModuleA}
      node_b = {:module, ModuleB}
      node_c = {:module, ModuleC}

      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:module, ModuleB, %{name: ModuleB})
      Store.add_node(:module, ModuleC, %{name: ModuleC})

      # Add multiple edges from node_a
      Store.add_edge(node_a, node_b, :imports)
      Store.add_edge(node_a, node_c, :imports)
      Store.add_edge(node_a, node_b, :calls)

      # Add edges to node_a
      Store.add_edge(node_b, node_a, :calls)
      Store.add_edge(node_c, node_a, :defines)
      Store.sync()

      # Verify edges exist
      assert length(Store.get_outgoing_edges(node_a, :imports)) == 2
      assert length(Store.get_outgoing_edges(node_a, :calls)) == 1
      assert length(Store.get_incoming_edges(node_a, :calls)) == 1
      assert length(Store.get_incoming_edges(node_a, :defines)) == 1

      # Remove node_a
      Store.remove_node(:module, ModuleA)
      Store.sync()

      # All edges should be gone
      assert Store.get_outgoing_edges(node_a, :imports) == []
      assert Store.get_outgoing_edges(node_a, :calls) == []
      assert Store.get_incoming_edges(node_a, :calls) == []
      assert Store.get_incoming_edges(node_a, :defines) == []

      # Edges between node_b and node_c should be unaffected
      # (none exist, so verify node_b->node_c edge creation still works)
      Store.add_edge(node_b, node_c, :imports)
      Store.sync()
      assert length(Store.get_outgoing_edges(node_b, :imports)) == 1
    end

    test "decrements node count correctly" do
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:module, ModuleB, %{name: ModuleB})
      Store.sync()

      assert Store.stats().nodes == 2

      Store.remove_node(:module, ModuleA)
      Store.sync()

      assert Store.stats().nodes == 1
    end
  end

  describe "clear/0" do
    test "removes all nodes and edges" do
      Store.add_node(:module, TestModule, %{name: TestModule})
      Store.add_edge({:module, TestModule}, {:module, OtherModule}, :imports)
      Store.sync()

      assert Store.stats().nodes > 0

      Store.clear()
      Store.sync()

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
      Store.sync()

      stats = Store.stats()
      assert stats.nodes == 2
      assert stats.edges == 1
    end
  end

  describe "count_nodes_by_type/1" do
    test "correctly counts nodes of a given type" do
      # Add various nodes
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:module, ModuleB, %{name: ModuleB})
      Store.add_node(:module, ModuleC, %{name: ModuleC})
      Store.add_node(:function, {ModuleA, :func1, 0}, %{name: :func1})
      Store.add_node(:function, {ModuleA, :func2, 1}, %{name: :func2})
      Store.sync()

      # Count modules
      assert Store.count_nodes_by_type(:module) == 3

      # Count functions
      assert Store.count_nodes_by_type(:function) == 2
    end

    test "returns 0 for a non-existent node type" do
      # Add some nodes
      Store.add_node(:module, ModuleA, %{name: ModuleA})
      Store.add_node(:function, {ModuleA, :func1, 0}, %{name: :func1})
      Store.sync()

      # Query non-existent type
      assert Store.count_nodes_by_type(:nonexistent) == 0
      assert Store.count_nodes_by_type(:variable) == 0
    end
  end

  describe "list_edges/1" do
    test "lists all edges without filter" do
      node_a = {:module, ModuleA}
      node_b = {:module, ModuleB}
      node_c = {:module, ModuleC}

      Store.add_edge(node_a, node_b, :imports)
      Store.add_edge(node_b, node_c, :calls)
      Store.add_edge(node_a, node_c, :defines)
      Store.sync()

      edges = Store.list_edges()
      assert length(edges) == 3
    end

    test "filters edges by type" do
      node_a = {:module, ModuleA}
      node_b = {:module, ModuleB}
      node_c = {:module, ModuleC}

      Store.add_edge(node_a, node_b, :imports)
      Store.add_edge(node_b, node_c, :calls)
      Store.add_edge(node_a, node_c, :imports)
      Store.sync()

      edges = Store.list_edges(edge_type: :imports)
      assert length(edges) == 2
      assert Enum.all?(edges, &(&1.type == :imports))
    end

    test "respects limit parameter" do
      for i <- 1..10 do
        Store.add_edge({:module, :"ModuleA#{i}"}, {:module, :"ModuleB#{i}"}, :imports)
      end

      Store.sync()
      edges = Store.list_edges(limit: 5)
      assert length(edges) == 5
    end

    test "returns empty list when no edges exist" do
      edges = Store.list_edges()
      assert edges == []
    end

    test "returns empty list when filtering by non-existent edge type" do
      Store.add_edge({:module, ModuleA}, {:module, ModuleB}, :imports)
      Store.add_edge({:module, ModuleB}, {:module, ModuleC}, :calls)
      Store.sync()

      edges = Store.list_edges(edge_type: :nonexistent)
      assert edges == []
    end

    test "includes metadata with weight in returned edges" do
      node_a = {:module, ModuleA}
      node_b = {:module, ModuleB}

      Store.add_edge(node_a, node_b, :imports, weight: 2.5, metadata: %{custom: "value"})
      Store.sync()

      [edge] = Store.list_edges()
      assert edge.from == node_a
      assert edge.to == node_b
      assert edge.type == :imports
      assert edge.metadata.weight == 2.5
      assert edge.metadata.custom == "value"
    end

    test "combines edge_type filter with limit" do
      for i <- 1..5 do
        Store.add_edge({:module, :"ModuleA#{i}"}, {:module, :"ModuleB#{i}"}, :imports)
        Store.add_edge({:module, :"ModuleC#{i}"}, {:module, :"ModuleD#{i}"}, :calls)
      end

      Store.sync()
      edges = Store.list_edges(edge_type: :imports, limit: 2)
      assert length(edges) == 2
      assert Enum.all?(edges, &(&1.type == :imports))
    end
  end
end
