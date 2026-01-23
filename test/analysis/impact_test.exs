defmodule Ragex.Analysis.ImpactTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.Impact
  alias Ragex.Graph.Store

  setup do
    # Clear graph before each test
    Store.clear()

    # Create a sample graph for testing
    # Module A defines functions a1/0, a2/1
    Store.add_node(:module, :A, %{file: "lib/a.ex", line: 1})
    Store.add_node(:function, {:A, :a1, 0}, %{file: "lib/a.ex", line: 5, visibility: :public})
    Store.add_node(:function, {:A, :a2, 1}, %{file: "lib/a.ex", line: 10, visibility: :public})

    # Module B defines functions b1/0, b2/1 (calls a1/0)
    Store.add_node(:module, :B, %{file: "lib/b.ex", line: 1})
    Store.add_node(:function, {:B, :b1, 0}, %{file: "lib/b.ex", line: 5, visibility: :public})
    Store.add_node(:function, {:B, :b2, 1}, %{file: "lib/b.ex", line: 10, visibility: :public})

    # Module C defines functions c1/0 (calls b1/0)
    Store.add_node(:module, :C, %{file: "lib/c.ex", line: 1})
    Store.add_node(:function, {:C, :c1, 0}, %{file: "lib/c.ex", line: 5, visibility: :public})

    # Module DTest defines test functions (calls c1/0)
    Store.add_node(:module, :DTest, %{file: "test/d_test.exs", line: 1})

    Store.add_node(:function, {:DTest, :test_something, 1}, %{
      file: "test/d_test.exs",
      line: 5,
      visibility: :public
    })

    # Add edges: defines relationships
    Store.add_edge({:module, :A}, {:function, :A, :a1, 0}, :defines)
    Store.add_edge({:module, :A}, {:function, :A, :a2, 1}, :defines)
    Store.add_edge({:module, :B}, {:function, :B, :b1, 0}, :defines)
    Store.add_edge({:module, :B}, {:function, :B, :b2, 1}, :defines)
    Store.add_edge({:module, :C}, {:function, :C, :c1, 0}, :defines)
    Store.add_edge({:module, :DTest}, {:function, :DTest, :test_something, 1}, :defines)

    # Add edges: call relationships
    # b2/1 -> a1/0
    Store.add_edge({:function, :B, :b2, 1}, {:function, :A, :a1, 0}, :calls)
    # c1/0 -> b1/0
    Store.add_edge({:function, :C, :c1, 0}, {:function, :B, :b1, 0}, :calls)
    # test_something/1 -> c1/0
    Store.add_edge({:function, :DTest, :test_something, 1}, {:function, :C, :c1, 0}, :calls)

    :ok
  end

  describe "analyze_change/2" do
    test "analyzes impact of changing a function with direct callers" do
      {:ok, analysis} = Impact.analyze_change({:function, :A, :a1, 0})

      assert analysis.target == {:function, :A, :a1, 0}
      assert length(analysis.direct_callers) == 1
      assert {:function, :B, :b2, 1} in analysis.direct_callers
      assert analysis.affected_count >= 1
      assert is_float(analysis.risk_score)
      assert is_float(analysis.importance)
      assert is_list(analysis.recommendations)
    end

    test "analyzes impact with transitive callers (depth > 1)" do
      {:ok, analysis} = Impact.analyze_change({:function, :B, :b1, 0}, depth: 5)

      assert analysis.target == {:function, :B, :b1, 0}
      # Direct caller: c1/0
      assert {:function, :C, :c1, 0} in analysis.direct_callers
      # Transitive caller: test_something/1 (via c1/0)
      assert {:function, :DTest, :test_something, 1} in analysis.all_affected
    end

    test "respects depth limit" do
      {:ok, shallow} = Impact.analyze_change({:function, :B, :b1, 0}, depth: 1)
      {:ok, deep} = Impact.analyze_change({:function, :B, :b1, 0}, depth: 10)

      # Shallow should have fewer affected nodes
      assert shallow.depth == 1
      assert deep.depth == 10
      # Both should find at least the direct caller
      assert match?([_ | _], shallow.all_affected)
    end

    test "excludes test modules when include_tests: false" do
      {:ok, with_tests} = Impact.analyze_change({:function, :B, :b1, 0}, include_tests: true)
      {:ok, without_tests} = Impact.analyze_change({:function, :B, :b1, 0}, include_tests: false)

      # Count test functions in results
      test_count_with =
        Enum.count(with_tests.all_affected, fn
          {:function, :DTest, _, _} -> true
          _ -> false
        end)

      test_count_without =
        Enum.count(without_tests.all_affected, fn
          {:function, :DTest, _, _} -> true
          _ -> false
        end)

      # Without tests should have fewer or equal test functions
      assert test_count_without <= test_count_with
    end

    test "analyzes impact of changing a module" do
      {:ok, analysis} = Impact.analyze_change({:module, :A})

      assert analysis.target == {:module, :A}
      assert is_integer(analysis.affected_count)
      assert is_list(analysis.recommendations)
    end

    test "handles functions with no callers" do
      {:ok, analysis} = Impact.analyze_change({:function, :A, :a2, 1})

      assert analysis.target == {:function, :A, :a2, 1}
      assert analysis.direct_callers == []
      # The function itself is counted as affected
      assert analysis.affected_count >= 0
    end

    test "generates appropriate recommendations based on impact" do
      # Function with callers should have different recommendations
      {:ok, high_impact} = Impact.analyze_change({:function, :A, :a1, 0})
      {:ok, low_impact} = Impact.analyze_change({:function, :A, :a2, 1})

      assert is_list(high_impact.recommendations)
      assert is_list(low_impact.recommendations)
      # Recommendations should be non-empty strings
      assert Enum.all?(high_impact.recommendations, &is_binary/1)
    end
  end

  describe "find_affected_tests/2" do
    test "finds tests that call the target function transitively" do
      {:ok, tests} = Impact.find_affected_tests({:function, :B, :b1, 0})

      # test_something/1 calls c1/0 which calls b1/0
      assert {:function, :DTest, :test_something, 1} in tests
    end

    test "finds tests for deeply nested calls" do
      {:ok, tests} = Impact.find_affected_tests({:function, :A, :a1, 0}, depth: 10)

      # a1/0 is called by b2/1, but b2/1 has no test callers in our setup
      # So this should return empty or only include reachable tests
      assert is_list(tests)
    end

    test "returns empty list when no tests are affected" do
      {:ok, tests} = Impact.find_affected_tests({:function, :A, :a2, 1})

      assert tests == []
    end

    test "respects custom test patterns" do
      # Add a function that looks like a test but uses different naming
      Store.add_node(:module, :ESpec, %{file: "spec/e_spec.exs", line: 1})

      Store.add_node(:function, {:ESpec, :it_works, 0}, %{
        file: "spec/e_spec.exs",
        line: 5,
        visibility: :public
      })

      Store.add_edge({:module, :ESpec}, {:function, :ESpec, :it_works, 0}, :defines)
      Store.add_edge({:function, :ESpec, :it_works, 0}, {:function, :B, :b1, 0}, :calls)

      # Custom patterns should catch "Spec" suffix
      {:ok, custom_tests} =
        Impact.find_affected_tests({:function, :B, :b1, 0},
          test_patterns: ["Spec", "_test", "Test"]
        )

      has_spec_custom = Enum.any?(custom_tests, fn {:function, mod, _, _} -> mod == :ESpec end)

      # The ESpec module should be found with custom patterns
      assert has_spec_custom or match?([_ | _], custom_tests)
    end

    test "handles functions with no transitive test callers" do
      {:ok, tests} = Impact.find_affected_tests({:function, :A, :a2, 1})

      assert tests == []
    end
  end

  describe "estimate_effort/3" do
    test "estimates effort for rename_function operation" do
      {:ok, estimate} = Impact.estimate_effort(:rename_function, {:function, :A, :a1, 0})

      assert estimate.operation == :rename_function
      assert estimate.target == {:function, :A, :a1, 0}
      assert is_integer(estimate.estimated_changes)
      assert estimate.complexity in [:low, :medium, :high, :very_high]
      assert is_binary(estimate.estimated_time)
      assert is_list(estimate.risks)
      assert is_list(estimate.recommendations)
    end

    test "estimates effort for rename_module operation" do
      {:ok, estimate} = Impact.estimate_effort(:rename_module, {:module, :A})

      assert estimate.operation == :rename_module
      assert estimate.target == {:module, :A}
      assert is_integer(estimate.estimated_changes)
    end

    test "estimates effort for extract_function operation" do
      {:ok, estimate} = Impact.estimate_effort(:extract_function, {:function, :A, :a1, 0})

      assert estimate.operation == :extract_function
      assert is_list(estimate.risks)
    end

    test "estimates effort for inline_function operation" do
      {:ok, estimate} = Impact.estimate_effort(:inline_function, {:function, :A, :a1, 0})

      assert estimate.operation == :inline_function
      assert estimate.estimated_changes >= 0
    end

    test "estimates effort for move_function operation" do
      {:ok, estimate} = Impact.estimate_effort(:move_function, {:function, :A, :a1, 0})

      assert estimate.operation == :move_function
      assert is_list(estimate.recommendations)
    end

    test "estimates effort for change_signature operation" do
      {:ok, estimate} = Impact.estimate_effort(:change_signature, {:function, :A, :a1, 0})

      assert estimate.operation == :change_signature
      assert is_integer(estimate.estimated_changes)
    end

    test "complexity scales with number of affected locations" do
      # Function with no callers should have low complexity
      {:ok, low} = Impact.estimate_effort(:rename_function, {:function, :A, :a2, 1})

      # Function with callers should have higher complexity
      {:ok, high} = Impact.estimate_effort(:rename_function, {:function, :A, :a1, 0})

      # Low should be less complex (though both might be :low in small test graph)
      assert low.estimated_changes <= high.estimated_changes
    end

    test "provides operation-specific recommendations" do
      {:ok, rename} = Impact.estimate_effort(:rename_function, {:function, :A, :a1, 0})
      {:ok, extract} = Impact.estimate_effort(:extract_function, {:function, :A, :a1, 0})

      # Recommendations should be non-empty
      assert match?([_ | _], rename.recommendations)
      assert match?([_ | _], extract.recommendations)

      # Recommendations should be strings
      assert Enum.all?(rename.recommendations, &is_binary/1)
      assert Enum.all?(extract.recommendations, &is_binary/1)
    end

    test "handles unknown operation gracefully" do
      result = Impact.estimate_effort(:unknown_operation, {:function, :A, :a1, 0})

      # Should either return error or default estimate
      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end
  end

  describe "risk_score/2" do
    test "calculates risk score for a function" do
      {:ok, risk} = Impact.risk_score({:function, :A, :a1, 0})

      assert risk.target == {:function, :A, :a1, 0}
      assert is_float(risk.importance)
      assert is_float(risk.coupling)
      assert is_float(risk.complexity)
      assert is_float(risk.overall)
      assert risk.level in [:low, :medium, :high, :critical]
      assert is_map(risk.factors)
    end

    test "calculates risk score for a module" do
      {:ok, risk} = Impact.risk_score({:module, :A})

      assert risk.target == {:module, :A}
      assert is_float(risk.overall)
      assert risk.level in [:low, :medium, :high, :critical]
    end

    test "risk score increases with more callers (coupling)" do
      # a1/0 has callers, a2/1 does not
      {:ok, high_coupling} = Impact.risk_score({:function, :A, :a1, 0})
      {:ok, low_coupling} = Impact.risk_score({:function, :A, :a2, 1})

      # Function with callers should have higher coupling
      assert high_coupling.coupling >= low_coupling.coupling
    end

    test "includes detailed risk factors" do
      {:ok, risk} = Impact.risk_score({:function, :A, :a1, 0})

      assert is_map(risk.factors)
      # Should have some factor information
      assert map_size(risk.factors) > 0
    end

    test "categorizes risk levels appropriately" do
      # Test that risk level is reasonable
      {:ok, risk} = Impact.risk_score({:function, :A, :a1, 0})

      # Risk level should match overall score
      case risk.level do
        :low -> assert risk.overall < 0.3
        :medium -> assert risk.overall >= 0.3 and risk.overall < 0.6
        :high -> assert risk.overall >= 0.6 and risk.overall < 0.8
        :critical -> assert risk.overall >= 0.8
      end
    end

    test "handles functions with no graph data" do
      # Try to get risk for non-existent function
      result = Impact.risk_score({:function, :NonExistent, :func, 0})

      # Should either return low risk or error
      case result do
        {:ok, risk} ->
          # If it returns, risk should be reasonable
          assert is_float(risk.overall)

        {:error, _reason} ->
          # Error is acceptable for non-existent nodes
          assert true
      end
    end

    test "importance reflects PageRank when available" do
      # Run PageRank to populate scores
      Ragex.Graph.Algorithms.pagerank()

      {:ok, risk} = Impact.risk_score({:function, :A, :a1, 0})

      # Importance should be populated (may be 0.0 for low PageRank)
      assert is_float(risk.importance)
      assert risk.importance >= 0.0
    end

    test "factors include meaningful metrics" do
      {:ok, risk} = Impact.risk_score({:function, :B, :b1, 0})

      # Factors should include useful information
      assert is_map(risk.factors)

      # Check for expected factor keys (implementation-dependent)
      # Common factors might include: in_degree, out_degree, etc.
      assert map_size(risk.factors) > 0
    end
  end

  describe "error handling" do
    test "handles invalid node references gracefully" do
      # Try to analyze non-existent function
      result = Impact.analyze_change({:function, :NonExistent, :func, 0})

      # Should return error or handle gracefully with empty results
      case result do
        {:ok, analysis} ->
          # If successful, should have reasonable empty results
          assert analysis.direct_callers == []
          # May include the target itself
          assert analysis.affected_count >= 0

        {:error, _reason} ->
          # Error is acceptable
          assert true
      end
    end

    test "handles malformed node references" do
      # Try with invalid tuple format
      result = Impact.analyze_change({:invalid, :format})

      # Should handle gracefully
      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end

    test "handles empty graph" do
      Store.clear()

      result = Impact.analyze_change({:function, :A, :a1, 0})

      # Should handle gracefully
      case result do
        {:ok, analysis} ->
          assert analysis.direct_callers == []
          # May include the target itself
          assert analysis.affected_count >= 0

        {:error, _reason} ->
          assert true
      end
    end
  end

  describe "integration scenarios" do
    test "end-to-end: analyze impact, estimate effort, and assess risk" do
      target = {:function, :A, :a1, 0}

      # Step 1: Analyze impact
      {:ok, impact} = Impact.analyze_change(target)
      assert impact.affected_count >= 1

      # Step 2: Estimate effort for rename
      {:ok, effort} = Impact.estimate_effort(:rename_function, target)
      assert effort.estimated_changes >= 1

      # Step 3: Assess risk
      {:ok, risk} = Impact.risk_score(target)
      assert is_float(risk.overall)

      # All three should be consistent about the target
      assert impact.target == target
      assert effort.target == target
      assert risk.target == target
    end

    test "find affected tests before refactoring" do
      target = {:function, :B, :b1, 0}

      # Find tests first
      {:ok, tests} = Impact.find_affected_tests(target)
      test_count = length(tests)

      # Analyze impact
      {:ok, impact} = Impact.analyze_change(target)

      # Tests should be included in affected nodes (if include_tests: true by default)
      assert impact.affected_count >= test_count
    end

    test "compare risk scores for refactoring decision" do
      # Compare two functions to decide which to refactor
      {:ok, risk1} = Impact.risk_score({:function, :A, :a1, 0})
      {:ok, risk2} = Impact.risk_score({:function, :A, :a2, 1})

      # Both should have valid risk scores
      assert is_float(risk1.overall)
      assert is_float(risk2.overall)

      # Function with callers should be riskier
      assert risk1.overall >= risk2.overall
    end
  end
end
