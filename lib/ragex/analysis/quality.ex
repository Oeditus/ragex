defmodule Ragex.Analysis.Quality do
  @moduledoc """
  High-level API for code quality analysis.

  Provides a unified interface for analyzing code quality metrics and storing/querying
  results. Combines MetastaticBridge for analysis and QualityStore for persistence.

  ## Features

  - File and directory analysis with complexity metrics
  - Automatic storage in knowledge graph
  - Quality reporting and statistics
  - Finding complex code patterns
  - Purity analysis

  ## Usage

      alias Ragex.Analysis.Quality

      # Analyze single file
      {:ok, result} = Quality.analyze_file("lib/my_module.ex")

      # Analyze with options
      {:ok, result} = Quality.analyze_file("lib/my_module.ex",
        metrics: [:cyclomatic, :cognitive],
        store: true
      )

      # Analyze directory
      {:ok, results} = Quality.analyze_directory("lib/")

      # Get statistics
      stats = Quality.statistics()

      # Find complex files
      complex = Quality.find_complex(metric: :cyclomatic, threshold: 10)
  """

  alias Ragex.Analysis.{MetastaticBridge, QualityStore, Security}
  require Logger

  @type analysis_result :: %{
          path: String.t(),
          language: atom(),
          complexity: map(),
          purity: map(),
          warnings: [String.t()],
          timestamp: DateTime.t()
        }

  @type quality_report :: %{
          total_files: non_neg_integer(),
          avg_cyclomatic: float(),
          avg_cognitive: float(),
          avg_nesting: float(),
          max_cyclomatic: non_neg_integer(),
          max_cognitive: non_neg_integer(),
          max_nesting: non_neg_integer(),
          files_with_warnings: non_neg_integer(),
          impure_files: non_neg_integer(),
          languages: %{atom() => non_neg_integer()}
        }

  @doc """
  Analyzes a single file for code quality metrics.

  Performs comprehensive quality analysis including complexity metrics and purity analysis.
  Optionally stores results in the knowledge graph for later querying.

  ## Parameters
  - `path`: Path to the file to analyze
  - `opts`: Keyword list of options
    - `:metrics` - List of specific metrics to calculate (default: all)
    - `:store` - Store results in knowledge graph (default: true)
    - `:thresholds` - Custom threshold map for warnings
    - `:language` - Explicit language (default: auto-detect)

  ## Returns
  - `{:ok, analysis_result}` - Analysis results with metrics
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      # Analyze with default options (all metrics, auto-store)
      {:ok, result} = Quality.analyze_file("lib/my_module.ex")
      result.complexity.cyclomatic  # => 5

      # Analyze specific metrics without storing
      {:ok, result} = Quality.analyze_file("lib/my_module.ex",
        metrics: [:cyclomatic, :cognitive],
        store: false
      )

      # Analyze with custom thresholds
      {:ok, result} = Quality.analyze_file("lib/my_module.ex",
        thresholds: %{cyclomatic: 15, cognitive: 10}
      )
  """
  @spec analyze_file(String.t(), keyword()) :: {:ok, analysis_result()} | {:error, term()}
  def analyze_file(path, opts \\ []) do
    store = Keyword.get(opts, :store, true)

    case MetastaticBridge.analyze_file(path, opts) do
      {:ok, result} ->
        # Store results if requested
        if store do
          case QualityStore.store_metrics(result) do
            :ok ->
              {:ok, result}

            {:error, store_error} ->
              Logger.warning("Failed to store metrics for #{path}: #{inspect(store_error)}")
              # Still return the analysis result even if storage fails
              {:ok, result}
          end
        else
          {:ok, result}
        end

      {:error, reason} = error ->
        Logger.error("Failed to analyze #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Analyzes all functions in a module.

  Retrieves quality metrics for all functions in the specified module.
  The module's file must have been analyzed and stored first.

  ## Parameters
  - `module`: Module name atom
  - `opts`: Keyword list of options
    - `:path` - Explicit file path (default: lookup from module in graph)
    - `:analyze_if_missing` - Analyze file if not found in store (default: false)
    - `:sort_by` - Sort functions by metric: `:cyclomatic`, `:cognitive`, `:nesting`, `:name` (default: `:name`)
    - `:threshold` - Only return functions exceeding this complexity (optional)

  ## Returns
  - `{:ok, module_analysis}` - Map with module-level and per-function metrics
  - `{:error, reason}` - Error if module not found or analysis fails

  ## Module Analysis Structure
  ```elixir
  %{
    module: MyModule,
    file: "lib/my_module.ex",
    language: :elixir,
    total_cyclomatic: 25,
    total_cognitive: 18,
    function_count: 5,
    functions: [
      %{function: :func1, arity: 2, cyclomatic: 3, ...},
      %{function: :func2, arity: 1, cyclomatic: 5, ...}
    ]
  }
  ```

  ## Examples

      # Analyze all functions in a module
      {:ok, analysis} = Quality.analyze_module(MyModule)
      analysis.function_count  # => 5

      # Sort by complexity
      {:ok, analysis} = Quality.analyze_module(MyModule, sort_by: :cyclomatic)

      # Only complex functions
      {:ok, analysis} = Quality.analyze_module(MyModule, threshold: 10)

      # With auto-analysis
      {:ok, analysis} = Quality.analyze_module(MyModule, analyze_if_missing: true)
  """
  @spec analyze_module(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def analyze_module(module, opts \\ []) do
    alias Ragex.Graph.Store

    analyze_if_missing = Keyword.get(opts, :analyze_if_missing, false)
    explicit_path = Keyword.get(opts, :path)
    sort_by = Keyword.get(opts, :sort_by, :name)
    threshold = Keyword.get(opts, :threshold)

    # Determine file path
    path =
      explicit_path ||
        case Store.get_module(module) do
          nil -> nil
          module_data -> Map.get(module_data, :file)
        end

    case path do
      nil ->
        {:error, {:module_not_found, module}}

      file_path ->
        # Try to get stored metrics
        case QualityStore.get_metrics(file_path) do
          {:ok, metrics} ->
            build_module_analysis(metrics, module, file_path, sort_by, threshold)

          {:error, :not_found} when analyze_if_missing ->
            # Analyze file and try again
            case analyze_file(file_path, store: true) do
              {:ok, result} ->
                # Convert to stored format and build analysis
                stored_metrics = convert_result_to_stored_format(result)
                build_module_analysis(stored_metrics, module, file_path, sort_by, threshold)

              error ->
                error
            end

          {:error, :not_found} ->
            {:error, {:metrics_not_found, file_path}}

          error ->
            error
        end
    end
  end

  @doc """
  Analyzes a specific function's quality metrics.

  Extracts function-level metrics from the file's stored analysis results.
  The file must have been analyzed and stored first using `analyze_file/2`.

  ## Parameters
  - `module`: Module name atom
  - `function`: Function name atom
  - `arity`: Function arity (non-negative integer)
  - `opts`: Keyword list of options
    - `:path` - Explicit file path (default: lookup from module in graph)
    - `:analyze_if_missing` - Analyze file if not found in store (default: false)

  ## Returns
  - `{:ok, function_metrics}` - Map with function-specific metrics
  - `{:error, :not_found}` - File not analyzed or function not found
  - `{:error, reason}` - Other errors

  ## Function Metrics Structure
  ```elixir
  %{
    module: MyModule,
    function: :my_function,
    arity: 2,
    cyclomatic: 3,
    cognitive: 2,
    nesting: 1,
    halstead: %{...},
    loc: %{total: 10, code: 8, comments: 2}
  }
  ```

  ## Examples

      # Analyze a specific function (file must be analyzed first)
      {:ok, result} = Quality.analyze_file("lib/my_module.ex")
      {:ok, func_metrics} = Quality.analyze_function(MyModule, :my_function, 2)

      # With auto-analysis if not found
      {:ok, func_metrics} = Quality.analyze_function(MyModule, :my_function, 2,
        analyze_if_missing: true
      )

      # With explicit path
      {:ok, func_metrics} = Quality.analyze_function(MyModule, :my_function, 2,
        path: "lib/my_module.ex"
      )
  """
  @spec analyze_function(module(), atom(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def analyze_function(module, function, arity, opts \\ []) do
    alias Ragex.Graph.Store

    analyze_if_missing = Keyword.get(opts, :analyze_if_missing, false)
    explicit_path = Keyword.get(opts, :path)

    # Determine file path
    path =
      explicit_path ||
        case Store.get_module(module) do
          nil -> nil
          module_data -> Map.get(module_data, :file)
        end

    case path do
      nil ->
        {:error, {:module_not_found, module}}

      file_path ->
        # Try to get stored metrics
        case QualityStore.get_metrics(file_path) do
          {:ok, metrics} ->
            extract_function_metrics(metrics, module, function, arity)

          {:error, :not_found} when analyze_if_missing ->
            # Analyze file and try again
            case analyze_file(file_path, store: true) do
              {:ok, result} ->
                extract_function_metrics_from_result(result, module, function, arity)

              error ->
                error
            end

          {:error, :not_found} ->
            {:error, {:metrics_not_found, file_path}}

          error ->
            error
        end
    end
  end

  @doc """
  Analyzes all files in a directory.

  Recursively analyzes all supported source files in the directory and optionally
  stores results in the knowledge graph.

  ## Parameters
  - `path`: Directory path to analyze
  - `opts`: Keyword list of options
    - `:recursive` - Recursively analyze subdirectories (default: true)
    - `:store` - Store results in knowledge graph (default: true)
    - `:metrics` - List of metrics to calculate (default: all)
    - `:parallel` - Use parallel processing (default: true)
    - `:max_concurrency` - Maximum concurrent analyses (default: System.schedulers_online())

  ## Returns
  - `{:ok, results}` - List of analysis results (mix of `{:ok, result}` and `{:error, reason}`)
  - `{:error, reason}` - Error if directory access fails

  ## Examples

      # Analyze entire lib directory
      {:ok, results} = Quality.analyze_directory("lib/")

      # Analyze without storing
      {:ok, results} = Quality.analyze_directory("lib/", store: false)

      # Sequential analysis (useful for debugging)
      {:ok, results} = Quality.analyze_directory("lib/", parallel: false)
  """
  @spec analyze_directory(String.t(), keyword()) ::
          {:ok, [{:ok, analysis_result()} | {:error, term()}]} | {:error, term()}
  def analyze_directory(path, opts \\ []) do
    store = Keyword.get(opts, :store, true)

    case MetastaticBridge.analyze_directory(path, opts) do
      {:ok, results} ->
        # Store results if requested
        if store do
          Enum.each(results, fn
            %{} = result ->
              case QualityStore.store_metrics(result) do
                :ok ->
                  :ok

                {:error, reason} ->
                  Logger.warning("Failed to store metrics for #{result.path}: #{inspect(reason)}")
              end

            _ ->
              :ok
          end)
        end

        {:ok, results}

      {:error, reason} = error ->
        Logger.error("Failed to analyze directory #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Returns project-wide quality statistics.

  Aggregates metrics from all analyzed files stored in the knowledge graph.

  ## Returns
  - Quality statistics map with averages, maximums, and counts

  ## Examples

      stats = Quality.statistics()
      stats.total_files        # => 42
      stats.avg_cyclomatic     # => 3.5
      stats.max_cognitive      # => 25
  """
  @spec statistics() :: quality_report()
  def statistics do
    QualityStore.project_stats()
  end

  @doc """
  Returns quality statistics grouped by language.

  ## Returns
  - Map of language => statistics

  ## Examples

      by_lang = Quality.statistics_by_language()
      by_lang[:elixir].avg_cyclomatic  # => 4.2
      by_lang[:python].avg_cognitive   # => 5.1
  """
  @spec statistics_by_language() :: %{atom() => quality_report()}
  def statistics_by_language do
    QualityStore.stats_by_language()
  end

  @doc """
  Finds files exceeding complexity thresholds.

  ## Parameters
  - `opts`: Keyword list of options
    - `:metric` - Metric to evaluate: `:cyclomatic`, `:cognitive`, `:nesting` (default: `:cyclomatic`)
    - `:threshold` - Threshold value (default: 10)
    - `:operator` - Comparison: `:gt`, `:gte`, `:lt`, `:lte`, `:eq` (default: `:gt`)
    - `:limit` - Maximum results (default: 20)

  ## Returns
  - List of file paths exceeding threshold

  ## Examples

      # Find files with cyclomatic complexity > 10
      complex = Quality.find_complex(threshold: 10)

      # Find files with cognitive complexity >= 15
      complex = Quality.find_complex(
        metric: :cognitive,
        threshold: 15,
        operator: :gte
      )

      # Find top 5 most complex files
      complex = Quality.find_complex(threshold: 5, limit: 5)
  """
  @spec find_complex(keyword()) :: [String.t()]
  def find_complex(opts \\ []) do
    metric = Keyword.get(opts, :metric, :cyclomatic)
    threshold = Keyword.get(opts, :threshold, 10)
    operator = Keyword.get(opts, :operator, :gt)
    limit = Keyword.get(opts, :limit, 20)

    metric
    |> QualityStore.find_by_threshold(threshold, operator: operator)
    |> Enum.take(limit)
  end

  @doc """
  Returns the most complex files.

  ## Parameters
  - `opts`: Keyword list of options
    - `:metric` - Metric to rank by: `:cyclomatic`, `:cognitive`, `:nesting` (default: `:cyclomatic`)
    - `:limit` - Number of results (default: 10)

  ## Returns
  - List of `{path, metric_value}` tuples, sorted by complexity

  ## Examples

      # Top 10 most complex files by cyclomatic complexity
      top = Quality.most_complex()

      # Top 5 by cognitive complexity
      top = Quality.most_complex(metric: :cognitive, limit: 5)
  """
  @spec most_complex(keyword()) :: [{String.t(), number()}]
  def most_complex(opts \\ []) do
    QualityStore.most_complex(opts)
  end

  @doc """
  Finds files with analysis warnings.

  ## Returns
  - List of `{path, warnings}` tuples

  ## Examples

      files_with_warnings = Quality.find_with_warnings()
      # => [{"lib/complex.ex", ["High cyclomatic complexity: 15"]}]
  """
  @spec find_with_warnings() :: [{String.t(), [String.t()]}]
  def find_with_warnings do
    QualityStore.find_with_warnings()
  end

  @doc """
  Finds impure files (files with side effects).

  ## Returns
  - List of file paths with side effects detected

  ## Examples

      impure = Quality.find_impure()
      # => ["lib/database.ex", "lib/logger.ex"]
  """
  @spec find_impure() :: [String.t()]
  def find_impure do
    QualityStore.find_impure()
  end

  @doc """
  Retrieves stored quality metrics for a file.

  ## Parameters
  - `path`: File path

  ## Returns
  - `{:ok, metrics}` - Stored metrics map
  - `{:error, :not_found}` - File not analyzed or metrics not stored

  ## Examples

      {:ok, metrics} = Quality.get_metrics("lib/my_module.ex")
      metrics.cyclomatic  # => 5
  """
  @spec get_metrics(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_metrics(path) do
    QualityStore.get_metrics(path)
  end

  @doc """
  Clears all stored quality metrics.

  Removes all quality_metrics nodes from the knowledge graph.
  Does not affect other graph data (modules, functions, etc.).

  ## Examples

      :ok = Quality.clear_all()
  """
  @spec clear_all() :: :ok
  def clear_all do
    QualityStore.clear_all()
  end

  @doc """
  Returns the number of files with stored quality metrics.

  ## Examples

      count = Quality.count()  # => 42
  """
  @spec count() :: non_neg_integer()
  def count do
    QualityStore.count()
  end

  @doc """
  Generates a comprehensive quality report.

  ## Parameters
  - `opts`: Keyword list of options
    - `:type` - Report type: `:summary`, `:detailed`, `:by_language` (default: `:summary`)
    - `:format` - Output format: `:text`, `:map` (default: `:map`)

  ## Returns
  - Report content (map or formatted string based on format option)

  ## Examples

      # Summary report as map
      report = Quality.generate_report()

      # Detailed report as text
      report = Quality.generate_report(type: :detailed, format: :text)

      # Language breakdown
      report = Quality.generate_report(type: :by_language)
  """
  @spec generate_report(keyword()) :: map() | String.t()
  def generate_report(opts \\ []) do
    report_type = Keyword.get(opts, :type, :summary)
    format = Keyword.get(opts, :format, :map)

    report_data =
      case report_type do
        :summary ->
          statistics()

        :detailed ->
          %{
            statistics: statistics(),
            most_complex: most_complex(limit: 10),
            with_warnings: find_with_warnings(),
            impure_files: find_impure()
          }

        :by_language ->
          statistics_by_language()

        _ ->
          %{error: "Unknown report type: #{report_type}"}
      end

    case format do
      :text -> format_report_as_text(report_data, report_type)
      :map -> report_data
      _ -> report_data
    end
  end

  # Private functions

  # Build module analysis from stored metrics
  defp build_module_analysis(metrics, module, file_path, sort_by, threshold) do
    per_function = Map.get(metrics, :per_function, %{})

    # Extract all functions for this module
    functions =
      per_function
      |> Enum.filter(fn {func_key, _metrics} ->
        String.starts_with?(func_key, "#{module}.")
      end)
      |> Enum.map(fn {func_key, func_metrics} ->
        # Parse function key: "Module.function/arity"
        [_module, name_arity] = String.split(func_key, ".", parts: 2)
        [name_str, arity_str] = String.split(name_arity, "/")
        name = String.to_atom(name_str)
        arity = String.to_integer(arity_str)

        %{
          function: name,
          arity: arity,
          cyclomatic: Map.get(func_metrics, :cyclomatic, 0),
          cognitive: Map.get(func_metrics, :cognitive, 0),
          nesting: Map.get(func_metrics, :nesting, 0),
          halstead: Map.get(func_metrics, :halstead, %{}),
          loc: Map.get(func_metrics, :loc, %{})
        }
      end)

    # Apply threshold filter if specified
    functions =
      if threshold do
        Enum.filter(functions, fn func -> func.cyclomatic >= threshold end)
      else
        functions
      end

    # Sort functions
    functions = sort_functions(functions, sort_by)
    fun_len = length(functions)

    # Calculate totals
    total_cyclomatic = Enum.sum(Enum.map(functions, & &1.cyclomatic))
    total_cognitive = Enum.sum(Enum.map(functions, & &1.cognitive))

    {avg_cyclomatic, avg_cognitive} =
      case functions do
        [_ | _] -> {total_cyclomatic / fun_len, total_cognitive / fun_len}
        [] -> {0.0, 0.0}
      end

    {:ok,
     %{
       module: module,
       file: file_path,
       language: Map.get(metrics, :language, :unknown),
       total_cyclomatic: total_cyclomatic,
       total_cognitive: total_cognitive,
       avg_cyclomatic: Float.round(avg_cyclomatic, 2),
       avg_cognitive: Float.round(avg_cognitive, 2),
       max_cyclomatic: Map.get(metrics, :cyclomatic, 0),
       max_cognitive: Map.get(metrics, :cognitive, 0),
       max_nesting: Map.get(metrics, :max_nesting, 0),
       function_count: length(functions),
       functions: functions
     }}
  end

  # Sort functions by specified metric
  defp sort_functions(functions, :name) do
    Enum.sort_by(functions, fn func -> {func.function, func.arity} end)
  end

  defp sort_functions(functions, :cyclomatic) do
    Enum.sort_by(functions, & &1.cyclomatic, :desc)
  end

  defp sort_functions(functions, :cognitive) do
    Enum.sort_by(functions, & &1.cognitive, :desc)
  end

  defp sort_functions(functions, :nesting) do
    Enum.sort_by(functions, & &1.nesting, :desc)
  end

  defp sort_functions(functions, _), do: functions

  # Convert fresh analysis result to stored metrics format
  defp convert_result_to_stored_format(result) do
    %{
      path: result.path,
      language: result.language,
      cyclomatic: get_in(result, [:complexity, :cyclomatic]) || 0,
      cognitive: get_in(result, [:complexity, :cognitive]) || 0,
      max_nesting: get_in(result, [:complexity, :max_nesting]) || 0,
      halstead: get_in(result, [:complexity, :halstead]) || %{},
      loc: get_in(result, [:complexity, :loc]) || %{},
      function_metrics: get_in(result, [:complexity, :function_metrics]) || %{},
      per_function: get_in(result, [:complexity, :per_function]) || %{},
      purity_pure?: get_in(result, [:purity, :pure?]),
      purity_effects: get_in(result, [:purity, :effects]) || [],
      purity_confidence: get_in(result, [:purity, :confidence]) || :unknown,
      warnings: result[:warnings] || [],
      timestamp: result[:timestamp] || DateTime.utc_now()
    }
  end

  # Extract function-specific metrics from stored metrics
  defp extract_function_metrics(metrics, module, function, arity) do
    func_key = "#{module}.#{function}/#{arity}"

    case get_in(metrics, [:per_function, func_key]) do
      nil ->
        {:error, {:function_not_found, {module, function, arity}}}

      func_metrics ->
        {:ok,
         %{
           module: module,
           function: function,
           arity: arity,
           cyclomatic: Map.get(func_metrics, :cyclomatic, 0),
           cognitive: Map.get(func_metrics, :cognitive, 0),
           nesting: Map.get(func_metrics, :nesting, 0),
           halstead: Map.get(func_metrics, :halstead, %{}),
           loc: Map.get(func_metrics, :loc, %{})
         }}
    end
  end

  # Extract function metrics from fresh analysis result
  defp extract_function_metrics_from_result(result, module, function, arity) do
    func_key = "#{module}.#{function}/#{arity}"

    case get_in(result, [:complexity, :per_function, func_key]) do
      nil ->
        {:error, {:function_not_found, {module, function, arity}}}

      func_metrics ->
        {:ok,
         %{
           module: module,
           function: function,
           arity: arity,
           cyclomatic: Map.get(func_metrics, :cyclomatic, 0),
           cognitive: Map.get(func_metrics, :cognitive, 0),
           nesting: Map.get(func_metrics, :nesting, 0),
           halstead: Map.get(func_metrics, :halstead, %{}),
           loc: Map.get(func_metrics, :loc, %{})
         }}
    end
  end

  defp format_report_as_text(data, :summary) do
    """
    Code Quality Summary
    ====================

    Total Files: #{data.total_files}

    Complexity Metrics:
    - Average Cyclomatic: #{data.avg_cyclomatic}
    - Average Cognitive: #{data.avg_cognitive}
    - Average Nesting: #{data.avg_nesting}
    - Max Cyclomatic: #{data.max_cyclomatic}
    - Max Cognitive: #{data.max_cognitive}
    - Max Nesting: #{data.max_nesting}

    Quality Indicators:
    - Files with Warnings: #{data.files_with_warnings}
    - Impure Files: #{data.impure_files}

    Languages: #{format_languages(data.languages)}
    """
  end

  defp format_report_as_text(data, :detailed) do
    summary = format_report_as_text(data.statistics, :summary)

    complex_section =
      if Enum.empty?(data.most_complex) do
        "No complex files found.\n"
      else
        "Most Complex Files:\n" <>
          Enum.map_join(data.most_complex, "\n", fn {path, value} ->
            "  - #{path}: #{value}"
          end)
      end

    warnings_section =
      if Enum.empty?(data.with_warnings) do
        "No warnings.\n"
      else
        "Files with Warnings:\n" <>
          Enum.map_join(data.with_warnings, "\n", fn {path, warnings} ->
            "  - #{path}: #{length(warnings)} warning(s)"
          end)
      end

    summary <> "\n" <> complex_section <> "\n\n" <> warnings_section
  end

  defp format_report_as_text(data, :by_language) do
    if Enum.empty?(data) do
      "No language-specific data available.\n"
    else
      "Code Quality by Language\n" <>
        "========================\n\n" <>
        Enum.map_join(data, "\n\n", fn {lang, stats} ->
          """
          #{lang |> Atom.to_string() |> String.upcase()}:
          - Files: #{stats.total_files}
          - Avg Cyclomatic: #{stats.avg_cyclomatic}
          - Avg Cognitive: #{stats.avg_cognitive}
          - Max Cyclomatic: #{stats.max_cyclomatic}
          """
          |> String.trim()
        end)
    end
  end

  defp format_languages(languages) when map_size(languages) == 0, do: "None"

  defp format_languages(languages) do
    Enum.map_join(languages, ", ", fn {lang, count} -> "#{lang} (#{count})" end)
  end

  @doc """
  Generates a comprehensive report including both quality and security metrics.

  This convenience function combines quality analysis with security scanning
  to provide a holistic view of code health.

  ## Parameters
  - `path`: Directory path to analyze
  - `opts`: Keyword list of options
    - `:min_severity` - Minimum security severity to report (default: `:medium`)
    - `:include_security` - Include security analysis (default: `true`)
    - All options from `analyze_directory/2`

  ## Returns
  - `{:ok, report}` - Comprehensive report map
  - `{:error, reason}` - Analysis failed

  ## Report Structure
  ```elixir
  %{
    quality: %{
      statistics: quality_report(),
      most_complex: [{path, complexity}],
      with_warnings: [{path, warnings}],
      impure_files: [path]
    },
    security: %{
      total_vulnerabilities: integer(),
      by_severity: %{critical: integer(), high: integer(), ...},
      files_with_vulnerabilities: [path],
      summary: string()
    }
  }
  ```

  ## Examples

      # Full analysis with security
      {:ok, report} = Quality.comprehensive_report("lib/")
      report.quality.statistics.avg_cyclomatic  # => 4.5
      report.security.total_vulnerabilities     # => 3

      # Quality only
      {:ok, report} = Quality.comprehensive_report("lib/", include_security: false)

      # Only critical security issues
      {:ok, report} = Quality.comprehensive_report("lib/", min_severity: :critical)
  """
  @spec comprehensive_report(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def comprehensive_report(path, opts \\ []) do
    include_security = Keyword.get(opts, :include_security, true)
    min_severity = Keyword.get(opts, :min_severity, :medium)

    # Quality analysis
    with {:ok, _results} <- analyze_directory(path, opts) do
      quality_report = %{
        statistics: statistics(),
        most_complex: most_complex(limit: 10),
        with_warnings: find_with_warnings(),
        impure_files: find_impure()
      }

      # Security analysis (optional)
      security_report =
        if include_security do
          case Security.analyze_directory(path, min_severity: min_severity) do
            {:ok, sec_results} ->
              audit = Security.audit_report(sec_results)

              %{
                total_vulnerabilities:
                  Enum.sum(Enum.map(sec_results, & &1.total_vulnerabilities)),
                by_severity: audit.by_severity,
                files_with_vulnerabilities:
                  sec_results
                  |> Enum.filter(& &1.has_vulnerabilities?)
                  |> Enum.map(& &1.file),
                summary: audit.summary
              }

            {:error, reason} ->
              Logger.warning("Security analysis failed: #{inspect(reason)}")

              %{
                total_vulnerabilities: 0,
                by_severity: %{},
                files_with_vulnerabilities: [],
                summary: "Security analysis unavailable",
                error: reason
              }
          end
        else
          nil
        end

      report = %{
        quality: quality_report,
        security: security_report,
        timestamp: DateTime.utc_now()
      }

      {:ok, report}
    end
  end

  @doc """
  Finds complex code in a directory.

  Convenience function that analyzes a directory and returns functions
  exceeding the complexity threshold.

  ## Options

  - `:min_complexity` - Minimum cyclomatic complexity (default: 10)

  ## Examples

      {:ok, functions} = Quality.find_complex_code("lib/", min_complexity: 15)
  """
  @spec find_complex_code(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def find_complex_code(path, opts \\ []) do
    alias Ragex.Graph.Store

    with {:ok, _stats} <- analyze_directory(path, opts) do
      min_complexity = Keyword.get(opts, :min_complexity, 10)

      # Get all functions from knowledge graph
      functions = Store.list_functions(limit: 100_000)

      # Filter by complexity and enrich with full metadata
      complex_functions =
        functions
        |> Enum.filter(fn func_node ->
          # Check if this function's file was analyzed
          file = Map.get(func_node.data, :file)

          if file do
            # Get metrics for this file
            case QualityStore.get_metrics(file) do
              {:ok, metrics} ->
                # Get per-function metrics
                {module, name, arity} = func_node.id

                complexity =
                  metrics
                  |> Map.get(:per_function, [])
                  |> Enum.reduce(0, fn per_func, acc ->
                    per_func
                    |> Map.get({module, name, arity}, %{})
                    |> Map.get(:cyclomatic, 0)
                    |> Kernel.+(acc)
                  end)

                complexity >= min_complexity

              {:error, _} ->
                false
            end
          else
            false
          end
        end)
        |> Enum.map(fn func_node ->
          {module, name, arity} = func_node.id
          file = Map.get(func_node.data, :file)
          line = Map.get(func_node.data, :line)

          # Get metrics for detailed complexity info
          func_metrics =
            case QualityStore.get_metrics(file) do
              {:ok, metrics} ->
                per_func = Map.get(metrics, :per_function, %{})
                Map.get(per_func, {module, name, arity}, %{})

              {:error, _} ->
                %{}
            end

          %{
            module: module,
            name: name,
            arity: arity,
            file: file,
            line: line,
            cyclomatic_complexity: Map.get(func_metrics, :cyclomatic, 0),
            cognitive_complexity: Map.get(func_metrics, :cognitive),
            max_nesting: Map.get(func_metrics, :max_nesting),
            location: if(line, do: "#{file}:#{line}", else: file)
          }
        end)
        |> Enum.sort_by(& &1.cyclomatic_complexity, :desc)

      {:ok, complex_functions}
    end
  end

  @doc """
  Analyzes directory quality metrics.

  Convenience function that returns a quality score and statistics.

  ## Options

  - `:min_complexity` - Complexity threshold (default: 10)

  ## Examples

      {:ok, metrics} = Quality.analyze_quality("lib/")
      metrics.overall_score  # => 75
  """
  @spec analyze_quality(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def analyze_quality(path, opts \\ []) do
    with {:ok, _stats} <- analyze_directory(path, opts) do
      stats = statistics()
      complex = find_complex(opts)

      metrics = %{
        overall_score: calculate_quality_score(stats),
        files_analyzed: stats.total_files,
        average_complexity: stats.avg_cyclomatic,
        max_complexity: stats.max_cyclomatic,
        complex_functions: length(complex),
        complex_function_list: complex,
        statistics: stats
      }

      {:ok, metrics}
    end
  end

  # Calculate overall quality score based on various metrics
  defp calculate_quality_score(stats) do
    avg_cyclomatic = stats.avg_cyclomatic
    max_cyclomatic = stats.max_cyclomatic
    avg_cognitive = stats.avg_cognitive

    # Base score from average complexity (lower is better)
    complexity_score = max(0, 100 - avg_cyclomatic * 5)

    # Penalty for max complexity
    max_penalty = min(20, max(0, (max_cyclomatic - 15) * 2))

    # Penalty for cognitive complexity
    cognitive_penalty = min(15, max(0, avg_cognitive - 10))

    # Calculate final score
    score = complexity_score - max_penalty - cognitive_penalty
    round(max(0, min(100, score)))
  end
end
