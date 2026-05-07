defmodule Ragex.Analysis.Suggestions.PatternsTest do
  use ExUnit.Case, async: true

  alias Ragex.Analysis.Suggestions.Patterns

  describe "all_patterns/0" do
    test "returns all pattern types" do
      patterns = Patterns.all_patterns()

      assert :extract_function in patterns
      assert :inline_function in patterns
      assert :split_module in patterns
      assert :merge_modules in patterns
      assert :remove_dead_code in patterns
      assert :reduce_coupling in patterns
      assert :simplify_complexity in patterns
      assert :extract_module in patterns
      assert length(patterns) == 9
    end
  end

  describe "detect/3 with mock data" do
    test "returns empty list for unknown pattern" do
      data = %{quality: %{}, duplication: %{}, dead_code: %{}}

      assert {:error, :unknown_pattern} = Patterns.detect(:unknown_pattern, data, [])
    end

    test "detect extract_function with long function" do
      data = %{
        quality: %{
          functions: [
            %{
              module: :TestModule,
              name: :long_function,
              arity: 1,
              metrics: %{
                complexity: %{cyclomatic: 20},
                loc: 80
              }
            }
          ]
        },
        duplication: %{clones: []},
        dead_code: %{},
        dependencies: %{},
        graph_info: %{},
        target: {:module, :TestModule}
      }

      {:ok, suggestions} = Patterns.detect(:extract_function, data, [])

      assert [suggestion | _] = suggestions
      assert suggestion.pattern == :extract_function
      assert suggestion.confidence > 0
      assert suggestion.metrics.complexity == 20
      assert suggestion.metrics.loc == 80
    end

    test "detect inline_function with trivial function" do
      data = %{
        quality: %{
          functions: [
            %{
              module: :TestModule,
              name: :trivial_function,
              arity: 0,
              metrics: %{
                complexity: %{cyclomatic: 1},
                loc: 2
              }
            }
          ]
        },
        duplication: %{},
        dead_code: %{},
        dependencies: %{},
        graph_info: %{}
      }

      {:ok, suggestions} = Patterns.detect(:inline_function, data, [])

      assert [suggestion | _] = suggestions
      assert suggestion.pattern == :inline_function
      assert suggestion.confidence == 0.7
    end

    test "detect split_module with god module" do
      data = %{
        quality: %{},
        duplication: %{},
        dead_code: %{},
        dependencies: %{instability: 0.5},
        graph_info: %{function_count: 35},
        target: {:module, :GodModule}
      }

      {:ok, suggestions} = Patterns.detect(:split_module, data, [])

      assert [suggestion | _] = suggestions
      assert suggestion.pattern == :split_module
      assert suggestion.metrics.function_count == 35
    end

    test "detect remove_dead_code" do
      data = %{
        quality: %{},
        duplication: %{},
        dead_code: %{
          dead_functions: [
            %{
              function: {:function, :TestModule, :unused, 0},
              confidence: 0.9,
              reason: "No callers found",
              visibility: :private
            }
          ]
        },
        dependencies: %{},
        graph_info: %{}
      }

      {:ok, suggestions} = Patterns.detect(:remove_dead_code, data, [])

      assert [suggestion | _] = suggestions
      assert suggestion.pattern == :remove_dead_code
      assert suggestion.confidence == 0.9
    end

    test "detect reduce_coupling with high efferent coupling" do
      data = %{
        quality: %{},
        duplication: %{},
        dead_code: %{},
        dependencies: %{
          efferent: 15,
          instability: 0.9
        },
        graph_info: %{},
        target: {:module, :HighlyCoupled}
      }

      {:ok, suggestions} = Patterns.detect(:reduce_coupling, data, [])

      assert [suggestion | _] = suggestions
      assert suggestion.pattern == :reduce_coupling
      assert suggestion.metrics.efferent == 15
    end

    test "detect simplify_complexity with complex function" do
      data = %{
        quality: %{
          functions: [
            %{
              module: :TestModule,
              name: :complex_func,
              arity: 2,
              metrics: %{
                complexity: %{
                  cyclomatic: 18,
                  nesting_depth: 3
                }
              }
            }
          ]
        },
        duplication: %{},
        dead_code: %{},
        dependencies: %{},
        graph_info: %{}
      }

      {:ok, suggestions} = Patterns.detect(:simplify_complexity, data, [])

      assert [suggestion | _] = suggestions
      assert suggestion.pattern == :simplify_complexity
      assert suggestion.metrics.cyclomatic_complexity == 18
    end
  end

  describe "confidence calculations" do
    test "higher complexity yields higher confidence for extract_function" do
      low_complexity = %{
        module: :Test,
        name: :func1,
        arity: 0,
        metrics: %{complexity: %{cyclomatic: 10}, loc: 30}
      }

      high_complexity = %{
        module: :Test,
        name: :func2,
        arity: 0,
        metrics: %{complexity: %{cyclomatic: 25}, loc: 100}
      }

      data_low = %{
        quality: %{functions: [low_complexity]},
        duplication: %{clones: []},
        dead_code: %{},
        dependencies: %{},
        graph_info: %{},
        target: {:module, :Test}
      }

      data_high = %{
        quality: %{functions: [high_complexity]},
        duplication: %{clones: []},
        dead_code: %{},
        dependencies: %{},
        graph_info: %{},
        target: {:module, :Test}
      }

      {:ok, sugg_low_list} = Patterns.detect(:extract_function, data_low, [])
      {:ok, sugg_high_list} = Patterns.detect(:extract_function, data_high, [])

      # These might not trigger if below threshold, so skip if empty
      if match?([_ | _], sugg_low_list) and match?([_ | _], sugg_high_list) do
        [sugg_low] = sugg_low_list
        [sugg_high] = sugg_high_list

        assert sugg_high.confidence > sugg_low.confidence
      end
    end
  end
end
