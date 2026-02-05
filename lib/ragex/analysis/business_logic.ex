defmodule Ragex.Analysis.BusinessLogic do
  @moduledoc """
  Business logic analysis using Metastatic analyzers.

  Provides unified access to 20 language-agnostic business logic analyzers
  that detect common anti-patterns and issues across multiple languages.

  ## Location Information

  Note: Business logic analyzers operate at the MetaAST (M2) abstraction level,
  which intentionally abstracts away language-specific details like line numbers.
  This is what makes them language-agnostic. As a result, precise line/column
  location information is typically not available. Issues will include file paths
  and function context when available.

  ## Analyzers

  ### Tier 1: Pure MetaAST (Language-Agnostic)
  - **CallbackHell** - Detects deeply nested conditionals (M2.1 Core)
  - **MissingErrorHandling** - Pattern matching without error case (M2.2 Extended)
  - **SilentErrorCase** - Conditionals with only success path (M2.1 Core)
  - **SwallowingException** - Exception handling without logging (M2.2 Extended)
  - **HardcodedValue** - Hardcoded URLs/IPs in literals (M2.1 Core)
  - **NPlusOneQuery** - DB queries in collection operations (M2.2 Extended)
  - **InefficientFilter** - Fetch-all then filter pattern (M2.2 Extended)
  - **UnmanagedTask** - Unsupervised async operations (M2.2 Extended)
  - **TelemetryInRecursiveFunction** - Metrics in recursive functions (M2.1 Core)

  ### Tier 2: Function Name Heuristics
  - **MissingTelemetryForExternalHttp** - HTTP calls without telemetry
  - **SyncOverAsync** - Blocking operations in async contexts
  - **DirectStructUpdate** - Struct updates bypassing validation
  - **MissingHandleAsync** - Unmonitored async operations

  ### Tier 3: Naming Conventions
  - **BlockingInPlug** - Blocking I/O in middleware
  - **MissingTelemetryInAuthPlug** - Auth checks without audit logging
  - **MissingTelemetryInLiveviewMount** - Component lifecycle without metrics
  - **MissingTelemetryInObanWorker** - Background jobs without telemetry

  ### Tier 4: Content Analysis
  - **MissingPreload** - Database queries without eager loading
  - **InlineJavascript** - Inline scripts in strings (XSS risk)
  - **MissingThrottle** - Expensive operations without rate limiting

  ## Usage

      alias Ragex.Analysis.BusinessLogic

      # Analyze single file
      {:ok, result} = BusinessLogic.analyze_file("lib/my_module.ex")

      # Check for issues
      result.has_issues?     # => true/false
      result.total_issues    # => 5
      result.critical_count  # => 1

      # Analyze directory
      {:ok, results} = BusinessLogic.analyze_directory("lib/")

      # Run specific analyzers
      {:ok, result} = BusinessLogic.analyze_file("lib/my_module.ex",
        analyzers: [:callback_hell, :missing_error_handling])

      # Filter by severity
      {:ok, results} = BusinessLogic.analyze_directory("lib/",
        min_severity: :high)

      # Generate report
      report = BusinessLogic.audit_report(results)
  """

  alias Metastatic.Adapter
  alias Metastatic.Analysis.{Registry, Runner}
  alias Ragex.Analysis.LocationEnricher
  require Logger

  @type issue :: %{
          analyzer: atom(),
          category: atom(),
          severity: :critical | :high | :medium | :low | :info,
          description: String.t(),
          suggestion: String.t() | nil,
          context: map(),
          location: location() | nil
        }

  @type location :: %{
          line: non_neg_integer() | nil,
          column: non_neg_integer() | nil,
          function: String.t() | nil
        }

  @type analysis_result :: %{
          file: String.t(),
          language: atom(),
          issues: [issue()],
          has_issues?: boolean(),
          total_issues: non_neg_integer(),
          critical_count: non_neg_integer(),
          high_count: non_neg_integer(),
          medium_count: non_neg_integer(),
          low_count: non_neg_integer(),
          info_count: non_neg_integer(),
          by_analyzer: %{atom() => non_neg_integer()},
          timestamp: DateTime.t()
        }

  @type directory_result :: %{
          total_files: non_neg_integer(),
          files_with_issues: non_neg_integer(),
          total_issues: non_neg_integer(),
          by_severity: %{atom() => non_neg_integer()},
          by_analyzer: %{atom() => non_neg_integer()},
          results: [analysis_result()],
          summary: String.t()
        }

  # All available business logic analyzers
  @available_analyzers [
    # Tier 1: Pure MetaAST
    :callback_hell,
    :missing_error_handling,
    :silent_error_case,
    :swallowing_exception,
    :hardcoded_value,
    :n_plus_one_query,
    :inefficient_filter,
    :unmanaged_task,
    :telemetry_in_recursive_function,
    # Tier 2: Function Name Heuristics
    :missing_telemetry_for_external_http,
    :sync_over_async,
    :direct_struct_update,
    :missing_handle_async,
    # Tier 3: Naming Conventions
    :blocking_in_plug,
    :missing_telemetry_in_auth_plug,
    :missing_telemetry_in_liveview_mount,
    :missing_telemetry_in_oban_worker,
    # Tier 4: Content Analysis
    :missing_preload,
    :inline_javascript,
    :missing_throttle
  ]

  # Map analyzer names to Metastatic modules
  @analyzer_modules %{
    callback_hell: Metastatic.Analysis.BusinessLogic.CallbackHell,
    missing_error_handling: Metastatic.Analysis.BusinessLogic.MissingErrorHandling,
    silent_error_case: Metastatic.Analysis.BusinessLogic.SilentErrorCase,
    swallowing_exception: Metastatic.Analysis.BusinessLogic.SwallowingException,
    hardcoded_value: Metastatic.Analysis.BusinessLogic.HardcodedValue,
    n_plus_one_query: Metastatic.Analysis.BusinessLogic.NPlusOneQuery,
    inefficient_filter: Metastatic.Analysis.BusinessLogic.InefficientFilter,
    unmanaged_task: Metastatic.Analysis.BusinessLogic.UnmanagedTask,
    telemetry_in_recursive_function:
      Metastatic.Analysis.BusinessLogic.TelemetryInRecursiveFunction,
    missing_telemetry_for_external_http:
      Metastatic.Analysis.BusinessLogic.MissingTelemetryForExternalHttp,
    sync_over_async: Metastatic.Analysis.BusinessLogic.SyncOverAsync,
    direct_struct_update: Metastatic.Analysis.BusinessLogic.DirectStructUpdate,
    missing_handle_async: Metastatic.Analysis.BusinessLogic.MissingHandleAsync,
    blocking_in_plug: Metastatic.Analysis.BusinessLogic.BlockingInPlug,
    missing_telemetry_in_auth_plug: Metastatic.Analysis.BusinessLogic.MissingTelemetryInAuthPlug,
    missing_telemetry_in_liveview_mount:
      Metastatic.Analysis.BusinessLogic.MissingTelemetryInLiveviewMount,
    missing_telemetry_in_oban_worker:
      Metastatic.Analysis.BusinessLogic.MissingTelemetryInObanWorker,
    missing_preload: Metastatic.Analysis.BusinessLogic.MissingPreload,
    inline_javascript: Metastatic.Analysis.BusinessLogic.InlineJavascript,
    missing_throttle: Metastatic.Analysis.BusinessLogic.MissingThrottle
  }

  @doc """
  Returns the list of available business logic analyzers.

  ## Examples

      iex> Ragex.Analysis.BusinessLogic.available_analyzers()
      [:callback_hell, :missing_error_handling, ...]
  """
  @spec available_analyzers() :: [atom()]
  def available_analyzers, do: @available_analyzers

  @doc """
  Analyzes a single file for business logic issues.

  ## Options

  - `:analyzers` - List of analyzer names to run (default: all)
  - `:language` - Explicit language (default: auto-detect)
  - `:min_severity` - Minimum severity to report (default: :info)
  - `:config` - Configuration map for analyzers

  ## Examples

      {:ok, result} = BusinessLogic.analyze_file("lib/my_module.ex")
      result.has_issues?  # => false

      {:ok, result} = BusinessLogic.analyze_file("lib/my_module.ex",
        analyzers: [:callback_hell, :missing_error_handling],
        min_severity: :high)
  """
  @spec analyze_file(String.t(), keyword()) :: {:ok, analysis_result()} | {:error, term()}
  def analyze_file(path, opts \\ []) do
    language = Keyword.get(opts, :language, detect_language(path))
    analyzers = Keyword.get(opts, :analyzers, :all)
    min_severity = Keyword.get(opts, :min_severity, :info)
    config = Keyword.get(opts, :config, %{})

    with {:ok, content} <- File.read(path),
         {:ok, adapter} <- get_adapter(language),
         {:ok, doc} <- parse_document(adapter, content, language),
         {:ok, report} <- run_analyzers(doc, analyzers, config) do
      result = build_result(path, language, report, min_severity)
      {:ok, result}
    else
      {:error, reason} = error ->
        Logger.warning("Business logic analysis failed for #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Analyzes all files in a directory for business logic issues.

  ## Options

  - `:recursive` - Recursively analyze subdirectories (default: true)
  - `:parallel` - Use parallel processing (default: true)
  - `:max_concurrency` - Maximum concurrent analyses (default: System.schedulers_online())
  - Plus all options from `analyze_file/2`

  ## Examples

      {:ok, results} = BusinessLogic.analyze_directory("lib/")
      total_issues = results.total_issues
  """
  @spec analyze_directory(String.t(), keyword()) ::
          {:ok, directory_result()} | {:error, term()}
  def analyze_directory(path, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, true)
    parallel = Keyword.get(opts, :parallel, true)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    case find_source_files(path, recursive) do
      {:ok, []} ->
        {:ok, empty_directory_result()}

      {:ok, files} ->
        results =
          if parallel do
            analyze_files_parallel(files, opts, max_concurrency)
          else
            analyze_files_sequential(files, opts)
          end

        {:ok, aggregate_results(results)}

      {:error, reason} = error ->
        Logger.error("Failed to list directory #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Generates a comprehensive business logic audit report.

  Returns a formatted map with:
  - Summary statistics
  - Issues grouped by severity
  - Issues grouped by analyzer
  - Recommendations

  ## Examples

      {:ok, results} = BusinessLogic.analyze_directory("lib/")
      report = BusinessLogic.audit_report(results.results)
      IO.puts(report.summary)
  """
  @spec audit_report([analysis_result()]) :: map()
  def audit_report(results) when is_list(results) do
    all_issues = Enum.flat_map(results, & &1.issues)

    %{
      summary: build_summary(results, all_issues),
      by_severity: group_by_severity(all_issues),
      by_analyzer: group_by_analyzer(all_issues),
      by_file: group_by_file(results),
      recommendations: generate_recommendations(all_issues),
      total_files: length(results),
      files_with_issues: Enum.count(results, & &1.has_issues?),
      timestamp: DateTime.utc_now()
    }
  end

  # Private functions

  defp detect_language(path) do
    case Path.extname(path) do
      ".ex" -> :elixir
      ".exs" -> :elixir
      ".erl" -> :erlang
      ".hrl" -> :erlang
      ".py" -> :python
      ".rb" -> :ruby
      ".hs" -> :haskell
      _ -> :unknown
    end
  end

  defp get_adapter(:elixir), do: {:ok, Metastatic.Adapters.Elixir}
  defp get_adapter(:erlang), do: {:ok, Metastatic.Adapters.Erlang}
  defp get_adapter(:python), do: {:ok, Metastatic.Adapters.Python}
  defp get_adapter(:ruby), do: {:ok, Metastatic.Adapters.Ruby}
  defp get_adapter(:haskell), do: {:ok, Metastatic.Adapters.Haskell}
  defp get_adapter(lang), do: {:error, {:unsupported_language, lang}}

  defp parse_document(adapter, content, language) do
    Adapter.abstract(adapter, content, language)
  end

  defp run_analyzers(doc, :all, config) do
    # Get all business logic analyzer modules
    analyzer_modules = Map.values(@analyzer_modules)

    # Ensure they're registered
    Enum.each(analyzer_modules, fn mod ->
      case Registry.get_by_name(mod.info().name) do
        nil -> Registry.register(mod)
        _ -> :ok
      end
    end)

    Runner.run(doc, analyzers: analyzer_modules, config: config)
  end

  defp run_analyzers(doc, analyzer_names, config) when is_list(analyzer_names) do
    # Map names to modules
    analyzer_modules =
      analyzer_names
      |> Enum.map(&Map.get(@analyzer_modules, &1))
      |> Enum.reject(&is_nil/1)

    # Ensure they're registered
    Enum.each(analyzer_modules, fn mod ->
      case Registry.get_by_name(mod.info().name) do
        nil -> Registry.register(mod)
        _ -> :ok
      end
    end)

    Runner.run(doc, analyzers: analyzer_modules, config: config)
  end

  defp build_result(path, language, report, min_severity) do
    # Convert Metastatic issues to our format
    issues =
      report.issues
      |> Enum.map(&format_issue(&1, path))
      |> filter_by_severity(min_severity)
      |> LocationEnricher.enrich_issues(path)

    severity_counts = count_by_severity(issues)
    analyzer_counts = count_by_analyzer(issues)
    issues_count = length(issues)

    %{
      file: path,
      language: language,
      issues: issues,
      has_issues?: issues_count > 0,
      total_issues: issues_count,
      critical_count: Map.get(severity_counts, :critical, 0),
      high_count: Map.get(severity_counts, :high, 0),
      medium_count: Map.get(severity_counts, :medium, 0),
      low_count: Map.get(severity_counts, :low, 0),
      info_count: Map.get(severity_counts, :info, 0),
      by_analyzer: analyzer_counts,
      timestamp: DateTime.utc_now()
    }
  end

  defp format_issue(meta_issue, file_path) do
    # Metastatic v0.5.0+ uses :message, older versions used :description
    message = Map.get(meta_issue, :message) || Map.get(meta_issue, :description, "No description")

    # Normalize severity levels - Metastatic may use :warning, :error, etc.
    # Ragex uses: :critical, :high, :medium, :low, :info
    severity = normalize_severity(meta_issue.severity)

    # Extract location from issue or node metadata
    location = extract_location(meta_issue)

    %{
      analyzer: meta_issue.analyzer,
      category: meta_issue.category,
      severity: severity,
      message: message,
      description: message,
      suggestion: Map.get(meta_issue, :suggestion),
      context: Map.get(meta_issue, :context, %{}),
      location: format_location(location),
      line: if(location, do: Map.get(location, :line), else: nil),
      column: if(location, do: Map.get(location, :column), else: nil),
      file: file_path
    }
  end

  defp extract_location(meta_issue) do
    # First try the issue's location field
    issue_location = Map.get(meta_issue, :location)

    # If location has actual values, use it
    if issue_location && (issue_location[:line] || issue_location[:column]) do
      issue_location
    else
      # Try to extract from metadata context (Metastatic metadata may include function_name, etc.)
      metadata = Map.get(meta_issue, :metadata, %{})
      function_name = Map.get(metadata, :function) || Map.get(metadata, :function_name)

      if function_name do
        %{
          line: nil,
          column: nil,
          function: function_name
        }
      else
        # Try to extract from node metadata
        case Map.get(meta_issue, :node) do
          nil ->
            nil

          node when is_tuple(node) ->
            extract_location_from_node(node)

          _ ->
            nil
        end
      end
    end
  end

  defp extract_location_from_node(node) do
    # Improved Metastatic embeds line numbers deep in the AST node tree
    # We need to traverse the entire node to find any metadata with line information
    find_line_in_node(node)
  end

  # Recursively traverse MetaAST node to find line/column metadata
  defp find_line_in_node(node) when is_tuple(node) do
    # Check each element of the tuple
    node
    |> Tuple.to_list()
    |> Enum.find_value(&find_line_in_node/1)
  end

  defp find_line_in_node(list) when is_list(list) do
    # Check each element of the list
    Enum.find_value(list, &find_line_in_node/1)
  end

  defp find_line_in_node(meta) when is_map(meta) do
    # Check if this map has line/column info
    extract_meta_location(meta)
  end

  defp find_line_in_node(_), do: nil

  defp extract_meta_location(meta) when is_map(meta) do
    line = Map.get(meta, :line) || Map.get(meta, :start_line)
    column = Map.get(meta, :column) || Map.get(meta, :start_column)

    if line || column do
      %{
        line: line,
        column: column,
        function: Map.get(meta, :function)
      }
    else
      nil
    end
  end

  defp extract_meta_location(_), do: nil

  defp format_location(nil), do: nil

  defp format_location(loc) do
    %{
      line: Map.get(loc, :line),
      column: Map.get(loc, :column),
      function: Map.get(loc, :function)
    }
  end

  # Normalize Metastatic severity levels to Ragex standard levels
  defp normalize_severity(:error), do: :critical
  defp normalize_severity(:warning), do: :medium
  defp normalize_severity(:critical), do: :critical
  defp normalize_severity(:high), do: :high
  defp normalize_severity(:medium), do: :medium
  defp normalize_severity(:low), do: :low
  defp normalize_severity(:info), do: :info
  # Default to medium for unknown
  defp normalize_severity(_), do: :medium

  defp filter_by_severity(issues, :info), do: issues

  defp filter_by_severity(issues, min_severity) do
    severity_levels = [:info, :low, :medium, :high, :critical]
    min_index = Enum.find_index(severity_levels, &(&1 == min_severity)) || 0

    Enum.filter(issues, fn issue ->
      issue_index = Enum.find_index(severity_levels, &(&1 == issue.severity)) || 0
      issue_index >= min_index
    end)
  end

  defp count_by_severity(issues) do
    Enum.reduce(issues, %{}, fn issue, acc ->
      Map.update(acc, issue.severity, 1, &(&1 + 1))
    end)
  end

  defp count_by_analyzer(issues) do
    Enum.reduce(issues, %{}, fn issue, acc ->
      Map.update(acc, issue.analyzer, 1, &(&1 + 1))
    end)
  end

  defp find_source_files(path, recursive) do
    cond do
      # If path is a file, return it directly
      File.regular?(path) ->
        {:ok, [path]}

      # If path is a directory, use wildcard
      File.dir?(path) ->
        pattern =
          if recursive do
            Path.join([path, "**", "*.{ex,exs,erl,hrl,py,rb,hs}"])
          else
            Path.join([path, "*.{ex,exs,erl,hrl,py,rb,hs}"])
          end

        files = Path.wildcard(pattern)
        {:ok, files}

      # Path doesn't exist
      true ->
        {:error, {:not_found, path}}
    end
  rescue
    e -> {:error, {:wildcard_failed, e}}
  end

  defp analyze_files_sequential(files, opts) do
    Enum.reduce(files, [], fn file, acc ->
      case analyze_file(file, opts) do
        {:ok, result} -> [result | acc]
        {:error, reason} -> [build_error_result(file, reason) | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp analyze_files_parallel(files, opts, max_concurrency) do
    files
    |> Task.async_stream(
      fn file ->
        case analyze_file(file, opts) do
          {:ok, result} -> result
          {:error, reason} -> build_error_result(file, reason)
        end
      end,
      max_concurrency: max_concurrency,
      timeout: 30_000
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> build_error_result("unknown", {:task_exit, reason})
    end)
  end

  defp build_error_result(path, error) do
    %{
      file: path,
      language: :unknown,
      issues: [],
      has_issues?: false,
      total_issues: 0,
      critical_count: 0,
      high_count: 0,
      medium_count: 0,
      low_count: 0,
      info_count: 0,
      by_analyzer: %{},
      timestamp: DateTime.utc_now(),
      error: error
    }
  end

  defp aggregate_results(results) do
    files_with_issues = Enum.count(results, & &1.has_issues?)
    total_issues = Enum.sum(Enum.map(results, & &1.total_issues))

    by_severity =
      results
      |> Enum.flat_map(& &1.issues)
      |> Enum.reduce(%{}, fn issue, acc ->
        Map.update(acc, issue.severity, 1, &(&1 + 1))
      end)

    by_analyzer =
      results
      |> Enum.flat_map(& &1.issues)
      |> Enum.reduce(%{}, fn issue, acc ->
        Map.update(acc, issue.analyzer, 1, &(&1 + 1))
      end)

    %{
      total_files: length(results),
      files_with_issues: files_with_issues,
      total_issues: total_issues,
      by_severity: by_severity,
      by_analyzer: by_analyzer,
      results: results,
      summary: build_summary_text(length(results), files_with_issues, total_issues, by_severity)
    }
  end

  defp empty_directory_result do
    %{
      total_files: 0,
      files_with_issues: 0,
      total_issues: 0,
      by_severity: %{},
      by_analyzer: %{},
      results: [],
      summary: "No files found"
    }
  end

  defp build_summary(results, all_issues) do
    total_files = length(results)
    files_with_issues = Enum.count(results, & &1.has_issues?)
    total_issues = length(all_issues)

    severity_counts = count_by_severity(all_issues)
    critical = Map.get(severity_counts, :critical, 0)
    high = Map.get(severity_counts, :high, 0)
    medium = Map.get(severity_counts, :medium, 0)
    low = Map.get(severity_counts, :low, 0)
    info = Map.get(severity_counts, :info, 0)

    status =
      cond do
        critical > 0 -> "CRITICAL - Immediate action required"
        high > 0 -> "HIGH RISK - Action recommended"
        medium > 0 -> "MEDIUM RISK - Review recommended"
        low > 0 -> "LOW RISK - Minor issues found"
        info > 0 -> "INFO - Informational findings"
        true -> "PASSED - No issues detected"
      end

    """
    Business Logic Analysis Summary
    ================================

    Status: #{status}

    Files Analyzed: #{total_files}
    Files with Issues: #{files_with_issues}
    Total Issues: #{total_issues}

    Severity Breakdown:
    - Critical: #{critical}
    - High: #{high}
    - Medium: #{medium}
    - Low: #{low}
    - Info: #{info}
    """
  end

  defp build_summary_text(total_files, files_with_issues, total_issues, by_severity) do
    if total_issues == 0 do
      "Analyzed #{total_files} files - no business logic issues detected"
    else
      severity_summary =
        by_severity
        |> Enum.sort_by(fn {sev, _} -> severity_order(sev) end, :desc)
        |> Enum.map_join(", ", fn {sev, count} -> "#{count} #{sev}" end)

      "Analyzed #{total_files} files - found #{total_issues} issue(s) in #{files_with_issues} file(s): #{severity_summary}"
    end
  end

  defp severity_order(:critical), do: 5
  defp severity_order(:high), do: 4
  defp severity_order(:medium), do: 3
  defp severity_order(:low), do: 2
  defp severity_order(:info), do: 1
  defp severity_order(_), do: 0

  defp group_by_severity(issues) do
    Enum.group_by(issues, & &1.severity)
    |> Enum.map(fn {severity, issues_list} ->
      {severity, Enum.sort_by(issues_list, & &1.analyzer)}
    end)
    |> Map.new()
  end

  defp group_by_analyzer(issues) do
    Enum.group_by(issues, & &1.analyzer)
    |> Enum.map(fn {analyzer, issues_list} ->
      {analyzer, Enum.sort_by(issues_list, & &1.severity, :desc)}
    end)
    |> Map.new()
  end

  defp group_by_file(results) do
    results
    |> Enum.filter(& &1.has_issues?)
    |> Enum.map(fn result ->
      {result.file, result.issues}
    end)
    |> Map.new()
  end

  defp generate_recommendations(issues) do
    issues
    |> Enum.group_by(& &1.analyzer)
    |> Enum.map(fn {analyzer, issues_list} ->
      count = length(issues_list)
      severity = Enum.max_by(issues_list, &severity_order(&1.severity)).severity

      %{
        analyzer: analyzer,
        count: count,
        severity: severity,
        recommendation: get_analyzer_recommendation(analyzer, count)
      }
    end)
    |> Enum.sort_by(&severity_order(&1.severity), :desc)
  end

  defp get_analyzer_recommendation(:callback_hell, count) do
    "Found #{count} instance(s) of deeply nested conditionals. Consider extracting complex conditions into separate functions or using guard clauses."
  end

  defp get_analyzer_recommendation(:missing_error_handling, count) do
    "Found #{count} instance(s) of pattern matching without error cases. Always handle both success and error cases explicitly."
  end

  defp get_analyzer_recommendation(:silent_error_case, count) do
    "Found #{count} instance(s) of conditionals with only success paths. Ensure all code paths are handled, especially error cases."
  end

  defp get_analyzer_recommendation(:swallowing_exception, count) do
    "Found #{count} instance(s) of exception handling without logging. Always log exceptions for debugging and monitoring."
  end

  defp get_analyzer_recommendation(:hardcoded_value, count) do
    "Found #{count} hardcoded value(s) (URLs/IPs). Move configuration to environment variables or config files."
  end

  defp get_analyzer_recommendation(:n_plus_one_query, count) do
    "Found #{count} potential N+1 query issue(s). Consider eager loading or batching database queries."
  end

  defp get_analyzer_recommendation(:inefficient_filter, count) do
    "Found #{count} inefficient filter pattern(s). Filter at the database level rather than fetching all records."
  end

  defp get_analyzer_recommendation(:unmanaged_task, count) do
    "Found #{count} unmanaged async task(s). Use supervised tasks or proper process supervision."
  end

  defp get_analyzer_recommendation(:telemetry_in_recursive_function, count) do
    "Found #{count} instance(s) of telemetry in recursive functions. Move telemetry outside the recursive loop to avoid performance issues."
  end

  defp get_analyzer_recommendation(:missing_telemetry_for_external_http, count) do
    "Found #{count} HTTP call(s) without telemetry. Add telemetry/logging for monitoring external service calls."
  end

  defp get_analyzer_recommendation(:sync_over_async, count) do
    "Found #{count} blocking operation(s) in async contexts. Use non-blocking alternatives or move to synchronous contexts."
  end

  defp get_analyzer_recommendation(:direct_struct_update, count) do
    "Found #{count} direct struct update(s) bypassing validation. Use proper update functions with validation."
  end

  defp get_analyzer_recommendation(:missing_handle_async, count) do
    "Found #{count} unmonitored async operation(s). Ensure async operations are properly monitored and their results handled."
  end

  defp get_analyzer_recommendation(:blocking_in_plug, count) do
    "Found #{count} blocking I/O operation(s) in plugs/middleware. Keep middleware fast; move expensive operations to background jobs."
  end

  defp get_analyzer_recommendation(:missing_telemetry_in_auth_plug, count) do
    "Found #{count} authentication check(s) without audit logging. Add telemetry for security monitoring."
  end

  defp get_analyzer_recommendation(:missing_telemetry_in_liveview_mount, count) do
    "Found #{count} LiveView mount(s) without telemetry. Add metrics to track component lifecycle and performance."
  end

  defp get_analyzer_recommendation(:missing_telemetry_in_oban_worker, count) do
    "Found #{count} background job(s) without telemetry. Add metrics to monitor job execution and failures."
  end

  defp get_analyzer_recommendation(:missing_preload, count) do
    "Found #{count} query/queries without preloading. Use preload to avoid N+1 queries."
  end

  defp get_analyzer_recommendation(:inline_javascript, count) do
    "Found #{count} inline JavaScript in strings. This is an XSS risk - use Content Security Policy and avoid inline scripts."
  end

  defp get_analyzer_recommendation(:missing_throttle, count) do
    "Found #{count} expensive operation(s) without rate limiting. Add throttling to prevent abuse and protect resources."
  end

  defp get_analyzer_recommendation(analyzer, count) do
    "Found #{count} #{analyzer} issue(s). Review and address these concerns."
  end
end
