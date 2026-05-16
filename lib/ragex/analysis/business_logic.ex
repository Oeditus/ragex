defmodule Ragex.Analysis.BusinessLogic do
  @moduledoc """
  Business logic analysis using Metastatic analyzers.

  Provides unified access to 33 language-agnostic business logic analyzers
  that detect common anti-patterns, security vulnerabilities, and issues
  across multiple languages.

  ## Semantic Analysis with OpKind

  Many analyzers leverage Metastatic's OpKind semantic metadata system for
  accurate detection. OpKind tags function calls with their semantic meaning:
  - **Domain**: `:db`, `:http`, `:auth`, `:cache`, `:queue`, `:file`, `:external_api`
  - **Operation**: `:retrieve`, `:create`, `:update`, `:delete`, `:query`, etc.
  - **Framework**: `:ecto`, `:django`, `:activerecord`, `:requests`, etc.

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

  ### Tier 5: Security (CWE-based)
  - **SQLInjection** - SQL query string concatenation (CWE-89)
  - **XSSVulnerability** - Cross-site scripting risks (CWE-79)
  - **SSRFVulnerability** - Server-side request forgery (CWE-918)
  - **PathTraversal** - Directory traversal attacks (CWE-22)
  - **InsecureDirectObjectReference** - IDOR vulnerabilities (CWE-639)
  - **MissingAuthentication** - Unprotected endpoints (CWE-306)
  - **MissingAuthorization** - Missing access control (CWE-862)
  - **IncorrectAuthorization** - Flawed access control (CWE-863)
  - **MissingCSRFProtection** - CSRF vulnerabilities (CWE-352)
  - **SensitiveDataExposure** - Data leaks in logs/responses (CWE-200)
  - **UnrestrictedFileUpload** - Unsafe file uploads (CWE-434)
  - **ImproperInputValidation** - Input validation issues (CWE-20)

  ### Tier 6: Race Conditions
  - **TOCTOU** - Time-of-check-time-of-use vulnerabilities (CWE-367)

  ### Tier 7: Refactoring
  - **ImperativeStatusHandling** - Imperative status/state management (suggests FSM)

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

  alias Ragex.Analysis.{LocationEnricher, MetaCredoBridge}
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
    :missing_throttle,
    # Tier 5: Security (CWE-based)
    :sql_injection,
    :xss_vulnerability,
    :ssrf_vulnerability,
    :path_traversal,
    :insecure_direct_object_reference,
    :missing_authentication,
    :missing_authorization,
    :incorrect_authorization,
    :missing_csrf_protection,
    :sensitive_data_exposure,
    :unrestricted_file_upload,
    :improper_input_validation,
    # Tier 6: Race Conditions
    :toctou,
    # Tier 7: Refactoring
    :imperative_status_handling
  ]

  # Map analyzer names to MetaCredo check modules
  @analyzer_modules %{
    callback_hell: MetaCredo.Check.Warning.CallbackHell,
    missing_error_handling: MetaCredo.Check.Warning.MissingErrorHandling,
    silent_error_case: MetaCredo.Check.Warning.SilentErrorCase,
    swallowing_exception: MetaCredo.Check.Warning.SwallowingException,
    hardcoded_value: MetaCredo.Check.Security.HardcodedValue,
    n_plus_one_query: MetaCredo.Check.Warning.NPlusOneQuery,
    inefficient_filter: MetaCredo.Check.Warning.InefficientFilter,
    unmanaged_task: MetaCredo.Check.Warning.UnmanagedTask,
    telemetry_in_recursive_function: MetaCredo.Check.Observability.TelemetryInRecursiveFunction,
    missing_telemetry_for_external_http:
      MetaCredo.Check.Observability.MissingTelemetryForExternalHttp,
    sync_over_async: MetaCredo.Check.Warning.SyncOverAsync,
    direct_struct_update: MetaCredo.Check.Warning.DirectStructUpdate,
    missing_handle_async: MetaCredo.Check.Warning.MissingHandleAsync,
    blocking_in_plug: MetaCredo.Check.Warning.BlockingInPlug,
    missing_telemetry_in_auth_plug: MetaCredo.Check.Observability.MissingTelemetryInAuthPlug,
    missing_telemetry_in_liveview_mount:
      MetaCredo.Check.Observability.MissingTelemetryInLiveviewMount,
    missing_telemetry_in_oban_worker: MetaCredo.Check.Observability.MissingTelemetryInObanWorker,
    missing_preload: MetaCredo.Check.Warning.MissingPreload,
    inline_javascript: MetaCredo.Check.Security.InlineJavascript,
    missing_throttle: MetaCredo.Check.Warning.MissingThrottle,
    # Security checks (CWE-based)
    sql_injection: MetaCredo.Check.Security.SQLInjection,
    xss_vulnerability: MetaCredo.Check.Security.XSSVulnerability,
    ssrf_vulnerability: MetaCredo.Check.Security.SSRFVulnerability,
    path_traversal: MetaCredo.Check.Security.PathTraversal,
    insecure_direct_object_reference: MetaCredo.Check.Security.InsecureDirectObjectReference,
    missing_authentication: MetaCredo.Check.Security.MissingAuthentication,
    missing_authorization: MetaCredo.Check.Security.MissingAuthorization,
    incorrect_authorization: MetaCredo.Check.Security.IncorrectAuthorization,
    missing_csrf_protection: MetaCredo.Check.Security.MissingCSRFProtection,
    sensitive_data_exposure: MetaCredo.Check.Security.SensitiveDataExposure,
    unrestricted_file_upload: MetaCredo.Check.Security.UnrestrictedFileUpload,
    improper_input_validation: MetaCredo.Check.Security.ImproperInputValidation,
    # Race condition checks
    toctou: MetaCredo.Check.Security.TOCTOU,
    # Refactoring checks
    imperative_status_handling: MetaCredo.Check.Warning.ImperativeStatusHandling
  }

  @doc """
  Returns the list of available business logic analyzers.

  ## Examples

      iex> Ragex.Analysis.BusinessLogic.available_analyzers()
      [:callback_hell, :missing_error_handling, ...]
  """
  @spec available_analyzers() :: [atom()]
  def available_analyzers, do: @available_analyzers

  # Recommendations for each analyzer, including CWE references for security analyzers
  @recommendations %{
    # Original analyzers
    callback_hell: "Reduce nesting depth by extracting functions or using `with` statements.",
    missing_error_handling: "Add explicit error case handling with {:error, _} pattern match.",
    silent_error_case: "Add logging or proper error propagation in error cases.",
    swallowing_exception:
      "Add logging (Logger.error) before rescue clauses that catch exceptions.",
    hardcoded_value: "Extract hardcoded URLs/IPs to configuration or environment variables.",
    n_plus_one_query: "Use preloading or batch queries to avoid N+1 query patterns.",
    inefficient_filter:
      "Apply filtering at the database level using Ecto queries instead of fetching all records.",
    unmanaged_task:
      "Use Task.Supervisor or link tasks to supervision tree for proper error handling.",
    telemetry_in_recursive_function:
      "Move telemetry calls outside recursive functions to avoid metric explosion.",
    missing_telemetry_for_external_http:
      "Add telemetry spans around HTTP calls for observability.",
    sync_over_async: "Avoid blocking calls in async contexts; use async patterns consistently.",
    direct_struct_update: "Use changesets for struct updates to ensure validation.",
    missing_handle_async:
      "Handle async results with await, monitor, or trap_exit for reliability.",
    blocking_in_plug: "Avoid blocking I/O in plugs; offload to background workers.",
    missing_telemetry_in_auth_plug: "Add telemetry/audit logging for authentication operations.",
    missing_telemetry_in_liveview_mount:
      "Add telemetry for LiveView mount operations for debugging.",
    missing_telemetry_in_oban_worker: "Add telemetry spans in Oban workers for job monitoring.",
    missing_preload: "Use Repo.preload or include preloads in queries to avoid lazy loading.",
    inline_javascript:
      "Move JavaScript to separate files; sanitize any dynamic content to prevent XSS.",
    missing_throttle: "Add rate limiting for expensive operations to prevent abuse.",
    # Security analyzers (CWE-based)
    sql_injection:
      "CWE-89: Use parameterized queries or Ecto's query DSL; never interpolate user input into SQL strings.",
    xss_vulnerability:
      "CWE-79: Escape user-provided content with proper HTML encoding; use Phoenix's automatic escaping.",
    ssrf_vulnerability:
      "CWE-918: Validate and whitelist allowed URLs; block internal network ranges.",
    path_traversal:
      "CWE-22: Sanitize file paths; use Path.expand with a base directory to prevent directory traversal.",
    insecure_direct_object_reference:
      "CWE-639: Implement authorization checks to verify user access to resources.",
    missing_authentication:
      "CWE-306: Add authentication middleware to protect sensitive endpoints.",
    missing_authorization:
      "CWE-862: Implement authorization checks before accessing protected resources.",
    incorrect_authorization:
      "CWE-863: Review authorization logic; ensure proper role/permission checks.",
    missing_csrf_protection: "CWE-352: Enable CSRF protection for state-changing operations.",
    sensitive_data_exposure:
      "CWE-200: Encrypt sensitive data; avoid logging sensitive information.",
    unrestricted_file_upload:
      "CWE-434: Validate file types, size limits, and store outside webroot.",
    improper_input_validation:
      "CWE-20: Implement strict input validation with allowlists; reject malformed input.",
    # Race condition analyzers
    toctou:
      "CWE-367: Use atomic operations or proper locking; avoid time-of-check-time-of-use patterns.",
    # Refactoring analyzers
    imperative_status_handling:
      "Replace imperative status/state management with a proper FSM (Finitomata for Elixir, gen_statem for Erlang) for explicit transitions, validation, and observability."
  }

  @doc """
  Returns the recommendation for a specific analyzer.

  For security analyzers, includes CWE reference numbers.

  ## Examples

      iex> Ragex.Analysis.BusinessLogic.recommendation(:sql_injection)
      "CWE-89: Use parameterized queries or Ecto's query DSL..."
  """
  @spec recommendation(atom()) :: String.t()
  def recommendation(analyzer) when is_atom(analyzer) do
    Map.get(@recommendations, analyzer, "No recommendation available for #{analyzer}.")
  end

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

    case MetaCredoBridge.parse_file(path) do
      {:ok, source_file} ->
        checks = resolve_checks(analyzers)
        issues = MetaCredoBridge.run_checks(source_file, checks)
        result = build_result(path, language, issues, min_severity)
        {:ok, result}

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

  defp detect_language(path), do: Ragex.LanguageSupport.detect_language(path)

  # Resolve analyzer names to MetaCredo check tuples [{module, params}]
  defp resolve_checks(:all) do
    Enum.map(Map.values(@analyzer_modules), &{&1, []})
  end

  defp resolve_checks(analyzer_names) when is_list(analyzer_names) do
    analyzer_names
    |> Enum.map(&Map.get(@analyzer_modules, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{&1, []})
  end

  defp build_result(path, language, mc_issues, min_severity) do
    # Convert MetaCredo issues to our format
    issues =
      mc_issues
      |> Enum.map(&MetaCredoBridge.issue_to_ragex_issue(&1, path))
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
    Ragex.LanguageSupport.find_source_files(path, recursive: recursive, metastatic_only: true)
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

  # Security analyzer recommendations
  defp get_analyzer_recommendation(:sql_injection, count) do
    "CRITICAL: Found #{count} potential SQL injection(s) (CWE-89). Use parameterized queries instead of string concatenation."
  end

  defp get_analyzer_recommendation(:xss_vulnerability, count) do
    "CRITICAL: Found #{count} potential XSS vulnerability/ies (CWE-79). Sanitize user input and use proper output encoding."
  end

  defp get_analyzer_recommendation(:ssrf_vulnerability, count) do
    "CRITICAL: Found #{count} potential SSRF vulnerability/ies (CWE-918). Validate and whitelist URLs before making requests."
  end

  defp get_analyzer_recommendation(:path_traversal, count) do
    "CRITICAL: Found #{count} path traversal risk(s) (CWE-22). Sanitize file paths and use safe path joining."
  end

  defp get_analyzer_recommendation(:insecure_direct_object_reference, count) do
    "HIGH: Found #{count} potential IDOR issue(s) (CWE-639). Verify user authorization for each resource access."
  end

  defp get_analyzer_recommendation(:missing_authentication, count) do
    "HIGH: Found #{count} endpoint(s) without authentication (CWE-306). Add authentication middleware."
  end

  defp get_analyzer_recommendation(:missing_authorization, count) do
    "HIGH: Found #{count} operation(s) without authorization checks (CWE-862). Implement proper access control."
  end

  defp get_analyzer_recommendation(:incorrect_authorization, count) do
    "HIGH: Found #{count} flawed authorization check(s) (CWE-863). Review and fix access control logic."
  end

  defp get_analyzer_recommendation(:missing_csrf_protection, count) do
    "HIGH: Found #{count} form(s) without CSRF protection (CWE-352). Add CSRF tokens to state-changing forms."
  end

  defp get_analyzer_recommendation(:sensitive_data_exposure, count) do
    "HIGH: Found #{count} potential sensitive data exposure(s) (CWE-200). Remove sensitive data from logs/responses."
  end

  defp get_analyzer_recommendation(:unrestricted_file_upload, count) do
    "HIGH: Found #{count} unsafe file upload(s) (CWE-434). Validate file types and use secure storage."
  end

  defp get_analyzer_recommendation(:improper_input_validation, count) do
    "MEDIUM: Found #{count} input validation issue(s) (CWE-20). Validate and sanitize all user input."
  end

  defp get_analyzer_recommendation(:toctou, count) do
    "MEDIUM: Found #{count} TOCTOU race condition(s) (CWE-367). Use atomic operations or proper locking."
  end

  defp get_analyzer_recommendation(:imperative_status_handling, count) do
    "Found #{count} imperative status management pattern(s). Consider modeling entity lifecycle with an FSM (Finitomata, gen_statem) for explicit state transitions and validation."
  end

  defp get_analyzer_recommendation(analyzer, count) do
    "Found #{count} #{analyzer} issue(s). Review and address these concerns."
  end
end
