defmodule Ragex.Analysis.CohesionTest do
  use ExUnit.Case, async: false

  alias Ragex.Analysis.Cohesion
  alias Ragex.Graph.Store

  setup do
    # Clear the graph store before each test
    Store.clear()
    Store.sync()
    :ok
  end

  describe "analyze_module/1" do
    test "returns error for nonexistent module" do
      assert {:error, {:module_not_found, :NonexistentModule}} = Cohesion.analyze_module(:NonexistentModule)
    end

    test "handles empty module gracefully" do
      Store.add_node(:module, :EmptyModule, %{file: "lib/empty.ex", language: :elixir})
      Store.sync()

      assert {:ok, result} = Cohesion.analyze_module(:EmptyModule)
      assert result.module == :EmptyModule
      assert result.cohesion_score == 1.0
      assert result.components_count == 0
      assert result.functions_count == 0
    end

    test "calculates high cohesion for fully connected module" do
      # Module: ConnectedModule
      Store.add_node(:module, :ConnectedModule, %{file: "lib/connected.ex", language: :elixir})

      # Functions: f1, f2, f3
      Store.add_node(:function, {:ConnectedModule, :f1, 0}, %{name: :f1, arity: 0, module: :ConnectedModule})
      Store.add_node(:function, {:ConnectedModule, :f2, 0}, %{name: :f2, arity: 0, module: :ConnectedModule})
      Store.add_node(:function, {:ConnectedModule, :f3, 0}, %{name: :f3, arity: 0, module: :ConnectedModule})

      # Internal calls: f1 -> f2, f2 -> f3
      Store.add_edge({:function, :ConnectedModule, :f1, 0}, {:function, :ConnectedModule, :f2, 0}, :calls)
      Store.add_edge({:function, :ConnectedModule, :f2, 0}, {:function, :ConnectedModule, :f3, 0}, :calls)
      Store.sync()

      assert {:ok, result} = Cohesion.analyze_module(:ConnectedModule)
      assert result.functions_count == 3
      assert result.components_count == 1
      assert result.functional_cohesion_index == 1.0
      assert result.tight_cohesion == 1.0
      assert result.cohesion_score == 1.0
    end

    test "calculates low cohesion for partitioned/disconnected module" do
      # Module: SplitModule
      Store.add_node(:module, :SplitModule, %{file: "lib/split.ex", language: :elixir})

      # Functions: f1, f2, f3, f4
      Store.add_node(:function, {:SplitModule, :f1, 0}, %{name: :f1, arity: 0, module: :SplitModule})
      Store.add_node(:function, {:SplitModule, :f2, 0}, %{name: :f2, arity: 0, module: :SplitModule})
      Store.add_node(:function, {:SplitModule, :f3, 0}, %{name: :f3, arity: 0, module: :SplitModule})
      Store.add_node(:function, {:SplitModule, :f4, 0}, %{name: :f4, arity: 0, module: :SplitModule})

      # Internal calls: f1 -> f2 (Component 1), f3 -> f4 (Component 2)
      Store.add_edge({:function, :SplitModule, :f1, 0}, {:function, :SplitModule, :f2, 0}, :calls)
      Store.add_edge({:function, :SplitModule, :f3, 0}, {:function, :SplitModule, :f4, 0}, :calls)
      Store.sync()

      assert {:ok, result} = Cohesion.analyze_module(:SplitModule)
      assert result.functions_count == 4
      assert result.components_count == 2
      assert result.functional_cohesion_index == 0.5
      # Total pairs = 4 * 3 / 2 = 6. Connected within components: (2*1/2) + (2*1/2) = 2.
      # TCC = 2 / 6 = 0.333333
      assert_in_delta result.tight_cohesion, 0.3333, 0.001
      assert_in_delta result.cohesion_score, 0.4166, 0.001
    end
  end

  describe "analyze_directory/1" do
    test "indexes and computes cohesion for all modules in a directory path" do
      Store.add_node(:module, :ModA, %{file: "lib/core/a.ex", language: :elixir})
      Store.add_node(:module, :ModB, %{file: "lib/core/b.ex", language: :elixir})
      Store.add_node(:module, :ModC, %{file: "lib/other/c.ex", language: :elixir})
      Store.sync()

      assert {:ok, results} = Cohesion.analyze_directory("lib/core/")
      assert length(results) == 2
      names = Enum.map(results, & &1.module)
      assert :ModA in names
      assert :ModB in names
      refute :ModC in names
    end
  end
end
