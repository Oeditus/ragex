defmodule Ragex.Graph.AlgorithmsTest do
  use ExUnit.Case, async: false

  alias Ragex.Graph.Algorithms
  alias Ragex.Graph.Store

  setup do
    # Clear the store before each test
    Store.clear()

    # Set up a simple test graph
    # A -> B -> C
    # A -> D
    # D -> C
    Store.add_node(:module, :ModuleA, %{file: "a.ex", line: 1})
    Store.add_node(:module, :ModuleB, %{file: "b.ex", line: 1})
    Store.add_node(:module, :ModuleC, %{file: "c.ex", line: 1})
    Store.add_node(:module, :ModuleD, %{file: "d.ex", line: 1})

    Store.add_node(:function, {:ModuleA, :foo, 0}, %{module: :ModuleA, name: :foo, arity: 0})
    Store.add_node(:function, {:ModuleB, :bar, 0}, %{module: :ModuleB, name: :bar, arity: 0})
    Store.add_node(:function, {:ModuleC, :baz, 0}, %{module: :ModuleC, name: :baz, arity: 0})
    Store.add_node(:function, {:ModuleD, :qux, 0}, %{module: :ModuleD, name: :qux, arity: 0})

    # Create call relationships by adding edges
    # A -> B
    Store.add_edge(
      {:function, :ModuleA, :foo, 0},
      {:function, :ModuleB, :bar, 0},
      :calls
    )

    # B -> C
    Store.add_edge(
      {:function, :ModuleB, :bar, 0},
      {:function, :ModuleC, :baz, 0},
      :calls
    )

    # A -> D
    Store.add_edge(
      {:function, :ModuleA, :foo, 0},
      {:function, :ModuleD, :qux, 0},
      :calls
    )

    # D -> C
    Store.add_edge(
      {:function, :ModuleD, :qux, 0},
      {:function, :ModuleC, :baz, 0},
      :calls
    )

    Store.sync()
    :ok
  end

  describe "pagerank/1" do
    test "computes PageRank scores for all nodes" do
      scores = Algorithms.pagerank()

      assert is_map(scores)
      assert map_size(scores) > 0

      # All scores should be positive floats
      for {_node, score} <- scores do
        assert is_float(score)
        assert score > 0.0
      end

      # Scores are computed only for nodes in the call graph
      # In our test graph: 4 functions with call relationships
      assert map_size(scores) == 4

      # Sum should be positive (normalized distribution)
      total = scores |> Map.values() |> Enum.sum()
      assert total > 0.0
    end

    test "nodes with more incoming edges have higher scores" do
      scores = Algorithms.pagerank()

      # ModuleC.baz/0 is called by both ModuleB.bar and ModuleD.qux
      # So it should have a higher score than ModuleA.foo (called by no one)
      baz_score = Map.get(scores, {:function, :ModuleC, :baz, 0}, 0.0)
      foo_score = Map.get(scores, {:function, :ModuleA, :foo, 0}, 0.0)

      assert baz_score > foo_score
    end

    test "converges with custom parameters" do
      scores =
        Algorithms.pagerank(
          damping_factor: 0.85,
          max_iterations: 50,
          tolerance: 0.001
        )

      assert is_map(scores)
      assert map_size(scores) > 0
    end

    test "handles empty graph" do
      Store.clear()
      Store.sync()
      scores = Algorithms.pagerank()

      assert scores == %{}
    end
  end

  describe "find_paths/3" do
    test "finds direct paths between nodes" do
      from = {:function, :ModuleA, :foo, 0}
      to = {:function, :ModuleB, :bar, 0}

      paths = Algorithms.find_paths(from, to)

      assert is_list(paths)
      assert paths != []

      # Should find the direct path A -> B
      assert [from, to] in paths
    end

    test "finds indirect paths" do
      from = {:function, :ModuleA, :foo, 0}
      to = {:function, :ModuleC, :baz, 0}

      paths = Algorithms.find_paths(from, to)

      assert Enum.count(paths) >= 2

      # Should find A -> B -> C
      path1 = [
        {:function, :ModuleA, :foo, 0},
        {:function, :ModuleB, :bar, 0},
        {:function, :ModuleC, :baz, 0}
      ]

      # Should find A -> D -> C
      path2 = [
        {:function, :ModuleA, :foo, 0},
        {:function, :ModuleD, :qux, 0},
        {:function, :ModuleC, :baz, 0}
      ]

      assert path1 in paths
      assert path2 in paths
    end

    test "respects max_depth limit" do
      from = {:function, :ModuleA, :foo, 0}
      to = {:function, :ModuleC, :baz, 0}

      # With max_depth 1, can't reach C from A (requires 2 hops)
      paths_shallow = Algorithms.find_paths(from, to, max_depth: 1)
      assert paths_shallow == []

      # With max_depth 2, should find paths
      paths_deep = Algorithms.find_paths(from, to, max_depth: 2)
      assert Enum.count(paths_deep) >= 2
    end

    test "returns empty list when no path exists" do
      from = {:function, :ModuleC, :baz, 0}
      to = {:function, :ModuleA, :foo, 0}

      # C doesn't call A, so no path
      paths = Algorithms.find_paths(from, to)

      assert paths == []
    end

    test "finds path to self (single node)" do
      from = {:function, :ModuleA, :foo, 0}
      to = {:function, :ModuleA, :foo, 0}

      paths = Algorithms.find_paths(from, to)

      assert [[{:function, :ModuleA, :foo, 0}]] == paths
    end

    test "respects max_paths limit" do
      # Create a dense graph with multiple paths
      # A calls B1, B2, B3, all of which call C
      Store.clear()
      Store.sync()

      Store.add_node(:function, {:ModuleA, :foo, 0}, %{module: :ModuleA, name: :foo, arity: 0})
      Store.add_node(:function, {:ModuleB1, :bar, 0}, %{module: :ModuleB1, name: :bar, arity: 0})
      Store.add_node(:function, {:ModuleB2, :bar, 0}, %{module: :ModuleB2, name: :bar, arity: 0})
      Store.add_node(:function, {:ModuleB3, :bar, 0}, %{module: :ModuleB3, name: :bar, arity: 0})
      Store.add_node(:function, {:ModuleC, :baz, 0}, %{module: :ModuleC, name: :baz, arity: 0})

      # A -> B1 -> C
      Store.add_edge(
        {:function, :ModuleA, :foo, 0},
        {:function, :ModuleB1, :bar, 0},
        :calls
      )

      Store.add_edge(
        {:function, :ModuleB1, :bar, 0},
        {:function, :ModuleC, :baz, 0},
        :calls
      )

      # A -> B2 -> C
      Store.add_edge(
        {:function, :ModuleA, :foo, 0},
        {:function, :ModuleB2, :bar, 0},
        :calls
      )

      Store.add_edge(
        {:function, :ModuleB2, :bar, 0},
        {:function, :ModuleC, :baz, 0},
        :calls
      )

      # A -> B3 -> C
      Store.add_edge(
        {:function, :ModuleA, :foo, 0},
        {:function, :ModuleB3, :bar, 0},
        :calls
      )

      Store.add_edge(
        {:function, :ModuleB3, :bar, 0},
        {:function, :ModuleC, :baz, 0},
        :calls
      )

      Store.sync()
      from = {:function, :ModuleA, :foo, 0}
      to = {:function, :ModuleC, :baz, 0}

      # Without limit, should find all 3 paths
      all_paths = Algorithms.find_paths(from, to)
      assert Enum.count(all_paths) == 3

      # With max_paths: 2, should only get 2 paths
      limited_paths = Algorithms.find_paths(from, to, max_paths: 2)
      assert Enum.count(limited_paths) == 2

      # With max_paths: 1, should only get 1 path
      single_path = Algorithms.find_paths(from, to, max_paths: 1)
      assert Enum.count(single_path) == 1
    end

    test "supports keyword options for max_depth and max_paths" do
      from = {:function, :ModuleA, :foo, 0}
      to = {:function, :ModuleC, :baz, 0}

      # Test with explicit options
      paths = Algorithms.find_paths(from, to, max_depth: 5, max_paths: 50)
      assert is_list(paths)

      # Can disable warnings
      paths_no_warn = Algorithms.find_paths(from, to, warn_dense: false)
      assert is_list(paths_no_warn)
    end
  end

  describe "degree_centrality/0" do
    test "computes in_degree and out_degree for all nodes" do
      centrality = Algorithms.degree_centrality()

      assert is_map(centrality)

      for {_node, metrics} <- centrality do
        assert Map.has_key?(metrics, :in_degree)
        assert Map.has_key?(metrics, :out_degree)
        assert Map.has_key?(metrics, :total_degree)

        assert metrics.total_degree == metrics.in_degree + metrics.out_degree
      end
    end

    test "correctly counts incoming edges" do
      centrality = Algorithms.degree_centrality()

      # ModuleC.baz is called by both B and D
      baz_metrics = Map.get(centrality, {:function, :ModuleC, :baz, 0})
      assert baz_metrics.in_degree == 2

      # ModuleA.foo is not called by anyone
      foo_metrics = Map.get(centrality, {:function, :ModuleA, :foo, 0})
      assert foo_metrics.in_degree == 0
    end

    test "correctly counts outgoing edges" do
      centrality = Algorithms.degree_centrality()

      # ModuleA.foo calls both B and D
      foo_metrics = Map.get(centrality, {:function, :ModuleA, :foo, 0})
      assert foo_metrics.out_degree == 2

      # ModuleC.baz calls no one
      baz_metrics = Map.get(centrality, {:function, :ModuleC, :baz, 0})
      assert baz_metrics.out_degree == 0
    end

    test "handles nodes with no edges" do
      # Modules have no call edges (only functions do)
      centrality = Algorithms.degree_centrality()

      module_a_metrics = Map.get(centrality, {:module, :ModuleA})
      assert module_a_metrics.in_degree == 0
      assert module_a_metrics.out_degree == 0
      assert module_a_metrics.total_degree == 0
    end
  end

  describe "graph_stats/0" do
    test "returns comprehensive statistics" do
      stats = Algorithms.graph_stats()

      assert Map.has_key?(stats, :node_count)
      assert Map.has_key?(stats, :node_counts_by_type)
      assert Map.has_key?(stats, :edge_count)
      assert Map.has_key?(stats, :average_degree)
      assert Map.has_key?(stats, :density)
      assert Map.has_key?(stats, :top_nodes)

      assert stats.node_count > 0
      assert is_map(stats.node_counts_by_type)
      assert stats.edge_count >= 0
      assert is_float(stats.average_degree)
      assert is_float(stats.density)
      assert is_list(stats.top_nodes)
    end

    test "node counts by type are correct" do
      stats = Algorithms.graph_stats()

      assert stats.node_counts_by_type[:module] == 4
      assert stats.node_counts_by_type[:function] == 4
    end

    test "edge count is correct" do
      stats = Algorithms.graph_stats()

      # We have 4 call relationships
      assert stats.edge_count == 4
    end

    test "top nodes are ordered by PageRank" do
      stats = Algorithms.graph_stats()

      scores = Enum.map(stats.top_nodes, fn {_node, score} -> score end)

      # Scores should be in descending order
      assert scores == Enum.sort(scores, :desc)
    end

    test "density is between 0 and 1" do
      stats = Algorithms.graph_stats()

      assert stats.density >= 0.0
      assert stats.density <= 1.0
    end
  end

  describe "integration with real code" do
    test "works with actual Elixir code analysis" do
      Store.clear()
      Store.sync()

      # Simulate analysis of a simple module
      _code = """
      defmodule TestModule do
        def foo, do: bar()
        def bar, do: baz()
        def baz, do: :ok
      end
      """

      # This would normally come from analyzer
      Store.add_node(:module, :TestModule, %{file: "test.ex"})

      Store.add_node(:function, {:TestModule, :foo, 0}, %{
        module: :TestModule,
        name: :foo,
        arity: 0
      })

      Store.add_node(:function, {:TestModule, :bar, 0}, %{
        module: :TestModule,
        name: :bar,
        arity: 0
      })

      Store.add_node(:function, {:TestModule, :baz, 0}, %{
        module: :TestModule,
        name: :baz,
        arity: 0
      })

      # Add edges for call relationships
      Store.add_edge(
        {:function, :TestModule, :foo, 0},
        {:function, :TestModule, :bar, 0},
        :calls
      )

      Store.add_edge(
        {:function, :TestModule, :bar, 0},
        {:function, :TestModule, :baz, 0},
        :calls
      )

      Store.sync()
      # Test PageRank
      scores = Algorithms.pagerank()
      assert map_size(scores) > 0

      # Test path finding
      paths =
        Algorithms.find_paths(
          {:function, :TestModule, :foo, 0},
          {:function, :TestModule, :baz, 0}
        )

      assert paths != []

      # Test centrality
      centrality = Algorithms.degree_centrality()
      bar_metrics = Map.get(centrality, {:function, :TestModule, :bar, 0})
      # called by foo
      assert bar_metrics.in_degree == 1
      # calls baz
      assert bar_metrics.out_degree == 1

      # Test stats
      stats = Algorithms.graph_stats()
      assert stats.node_count > 0
    end
  end
end
