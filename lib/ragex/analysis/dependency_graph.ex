defmodule Ragex.Analysis.DependencyGraph do
  @moduledoc """
  Dependency analysis for module and function relationships.

  Analyzes the dependency graph stored in the knowledge graph to:
  - Detect circular dependencies
  - Calculate coupling metrics (afferent, efferent, instability)
  - Find unused modules
  - Identify God modules (high coupling)
  - Suggest decoupling opportunities

  All analysis operates on the existing knowledge graph edges (`:calls`, `:imports`).
  """

  alias Ragex.Graph.Store
  require Logger

  @type module_name :: atom()
  @type function_ref :: {:function, module(), atom(), non_neg_integer()}
  @type coupling_metrics :: %{
          afferent: non_neg_integer(),
          efferent: non_neg_integer(),
          instability: float()
        }
  @type suggestion :: %{
          type: atom(),
          severity: :low | :medium | :high,
          description: String.t(),
          entities: [term()],
          metadata: map()
        }

  # Cycle Detection

  @doc """
  Finds circular dependencies in the module dependency graph.

  Returns a list of cycles, where each cycle is a list of module names forming a circular dependency.
  Uses depth-first search to detect cycles.

  ## Parameters
  - `opts`: Keyword list of options
    - `:min_cycle_length` - Minimum cycle length (default: 2)
    - `:scope` - `:module` or `:function` (default: `:module`)
    - `:limit` - Maximum number of cycles to return (default: 100)

  ## Returns
  - `{:ok, [cycle]}` - List of cycles found
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      # Find all module-level cycles
      {:ok, cycles} = find_cycles()

      # Find function-level cycles (minimum length 3)
      {:ok, cycles} = find_cycles(scope: :function, min_cycle_length: 3)
  """
  @spec find_cycles(keyword()) :: {:ok, [[module_name() | function_ref()]]} | {:error, term()}
  def find_cycles(opts \\ []) do
    scope = Keyword.get(opts, :scope, :module)
    min_length = Keyword.get(opts, :min_cycle_length, 2)
    limit = Keyword.get(opts, :limit, 100)

    try do
      # Build adjacency list based on scope
      adjacency = build_dependency_adjacency(scope)

      # Find all cycles using DFS
      nodes = Map.keys(adjacency)
      cycles = find_all_cycles(nodes, adjacency, min_length, limit)

      {:ok, cycles}
    rescue
      e ->
        Logger.error("Failed to detect cycles: #{inspect(e)}")
        {:error, {:analysis_failed, Exception.message(e)}}
    end
  end

  # Coupling Metrics

  @doc """
  Calculates coupling metrics for a module.

  Coupling metrics:
  - **Afferent coupling (Ca)**: Number of modules that depend on this module (incoming)
  - **Efferent coupling (Ce)**: Number of modules this module depends on (outgoing)
  - **Instability (I)**: Ce / (Ca + Ce) - ranges from 0 (stable) to 1 (unstable)

  ## Parameters
  - `module`: Module name atom
  - `opts`: Keyword list of options
    - `:include_transitive` - Include transitive dependencies (default: false)

  ## Returns
  - `{:ok, metrics}` - Coupling metrics map
  - `{:error, reason}` - Error if module not found or analysis fails

  ## Examples

      {:ok, metrics} = coupling_metrics(MyModule)
      # => %{afferent: 5, efferent: 3, instability: 0.375}
  """
  @spec coupling_metrics(module_name(), keyword()) ::
          {:ok, coupling_metrics()} | {:error, term()}
  def coupling_metrics(module, opts \\ []) do
    include_transitive = Keyword.get(opts, :include_transitive, false)

    case Store.find_node(:module, module) do
      nil ->
        {:error, {:module_not_found, module}}

      _node ->
        try do
          metrics =
            if include_transitive do
              calculate_transitive_coupling(module)
            else
              calculate_direct_coupling(module)
            end

          {:ok, metrics}
        rescue
          e ->
            Logger.error("Failed to calculate coupling for #{module}: #{inspect(e)}")
            {:error, {:analysis_failed, Exception.message(e)}}
        end
    end
  end

  @doc """
  Calculates coupling metrics for all modules in the project.

  Returns a map of module => coupling_metrics.

  ## Parameters
  - `opts`: Keyword list of options
    - `:include_transitive` - Include transitive dependencies (default: false)
    - `:sort_by` - Sort by `:instability`, `:afferent`, `:efferent`, or `:name` (default: `:instability`)
    - `:descending` - Sort in descending order (default: true)

  ## Returns
  - `{:ok, [{module, metrics}]}` - List of module-metrics tuples, sorted

  ## Examples

      {:ok, all_metrics} = all_coupling_metrics(sort_by: :instability)
  """
  @spec all_coupling_metrics(keyword()) ::
          {:ok, [{module_name(), coupling_metrics()}]} | {:error, term()}
  def all_coupling_metrics(opts \\ []) do
    include_transitive = Keyword.get(opts, :include_transitive, false)
    sort_by = Keyword.get(opts, :sort_by, :instability)
    descending = Keyword.get(opts, :descending, true)

    try do
      modules =
        Store.list_nodes(:module, :infinity)
        |> Enum.map(& &1.id)

      metrics_list =
        modules
        |> Enum.map(fn module ->
          {:ok, metrics} = coupling_metrics(module, include_transitive: include_transitive)
          {module, metrics}
        end)
        |> sort_coupling_metrics(sort_by, descending)

      {:ok, metrics_list}
    rescue
      e ->
        Logger.error("Failed to calculate all coupling metrics: #{inspect(e)}")
        {:error, {:analysis_failed, Exception.message(e)}}
    end
  end

  # Dead Code / Unused Module Detection

  @doc """
  Finds modules that are not referenced by any other module.

  A module is considered unused if:
  - No functions in the module are called by other modules
  - The module is not imported/required/used by other modules
  - The module is not an entry point (tests, mix tasks, etc.)

  ## Parameters
  - `opts`: Keyword list of options
    - `:exclude_tests` - Exclude test modules from results (default: true)
    - `:exclude_mix_tasks` - Exclude Mix tasks (default: true)

  ## Returns
  - `{:ok, [module_name]}` - List of potentially unused modules
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      {:ok, unused} = find_unused()
  """
  @spec find_unused(keyword()) :: {:ok, [module_name()]} | {:error, term()}
  def find_unused(opts \\ []) do
    exclude_tests = Keyword.get(opts, :exclude_tests, true)
    exclude_mix_tasks = Keyword.get(opts, :exclude_mix_tasks, true)

    try do
      # Get all modules
      all_modules =
        Store.list_nodes(:module, :infinity)
        |> Enum.map(& &1.id)
        |> MapSet.new()

      # Get modules that have incoming edges (are referenced)
      referenced_modules =
        Store.list_nodes(:module, :infinity)
        |> Enum.flat_map(fn %{id: module} ->
          # Check for incoming imports
          imports = Store.get_incoming_edges({:module, module}, :imports)
          # Check for incoming calls to functions in this module
          functions = get_module_functions(module)

          calls =
            Enum.flat_map(functions, fn func ->
              Store.get_incoming_edges(func, :calls)
            end)

          if Enum.empty?(imports) && Enum.empty?(calls) do
            []
          else
            [module]
          end
        end)
        |> MapSet.new()

      # Find unreferenced modules
      unused = MapSet.difference(all_modules, referenced_modules) |> MapSet.to_list()

      # Apply filters
      unused =
        unused
        |> filter_if(exclude_tests, &(!test_module?(&1)))
        |> filter_if(exclude_mix_tasks, &(!mix_task?(&1)))

      {:ok, unused}
    rescue
      e ->
        Logger.error("Failed to find unused modules: #{inspect(e)}")
        {:error, {:analysis_failed, Exception.message(e)}}
    end
  end

  # God Module Detection

  @doc """
  Finds "God modules" - modules with high coupling.

  God modules are modules that have excessive dependencies or dependents,
  indicating potential design issues.

  ## Parameters
  - `threshold`: Minimum total coupling (afferent + efferent) to be considered a God module
  - `opts`: Keyword list of options
    - `:sort_by` - Sort by `:total`, `:afferent`, `:efferent`, or `:instability` (default: `:total`)

  ## Returns
  - `{:ok, [{module, metrics}]}` - List of God modules with their metrics

  ## Examples

      # Find modules with total coupling >= 20
      {:ok, god_modules} = find_god_modules(20)
  """
  @spec find_god_modules(non_neg_integer(), keyword()) ::
          {:ok, [{module_name(), coupling_metrics()}]} | {:error, term()}
  def find_god_modules(threshold, opts \\ []) do
    sort_by = Keyword.get(opts, :sort_by, :total)

    case all_coupling_metrics(sort_by: sort_by) do
      {:ok, all_metrics} ->
        god_modules =
          all_metrics
          |> Enum.filter(fn {_module, metrics} ->
            metrics.afferent + metrics.efferent >= threshold
          end)

        {:ok, god_modules}

      error ->
        error
    end
  end

  # Decoupling Suggestions

  @doc """
  Generates suggestions for decoupling the codebase.

  Analyzes the dependency graph to find:
  - Circular dependencies that should be broken
  - God modules that should be split
  - Highly unstable modules that need stabilization
  - Unused modules that can be removed

  ## Returns
  - `{:ok, [suggestion]}` - List of decoupling suggestions
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      {:ok, suggestions} = decoupling_suggestions()
  """
  @spec decoupling_suggestions(keyword()) :: {:ok, [suggestion()]} | {:error, term()}
  def decoupling_suggestions(_opts \\ []) do
    suggestions = []

    # Detect circular dependencies
    suggestions =
      case find_cycles(scope: :module) do
        {:ok, [_ | _] = cycles} ->
          cycle_suggestions =
            cycles
            |> Enum.map(fn cycle ->
              %{
                type: :circular_dependency,
                severity: severity_for_cycle(cycle),
                description: "Circular dependency detected: #{format_cycle(cycle)}",
                entities: cycle,
                metadata: %{cycle_length: length(cycle)}
              }
            end)

          suggestions ++ cycle_suggestions

        _ ->
          suggestions
      end

    # Find God modules
    suggestions =
      case find_god_modules(15) do
        {:ok, [_ | _] = god_modules} ->
          god_suggestions =
            god_modules
            |> Enum.map(fn {module, metrics} ->
              %{
                type: :god_module,
                severity: severity_for_coupling(metrics),
                description:
                  "Module #{module} has high coupling (#{metrics.afferent + metrics.efferent} total dependencies)",
                entities: [module],
                metadata: metrics
              }
            end)

          suggestions ++ god_suggestions

        _ ->
          suggestions
      end

    # Find highly unstable modules
    suggestions =
      case all_coupling_metrics() do
        {:ok, all_metrics} ->
          unstable_suggestions =
            all_metrics
            |> Enum.filter(fn {_module, metrics} -> metrics.instability > 0.8 end)
            |> Enum.map(fn {module, metrics} ->
              %{
                type: :unstable_module,
                severity: :medium,
                description:
                  "Module #{module} is highly unstable (I=#{Float.round(metrics.instability, 2)})",
                entities: [module],
                metadata: metrics
              }
            end)

          suggestions ++ unstable_suggestions

        _ ->
          suggestions
      end

    # Find unused modules
    suggestions =
      case find_unused() do
        {:ok, [_ | _] = unused} ->
          unused_suggestions =
            unused
            |> Enum.map(fn module ->
              %{
                type: :unused_module,
                severity: :low,
                description: "Module #{module} appears to be unused and could be removed",
                entities: [module],
                metadata: %{}
              }
            end)

          suggestions ++ unused_suggestions

        _ ->
          suggestions
      end

    {:ok, suggestions}
  rescue
    e ->
      Logger.error("Failed to generate decoupling suggestions: #{inspect(e)}")
      {:error, {:analysis_failed, Exception.message(e)}}
  end

  # Private functions

  # Build adjacency list for dependency analysis
  defp build_dependency_adjacency(:module) do
    # Build module-level adjacency from :imports edges and function calls
    modules = Store.list_nodes(:module, :infinity) |> Enum.map(& &1.id)

    Enum.reduce(modules, %{}, fn module, acc ->
      # Get direct imports
      imports = Store.get_outgoing_edges({:module, module}, :imports)
      import_targets = Enum.map(imports, fn %{to: {:module, target}} -> target end)

      # Get calls from functions in this module to other modules
      call_targets =
        get_module_functions(module)
        |> Enum.flat_map(fn func ->
          Store.get_outgoing_edges(func, :calls)
        end)
        |> Enum.map(fn %{to: {:function, target_module, _, _}} -> target_module end)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == module))

      all_targets = (import_targets ++ call_targets) |> Enum.uniq()
      Map.put(acc, module, all_targets)
    end)
  end

  defp build_dependency_adjacency(:function) do
    # Build function-level adjacency from :calls edges
    functions = Store.list_nodes(:function, :infinity) |> Enum.map(& &1.id)

    Enum.reduce(functions, %{}, fn {module, name, arity}, acc ->
      func_id = {:function, module, name, arity}
      calls = Store.get_outgoing_edges(func_id, :calls)
      targets = Enum.map(calls, fn %{to: target} -> target end)

      Map.put(acc, func_id, targets)
    end)
  end

  # Find all cycles using DFS
  defp find_all_cycles(nodes, adjacency, min_length, limit) do
    {cycles, _} =
      Enum.reduce_while(nodes, {[], 0}, fn node, {cycles_acc, count} ->
        if count >= limit do
          {:halt, {cycles_acc, count}}
        else
          node_cycles = find_cycles_from_node(node, adjacency, min_length)
          new_count = count + length(node_cycles)
          {:cont, {cycles_acc ++ node_cycles, new_count}}
        end
      end)

    # Deduplicate cycles (same cycle can be found from different starting points)
    cycles
    |> Enum.map(&normalize_cycle/1)
    |> Enum.uniq()
    |> Enum.take(limit)
  end

  # Find cycles starting from a specific node using DFS
  defp find_cycles_from_node(start_node, adjacency, min_length) do
    find_cycles_dfs(start_node, adjacency, [start_node], MapSet.new([start_node]), start_node, [])
    |> Enum.filter(fn cycle -> length(cycle) >= min_length end)
  end

  # DFS to detect cycles
  defp find_cycles_dfs(current, adjacency, path, visited, target, cycles) do
    neighbors = Map.get(adjacency, current, [])

    Enum.reduce(neighbors, cycles, fn neighbor, acc ->
      cond do
        # Found cycle back to target
        neighbor == target && length(path) >= 2 ->
          [path | acc]

        # Already visited, skip
        MapSet.member?(visited, neighbor) ->
          acc

        # Continue DFS
        true ->
          new_path = path ++ [neighbor]
          new_visited = MapSet.put(visited, neighbor)
          find_cycles_dfs(neighbor, adjacency, new_path, new_visited, target, acc)
      end
    end)
  end

  # Normalize cycle to start with the smallest element (for deduplication)
  defp normalize_cycle(cycle) do
    min_idx = Enum.find_index(cycle, &(&1 == Enum.min(cycle)))
    {first, second} = Enum.split(cycle, min_idx)
    second ++ first
  end

  # Calculate direct coupling metrics
  defp calculate_direct_coupling(module) do
    # Afferent: modules that depend on this module
    afferent = count_module_dependents(module)

    # Efferent: modules this module depends on
    efferent = count_module_dependencies(module)

    # Instability
    total = afferent + efferent
    instability = if total == 0, do: 0.0, else: efferent / total

    %{
      afferent: afferent,
      efferent: efferent,
      instability: instability
    }
  end

  # Calculate transitive coupling metrics
  defp calculate_transitive_coupling(module) do
    # For transitive, we need to walk the graph
    # Afferent: all modules that transitively depend on this module
    afferent_set = find_transitive_dependents(module)

    # Efferent: all modules this module transitively depends on
    efferent_set = find_transitive_dependencies(module)

    afferent = MapSet.size(afferent_set)
    efferent = MapSet.size(efferent_set)

    total = afferent + efferent
    instability = if total == 0, do: 0.0, else: efferent / total

    %{
      afferent: afferent,
      efferent: efferent,
      instability: instability
    }
  end

  # Count direct dependents (modules that depend on this module)
  defp count_module_dependents(module) do
    # Check imports to this module
    import_dependents =
      Store.get_incoming_edges({:module, module}, :imports)
      |> Enum.map(fn %{from: {:module, source}} -> source end)
      |> Enum.uniq()

    # Check calls to functions in this module from other modules
    call_dependents =
      get_module_functions(module)
      |> Enum.flat_map(fn func ->
        Store.get_incoming_edges(func, :calls)
      end)
      |> Enum.map(fn %{from: {:function, source_module, _, _}} -> source_module end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == module))

    (import_dependents ++ call_dependents) |> Enum.uniq() |> length()
  end

  # Count direct dependencies (modules this module depends on)
  defp count_module_dependencies(module) do
    # Check imports from this module
    import_deps =
      Store.get_outgoing_edges({:module, module}, :imports)
      |> Enum.map(fn %{to: {:module, target}} -> target end)
      |> Enum.uniq()

    # Check calls from functions in this module to other modules
    call_deps =
      get_module_functions(module)
      |> Enum.flat_map(fn func ->
        Store.get_outgoing_edges(func, :calls)
      end)
      |> Enum.map(fn %{to: {:function, target_module, _, _}} -> target_module end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == module))

    (import_deps ++ call_deps) |> Enum.uniq() |> length()
  end

  # Find all modules that transitively depend on this module (BFS)
  defp find_transitive_dependents(module) do
    initial = [module]
    visited = MapSet.new([module])

    find_transitive_dependents_bfs(initial, visited, MapSet.new())
  end

  defp find_transitive_dependents_bfs([], _visited, dependents), do: dependents

  defp find_transitive_dependents_bfs([current | rest], visited, dependents) do
    # Find modules that directly depend on current
    direct_dependents =
      get_module_functions(current)
      |> Enum.flat_map(fn func ->
        Store.get_incoming_edges(func, :calls)
      end)
      |> Enum.map(fn %{from: {:function, source_module, _, _}} -> source_module end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == current))

    # Add to dependents and queue unvisited
    new_dependents = MapSet.union(dependents, MapSet.new(direct_dependents))
    unvisited = Enum.reject(direct_dependents, &MapSet.member?(visited, &1))
    new_visited = MapSet.union(visited, MapSet.new(unvisited))

    find_transitive_dependents_bfs(rest ++ unvisited, new_visited, new_dependents)
  end

  # Find all modules this module transitively depends on (BFS)
  defp find_transitive_dependencies(module) do
    initial = [module]
    visited = MapSet.new([module])

    find_transitive_dependencies_bfs(initial, visited, MapSet.new())
  end

  defp find_transitive_dependencies_bfs([], _visited, dependencies), do: dependencies

  defp find_transitive_dependencies_bfs([current | rest], visited, dependencies) do
    # Find modules current directly depends on
    direct_deps =
      get_module_functions(current)
      |> Enum.flat_map(fn func ->
        Store.get_outgoing_edges(func, :calls)
      end)
      |> Enum.map(fn %{to: {:function, target_module, _, _}} -> target_module end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == current))

    # Add to dependencies and queue unvisited
    new_dependencies = MapSet.union(dependencies, MapSet.new(direct_deps))
    unvisited = Enum.reject(direct_deps, &MapSet.member?(visited, &1))
    new_visited = MapSet.union(visited, MapSet.new(unvisited))

    find_transitive_dependencies_bfs(rest ++ unvisited, new_visited, new_dependencies)
  end

  # Get all functions in a module
  defp get_module_functions(module) do
    Store.list_nodes(:function, :infinity)
    |> Enum.filter(fn %{id: {mod, _name, _arity}} -> mod == module end)
    |> Enum.map(fn %{id: {mod, name, arity}} -> {:function, mod, name, arity} end)
  end

  # Helper: determine severity for cycle
  defp severity_for_cycle(cycle) do
    length = length(cycle)

    cond do
      length >= 5 -> :high
      length >= 3 -> :medium
      true -> :low
    end
  end

  # Helper: determine severity for coupling
  defp severity_for_coupling(%{afferent: a, efferent: e}) do
    total = a + e

    cond do
      total >= 30 -> :high
      total >= 20 -> :medium
      true -> :low
    end
  end

  # Helper: format cycle for display
  defp format_cycle(cycle) do
    Enum.map_join(cycle, " -> ", &format_entity/1)
  end

  # Helper: format entity for display
  defp format_entity({:function, module, name, arity}), do: "#{module}.#{name}/#{arity}"
  defp format_entity(module) when is_atom(module), do: inspect(module)
  defp format_entity(other), do: inspect(other)

  # Helper: sort coupling metrics
  defp sort_coupling_metrics(metrics_list, sort_by, descending) do
    sorted =
      case sort_by do
        :name ->
          Enum.sort_by(metrics_list, fn {module, _} -> module end)

        :instability ->
          Enum.sort_by(metrics_list, fn {_, metrics} -> metrics.instability end)

        :afferent ->
          Enum.sort_by(metrics_list, fn {_, metrics} -> metrics.afferent end)

        :efferent ->
          Enum.sort_by(metrics_list, fn {_, metrics} -> metrics.efferent end)

        _ ->
          metrics_list
      end

    if descending && sort_by != :name do
      Enum.reverse(sorted)
    else
      sorted
    end
  end

  # Helper: filter list if condition is true
  defp filter_if(list, true, filter_fn), do: Enum.filter(list, filter_fn)
  defp filter_if(list, false, _filter_fn), do: list

  # Helper: check if module is a test module
  defp test_module?(module) do
    module_str = to_string(module)
    String.ends_with?(module_str, "Test") || String.contains?(module_str, ".Test.")
  end

  # Helper: check if module is a Mix task
  defp mix_task?(module) do
    module_str = to_string(module)
    String.starts_with?(module_str, "Mix.Tasks.")
  end
end
