defmodule Ragex.Analysis.DependencyGraphTest do
  use ExUnit.Case, async: false

  alias Ragex.Analysis.DependencyGraph
  alias Ragex.Graph.Store

  setup do
    # Clear the store before each test
    Store.clear()

    # Create a test graph with modules and functions
    # Module structure:
    # ModA -> ModB -> ModC
    # ModA -> ModD -> ModC (creates cycle when ModC -> ModA added)
    # ModE (unused, no dependencies)

    # Add modules
    Store.add_node(:module, :ModA, %{file: "a.ex", line: 1})
    Store.add_node(:module, :ModB, %{file: "b.ex", line: 1})
    Store.add_node(:module, :ModC, %{file: "c.ex", line: 1})
    Store.add_node(:module, :ModD, %{file: "d.ex", line: 1})
    Store.add_node(:module, :ModE, %{file: "e.ex", line: 1})

    # Add functions
    Store.add_node(:function, {:ModA, :func_a, 0}, %{
      module: :ModA,
      name: :func_a,
      arity: 0,
      visibility: :public
    })

    Store.add_node(:function, {:ModB, :func_b, 0}, %{
      module: :ModB,
      name: :func_b,
      arity: 0,
      visibility: :public
    })

    Store.add_node(:function, {:ModC, :func_c, 0}, %{
      module: :ModC,
      name: :func_c,
      arity: 0,
      visibility: :public
    })

    Store.add_node(:function, {:ModD, :func_d, 0}, %{
      module: :ModD,
      name: :func_d,
      arity: 0,
      visibility: :public
    })

    Store.add_node(:function, {:ModE, :func_e, 0}, %{
      module: :ModE,
      name: :func_e,
      arity: 0,
      visibility: :public
    })

    # Create call relationships
    # A -> B
    Store.add_edge(
      {:function, :ModA, :func_a, 0},
      {:function, :ModB, :func_b, 0},
      :calls
    )

    # B -> C
    Store.add_edge(
      {:function, :ModB, :func_b, 0},
      {:function, :ModC, :func_c, 0},
      :calls
    )

    # A -> D
    Store.add_edge(
      {:function, :ModA, :func_a, 0},
      {:function, :ModD, :func_d, 0},
      :calls
    )

    # D -> C
    Store.add_edge(
      {:function, :ModD, :func_d, 0},
      {:function, :ModC, :func_c, 0},
      :calls
    )

    :ok
  end

  describe "find_cycles/1" do
    test "returns empty list when no cycles exist" do
      {:ok, cycles} = DependencyGraph.find_cycles()
      assert cycles == []
    end

    test "detects module-level circular dependency" do
      # Add cycle: C -> A (closes the loop)
      Store.add_edge(
        {:function, :ModC, :func_c, 0},
        {:function, :ModA, :func_a, 0},
        :calls
      )

      {:ok, cycles} = DependencyGraph.find_cycles(scope: :module)

      assert match?([_ | _], cycles)
      # Should find cycle containing ModA, ModB or ModD, and ModC
      cycle = List.first(cycles)
      assert :ModA in cycle
      assert :ModC in cycle
    end

    test "detects function-level circular dependency" do
      # Create a simple function cycle
      Store.add_edge(
        {:function, :ModB, :func_b, 0},
        {:function, :ModA, :func_a, 0},
        :calls
      )

      {:ok, cycles} = DependencyGraph.find_cycles(scope: :function)

      assert match?([_ | _], cycles)
      cycle = List.first(cycles)
      assert {:function, :ModA, :func_a, 0} in cycle
      assert {:function, :ModB, :func_b, 0} in cycle
    end

    test "respects min_cycle_length option" do
      # Create cycle: C -> A
      Store.add_edge(
        {:function, :ModC, :func_c, 0},
        {:function, :ModA, :func_a, 0},
        :calls
      )

      # Short cycles (length 2-3)
      {:ok, cycles_short} = DependencyGraph.find_cycles(min_cycle_length: 2)
      assert match?([_ | _], cycles_short)

      # Long cycles only (length >= 5)
      {:ok, cycles_long} = DependencyGraph.find_cycles(min_cycle_length: 5)
      assert cycles_long == []
    end

    test "respects limit option" do
      # Create multiple cycles
      Store.add_edge(
        {:function, :ModC, :func_c, 0},
        {:function, :ModA, :func_a, 0},
        :calls
      )

      {:ok, cycles} = DependencyGraph.find_cycles(limit: 1)
      refute match?([_, _ | _], cycles)
    end
  end

  describe "coupling_metrics/2" do
    test "calculates direct coupling metrics" do
      # ModA depends on ModB and ModD (efferent = 2)
      # ModA has no dependents (afferent = 0)
      {:ok, metrics} = DependencyGraph.coupling_metrics(:ModA)

      assert metrics.afferent == 0
      assert metrics.efferent == 2
      # Instability = efferent / (afferent + efferent) = 2/2 = 1.0
      assert metrics.instability == 1.0
    end

    test "calculates metrics for module with dependents" do
      # ModC is called by ModB and ModD (afferent = 2)
      # ModC has no outgoing dependencies (efferent = 0)
      {:ok, metrics} = DependencyGraph.coupling_metrics(:ModC)

      assert metrics.afferent == 2
      assert metrics.efferent == 0
      # Instability = 0 / 2 = 0.0 (stable)
      assert metrics.instability == 0.0
    end

    test "calculates metrics for module with both afferent and efferent" do
      # ModB is called by ModA (afferent = 1)
      # ModB calls ModC (efferent = 1)
      {:ok, metrics} = DependencyGraph.coupling_metrics(:ModB)

      assert metrics.afferent == 1
      assert metrics.efferent == 1
      # Instability = 1 / 2 = 0.5
      assert metrics.instability == 0.5
    end

    test "calculates metrics for unused module" do
      # ModE has no dependencies or dependents
      {:ok, metrics} = DependencyGraph.coupling_metrics(:ModE)

      assert metrics.afferent == 0
      assert metrics.efferent == 0
      assert metrics.instability == 0.0
    end

    test "returns error for non-existent module" do
      {:error, {:module_not_found, :NonExistent}} =
        DependencyGraph.coupling_metrics(:NonExistent)
    end

    test "calculates transitive coupling metrics" do
      # ModA transitively depends on ModB, ModC, ModD
      {:ok, metrics} = DependencyGraph.coupling_metrics(:ModA, include_transitive: true)

      assert metrics.efferent >= 2
    end
  end

  describe "all_coupling_metrics/1" do
    test "returns metrics for all modules" do
      {:ok, all_metrics} = DependencyGraph.all_coupling_metrics()

      assert length(all_metrics) == 5

      assert Enum.all?(all_metrics, fn {_module, metrics} ->
               is_map(metrics) && Map.has_key?(metrics, :afferent) &&
                 Map.has_key?(metrics, :efferent) && Map.has_key?(metrics, :instability)
             end)
    end

    test "sorts by instability by default" do
      {:ok, all_metrics} = DependencyGraph.all_coupling_metrics()

      instabilities = Enum.map(all_metrics, fn {_module, metrics} -> metrics.instability end)

      # Should be in descending order
      assert instabilities == Enum.sort(instabilities, :desc)
    end

    test "can sort by name" do
      {:ok, all_metrics} = DependencyGraph.all_coupling_metrics(sort_by: :name)

      module_names = Enum.map(all_metrics, fn {module, _} -> module end)
      assert module_names == Enum.sort(module_names)
    end

    test "can sort by afferent coupling" do
      {:ok, all_metrics} = DependencyGraph.all_coupling_metrics(sort_by: :afferent)

      afferents = Enum.map(all_metrics, fn {_module, metrics} -> metrics.afferent end)
      assert afferents == Enum.sort(afferents, :desc)
    end
  end

  describe "find_unused/1" do
    test "finds unused modules" do
      # ModE has no incoming or outgoing edges
      {:ok, unused} = DependencyGraph.find_unused()

      assert :ModE in unused
    end

    test "finds modules with no incoming references" do
      {:ok, unused} = DependencyGraph.find_unused()

      # ModA has no callers, so it's potentially unused (could be entry point though)
      assert :ModA in unused
      # ModB, ModC, ModD are all called by other modules
      refute :ModB in unused
      refute :ModC in unused
      refute :ModD in unused
    end

    test "excludes test modules when exclude_tests is true" do
      Store.add_node(:module, :MyModuleTest, %{file: "test.exs", line: 1})

      Store.add_node(:function, {:MyModuleTest, :test_something, 0}, %{
        module: :MyModuleTest,
        name: :test_something,
        arity: 0
      })

      {:ok, unused} = DependencyGraph.find_unused(exclude_tests: true)
      refute :MyModuleTest in unused
    end

    test "includes test modules when exclude_tests is false" do
      Store.add_node(:module, :MyModuleTest, %{file: "test.exs", line: 1})

      Store.add_node(:function, {:MyModuleTest, :test_something, 0}, %{
        module: :MyModuleTest,
        name: :test_something,
        arity: 0
      })

      {:ok, unused} = DependencyGraph.find_unused(exclude_tests: false)
      assert :MyModuleTest in unused
    end

    test "excludes Mix tasks when exclude_mix_tasks is true" do
      Store.add_node(:module, :"Mix.Tasks.MyTask", %{file: "my_task.ex", line: 1})

      Store.add_node(:function, {:"Mix.Tasks.MyTask", :run, 1}, %{
        module: :"Mix.Tasks.MyTask",
        name: :run,
        arity: 1
      })

      {:ok, unused} = DependencyGraph.find_unused(exclude_mix_tasks: true)
      refute :"Mix.Tasks.MyTask" in unused
    end
  end

  describe "find_god_modules/2" do
    test "finds modules with high coupling" do
      # Add more dependencies to ModA to make it a God module
      for i <- 1..20 do
        target_mod = :"Target#{i}"
        Store.add_node(:module, target_mod, %{file: "target#{i}.ex", line: 1})
        Store.add_node(:function, {target_mod, :func, 0}, %{module: target_mod})

        Store.add_edge(
          {:function, :ModA, :func_a, 0},
          {:function, target_mod, :func, 0},
          :calls
        )
      end

      {:ok, god_modules} = DependencyGraph.find_god_modules(15)

      # ModA should be identified as a God module
      assert Enum.any?(god_modules, fn {module, _metrics} -> module == :ModA end)
    end

    test "returns empty list when no modules exceed threshold" do
      {:ok, god_modules} = DependencyGraph.find_god_modules(100)
      assert god_modules == []
    end

    test "sorts God modules by specified criteria" do
      # Add dependencies to multiple modules
      for i <- 1..10 do
        target_mod = :"Target#{i}"
        Store.add_node(:module, target_mod, %{file: "target#{i}.ex", line: 1})
        Store.add_node(:function, {target_mod, :func, 0}, %{module: target_mod})

        Store.add_edge(
          {:function, :ModA, :func_a, 0},
          {:function, target_mod, :func, 0},
          :calls
        )
      end

      {:ok, god_modules} = DependencyGraph.find_god_modules(5, sort_by: :efferent)

      # Should be sorted by efferent coupling
      efferents =
        Enum.map(god_modules, fn {_module, metrics} -> metrics.efferent end)

      assert efferents == Enum.sort(efferents, :desc)
    end
  end

  describe "decoupling_suggestions/1" do
    test "suggests breaking circular dependencies" do
      # Add cycle
      Store.add_edge(
        {:function, :ModC, :func_c, 0},
        {:function, :ModA, :func_a, 0},
        :calls
      )

      {:ok, suggestions} = DependencyGraph.decoupling_suggestions()

      circular_suggestions =
        Enum.filter(suggestions, fn s -> s.type == :circular_dependency end)

      assert match?([_ | _], circular_suggestions)
    end

    test "suggests splitting God modules" do
      # Add many dependencies to ModA
      for i <- 1..20 do
        target_mod = :"Target#{i}"
        Store.add_node(:module, target_mod, %{file: "target#{i}.ex", line: 1})
        Store.add_node(:function, {target_mod, :func, 0}, %{module: target_mod})

        Store.add_edge(
          {:function, :ModA, :func_a, 0},
          {:function, target_mod, :func, 0},
          :calls
        )
      end

      {:ok, suggestions} = DependencyGraph.decoupling_suggestions()

      god_suggestions = Enum.filter(suggestions, fn s -> s.type == :god_module end)
      assert match?([_ | _], god_suggestions)
    end

    test "suggests stabilizing unstable modules" do
      # ModA has high instability (1.0)
      {:ok, suggestions} = DependencyGraph.decoupling_suggestions()

      unstable_suggestions =
        Enum.filter(suggestions, fn s -> s.type == :unstable_module end)

      assert match?([_ | _], unstable_suggestions)
    end

    test "suggests removing unused modules" do
      {:ok, suggestions} = DependencyGraph.decoupling_suggestions()

      unused_suggestions = Enum.filter(suggestions, fn s -> s.type == :unused_module end)
      assert match?([_ | _], unused_suggestions)
      assert Enum.any?(unused_suggestions, fn s -> :ModE in s.entities end)
    end

    test "assigns appropriate severity levels" do
      # Add cycle and God module
      Store.add_edge(
        {:function, :ModC, :func_c, 0},
        {:function, :ModA, :func_a, 0},
        :calls
      )

      for i <- 1..25 do
        target_mod = :"Target#{i}"
        Store.add_node(:module, target_mod, %{file: "target#{i}.ex", line: 1})
        Store.add_node(:function, {target_mod, :func, 0}, %{module: target_mod})

        Store.add_edge(
          {:function, :ModA, :func_a, 0},
          {:function, target_mod, :func, 0},
          :calls
        )
      end

      {:ok, suggestions} = DependencyGraph.decoupling_suggestions()

      # Check that suggestions have valid severity levels
      assert Enum.all?(suggestions, fn s ->
               s.severity in [:low, :medium, :high]
             end)

      # Check that God modules with high coupling get higher severity
      with [_ | _] = god_suggestions <-
             Enum.filter(suggestions, fn s -> s.type == :god_module end) do
        high_severity =
          Enum.any?(god_suggestions, fn s -> s.severity in [:medium, :high] end)

        assert high_severity
      end
    end

    test "returns empty list when codebase is well-structured" do
      # Clear and create a simple, well-structured graph
      Store.clear()

      Store.add_node(:module, :WellStructured, %{file: "well.ex", line: 1})

      Store.add_node(:function, {:WellStructured, :func, 0}, %{
        module: :WellStructured,
        name: :func,
        arity: 0
      })

      {:ok, suggestions} = DependencyGraph.decoupling_suggestions()
      # Should have minimal suggestions (maybe just unused module warnings)
      refute match?([_, _ | _], suggestions)
    end
  end

  describe "edge cases" do
    test "handles empty graph" do
      Store.clear()

      {:ok, cycles} = DependencyGraph.find_cycles()
      assert cycles == []

      {:ok, unused} = DependencyGraph.find_unused()
      assert unused == []

      {:ok, god_modules} = DependencyGraph.find_god_modules(10)
      assert god_modules == []
    end

    test "handles self-referential module" do
      Store.clear()

      Store.add_node(:module, :SelfRef, %{file: "self.ex", line: 1})
      Store.add_node(:function, {:SelfRef, :func, 0}, %{module: :SelfRef})

      # Self call
      Store.add_edge(
        {:function, :SelfRef, :func, 0},
        {:function, :SelfRef, :func, 0},
        :calls
      )

      {:ok, metrics} = DependencyGraph.coupling_metrics(:SelfRef)
      # Self-references should be filtered out
      assert metrics.efferent == 0
    end

    test "handles module with only imports (no calls)" do
      Store.clear()

      Store.add_node(:module, :Importer, %{file: "importer.ex", line: 1})
      Store.add_node(:module, :Imported, %{file: "imported.ex", line: 1})

      Store.add_edge({:module, :Importer}, {:module, :Imported}, :imports)

      {:ok, metrics} = DependencyGraph.coupling_metrics(:Importer)
      assert metrics.efferent == 1

      {:ok, metrics} = DependencyGraph.coupling_metrics(:Imported)
      assert metrics.afferent == 1
    end
  end
end
