defmodule Ragex.Analysis.Runner do
  @moduledoc """
  Shared analysis runner logic used by both Mix tasks and MCP tools.

  Extracts the "run all analyses" pipeline so that:
  - `mix ragex.analyze` can run it locally
  - The `comprehensive_analyze` MCP tool can run it on the server
  - Mix tasks can delegate to the running server via MCP without
    starting a second BEAM VM
  """

  alias Ragex.Analysis.{
    BusinessLogic,
    DeadCode,
    DependencyGraph,
    Duplication,
    Quality,
    Security,
    Smells
  }

  alias Ragex.Analyzers.Directory

  @type config :: %{
          required(:path) => String.t(),
          required(:severity) => [atom()],
          required(:threshold) => float(),
          required(:min_complexity) => integer(),
          required(:god_threshold) => integer(),
          required(:instability_threshold) => float(),
          required(:analyses) => %{atom() => boolean()},
          optional(atom()) => term()
        }

  @type analyze_result :: %{
          files_analyzed: non_neg_integer(),
          entities_found: non_neg_integer(),
          errors: list()
        }

  @doc """
  Analyzes a directory and populates the knowledge graph.

  Returns `{:ok, analyze_result}` or `{:error, reason}`.
  """
  @spec analyze_directory(String.t(), keyword()) :: {:ok, analyze_result()} | {:error, term()}
  def analyze_directory(path, opts \\ []) do
    case Directory.analyze_directory(path, opts) do
      {:ok, stats} -> {:ok, stats_to_result(stats)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Analyzes an explicit list of file paths and populates the knowledge graph.

  Used by diff-based analysis to index only changed files.
  """
  @spec analyze_files([String.t()], keyword()) :: {:ok, analyze_result()} | {:error, term()}
  def analyze_files(file_paths, opts \\ []) do
    # Directory.analyze_files/2 always returns {:ok, stats}
    {:ok, stats} = Directory.analyze_files(file_paths, opts)
    {:ok, stats_to_result(stats)}
  end

  defp stats_to_result(stats) do
    entities_found =
      if stats[:graph_stats] do
        Map.get(stats.graph_stats, :nodes, 0)
      else
        0
      end

    %{
      files_analyzed: stats.total,
      entities_found: entities_found,
      errors: stats[:error_details] || []
    }
  end

  @doc """
  Runs all enabled analyses based on the config.

  Returns a map of `%{analysis_type => result}` matching the format
  expected by `Mix.Tasks.Ragex.Analyze` formatters.
  """
  @spec run_all(config()) :: map()
  def run_all(config) do
    analyses = config.analyses

    %{}
    |> maybe_run(:security, analyses, fn -> run_security(config) end)
    |> maybe_run(:business_logic, analyses, fn -> run_business_logic(config) end)
    |> maybe_run(:complexity, analyses, fn -> run_complexity(config) end)
    |> maybe_run(:smells, analyses, fn -> run_smells(config) end)
    |> maybe_run(:duplicates, analyses, fn -> run_duplicates(config) end)
    |> maybe_run(:dead_code, analyses, fn -> run_dead_code() end)
    |> maybe_run(:dependencies, analyses, fn -> run_dependencies() end)
    |> maybe_run(:quality, analyses, fn -> run_quality(config) end)
    |> maybe_run(:circulars, analyses, fn -> run_circulars() end)
    |> maybe_run(:god_modules, analyses, fn -> run_god_modules(config) end)
    |> maybe_run(:unstable_modules, analyses, fn -> run_unstable_modules(config) end)
    |> maybe_run(:unused_modules, analyses, fn -> run_unused_modules() end)
    |> maybe_run(:coupling, analyses, fn -> run_coupling() end)
  end

  # Private functions

  defp maybe_run(results, key, analyses, fun) do
    if Map.get(analyses, key, false) do
      Map.put(results, key, fun.())
    else
      results
    end
  end

  defp run_security(config) do
    case Security.analyze_directory(config.path, severity: config.severity) do
      {:ok, issues} -> %{issues: issues}
      {:error, _} -> %{issues: []}
    end
  end

  defp run_business_logic(config) do
    severity_map = %{
      [:low, :medium, :high, :critical] => :low,
      [:medium, :high, :critical] => :medium,
      [:high, :critical] => :high,
      [:critical] => :critical
    }

    min_severity = Map.get(severity_map, config.severity, :medium)

    case BusinessLogic.analyze_directory(config.path, min_severity: min_severity) do
      {:ok, result} -> result
      {:error, _} -> %{total_files: 0, files_with_issues: 0, total_issues: 0, results: []}
    end
  end

  defp run_complexity(config) do
    case Quality.find_complex_code(config.path, min_complexity: config.min_complexity) do
      {:ok, functions} -> %{complex_functions: functions}
      {:error, _} -> %{complex_functions: []}
    end
  end

  @dialyzer {:nowarn_function, run_smells: 1}
  defp run_smells(config) do
    case Smells.detect_smells(config.path) do
      {:ok, smells} -> %{smells: smells}
      {:error, _} -> %{smells: []}
    end
  end

  defp run_duplicates(config) do
    case Duplication.find_duplicates(config.path, threshold: config.threshold) do
      {:ok, duplicates} -> %{duplicates: duplicates}
      {:error, _} -> %{duplicates: []}
    end
  end

  defp run_dead_code do
    case DeadCode.find_dead_code() do
      {:ok, dead_functions} -> %{dead_functions: dead_functions}
      {:error, _} -> %{dead_functions: []}
    end
  end

  defp run_dependencies do
    case DependencyGraph.analyze_all_dependencies() do
      {:ok, analysis} -> analysis
    end
  end

  defp run_quality(config) do
    case Quality.analyze_quality(config.path) do
      {:ok, metrics} -> metrics
      {:error, _} -> %{overall_score: 0}
    end
  end

  defp run_circulars do
    case DependencyGraph.find_cycles(scope: :module) do
      {:ok, cycles} -> %{cycles: cycles}
      {:error, _} -> %{cycles: []}
    end
  end

  defp run_god_modules(config) do
    case DependencyGraph.find_god_modules(config.god_threshold) do
      {:ok, god_modules} ->
        modules =
          Enum.map(god_modules, fn {module, metrics} ->
            %{
              module: module,
              afferent: metrics.afferent,
              efferent: metrics.efferent,
              total: metrics.afferent + metrics.efferent,
              instability: metrics.instability
            }
          end)

        %{modules: modules, threshold: config.god_threshold}

      {:error, _} ->
        %{modules: [], threshold: config.god_threshold}
    end
  end

  defp run_unstable_modules(config) do
    case DependencyGraph.all_coupling_metrics() do
      {:ok, all_metrics} ->
        unstable =
          all_metrics
          |> Enum.filter(fn {_mod, metrics} ->
            metrics.instability > config.instability_threshold
          end)
          |> Enum.map(fn {module, metrics} ->
            %{
              module: module,
              instability: metrics.instability,
              afferent: metrics.afferent,
              efferent: metrics.efferent
            }
          end)
          |> Enum.sort_by(& &1.instability, :desc)

        %{modules: unstable, threshold: config.instability_threshold}

      {:error, _} ->
        %{modules: [], threshold: config.instability_threshold}
    end
  end

  defp run_unused_modules do
    case DependencyGraph.find_unused() do
      {:ok, unused} -> %{modules: unused}
      {:error, _} -> %{modules: []}
    end
  end

  defp run_coupling do
    case DependencyGraph.all_coupling_metrics() do
      {:ok, all_metrics} ->
        metrics =
          Enum.map(all_metrics, fn {module, m} ->
            %{
              module: module,
              afferent: m.afferent,
              efferent: m.efferent,
              instability: m.instability
            }
          end)

        %{metrics: metrics}

      {:error, _} ->
        %{metrics: []}
    end
  end

  # ── Diff filtering ────────────────────────────────────────────────────

  @doc """
  Filters analysis results to only include issues touching the given files.

  `changed_files` is a `MapSet` of relative file paths. Results whose file
  path is not in the set are removed. Whole-project analyses (circulars,
  coupling, etc.) pass through unfiltered since they represent structural
  properties, not per-file issues.
  """
  @spec filter_results_by_files(map(), MapSet.t()) :: map()
  def filter_results_by_files(results, changed_files) do
    Map.new(results, fn {type, data} ->
      {type, filter_type(type, data, changed_files)}
    end)
  end

  defp filter_type(:security, %{issues: issues} = data, files) do
    %{data | issues: Enum.filter(issues, &file_in_set?(&1[:file] || &1[:path], files))}
  end

  defp filter_type(:business_logic, %{results: results} = data, files) do
    filtered = Enum.filter(results, &file_in_set?(&1[:file] || &1[:path], files))

    total =
      Enum.reduce(filtered, 0, fn r, acc -> acc + length(Map.get(r, :issues, [])) end)

    %{data | results: filtered, total_issues: total, files_with_issues: length(filtered)}
  end

  defp filter_type(:complexity, %{complex_functions: funcs} = data, files) do
    %{data | complex_functions: Enum.filter(funcs, &file_in_set?(&1[:file] || &1[:path], files))}
  end

  defp filter_type(:smells, %{smells: smells} = data, files) do
    case smells do
      %{results: results} ->
        filtered = Enum.filter(results, &file_in_set?(&1[:path] || &1[:file], files))
        %{data | smells: %{smells | results: filtered}}

      list when is_list(list) ->
        %{data | smells: Enum.filter(list, &file_in_set?(&1[:file] || &1[:path], files))}

      _ ->
        data
    end
  end

  defp filter_type(:duplicates, %{duplicates: dups} = data, files) do
    filtered =
      Enum.filter(dups, fn dup ->
        locations = Map.get(dup, :locations, [])
        Enum.any?(locations, &file_in_set?(&1[:file] || &1[:path], files))
      end)

    %{data | duplicates: filtered}
  end

  defp filter_type(:dead_code, %{dead_functions: funcs} = data, files) do
    %{data | dead_functions: Enum.filter(funcs, &file_in_set?(&1[:file] || &1[:path], files))}
  end

  # Structural / whole-project analyses pass through unfiltered
  defp filter_type(_type, data, _files), do: data

  defp file_in_set?(nil, _files), do: false

  defp file_in_set?(path, files) do
    # Match both absolute and relative paths
    MapSet.member?(files, path) or
      MapSet.member?(files, Path.basename(path)) or
      Enum.any?(files, fn f ->
        String.ends_with?(path, "/" <> f) or String.ends_with?(f, "/" <> path) or path == f
      end)
  end
end
