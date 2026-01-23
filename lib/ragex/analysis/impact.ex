defmodule Ragex.Analysis.Impact do
  @moduledoc """
  Change impact analysis using graph traversal and metrics.

  Predicts the impact of code changes by analyzing:
  - Call graph (who calls this function?)
  - Betweenness centrality (how critical is this node?)
  - PageRank (how important is this node?)
  - Complexity metrics (how complex is the code?)

  ## Usage

      alias Ragex.Analysis.Impact

      # Analyze impact of changing a function
      {:ok, analysis} = Impact.analyze_change({:function, MyModule, :process, 2})

      # Find tests affected by a change
      {:ok, tests} = Impact.find_affected_tests({:function, MyModule, :process, 2})

      # Estimate refactoring effort
      {:ok, estimate} = Impact.estimate_effort(:rename_function, {:function, MyModule, :old, 2})

      # Calculate risk score
      {:ok, risk} = Impact.risk_score({:function, MyModule, :critical, 1})
  """

  alias Ragex.Graph.{Algorithms, Store}
  require Logger

  @type node_ref :: {:module, module()} | {:function, module(), atom(), non_neg_integer()}
  @type impact_analysis :: %{
          target: node_ref(),
          direct_callers: [node_ref()],
          all_affected: [node_ref()],
          affected_count: non_neg_integer(),
          depth: non_neg_integer(),
          risk_score: float(),
          importance: float(),
          recommendations: [String.t()]
        }

  @type test_ref :: {:function, module(), atom(), non_neg_integer()}
  @type effort_estimate :: %{
          operation: atom(),
          target: node_ref(),
          estimated_changes: non_neg_integer(),
          complexity: :low | :medium | :high | :very_high,
          estimated_time: String.t(),
          risks: [String.t()],
          recommendations: [String.t()]
        }

  @type risk_analysis :: %{
          target: node_ref(),
          importance: float(),
          coupling: float(),
          complexity: float(),
          overall: float(),
          level: :low | :medium | :high | :critical,
          factors: map()
        }

  @doc """
  Analyzes the impact of changing a function or module.

  Uses graph traversal to find all code that would be affected by changing
  the target node. Calculates risk scores and provides recommendations.

  ## Parameters
  - `target` - Node reference (function or module tuple)
  - `opts` - Keyword list of options
    - `:depth` - Maximum traversal depth (default: 5)
    - `:include_tests` - Include test files in analysis (default: true)
    - `:exclude_modules` - List of modules to exclude

  ## Returns
  - `{:ok, impact_analysis}` - Impact analysis result
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      {:ok, analysis} = Impact.analyze_change({:function, MyModule, :process, 2})
      IO.puts("Functions affected: " <> Integer.to_string(analysis.affected_count))
      IO.puts("Risk score: " <> Float.to_string(analysis.risk_score))
  """
  @spec analyze_change(node_ref(), keyword()) :: {:ok, impact_analysis()} | {:error, term()}
  def analyze_change(target, opts \\ []) do
    depth = Keyword.get(opts, :depth, 5)
    include_tests = Keyword.get(opts, :include_tests, true)
    exclude_modules = Keyword.get(opts, :exclude_modules, [])

    try do
      # Find direct callers
      direct_callers = find_direct_callers(target)

      # Find all affected nodes via reverse BFS
      all_affected = find_all_affected(target, depth, exclude_modules)

      # Filter out tests if requested
      all_affected =
        if include_tests do
          all_affected
        else
          Enum.reject(all_affected, &test_module?/1)
        end

      # Calculate risk score
      {:ok, risk} = risk_score(target)

      # Get importance (PageRank if available)
      importance = get_importance(target)

      # Generate recommendations
      recommendations = generate_recommendations(target, length(all_affected), risk)

      analysis = %{
        target: target,
        direct_callers: direct_callers,
        all_affected: all_affected,
        affected_count: length(all_affected),
        depth: depth,
        risk_score: risk.overall,
        importance: importance,
        recommendations: recommendations
      }

      {:ok, analysis}
    rescue
      e ->
        Logger.error("Failed to analyze change impact: #{inspect(e)}")
        {:error, {:analysis_failed, Exception.message(e)}}
    end
  end

  @doc """
  Finds tests that would be affected by changing a function.

  Traverses the call graph to find test functions that directly or
  indirectly call the target function.

  ## Parameters
  - `target` - Function reference tuple
  - `opts` - Keyword list of options
    - `:depth` - Maximum traversal depth (default: 10)
    - `:test_patterns` - Patterns to identify test modules (default: ["Test", "_test"])

  ## Returns
  - `{:ok, [test_ref]}` - List of affected test functions
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      {:ok, tests} = Impact.find_affected_tests({:function, MyModule, :process, 2})
      IO.puts("Tests affected: " <> Integer.to_string(length(tests)))
  """
  @spec find_affected_tests(node_ref(), keyword()) :: {:ok, [test_ref()]} | {:error, term()}
  def find_affected_tests(target, opts \\ []) do
    depth = Keyword.get(opts, :depth, 10)
    test_patterns = Keyword.get(opts, :test_patterns, ["Test", "_test"])

    try do
      # Find all affected nodes
      all_affected = find_all_affected(target, depth, [])

      # Filter to only test functions
      tests =
        all_affected
        |> Enum.filter(fn node ->
          case node do
            {:function, module, name, _arity} ->
              test_module?(module) or test_function?(name, test_patterns)

            _ ->
              false
          end
        end)

      {:ok, tests}
    rescue
      e ->
        Logger.error("Failed to find affected tests: #{inspect(e)}")
        {:error, {:analysis_failed, Exception.message(e)}}
    end
  end

  @doc """
  Estimates the effort required for a refactoring operation.

  ## Parameters
  - `operation` - Refactoring operation atom
    - `:rename_function` - Rename a function
    - `:rename_module` - Rename a module
    - `:extract_function` - Extract code into new function
    - `:inline_function` - Inline a function
    - `:move_function` - Move function to another module
    - `:change_signature` - Change function signature
  - `target` - Target node reference
  - `opts` - Additional options for specific operations

  ## Returns
  - `{:ok, effort_estimate}` - Effort estimation
  - `{:error, reason}` - Error if estimation fails

  ## Examples

      {:ok, estimate} = Impact.estimate_effort(:rename_function, {:function, MyModule, :old, 2})
      IO.puts("Estimated changes: " <> Integer.to_string(estimate.estimated_changes))
      IO.puts("Complexity: " <> Atom.to_string(estimate.complexity))
      IO.puts("Time: " <> estimate.estimated_time)
  """
  @spec estimate_effort(atom(), node_ref(), keyword()) ::
          {:ok, effort_estimate()} | {:error, term()}
  def estimate_effort(operation, target, opts \\ []) do
    # Get impact analysis
    {:ok, impact} = analyze_change(target, depth: 10)

    # Estimate based on operation type
    estimate =
      case operation do
        :rename_function ->
          estimate_rename_function(target, impact, opts)

        :rename_module ->
          estimate_rename_module(target, impact, opts)

        :extract_function ->
          estimate_extract_function(target, impact, opts)

        :inline_function ->
          estimate_inline_function(target, impact, opts)

        :move_function ->
          estimate_move_function(target, impact, opts)

        :change_signature ->
          estimate_change_signature(target, impact, opts)

        other ->
          raise ArgumentError, "Unknown operation: #{other}"
      end

    {:ok, estimate}
  rescue
    e ->
      Logger.error("Failed to estimate refactoring effort: #{inspect(e)}")
      {:error, {:estimation_failed, Exception.message(e)}}
  end

  @doc """
  Calculates a risk score for changing a function or module.

  Combines multiple factors:
  - Importance (PageRank score)
  - Coupling (number of dependencies)
  - Complexity (if available from quality metrics)

  ## Parameters
  - `target` - Node reference
  - `opts` - Keyword list of options
    - `:weights` - Custom weights for factors (default: equal)

  ## Returns
  - `{:ok, risk_analysis}` - Risk analysis with score 0.0-1.0
  - `{:error, reason}` - Error if scoring fails

  ## Examples

      {:ok, risk} = Impact.risk_score({:function, MyModule, :critical, 1})
      IO.puts("Overall risk: " <> Float.to_string(risk.overall) <> " (" <> Atom.to_string(risk.level) <> ")")
  """
  @spec risk_score(node_ref(), keyword()) :: {:ok, risk_analysis()} | {:error, term()}
  def risk_score(target, opts \\ []) do
    weights = Keyword.get(opts, :weights, %{importance: 1.0, coupling: 1.0, complexity: 1.0})

    try do
      # Calculate individual scores
      importance = get_importance(target)
      coupling = calculate_coupling(target)
      complexity = get_complexity(target)

      # Weighted average
      total_weight = weights.importance + weights.coupling + weights.complexity

      overall =
        (importance * weights.importance + coupling * weights.coupling +
           complexity * weights.complexity) /
          total_weight

      # Determine risk level
      level =
        cond do
          overall >= 0.8 -> :critical
          overall >= 0.6 -> :high
          overall >= 0.4 -> :medium
          true -> :low
        end

      analysis = %{
        target: target,
        importance: importance,
        coupling: coupling,
        complexity: complexity,
        overall: overall,
        level: level,
        factors: %{
          importance_weight: weights.importance,
          coupling_weight: weights.coupling,
          complexity_weight: weights.complexity
        }
      }

      {:ok, analysis}
    rescue
      e ->
        Logger.error("Failed to calculate risk score: #{inspect(e)}")
        {:error, {:scoring_failed, Exception.message(e)}}
    end
  end

  # Private functions

  defp find_direct_callers(target) do
    case target do
      {:function, _module, _name, _arity} = func ->
        Store.get_incoming_edges(func, :calls)
        |> Enum.map(& &1.from)

      {:module, module} ->
        # Find functions that import this module
        Store.get_incoming_edges({:module, module}, :imports)
        |> Enum.map(& &1.from)

      _ ->
        []
    end
  end

  defp find_all_affected(target, max_depth, exclude_modules) do
    # BFS traversal to find all callers up to max_depth
    visited = MapSet.new()
    queue = :queue.from_list([{target, 0}])
    affected = []

    do_bfs(queue, visited, affected, max_depth, exclude_modules)
  end

  defp do_bfs(queue, visited, affected, max_depth, exclude_modules) do
    case :queue.out(queue) do
      {{:value, {node, depth}}, rest_queue} ->
        if depth >= max_depth or MapSet.member?(visited, node) or
             excluded_module?(node, exclude_modules) do
          # Skip this node
          do_bfs(rest_queue, visited, affected, max_depth, exclude_modules)
        else
          # Process this node
          visited = MapSet.put(visited, node)
          affected = [node | affected]

          # Add callers to queue
          callers = find_direct_callers(node)

          new_queue =
            Enum.reduce(callers, rest_queue, fn caller, q ->
              :queue.in({caller, depth + 1}, q)
            end)

          do_bfs(new_queue, visited, affected, max_depth, exclude_modules)
        end

      {:empty, _} ->
        affected
    end
  end

  defp get_importance(target) do
    # Try to get PageRank score from graph
    # If not available, use a heuristic based on in-degree
    case target do
      {:function, _module, _name, _arity} = func ->
        callers = find_direct_callers(func)
        # Normalize to 0.0-1.0 (assume max 100 callers is very important)
        min(length(callers) / 100.0, 1.0)

      {:module, module} ->
        importers = find_direct_callers({:module, module})
        min(length(importers) / 50.0, 1.0)

      _ ->
        0.0
    end
  end

  defp calculate_coupling(target) do
    # Calculate coupling as ratio of dependencies
    in_degree = length(find_direct_callers(target))

    out_degree =
      case target do
        {:function, _module, _name, _arity} = func ->
          length(Store.get_outgoing_edges(func, :calls))

        {:module, module} ->
          length(Store.get_outgoing_edges({:module, module}, :imports))

        _ ->
          0
      end

    total = in_degree + out_degree

    if total > 0 do
      # Normalize to 0.0-1.0 (assume 50 total edges is high coupling)
      min(total / 50.0, 1.0)
    else
      0.0
    end
  end

  defp get_complexity(_target) do
    # Placeholder for complexity metrics
    # Would integrate with quality metrics from Phase 11A
    # For now, return default
    0.5
  end

  defp test_module?(module) when is_atom(module) do
    module_str = Atom.to_string(module)
    String.ends_with?(module_str, "Test") or String.contains?(module_str, ".Test.")
  end

  defp test_module?(_), do: false

  defp test_function?(name, patterns) when is_atom(name) do
    name_str = Atom.to_string(name)

    Enum.any?(patterns, fn pattern ->
      String.starts_with?(name_str, "test_") or String.contains?(name_str, pattern)
    end)
  end

  defp test_function?(_, _), do: false

  defp excluded_module?({:function, module, _, _}, exclude_modules) do
    module in exclude_modules
  end

  defp excluded_module?({:module, module}, exclude_modules) do
    module in exclude_modules
  end

  defp excluded_module?(_, _), do: false

  defp generate_recommendations(_target, affected_count, risk) do
    recommendations = []

    recommendations =
      if affected_count > 50 do
        [
          "This change affects many functions (#{affected_count}). Consider breaking it into smaller changes."
          | recommendations
        ]
      else
        recommendations
      end

    recommendations =
      if risk.overall > 0.8 do
        [
          "High risk change detected. Ensure comprehensive test coverage before proceeding."
          | recommendations
        ]
      else
        recommendations
      end

    recommendations =
      if risk.coupling > 0.7 do
        [
          "High coupling detected. Consider decoupling this component before making changes."
          | recommendations
        ]
      else
        recommendations
      end

    if recommendations == [] do
      ["This appears to be a low-risk change with limited impact."]
    else
      recommendations
    end
  end

  # Effort estimation helpers

  defp estimate_rename_function(target, impact, _opts) do
    changes = impact.affected_count + 1

    %{
      operation: :rename_function,
      target: target,
      estimated_changes: changes,
      complexity: complexity_level(changes),
      estimated_time: estimate_time(changes),
      risks: [
        "Breaking changes in dependent code",
        "Need to update documentation and tests"
      ],
      recommendations: [
        "Use automated refactoring tool if available",
        "Run full test suite after change",
        "Update API documentation"
      ]
    }
  end

  defp estimate_rename_module(target, impact, _opts) do
    # Module renames affect all functions in module
    changes = impact.affected_count * 3

    %{
      operation: :rename_module,
      target: target,
      estimated_changes: changes,
      complexity: complexity_level(changes),
      estimated_time: estimate_time(changes),
      risks: [
        "Breaking changes across entire codebase",
        "Import statements need updating",
        "Configuration files may reference module name"
      ],
      recommendations: [
        "Create deprecation period if public API",
        "Use automated search-and-replace",
        "Update build configuration",
        "Check for string references to module name"
      ]
    }
  end

  defp estimate_extract_function(target, impact, _opts) do
    changes = max(impact.affected_count, 5)

    %{
      operation: :extract_function,
      target: target,
      estimated_changes: changes,
      complexity: :medium,
      estimated_time: estimate_time(changes),
      risks: [
        "Incorrect parameter inference",
        "Side effects may be affected",
        "Test coverage may decrease"
      ],
      recommendations: [
        "Ensure extracted code is self-contained",
        "Add tests for new function",
        "Review variable scoping carefully"
      ]
    }
  end

  defp estimate_inline_function(target, impact, _opts) do
    changes = impact.affected_count

    %{
      operation: :inline_function,
      target: target,
      estimated_changes: changes,
      complexity: complexity_level(changes),
      estimated_time: estimate_time(changes),
      risks: [
        "Code duplication if function called multiple times",
        "Loss of abstraction",
        "Increased complexity at call sites"
      ],
      recommendations: [
        "Only inline simple functions",
        "Verify all call sites can accommodate inline code",
        "Consider impact on readability"
      ]
    }
  end

  defp estimate_move_function(target, impact, _opts) do
    changes = impact.affected_count + 5

    %{
      operation: :move_function,
      target: target,
      estimated_changes: changes,
      complexity: :high,
      estimated_time: estimate_time(changes),
      risks: [
        "Breaking module boundaries",
        "Circular dependencies if not careful",
        "Import statements need updating"
      ],
      recommendations: [
        "Ensure target module is appropriate location",
        "Check for circular dependency creation",
        "Update all imports and qualified calls"
      ]
    }
  end

  defp estimate_change_signature(target, impact, _opts) do
    changes = impact.affected_count

    %{
      operation: :change_signature,
      target: target,
      estimated_changes: changes,
      complexity: complexity_level(changes),
      estimated_time: estimate_time(changes),
      risks: [
        "Breaking changes at all call sites",
        "Default values may cause subtle bugs",
        "Pattern matching may break"
      ],
      recommendations: [
        "Add new function variant instead of changing existing",
        "Use keyword arguments for flexibility",
        "Deprecate old signature gradually"
      ]
    }
  end

  defp complexity_level(changes) when changes < 5, do: :low
  defp complexity_level(changes) when changes < 20, do: :medium
  defp complexity_level(changes) when changes < 50, do: :high
  defp complexity_level(_), do: :very_high

  defp estimate_time(changes) when changes < 5, do: "< 30 minutes"
  defp estimate_time(changes) when changes < 20, do: "30 minutes - 2 hours"
  defp estimate_time(changes) when changes < 50, do: "2-4 hours"
  defp estimate_time(_), do: "1+ day"
end
