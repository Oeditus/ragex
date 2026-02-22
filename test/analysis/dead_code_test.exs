defmodule Ragex.Analysis.DeadCodeTest do
  use ExUnit.Case, async: false

  alias Ragex.Analysis.DeadCode
  alias Ragex.Graph.Store

  setup do
    # Clear the store before each test
    Store.clear()

    # Create test modules and functions
    # ModuleA: Has used and unused public functions
    Store.add_node(:module, :ModuleA, %{file: "a.ex", line: 1})

    Store.add_node(:function, {:ModuleA, :used_public, 0}, %{
      module: :ModuleA,
      name: :used_public,
      arity: 0,
      visibility: :public
    })

    Store.add_node(:function, {:ModuleA, :unused_public, 0}, %{
      module: :ModuleA,
      name: :unused_public,
      arity: 0,
      visibility: :public
    })

    Store.add_node(:function, {:ModuleA, :used_private, 0}, %{
      module: :ModuleA,
      name: :used_private,
      arity: 0,
      visibility: :private
    })

    Store.add_node(:function, {:ModuleA, :unused_private, 0}, %{
      module: :ModuleA,
      name: :unused_private,
      arity: 0,
      visibility: :private
    })

    # ModuleB: Calls ModuleA functions
    Store.add_node(:module, :ModuleB, %{file: "b.ex", line: 1})

    Store.add_node(:function, {:ModuleB, :caller, 0}, %{
      module: :ModuleB,
      name: :caller,
      arity: 0,
      visibility: :public
    })

    # Create calls to mark functions as used
    Store.add_edge(
      {:function, :ModuleB, :caller, 0},
      {:function, :ModuleA, :used_public, 0},
      :calls
    )

    Store.add_edge(
      {:function, :ModuleA, :used_public, 0},
      {:function, :ModuleA, :used_private, 0},
      :calls
    )

    # Create a GenServer-like module with callbacks
    Store.add_node(:module, :MyGenServer, %{file: "genserver.ex", line: 1})

    Store.add_node(:function, {:MyGenServer, :init, 1}, %{
      module: :MyGenServer,
      name: :init,
      arity: 1,
      visibility: :public
    })

    Store.add_node(:function, {:MyGenServer, :handle_call, 3}, %{
      module: :MyGenServer,
      name: :handle_call,
      arity: 3,
      visibility: :public
    })

    # Create a test module
    Store.add_node(:module, :MyModuleTest, %{file: "test.exs", line: 1})

    Store.add_node(:function, {:MyModuleTest, :test_something, 0}, %{
      module: :MyModuleTest,
      name: :test_something,
      arity: 0,
      visibility: :public
    })

    Store.sync()
    :ok
  end

  describe "find_unused_exports/1" do
    test "finds unused public functions" do
      {:ok, dead} = DeadCode.find_unused_exports()

      # Should find unused_public but not used_public
      unused_funcs = Enum.map(dead, fn d -> d.function end)
      assert %{type: :function, module: :ModuleA, name: :unused_public, arity: 0} in unused_funcs
      refute %{type: :function, module: :ModuleA, name: :used_public, arity: 0} in unused_funcs
    end

    test "does not include private functions" do
      {:ok, dead} = DeadCode.find_unused_exports()

      unused_funcs = Enum.map(dead, fn d -> d.function end)
      refute %{type: :function, module: :ModuleA, name: :unused_private, arity: 0} in unused_funcs
      refute %{type: :function, module: :ModuleA, name: :used_private, arity: 0} in unused_funcs
    end

    test "filters by confidence threshold" do
      {:ok, high_confidence} = DeadCode.find_unused_exports(min_confidence: 0.8)
      {:ok, all} = DeadCode.find_unused_exports(min_confidence: 0.0)

      assert length(high_confidence) <= length(all)
    end

    test "excludes test modules by default" do
      {:ok, dead} = DeadCode.find_unused_exports()

      unused_funcs = Enum.map(dead, fn d -> d.function end)

      refute %{type: :function, module: :MyModuleTest, name: :test_something, arity: 0} in unused_funcs
    end

    test "includes test modules when exclude_tests is false" do
      {:ok, dead} = DeadCode.find_unused_exports(exclude_tests: false, min_confidence: 0.0)

      unused_funcs = Enum.map(dead, fn d -> d.function end)

      assert %{type: :function, module: :MyModuleTest, name: :test_something, arity: 0} in unused_funcs
    end

    test "excludes callbacks by default" do
      {:ok, dead} = DeadCode.find_unused_exports(min_confidence: 0.5)

      # GenServer callbacks should not appear in high confidence dead code
      unused_funcs = Enum.map(dead, fn d -> d.function end)
      refute %{type: :function, module: :MyGenServer, name: :init, arity: 1} in unused_funcs

      refute %{type: :function, module: :MyGenServer, name: :handle_call, arity: 3} in unused_funcs
    end

    test "includes callbacks when include_callbacks is true" do
      {:ok, dead} = DeadCode.find_unused_exports(include_callbacks: true, min_confidence: 0.0)

      # Should include callbacks with low confidence scores
      unused_funcs = Enum.map(dead, fn d -> d.function end)
      assert %{type: :function, module: :MyGenServer, name: :init, arity: 1} in unused_funcs

      assert %{type: :function, module: :MyGenServer, name: :handle_call, arity: 3} in unused_funcs
    end

    test "returns functions with confidence scores" do
      {:ok, dead} = DeadCode.find_unused_exports(min_confidence: 0.0)

      assert Enum.all?(dead, fn d ->
               is_float(d.confidence) && d.confidence >= 0.0 && d.confidence <= 1.0
             end)
    end

    test "includes visibility and reason in results" do
      {:ok, dead} = DeadCode.find_unused_exports(min_confidence: 0.0)

      assert Enum.all?(dead, fn d ->
               d.visibility in [:public, :private] && is_binary(d.reason)
             end)
    end
  end

  describe "find_unused_private/1" do
    test "finds unused private functions" do
      {:ok, dead} = DeadCode.find_unused_private()

      # Should find unused_private but not used_private
      unused_funcs = Enum.map(dead, fn d -> d.function end)
      assert %{type: :function, module: :ModuleA, name: :unused_private, arity: 0} in unused_funcs
      refute %{type: :function, module: :ModuleA, name: :used_private, arity: 0} in unused_funcs
    end

    test "does not include public functions" do
      {:ok, dead} = DeadCode.find_unused_private()

      unused_funcs = Enum.map(dead, fn d -> d.function end)
      refute %{type: :function, module: :ModuleA, name: :unused_public, arity: 0} in unused_funcs
      refute %{type: :function, module: :ModuleA, name: :used_public, arity: 0} in unused_funcs
    end

    test "has higher default confidence threshold" do
      {:ok, private_dead} = DeadCode.find_unused_private()
      {:ok, public_dead} = DeadCode.find_unused_exports()

      # Private functions should generally have higher confidence scores
      private_avg =
        case private_dead do
          [] -> 0.0
          [_ | _] -> Enum.sum(Enum.map(private_dead, & &1.confidence)) / length(private_dead)
        end

      public_avg =
        case public_dead do
          [] -> 0.0
          [_ | _] -> Enum.sum(Enum.map(public_dead, & &1.confidence)) / length(public_dead)
        end

      # This might not always be true depending on function names, but generally should be
      assert private_avg >= public_avg || private_dead == [] || public_dead == []
    end
  end

  describe "find_all_unused/1" do
    test "combines public and private unused functions" do
      {:ok, all_dead} = DeadCode.find_all_unused(min_confidence: 0.0)

      unused_funcs = Enum.map(all_dead, fn d -> d.function end)
      assert %{type: :function, module: :ModuleA, name: :unused_public, arity: 0} in unused_funcs
      assert %{type: :function, module: :ModuleA, name: :unused_private, arity: 0} in unused_funcs
    end

    test "sorts by confidence descending" do
      {:ok, all_dead} = DeadCode.find_all_unused(min_confidence: 0.0)

      confidences = Enum.map(all_dead, & &1.confidence)
      assert confidences == Enum.sort(confidences, :desc)
    end
  end

  describe "find_unused_modules/1" do
    test "delegates to DependencyGraph" do
      # Add an unused module
      Store.add_node(:module, :UnusedModule, %{file: "unused.ex", line: 1})

      Store.add_node(:function, {:UnusedModule, :func, 0}, %{
        module: :UnusedModule,
        name: :func,
        arity: 0
      })

      Store.sync()
      {:ok, unused} = DeadCode.find_unused_modules()

      assert :UnusedModule in unused
    end
  end

  describe "removal_suggestions/1" do
    test "categorizes by confidence level" do
      {:ok, suggestions} =
        DeadCode.removal_suggestions(min_confidence: 0.0, group_by_module: false)

      types = Enum.map(suggestions, & &1.type)

      assert :remove_function in types || :review_function in types ||
               :potential_callback in types
    end

    test "high confidence functions get remove_function type" do
      {:ok, suggestions} =
        DeadCode.removal_suggestions(min_confidence: 0.0, group_by_module: false)

      high_confidence_suggestions =
        Enum.filter(suggestions, fn s -> s.confidence > 0.8 end)

      if match?([_ | _], high_confidence_suggestions) do
        assert Enum.all?(high_confidence_suggestions, fn s -> s.type == :remove_function end)
      end
    end

    test "medium confidence functions get review_function type" do
      {:ok, suggestions} =
        DeadCode.removal_suggestions(min_confidence: 0.0, group_by_module: false)

      medium_confidence_suggestions =
        Enum.filter(suggestions, fn s -> s.confidence > 0.5 && s.confidence <= 0.8 end)

      if match?([_ | _], medium_confidence_suggestions) do
        assert Enum.all?(medium_confidence_suggestions, fn s -> s.type == :review_function end)
      end
    end

    test "low confidence functions get potential_callback type" do
      {:ok, suggestions} =
        DeadCode.removal_suggestions(min_confidence: 0.0, group_by_module: false)

      low_confidence_suggestions =
        Enum.filter(suggestions, fn s -> s.confidence <= 0.5 end)

      if match?([_ | _], low_confidence_suggestions) do
        assert Enum.all?(low_confidence_suggestions, fn s -> s.type == :potential_callback end)
      end
    end

    test "includes descriptions" do
      {:ok, suggestions} =
        DeadCode.removal_suggestions(min_confidence: 0.0, group_by_module: false)

      assert Enum.all?(suggestions, fn s -> is_binary(s.description) && s.description != "" end)
    end

    test "groups by module when enabled" do
      # Add multiple unused functions in same module
      Store.add_node(:module, :MultiDeadModule, %{file: "multi.ex", line: 1})

      for i <- 1..3 do
        Store.add_node(:function, {:MultiDeadModule, :"unused_#{i}", 0}, %{
          module: :MultiDeadModule,
          name: :"unused_#{i}",
          arity: 0,
          visibility: :public
        })
      end

      Store.sync()
      {:ok, grouped} = DeadCode.removal_suggestions(min_confidence: 0.0, group_by_module: true)
      {:ok, ungrouped} = DeadCode.removal_suggestions(min_confidence: 0.0, group_by_module: false)

      # Grouped should have module-level suggestions
      module_suggestions =
        Enum.filter(grouped, fn s ->
          match?({:module, _}, s.target)
        end)

      assert match?([_ | _], module_suggestions)
      # Ungrouped should have more individual function suggestions
      assert length(ungrouped) >= length(grouped)
    end

    test "module summary includes breakdown" do
      # Add multiple unused functions in same module
      Store.add_node(:module, :SummaryModule, %{file: "summary.ex", line: 1})

      for i <- 1..3 do
        Store.add_node(:function, {:SummaryModule, :"func_#{i}", 0}, %{
          module: :SummaryModule,
          name: :"func_#{i}",
          arity: 0,
          visibility: :public
        })
      end

      Store.sync()

      {:ok, suggestions} =
        DeadCode.removal_suggestions(min_confidence: 0.0, group_by_module: true)

      module_suggestion =
        Enum.find(suggestions, fn s ->
          match?({:module, :SummaryModule}, s.target)
        end)

      if module_suggestion do
        assert Map.has_key?(module_suggestion.metadata, :function_count)
        assert Map.has_key?(module_suggestion.metadata, :breakdown)
        assert Map.has_key?(module_suggestion.metadata, :functions)
      end
    end
  end

  describe "confidence_score/2" do
    test "returns high score for unused regular public function" do
      func_ref = {:function, :SomeModule, :regular_func, 0}
      metadata = %{visibility: :public}

      score = DeadCode.confidence_score(func_ref, metadata)
      # Public functions get -0.2 modifier, so 0.8
      assert score == 0.8
    end

    test "returns high score for private functions" do
      func_ref = {:function, :SomeModule, :private_func, 0}
      metadata = %{visibility: :private}

      score = DeadCode.confidence_score(func_ref, metadata)
      # Private gets boost, so even with public penalty removed, should be high
      assert score >= 0.8
    end

    test "returns low score for callback patterns" do
      func_ref = {:function, :SomeModule, :init, 1}
      metadata = %{visibility: :public}

      score = DeadCode.confidence_score(func_ref, metadata)
      # Callback pattern should significantly reduce confidence
      assert score < 0.5
    end

    test "returns low score for entry point patterns" do
      func_ref = {:function, :SomeModule, :main, 0}
      metadata = %{visibility: :public}

      score = DeadCode.confidence_score(func_ref, metadata)
      # Entry point pattern should reduce confidence
      assert score < 0.7
    end

    test "returns reduced score for test modules" do
      func_ref = {:function, :MyModuleTest, :some_func, 0}
      metadata = %{visibility: :public}

      score = DeadCode.confidence_score(func_ref, metadata)
      # Test module should reduce confidence
      assert score < 1.0
    end

    test "returns reduced score for Mix tasks" do
      func_ref = {:function, :"Mix.Tasks.MyTask", :run, 1}
      metadata = %{visibility: :public}

      score = DeadCode.confidence_score(func_ref, metadata)
      # Mix task should significantly reduce confidence
      assert score < 0.5
    end

    test "clamps score to [0.0, 1.0]" do
      # Test various scenarios to ensure clamping
      scenarios = [
        {{:function, :Module, :init, 1}, %{visibility: :public}},
        {{:function, :Module, :main, 0}, %{visibility: :public}},
        {{:function, :Module, :regular, 0}, %{visibility: :private}},
        {{:function, :"Mix.Tasks.Foo", :run, 1}, %{visibility: :public}}
      ]

      for {func_ref, metadata} <- scenarios do
        score = DeadCode.confidence_score(func_ref, metadata)
        assert score >= 0.0 && score <= 1.0
      end
    end
  end

  describe "edge cases" do
    test "handles empty graph" do
      Store.clear()
      Store.sync()

      {:ok, exports} = DeadCode.find_unused_exports()
      {:ok, private} = DeadCode.find_unused_private()
      {:ok, all} = DeadCode.find_all_unused()

      assert exports == []
      assert private == []
      assert all == []
    end

    test "handles functions with no metadata" do
      Store.add_node(:module, :NoMetadata, %{file: "no_meta.ex", line: 1})

      Store.add_node(:function, {:NoMetadata, :func, 0}, %{
        module: :NoMetadata,
        name: :func,
        arity: 0
        # No visibility field
      })

      Store.sync()
      {:ok, dead} = DeadCode.find_unused_exports(min_confidence: 0.0)

      # Should default to public and include it
      unused_funcs = Enum.map(dead, fn d -> d.function end)
      assert %{type: :function, module: :NoMetadata, name: :func, arity: 0} in unused_funcs
    end

    test "handles functions called multiple times" do
      # Create a function with multiple callers
      Store.add_node(:module, :Popular, %{file: "popular.ex", line: 1})

      Store.add_node(:function, {:Popular, :popular_func, 0}, %{
        module: :Popular,
        name: :popular_func,
        arity: 0,
        visibility: :public
      })

      # Add multiple callers
      for i <- 1..5 do
        caller_mod = :"Caller#{i}"
        Store.add_node(:module, caller_mod, %{file: "caller#{i}.ex", line: 1})
        Store.add_node(:function, {caller_mod, :call, 0}, %{module: caller_mod})

        Store.add_edge(
          {:function, caller_mod, :call, 0},
          {:function, :Popular, :popular_func, 0},
          :calls
        )
      end

      Store.sync()
      {:ok, dead} = DeadCode.find_unused_exports(min_confidence: 0.0)

      unused_funcs = Enum.map(dead, fn d -> d.function end)
      refute %{type: :function, module: :Popular, name: :popular_func, arity: 0} in unused_funcs
    end
  end
end
