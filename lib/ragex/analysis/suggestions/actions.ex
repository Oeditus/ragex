defmodule Ragex.Analysis.Suggestions.Actions do
  @moduledoc """
  Generates actionable refactoring plans for suggestions.

  Creates step-by-step instructions for executing refactoring operations
  using existing MCP tools and validated workflows.

  Each action plan includes:
  - Ordered list of steps with tool invocations
  - Validation checks (syntax, tests)
  - Rollback procedures
  - Estimated time per step

  ## Usage

      alias Ragex.Analysis.Suggestions.Actions

      {:ok, plan} = Actions.generate_action_plan(suggestion)
      
      # Plan structure:
      # %{
      #   suggestion_id: "...",
      #   steps: [
      #     %{order: 1, action: "...", tool: "...", params: %{...}},
      #     ...
      #   ],
      #   validation: [...],
      #   rollback: [...]
      # }
  """

  require Logger

  @doc """
  Generates an action plan for a suggestion.

  ## Parameters
  - `suggestion` - Scored suggestion with pattern, target, and metrics

  ## Returns
  - `{:ok, action_plan}` - Executable action plan
  - `{:error, reason}` - Error if plan generation fails
  """
  @spec generate_action_plan(map()) :: {:ok, map()} | {:error, term()}
  def generate_action_plan(suggestion) do
    pattern = suggestion[:pattern]

    case pattern do
      :extract_function -> generate_extract_function_plan(suggestion)
      :inline_function -> generate_inline_function_plan(suggestion)
      :split_module -> generate_split_module_plan(suggestion)
      :merge_modules -> generate_merge_modules_plan(suggestion)
      :remove_dead_code -> generate_remove_dead_code_plan(suggestion)
      :reduce_coupling -> generate_reduce_coupling_plan(suggestion)
      :simplify_complexity -> generate_simplify_complexity_plan(suggestion)
      :extract_module -> generate_extract_module_plan(suggestion)
      _ -> {:error, :unsupported_pattern}
    end
  rescue
    e ->
      Logger.error("Failed to generate action plan: #{inspect(e)}")
      {:error, {:plan_generation_failed, Exception.message(e)}}
  end

  # Pattern-specific plan generators

  defp generate_extract_function_plan(suggestion) do
    target = suggestion[:target]

    steps =
      case target[:type] do
        :function ->
          [
            %{
              order: 1,
              action: "Analyze impact of extracting parts of this function",
              tool: "analyze_impact",
              params: %{
                module: target[:module],
                function: target[:function],
                arity: target[:arity]
              },
              estimated_time: "30 seconds"
            },
            %{
              order: 2,
              action: "Identify code blocks to extract (manual review needed)",
              tool: nil,
              params: %{},
              estimated_time: "5-10 minutes",
              notes: "Review function code and identify logical blocks that can be extracted"
            },
            %{
              order: 3,
              action: "Preview extraction with proposed function name",
              tool: "preview_refactor",
              params: %{
                operation: "extract_function",
                module: target[:module],
                source_function: target[:function],
                source_arity: target[:arity]
              },
              estimated_time: "1 minute"
            },
            %{
              order: 4,
              action: "Apply extraction refactoring",
              tool: "advanced_refactor",
              params: %{
                operation: "extract_function",
                module: target[:module],
                source_function: target[:function],
                source_arity: target[:arity],
                validate: true,
                format: true
              },
              estimated_time: "30 seconds"
            },
            %{
              order: 5,
              action: "Run tests",
              tool: nil,
              command: "mix test",
              estimated_time: "1-5 minutes"
            }
          ]

        :files ->
          [
            %{
              order: 1,
              action: "Review duplicate code in both files",
              tool: "find_duplicates",
              params: %{
                file1: target[:file1],
                file2: target[:file2]
              },
              estimated_time: "2 minutes"
            },
            %{
              order: 2,
              action: "Extract common code into shared module",
              tool: nil,
              params: %{},
              estimated_time: "10-20 minutes",
              notes: "Manual refactoring to create shared module"
            },
            %{
              order: 3,
              action: "Run tests",
              tool: nil,
              command: "mix test",
              estimated_time: "1-5 minutes"
            }
          ]

        _ ->
          []
      end

    {:ok, build_plan(suggestion, steps)}
  end

  defp generate_inline_function_plan(suggestion) do
    target = suggestion[:target]

    steps = [
      %{
        order: 1,
        action: "Analyze impact of inlining function",
        tool: "analyze_impact",
        params: %{
          module: target[:module],
          function: target[:function],
          arity: target[:arity]
        },
        estimated_time: "30 seconds"
      },
      %{
        order: 2,
        action: "Preview inline refactoring",
        tool: "preview_refactor",
        params: %{
          operation: "inline_function",
          module: target[:module],
          function: target[:function],
          arity: target[:arity]
        },
        estimated_time: "1 minute"
      },
      %{
        order: 3,
        action: "Apply inline refactoring",
        tool: "advanced_refactor",
        params: %{
          operation: "inline_function",
          module: target[:module],
          function: target[:function],
          arity: target[:arity],
          validate: true,
          format: true
        },
        estimated_time: "30 seconds"
      },
      %{
        order: 4,
        action: "Run tests",
        tool: nil,
        command: "mix test",
        estimated_time: "1-5 minutes"
      }
    ]

    {:ok, build_plan(suggestion, steps)}
  end

  defp generate_split_module_plan(suggestion) do
    target = suggestion[:target]

    steps = [
      %{
        order: 1,
        action: "Analyze module structure and dependencies",
        tool: "analyze_dependencies",
        params: %{module: target[:module]},
        estimated_time: "1 minute"
      },
      %{
        order: 2,
        action: "Detect natural module boundaries using community detection",
        tool: "detect_communities",
        params: %{},
        estimated_time: "30 seconds"
      },
      %{
        order: 3,
        action: "Plan module split (manual review needed)",
        tool: nil,
        params: %{},
        estimated_time: "15-30 minutes",
        notes: "Identify logical groups of functions and plan new module structure"
      },
      %{
        order: 4,
        action: "Create new modules and move functions",
        tool: nil,
        params: %{},
        estimated_time: "30-60 minutes",
        notes: "Manual refactoring to split module"
      },
      %{
        order: 5,
        action: "Run tests",
        tool: nil,
        command: "mix test",
        estimated_time: "1-5 minutes"
      }
    ]

    {:ok, build_plan(suggestion, steps)}
  end

  defp generate_merge_modules_plan(suggestion) do
    steps = [
      %{
        order: 1,
        action: "Analyze modules for similarity",
        tool: "find_similar_code",
        params: %{},
        estimated_time: "1 minute"
      },
      %{
        order: 2,
        action: "Plan module merge (manual review needed)",
        tool: nil,
        params: %{},
        estimated_time: "10-20 minutes",
        notes: "Review modules and plan merge strategy"
      },
      %{
        order: 3,
        action: "Merge modules",
        tool: nil,
        params: %{},
        estimated_time: "30-60 minutes",
        notes: "Manual refactoring to merge modules"
      }
    ]

    {:ok, build_plan(suggestion, steps)}
  end

  defp generate_remove_dead_code_plan(suggestion) do
    target = suggestion[:target]

    steps = [
      %{
        order: 1,
        action: "Verify function is truly unused",
        tool: "analyze_impact",
        params: %{
          module: target[:module],
          function: target[:function],
          arity: target[:arity]
        },
        estimated_time: "30 seconds"
      },
      %{
        order: 2,
        action: "Search for any dynamic calls or external references",
        tool: "query_graph",
        params: %{
          module: target[:module],
          function: target[:function]
        },
        estimated_time: "30 seconds"
      },
      %{
        order: 3,
        action: "Remove function definition",
        tool: "edit_file",
        params: %{
          validate: true,
          format: true
        },
        estimated_time: "1 minute",
        notes: "Remove the dead function and any related private helpers"
      },
      %{
        order: 4,
        action: "Run tests to ensure nothing broke",
        tool: nil,
        command: "mix test",
        estimated_time: "1-5 minutes"
      }
    ]

    {:ok, build_plan(suggestion, steps)}
  end

  defp generate_reduce_coupling_plan(suggestion) do
    target = suggestion[:target]

    steps = [
      %{
        order: 1,
        action: "Analyze coupling metrics",
        tool: "coupling_report",
        params: %{module: target[:module]},
        estimated_time: "1 minute"
      },
      %{
        order: 2,
        action: "Identify unnecessary dependencies",
        tool: "analyze_dependencies",
        params: %{module: target[:module]},
        estimated_time: "1 minute"
      },
      %{
        order: 3,
        action: "Plan dependency reduction strategy",
        tool: nil,
        params: %{},
        estimated_time: "15-30 minutes",
        notes: "Review dependencies and plan how to reduce coupling"
      },
      %{
        order: 4,
        action: "Refactor to reduce dependencies",
        tool: nil,
        params: %{},
        estimated_time: "1-3 hours",
        notes: "May involve introducing interfaces, dependency injection, or restructuring"
      },
      %{
        order: 5,
        action: "Run tests",
        tool: nil,
        command: "mix test",
        estimated_time: "1-5 minutes"
      }
    ]

    {:ok, build_plan(suggestion, steps)}
  end

  defp generate_simplify_complexity_plan(suggestion) do
    target = suggestion[:target]

    steps = [
      %{
        order: 1,
        action: "Analyze function complexity metrics",
        tool: "analyze_quality",
        params: %{
          module: target[:module],
          function: target[:function]
        },
        estimated_time: "30 seconds"
      },
      %{
        order: 2,
        action: "Identify complexity hotspots",
        tool: "find_complex_code",
        params: %{
          module: target[:module]
        },
        estimated_time: "30 seconds"
      },
      %{
        order: 3,
        action: "Plan simplification approach",
        tool: nil,
        params: %{},
        estimated_time: "10-15 minutes",
        notes: "Review code and identify: nested conditions, long functions, complex logic"
      },
      %{
        order: 4,
        action: "Apply refactoring (extract methods, simplify conditionals, etc.)",
        tool: nil,
        params: %{},
        estimated_time: "30-90 minutes",
        notes: "May involve multiple extract_function operations"
      },
      %{
        order: 5,
        action: "Run tests",
        tool: nil,
        command: "mix test",
        estimated_time: "1-5 minutes"
      }
    ]

    {:ok, build_plan(suggestion, steps)}
  end

  defp generate_extract_module_plan(suggestion) do
    steps = [
      %{
        order: 1,
        action: "Identify related functions across modules",
        tool: "find_similar_code",
        params: %{},
        estimated_time: "1 minute"
      },
      %{
        order: 2,
        action: "Plan new module structure",
        tool: nil,
        params: %{},
        estimated_time: "15-30 minutes",
        notes: "Review related functions and design new module"
      },
      %{
        order: 3,
        action: "Create new module and move functions",
        tool: nil,
        params: %{},
        estimated_time: "1-2 hours",
        notes: "Manual refactoring using move_function operations"
      }
    ]

    {:ok, build_plan(suggestion, steps)}
  end

  # Helper functions

  defp build_plan(suggestion, steps) do
    %{
      suggestion_id: suggestion[:id],
      pattern: suggestion[:pattern],
      steps: steps,
      total_steps: length(steps),
      estimated_total_time: estimate_total_time(steps),
      validation: build_validation_steps(suggestion),
      rollback: build_rollback_steps(suggestion)
    }
  end

  defp estimate_total_time(steps) do
    # Parse time estimates and sum them
    # Simplified: just count steps
    step_count = length(steps)

    case step_count do
      n when n <= 3 -> "15-30 minutes"
      n when n <= 5 -> "30-60 minutes"
      _ -> "1-2 hours"
    end
  end

  defp build_validation_steps(_suggestion) do
    [
      "Run mix format to ensure code is properly formatted",
      "Run mix test to ensure tests pass",
      "Run mix credo (if available) for code quality",
      "Review changed files for correctness"
    ]
  end

  defp build_rollback_steps(_suggestion) do
    [
      "Use undo_refactor MCP tool if recently applied",
      "Check refactor_history for rollback ID",
      "Or use git revert if changes were committed",
      "Or restore from editor backup in ~/.ragex/backups/"
    ]
  end

  @doc """
  Estimates the effort level for executing an action plan.

  Returns one of: :trivial, :easy, :moderate, :significant, :major
  """
  @spec estimate_effort_level(map()) :: :trivial | :easy | :moderate | :significant | :major
  def estimate_effort_level(plan) do
    step_count = plan[:total_steps] || 0
    has_manual_steps = Enum.any?(plan[:steps] || [], fn step -> is_nil(step[:tool]) end)

    cond do
      step_count <= 2 and not has_manual_steps -> :trivial
      step_count <= 3 -> :easy
      step_count <= 5 and not has_manual_steps -> :moderate
      step_count <= 5 -> :significant
      true -> :major
    end
  end

  @doc """
  Formats an action plan for display.

  Returns a human-readable string representation of the plan.
  """
  @spec format_plan(map()) :: String.t()
  def format_plan(plan) do
    steps_text =
      Enum.map_join(plan[:steps], "\n", fn step ->
        tool_text = if step[:tool], do: " [#{step[:tool]}]", else: ""
        "  #{step[:order]}. #{step[:action]}#{tool_text} (#{step[:estimated_time]})"
      end)

    """
    Action Plan for #{plan[:pattern]} (#{plan[:total_steps]} steps)
    Estimated Time: #{plan[:estimated_total_time]}

    Steps:
    #{steps_text}

    Validation:
    #{Enum.map_join(plan[:validation], "\n", fn v -> "  - #{v}" end)}

    Rollback Options:
    #{Enum.map_join(plan[:rollback], "\n", fn r -> "  - #{r}" end)}
    """
  end
end
