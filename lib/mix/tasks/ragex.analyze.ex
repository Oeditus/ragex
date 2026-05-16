# credo:disable-for-this-file Credo.Check.Refactor.Apply

defmodule Mix.Tasks.Ragex.Analyze do
  @moduledoc """
  Performs comprehensive analysis on a directory.

  Analyzes a directory using all available Ragex analysis features:
  - Security vulnerability scanning
  - Business logic analysis (33 analyzers, including 13 CWE-based security analyzers)
  - Code complexity metrics
  - Code smell detection
  - Code duplication detection
  - Dead code analysis
  - Dependency analysis
  - Quality metrics
  - Circular dependency detection
  - God module detection (excessive coupling)
  - Unstable module detection
  - Unused module detection
  - Coupling metrics report

  ## Usage

      mix ragex.analyze [options]

  ## Options

    * `--path PATH` - Directory to analyze (default: current directory)
    * `--output FILE` - Output file for results (default: stdout)
    * `--format FORMAT` - Output format: text, json, markdown (default: text)
    * `--security` - Include security analysis
    * `--business-logic` - Include business logic analysis (33 analyzers)
    * `--complexity` - Include complexity analysis
    * `--smells` - Include code smell detection
    * `--duplicates` - Include duplication detection
    * `--dead-code` - Include dead code analysis
    * `--dependencies` - Include dependency analysis
    * `--quality` - Include quality metrics
    * `--circulars` - Detect circular dependency clusters
    * `--god-modules` - Detect modules with excessive coupling
    * `--unstable-modules` - Detect highly unstable modules
    * `--unused-modules` - Detect unreferenced modules
    * `--coupling` - Full coupling metrics report
    * `--all` - Include all analyses (default)
    * `--severity LEVEL` - Minimum severity for issues: low, medium, high, critical (default: medium)
    * `--threshold FLOAT` - Duplication threshold 0.0-1.0 (default: 0.85)
    * `--min-complexity INT` - Minimum complexity to report (default: 10)
    * `--god-threshold INT` - Min total coupling for god module detection (default: 15)
    * `--instability-threshold FLOAT` - Min instability to report (default: 0.8)
    * `--verbose` - Show detailed progress information
    * `--with-empty` / `--without-empty` - Include/exclude empty issue reports in output (default: without-empty)
    * `--ci` - CI mode: plain text, no colors, non-zero exit on issues
    * `--strict` - Exit with code 1 if any issues are found
    * `--diff` - Diff mode: analyze only files changed between --base and --head (implies --ci)
    * `--base REF` - Base git ref for diff mode (default: origin/main)
    * `--head REF` - Head git ref for diff mode (default: HEAD)

  ## Examples

      # Analyze current directory with all features
      mix ragex.analyze

      # Analyze specific directory
      mix ragex.analyze --path lib/

      # Security and quality analysis only
      mix ragex.analyze --security --quality

      # Output to file in JSON format
      mix ragex.analyze --output report.json --format json

      # High severity issues only
      mix ragex.analyze --severity high

      # Analyze with custom thresholds
      mix ragex.analyze --threshold 0.9 --min-complexity 15

      # CI pipeline: check for circular deps, fail if found
      mix ragex.analyze --circulars --ci

      # CI pipeline: full dependency health check
      mix ragex.analyze --circulars --god-modules --unstable-modules --unused-modules --ci

      # Strict mode with custom thresholds
      mix ragex.analyze --coupling --god-threshold 20 --instability-threshold 0.9 --strict

      # Diff mode: only check changed files in a PR
      mix ragex.analyze --diff

      # Diff mode with custom base ref and GitHub Actions annotations
      mix ragex.analyze --diff --base origin/develop --format github

  """

  use Mix.Task

  alias Ragex.Analysis.Runner
  alias Ragex.Git.Diff
  alias Ragex.MCP.{Client, Delegate}

  @shortdoc "Performs comprehensive code analysis on a directory"

  # Check if CLI modules are available (not available when installed as archive)
  @has_cli_modules match?({:ok, _}, Code.ensure_compiled(Ragex.CLI.Colors))

  @impl Mix.Task
  def run(args) do
    # Parse options early to check format and decide whether to start MCP server
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          path: :string,
          output: :string,
          format: :string,
          security: :boolean,
          business_logic: :boolean,
          complexity: :boolean,
          smells: :boolean,
          duplicates: :boolean,
          dead_code: :boolean,
          dependencies: :boolean,
          quality: :boolean,
          circulars: :boolean,
          god_modules: :boolean,
          unstable_modules: :boolean,
          unused_modules: :boolean,
          coupling: :boolean,
          all: :boolean,
          severity: :string,
          threshold: :float,
          min_complexity: :integer,
          god_threshold: :integer,
          instability_threshold: :float,
          verbose: :boolean,
          with_empty: :boolean,
          ci: :boolean,
          strict: :boolean,
          diff: :boolean,
          base: :string,
          head: :string
        ]
      )

    config = build_config(opts)

    # If a Ragex server is already running, delegate all work to it
    # via MCP socket -- avoids starting a second BEAM VM / Bumblebee.
    if Client.server_running?() do
      run_delegated(config)
    else
      run_local(config)
    end
  end

  # Delegation path: all heavy work happens on the running server
  defp run_delegated(config) do
    show_progress = config.format != "json" and not config.ci

    if config.format == "json" or config.ci do
      Logger.configure(level: :emergency)
    end

    if show_progress do
      info_msg("Ragex Comprehensive Analysis (delegated to running server)")
      Mix.shell().info("")
    end

    # Build MCP tool arguments from config
    analyses_arg =
      Map.new(config.analyses, fn {k, v} -> {Atom.to_string(k), v} end)

    severity_str =
      case config.severity do
        [:low, :medium, :high, :critical] -> "low"
        [:medium, :high, :critical] -> "medium"
        [:high, :critical] -> "high"
        [:critical] -> "critical"
        _ -> "medium"
      end

    tool_args = %{
      "path" => config.path,
      "analyses" => analyses_arg,
      "severity" => severity_str,
      "threshold" => config.threshold,
      "min_complexity" => config.min_complexity,
      "god_threshold" => config.god_threshold,
      "instability_threshold" => config.instability_threshold
    }

    case Delegate.with_server(fn conn ->
           Delegate.call!(conn, "comprehensive_analyze", tool_args)
         end) do
      {:ok, remote_result} ->
        analyze_result =
          Map.get(remote_result, :analyze_result, %{
            files_analyzed: 0,
            entities_found: 0,
            errors: []
          })

        results = Map.get(remote_result, :results, %{})

        # Feed into the existing report/output/summary pipeline
        report = generate_report(config, analyze_result, results)
        output_results(config, report)
        print_summary(config, results)
        maybe_exit(config, report.results)

      {:error, reason} ->
        error_msg("Delegation to running server failed: #{inspect(reason)}")
        error_msg("Falling back to local execution...")
        run_local(config)
    end

    :ok
  end

  # Local path: starts the full application (original behavior)
  defp run_local(config) do
    # Disable MCP server for non-interactive formats (prevents hanging)
    if config.format in ["json", "markdown", "github"] or config.ci do
      Application.put_env(:ragex, :start_server, false)
    end

    # In CI/diff mode, skip Bumblebee: ML embeddings are not needed for static analysis
    if config.ci do
      Application.put_env(:ragex, :skip_bumblebee, true)
    end

    # Start required applications
    Mix.Task.run("app.start")

    show_progress = config.format not in ["json", "github"] and not config.ci

    if config.format in ["json", "github"] or config.ci do
      Logger.configure(level: :emergency)
    end

    if config.verbose and show_progress do
      info_msg("Ragex Comprehensive Analysis")
      Mix.shell().info("")
    end

    # Step 1: Analyze files and build knowledge graph
    if show_progress,
      do: header_msg("Step 1: Analyzing#{if config.diff, do: " changed", else: ""} files...")

    analyze_result =
      if config.diff do
        # Diff mode: only analyze changed files
        {:ok, result} = Runner.analyze_files(config.changed_files_absolute)
        result
      else
        case Runner.analyze_directory(config.path) do
          {:ok, result} ->
            result

          {:error, reason} ->
            error_msg("Failed to analyze directory: #{inspect(reason)}")
            System.halt(1)
        end
      end

    if config.verbose and show_progress do
      success_msg(
        "  analyzed #{analyze_result.files_analyzed} files (#{analyze_result.entities_found} entities)"
      )

      Mix.shell().info("")
    end

    # Step 2: Run analyses
    results = run_analyses(config)

    # Step 2.5: In diff mode, filter results to changed files only
    results =
      if config.diff and config.changed_files_set do
        Runner.filter_results_by_files(results, config.changed_files_set)
      else
        results
      end

    # Step 3: Generate report
    report = generate_report(config, analyze_result, results)

    # Step 4: Output results
    output_results(config, report)

    # Step 5: Summary
    print_summary(config, results)

    # Step 6: Exit code for CI/strict mode
    maybe_exit(config, report.results)

    :ok
  end

  # Build configuration from options
  @doc false
  def build_config(opts) do
    path = Keyword.get(opts, :path, File.cwd!())
    ci = Keyword.get(opts, :ci, false)
    strict = Keyword.get(opts, :strict, false)

    # All analysis flag keys (original + new)
    all_analysis_keys = [
      :security,
      :business_logic,
      :complexity,
      :smells,
      :duplicates,
      :dead_code,
      :dependencies,
      :quality,
      :circulars,
      :god_modules,
      :unstable_modules,
      :unused_modules,
      :coupling
    ]

    # Check if user explicitly provided any positive flags
    positive_analyses =
      Keyword.take(opts, all_analysis_keys)
      |> Enum.filter(fn {_key, value} -> value == true end)

    # If --all is explicitly set, use it; otherwise enable all only if no positive flags
    all_analyses = Keyword.get(opts, :all)

    enable_all =
      cond do
        # --all was explicitly provided
        all_analyses == true -> true
        # --no-all was explicitly provided
        all_analyses == false -> false
        # No positive analyses selected, default to all
        Enum.empty?(positive_analyses) -> true
        # Positive analyses selected, don't enable all
        true -> false
      end

    resolve = fn key ->
      if enable_all,
        do: Keyword.get(opts, key, true),
        else: Keyword.get(opts, key, false)
    end

    diff = Keyword.get(opts, :diff, false)

    # --diff implies --ci
    ci = if diff, do: true, else: ci

    # Resolve changed files when in diff mode
    {changed_files_absolute, changed_files_set} =
      if diff do
        resolve_diff_files(path, opts)
      else
        {[], nil}
      end

    %{
      path: path,
      output: Keyword.get(opts, :output),
      format: Keyword.get(opts, :format, "text"),
      verbose: Keyword.get(opts, :verbose, false),
      ci: ci,
      strict: strict,
      diff: diff,
      changed_files_absolute: changed_files_absolute,
      changed_files_set: changed_files_set,
      severity: parse_severity(Keyword.get(opts, :severity, "medium")),
      threshold: Keyword.get(opts, :threshold, 0.85),
      min_complexity: Keyword.get(opts, :min_complexity, 10),
      god_threshold: Keyword.get(opts, :god_threshold, 15),
      instability_threshold: Keyword.get(opts, :instability_threshold, 0.8),
      with_empty: Keyword.get(opts, :with_empty, false),
      analyses: %{
        security: resolve.(:security),
        business_logic: resolve.(:business_logic),
        complexity: resolve.(:complexity),
        smells: resolve.(:smells),
        duplicates: resolve.(:duplicates),
        dead_code: resolve.(:dead_code),
        dependencies: resolve.(:dependencies),
        quality: resolve.(:quality),
        circulars: resolve.(:circulars),
        god_modules: resolve.(:god_modules),
        unstable_modules: resolve.(:unstable_modules),
        unused_modules: resolve.(:unused_modules),
        coupling: resolve.(:coupling)
      }
    }
  end

  defp resolve_diff_files(path, opts) do
    diff_opts =
      []
      |> then(fn o -> if opts[:base], do: [{:base, opts[:base]} | o], else: o end)
      |> then(fn o -> if opts[:head], do: [{:head, opts[:head]} | o], else: o end)

    case Diff.changed_files_for_path(path, diff_opts) do
      {:ok, repo_root, files} ->
        absolute = Enum.map(files, &Path.join(repo_root, &1))
        relative_set = MapSet.new(files)
        {absolute, relative_set}

      {:error, reason} ->
        Mix.raise("--diff: failed to resolve changed files: #{inspect(reason)}")
    end
  end

  defp parse_severity(severity) when is_binary(severity) do
    case String.downcase(severity) do
      "low" -> [:low, :medium, :high, :critical]
      "medium" -> [:medium, :high, :critical]
      "high" -> [:high, :critical]
      "critical" -> [:critical]
      _ -> [:medium, :high, :critical]
    end
  end

  # Run all enabled analyses using shared Runner
  defp run_analyses(config) do
    Runner.run_all(config)
  end

  # Generate report
  defp generate_report(config, analyze_result, results) do
    # Filter out empty results if --without-empty (default)
    filtered_results =
      if config.with_empty do
        results
      else
        filter_non_empty_results(results)
      end

    %{
      timestamp: DateTime.utc_now(),
      path: config.path,
      files_analyzed: analyze_result.files_analyzed,
      entities: analyze_result.entities_found,
      results: filtered_results,
      config: %{
        severity: config.severity,
        threshold: config.threshold,
        min_complexity: config.min_complexity
      }
    }
  end

  # Filter out empty results and clean up empty file reports within each analysis
  defp filter_non_empty_results(results) do
    results
    |> Enum.map(fn {type, data} -> {type, filter_empty_within_result(type, data)} end)
    |> Enum.reject(fn {type, data} -> result_is_empty?(type, data) end)
    |> Map.new()
  end

  # Filter empty file results within each analysis type
  defp filter_empty_within_result(:security, %{issues: issues} = data) do
    filtered =
      Enum.reject(issues, fn issue ->
        Map.get(issue, :has_vulnerabilities?, true) == false and
          Enum.empty?(Map.get(issue, :vulnerabilities, []))
      end)

    %{data | issues: filtered}
  end

  defp filter_empty_within_result(:business_logic, %{results: results} = data) do
    filtered =
      Enum.reject(results, fn result ->
        Map.get(result, :has_issues?, true) == false and
          Enum.empty?(Map.get(result, :issues, []))
      end)

    %{data | results: filtered}
  end

  defp filter_empty_within_result(:smells, %{smells: smells} = data) do
    case smells do
      %{results: results} ->
        filtered =
          Enum.reject(results, fn result ->
            Map.get(result, :has_smells?, true) == false and
              Enum.empty?(Map.get(result, :smells, []))
          end)

        %{data | smells: %{smells | results: filtered}}

      _ ->
        data
    end
  end

  defp filter_empty_within_result(_type, data), do: data

  # Check if entire result section is empty after filtering
  defp result_is_empty?(:security, %{issues: issues}), do: Enum.empty?(issues)
  defp result_is_empty?(:business_logic, data), do: Map.get(data, :total_issues, 0) == 0
  defp result_is_empty?(:complexity, %{complex_functions: funcs}), do: Enum.empty?(funcs)

  defp result_is_empty?(:smells, %{smells: smells}) do
    case smells do
      %{total_smells: 0} -> true
      %{results: results} -> Enum.all?(results, &(Map.get(&1, :total_smells, 0) == 0))
      list when is_list(list) -> Enum.empty?(list)
      _ -> true
    end
  end

  defp result_is_empty?(:duplicates, %{duplicates: dups}), do: Enum.empty?(dups)
  defp result_is_empty?(:dead_code, %{dead_functions: funcs}), do: Enum.empty?(funcs)
  defp result_is_empty?(:dependencies, %{modules: modules}), do: map_size(modules) == 0
  defp result_is_empty?(:circulars, %{cycles: cycles}), do: Enum.empty?(cycles)
  defp result_is_empty?(:god_modules, %{modules: mods}), do: Enum.empty?(mods)
  defp result_is_empty?(:unstable_modules, %{modules: mods}), do: Enum.empty?(mods)
  defp result_is_empty?(:unused_modules, %{modules: mods}), do: Enum.empty?(mods)
  defp result_is_empty?(:coupling, %{metrics: metrics}), do: Enum.empty?(metrics)
  # Quality always has a score, never considered "empty"
  defp result_is_empty?(:quality, _), do: false
  defp result_is_empty?(_, _), do: false

  # Output results
  defp output_results(config, report) do
    cond do
      config.format == "github" ->
        output_github(report)

      config.ci ->
        output_ci(report)

      true ->
        content =
          case config.format do
            "json" -> format_json(report)
            "markdown" -> format_markdown(report)
            _ -> format_text(report)
          end

        case config.output do
          nil ->
            if config.format != "json", do: Mix.shell().info("")
            Mix.shell().info(content)

          file ->
            File.write!(file, content)
            if config.format != "json", do: success_msg("\nReport written to #{file}")
        end
    end
  end

  # GitHub Actions workflow command format for inline PR annotations
  defp output_github(report) do
    lines =
      report.results
      |> Enum.flat_map(fn {type, data} -> github_lines_for(type, data) end)

    Enum.each(lines, fn line -> Mix.shell().info(line) end)

    total = length(lines)
    Mix.shell().info("ragex: #{total} issue(s) found")
  end

  defp github_lines_for(:security, %{issues: issues}) do
    issues
    |> Enum.flat_map(fn result -> Map.get(result, :vulnerabilities, []) end)
    |> Enum.map(fn vuln ->
      level = if vuln.severity in [:critical, :high], do: "error", else: "warning"

      "::#{level} file=#{vuln.file},line=#{vuln.line}::SECURITY #{vuln.category}: #{vuln.description}"
    end)
  end

  defp github_lines_for(:business_logic, data) do
    data
    |> Map.get(:results, [])
    |> Enum.flat_map(&Map.get(&1, :issues, []))
    |> Enum.map(fn issue ->
      level = if issue[:severity] in [:critical, :high], do: "error", else: "warning"

      "::#{level} file=#{issue[:file]},line=#{issue[:line]}::#{issue[:analyzer]}: #{issue[:description]}"
    end)
  end

  defp github_lines_for(:complexity, %{complex_functions: funcs}) do
    Enum.map(funcs, fn f ->
      "::warning file=#{f[:file] || f[:path]},line=#{f[:line] || 1}::COMPLEXITY #{f.module}.#{f.name}/#{f.arity} cyclomatic=#{f.cyclomatic_complexity}"
    end)
  end

  defp github_lines_for(:dead_code, %{dead_functions: funcs}) do
    Enum.map(funcs, fn f ->
      "::notice file=#{f[:file] || f[:path]},line=#{f[:line] || 1}::DEAD_CODE #{f.module}.#{f.name}/#{f.arity}: #{f.reason}"
    end)
  end

  defp github_lines_for(:circulars, %{cycles: cycles}) do
    Enum.map(cycles, fn cycle ->
      chain = Enum.map_join(cycle, " -> ", &format_module_name/1)
      "::error::CIRCULAR dependency: #{chain}"
    end)
  end

  defp github_lines_for(_, _), do: []

  # CI output: one-line-per-issue, no ANSI, machine-friendly
  defp output_ci(report) do
    lines =
      report.results
      |> Enum.flat_map(fn {type, data} -> ci_lines_for(type, data) end)

    Enum.each(lines, fn line -> Mix.shell().info(line) end)

    total = length(lines)
    Mix.shell().info("ragex: #{total} issue(s) found")
  end

  defp ci_lines_for(:security, %{issues: issues}) do
    issues
    |> Enum.flat_map(fn result -> Map.get(result, :vulnerabilities, []) end)
    |> Enum.map(fn vuln ->
      "SECURITY: #{vuln.category} (#{vuln.severity}) #{vuln.file}:#{vuln.line} - #{vuln.description}"
    end)
  end

  defp ci_lines_for(:business_logic, data) do
    data
    |> Map.get(:results, [])
    |> Enum.flat_map(&Map.get(&1, :issues, []))
    |> Enum.map(fn issue ->
      "BUSINESS_LOGIC: #{issue[:analyzer] || "unknown"} (#{issue[:severity]}) #{issue[:file]}:#{issue[:line]} - #{issue[:description]}"
    end)
  end

  defp ci_lines_for(:complexity, %{complex_functions: funcs}) do
    Enum.map(funcs, fn f ->
      "COMPLEXITY: #{f.module}.#{f.name}/#{f.arity} (cyclomatic=#{f.cyclomatic_complexity})"
    end)
  end

  defp ci_lines_for(:smells, %{smells: smells}) do
    all =
      case smells do
        %{results: results} when is_list(results) ->
          Enum.flat_map(results, &Map.get(&1, :smells, []))

        list when is_list(list) ->
          list

        _ ->
          []
      end

    Enum.map(all, fn s -> "SMELL: #{s[:type]} (#{s[:severity]})" end)
  end

  defp ci_lines_for(:duplicates, %{duplicates: dups}) do
    Enum.map(dups, fn d ->
      sim = Float.round((d[:similarity] || 0.0) * 100, 1)
      "DUPLICATE: #{sim}% similar (#{d[:lines] || 0} lines)"
    end)
  end

  defp ci_lines_for(:dead_code, %{dead_functions: funcs}) do
    Enum.map(funcs, fn f ->
      "DEAD_CODE: #{f.module}.#{f.name}/#{f.arity} - #{f.reason}"
    end)
  end

  defp ci_lines_for(:circulars, %{cycles: cycles}) do
    Enum.map(cycles, fn cycle ->
      chain = Enum.map_join(cycle, " -> ", &format_module_name/1)
      "CIRCULAR: #{chain} (#{length(cycle)} modules)"
    end)
  end

  defp ci_lines_for(:god_modules, %{modules: modules}) do
    Enum.map(modules, fn m ->
      "GOD_MODULE: #{format_module_name(m.module)} (afferent=#{m.afferent}, efferent=#{m.efferent}, total=#{m.total})"
    end)
  end

  defp ci_lines_for(:unstable_modules, %{modules: modules}) do
    Enum.map(modules, fn m ->
      "UNSTABLE: #{format_module_name(m.module)} (instability=#{Float.round(m.instability, 2)})"
    end)
  end

  defp ci_lines_for(:unused_modules, %{modules: modules}) do
    Enum.map(modules, fn mod -> "UNUSED: #{format_module_name(mod)}" end)
  end

  defp ci_lines_for(:coupling, %{metrics: metrics}) do
    Enum.map(metrics, fn m ->
      "COUPLING: #{format_module_name(m.module)} afferent=#{m.afferent} efferent=#{m.efferent} instability=#{Float.round(m.instability, 2)}"
    end)
  end

  defp ci_lines_for(:dependencies, _), do: []
  defp ci_lines_for(:quality, _), do: []
  defp ci_lines_for(_, _), do: []

  defp format_module_name(mod) when is_atom(mod), do: inspect(mod)
  defp format_module_name(other), do: to_string(other)

  # Format as JSON
  defp format_json(report) do
    Jason.encode!(report, pretty: true)
  end

  # Format as Markdown
  defp format_markdown(report) do
    """
    # Ragex Analysis Report

    **Timestamp**: #{report.timestamp}  
    **Path**: #{report.path}  
    **Files Analyzed**: #{report.files_analyzed}  
    **Entities Found**: #{report.entities}

    ## Configuration

    - Severity: #{inspect(report.config.severity)}
    - Duplication Threshold: #{report.config.threshold}
    - Min Complexity: #{report.config.min_complexity}

    #{format_markdown_results(report.results)}
    """
  end

  defp format_markdown_results(results) do
    Enum.map_join(results, "\n\n", fn {type, data} ->
      case type do
        :security -> format_markdown_security(data)
        :business_logic -> format_markdown_business_logic(data)
        :complexity -> format_markdown_complexity(data)
        :smells -> format_markdown_smells(data)
        :duplicates -> format_markdown_duplicates(data)
        :dead_code -> format_markdown_dead_code(data)
        :dependencies -> format_markdown_dependencies(data)
        :quality -> format_markdown_quality(data)
        :circulars -> format_markdown_circulars(data)
        :god_modules -> format_markdown_god_modules(data)
        :unstable_modules -> format_markdown_unstable_modules(data)
        :unused_modules -> format_markdown_unused_modules(data)
        :coupling -> format_markdown_coupling(data)
        _ -> ""
      end
    end)
  end

  defp format_markdown_security(%{issues: issues}) do
    """
    ## Security Issues (#{length(issues)})

    #{Enum.map_join(issues, "\n", fn issue -> "- **#{issue.type}** (#{issue.severity}): #{issue.file}:#{issue.line} - #{issue.description}" end)}
    """
  end

  defp format_markdown_business_logic(data) do
    total = Map.get(data, :total_issues, 0)
    files_with_issues = Map.get(data, :files_with_issues, 0)
    by_severity = Map.get(data, :by_severity, %{})
    by_analyzer = Map.get(data, :by_analyzer, %{})

    severity_summary =
      Enum.map_join([:critical, :high, :medium, :low, :info], ", ", fn sev ->
        "#{sev}: #{Map.get(by_severity, sev, 0)}"
      end)

    analyzer_summary =
      by_analyzer
      |> Enum.filter(fn {_name, count} -> count > 0 end)
      |> Enum.sort_by(fn {_name, count} -> count end, :desc)
      |> Enum.map_join("\n", fn {name, count} -> "- **#{name}**: #{count}" end)

    """
    ## Business Logic Issues (#{total})

    Files with issues: #{files_with_issues}  
    By severity: #{severity_summary}

    ### By Analyzer

    #{analyzer_summary}
    """
  end

  defp format_markdown_complexity(%{complex_functions: functions}) do
    """
    ## Complex Functions (#{length(functions)})

    #{Enum.map_join(functions, "\n", fn func -> "- **#{func.module}.#{func.name}/#{func.arity}**: Complexity #{func.cyclomatic_complexity}" end)}
    """
  end

  defp format_markdown_smells(%{smells: directory_result}) do
    # Extract all smells from directory results and flatten
    all_smells =
      case directory_result do
        %{results: results} when is_list(results) ->
          Enum.flat_map(results, fn file_result ->
            Enum.map(Map.get(file_result, :smells, []), fn smell ->
              # Add file path to smell for context
              Map.put(smell, :file, Map.get(file_result, :path, "unknown"))
            end)
          end)

        smells when is_list(smells) ->
          smells

        _ ->
          []
      end

    # Sort by severity (critical > high > medium > low)
    sorted_smells = Enum.sort_by(all_smells, &smell_severity_order(&1.severity), :desc)

    # Format location for display
    formatted_smells =
      Enum.map(sorted_smells, fn smell ->
        location =
          case smell do
            %{location: %{formatted: fmt}} when is_binary(fmt) -> fmt
            %{location: loc} when is_map(loc) -> format_smell_location(loc)
            %{file: file} -> file
            _ -> "unknown"
          end

        "- **#{smell.type}** (#{smell.severity}): #{location}"
      end)

    """
    ## Code Smells (#{length(sorted_smells)})

    #{Enum.join(formatted_smells, "\n")}
    """
  end

  defp format_smell_location(location) do
    module = Map.get(location, :module)
    function = Map.get(location, :function)
    arity = Map.get(location, :arity)
    line = Map.get(location, :line)

    cond do
      module && function && arity && line ->
        "#{inspect(module)}.#{function}/#{arity}:#{line}"

      module && function && arity ->
        "#{inspect(module)}.#{function}/#{arity}"

      line ->
        "line #{line}"

      true ->
        "unknown"
    end
  end

  defp format_markdown_duplicates(%{duplicates: duplicates}) do
    formatted_duplicates =
      Enum.map(duplicates, fn dup ->
        # Extract unique locations with line numbers
        locations =
          case dup do
            %{locations: locs} when is_list(locs) ->
              locs
              |> Enum.map(fn loc ->
                file = loc[:file] || loc.file || "unknown"
                line = loc[:start_line] || loc.start_line || loc[:line] || loc.line
                %{file: file, line: line}
              end)
              |> Enum.uniq_by(&{&1.file, &1.line})

            %{file1: f1, file2: f2, line1: l1, line2: l2} ->
              [%{file: f1, line: l1}, %{file: f2, line: l2}]

            %{file1: f1, file2: f2} ->
              [%{file: f1, line: nil}, %{file: f2, line: nil}]

            _ ->
              []
          end

        # Format locations with line numbers and individual truncation
        # Max length per location (allow reasonable space for each path)
        max_per_location = 35

        loc_str =
          locations
          |> Enum.take(2)
          |> Enum.map_join(" ↔ ", fn %{file: file, line: line} ->
            # Format with line number if available
            full_location =
              if line && is_integer(line) do
                "#{file}:#{line}"
              else
                file
              end

            # Truncate from right to preserve filename
            truncate_from_right_md(full_location, max_per_location)
          end)
          |> then(fn str ->
            locations_len = length(locations)

            if locations_len > 2 do
              "#{str} (+#{locations_len - 2} more)"
            else
              str
            end
          end)

        similarity = (dup[:similarity] || dup.similarity || 0.0) * 100
        lines = dup[:lines] || dup.lines || 0

        "- **#{Float.round(similarity, 1)}% similar** (#{lines} lines): #{loc_str}"
      end)

    """
    ## Code Duplicates (#{length(duplicates)})

    #{Enum.join(formatted_duplicates, "\n")}
    """
  end

  defp format_markdown_dead_code(%{dead_functions: functions}) do
    """
    ## Dead Code (#{length(functions)})

    #{Enum.map_join(functions, "\n", fn func -> "- **#{func.module}.#{func.name}/#{func.arity}**: #{func.reason}" end)}
    """
  end

  defp format_markdown_dependencies(%{modules: modules}) do
    """
    ## Dependencies

    Total Modules: #{map_size(modules)}
    """
  end

  defp format_markdown_quality(metrics) do
    """
    ## Quality Metrics

    Overall Score: #{metrics.overall_score}/100
    """
  end

  defp format_markdown_circulars(%{cycles: cycles}) do
    formatted =
      Enum.map(cycles, fn cycle ->
        chain = Enum.map_join(cycle, " -> ", &format_module_name/1)
        "- #{chain} (#{length(cycle)} modules)"
      end)

    """
    ## Circular Dependencies (#{length(cycles)})

    #{Enum.join(formatted, "\n")}
    """
  end

  defp format_markdown_god_modules(%{modules: modules, threshold: threshold}) do
    formatted =
      Enum.map(modules, fn m ->
        "- **#{format_module_name(m.module)}**: afferent=#{m.afferent}, efferent=#{m.efferent}, total=#{m.total}, instability=#{Float.round(m.instability, 2)}"
      end)

    """
    ## God Modules (#{length(modules)}, threshold >= #{threshold})

    #{Enum.join(formatted, "\n")}
    """
  end

  defp format_markdown_unstable_modules(%{modules: modules, threshold: threshold}) do
    formatted =
      Enum.map(modules, fn m ->
        "- **#{format_module_name(m.module)}**: instability=#{Float.round(m.instability, 2)} (Ca=#{m.afferent}, Ce=#{m.efferent})"
      end)

    """
    ## Unstable Modules (#{length(modules)}, threshold > #{threshold})

    #{Enum.join(formatted, "\n")}
    """
  end

  defp format_markdown_unused_modules(%{modules: modules}) do
    formatted = Enum.map(modules, fn mod -> "- #{format_module_name(mod)}" end)

    """
    ## Unused Modules (#{length(modules)})

    #{Enum.join(formatted, "\n")}
    """
  end

  defp format_markdown_coupling(%{metrics: metrics}) do
    formatted =
      Enum.map(metrics, fn m ->
        "- **#{format_module_name(m.module)}**: Ca=#{m.afferent}, Ce=#{m.efferent}, I=#{Float.round(m.instability, 2)}"
      end)

    """
    ## Coupling Metrics (#{length(metrics)} modules)

    #{Enum.join(formatted, "\n")}
    """
  end

  # Helper to get severity order for sorting (higher = more severe)
  defp smell_severity_order(:critical), do: 4
  defp smell_severity_order(:high), do: 3
  defp smell_severity_order(:medium), do: 2
  defp smell_severity_order(:low), do: 1
  defp smell_severity_order(_), do: 0

  # Truncate from the right for markdown, preserving filenames
  defp truncate_from_right_md(text, max_length) when is_binary(text) do
    if String.length(text) > max_length do
      keep_length = max_length - 1
      "…" <> String.slice(text, -keep_length, keep_length)
    else
      text
    end
  end

  defp truncate_from_right_md(text, _), do: to_string(text)

  # Format as text
  defp format_text(report) do
    if @has_cli_modules do
      apply(Ragex.CLI.Output, :format_analysis_report, [report])
    else
      # Fallback simple text format when CLI modules not available
      Jason.encode!(report, pretty: true)
    end
  end

  # Print summary
  defp print_summary(config, results) do
    # Skip summary in CI mode (output_ci already prints summary)
    if config.verbose and not config.ci do
      Mix.shell().info("")
      header_msg("Summary:")

      Enum.each(results, fn {type, data} ->
        case type do
          :security ->
            count = length(data.issues)
            msg = "  Security Issues: #{count}"
            if count > 0, do: error_msg(msg), else: success_msg(msg)

          :business_logic ->
            count = Map.get(data, :total_issues, 0)
            msg = "  Business Logic Issues: #{count}"
            if count > 0, do: warning_msg(msg), else: success_msg(msg)

          :complexity ->
            count = length(data.complex_functions)
            msg = "  Complex Functions: #{count}"
            if count > 0, do: warning_msg(msg), else: success_msg(msg)

          :smells ->
            count =
              case data.smells do
                %{total_smells: n} -> n
                list when is_list(list) -> length(list)
                _ -> 0
              end

            msg = "  Code Smells: #{count}"
            if count > 0, do: warning_msg(msg), else: success_msg(msg)

          :duplicates ->
            count = length(data.duplicates)
            msg = "  Duplicate Blocks: #{count}"
            if count > 0, do: warning_msg(msg), else: success_msg(msg)

          :dead_code ->
            count = length(data.dead_functions)
            msg = "  Dead Functions: #{count}"
            if count > 0, do: info_msg(msg), else: success_msg(msg)

          :dependencies ->
            count = map_size(data.modules)
            info_msg("  Modules Analyzed: #{count}")

          :quality ->
            score = data.overall_score
            msg = "  Quality Score: #{score}/100"

            cond do
              score >= 80 -> success_msg(msg)
              score >= 60 -> warning_msg(msg)
              true -> error_msg(msg)
            end

          :circulars ->
            count = length(data.cycles)
            msg = "  Circular Dependencies: #{count}"
            if count > 0, do: error_msg(msg), else: success_msg(msg)

          :god_modules ->
            count = length(data.modules)
            msg = "  God Modules: #{count}"
            if count > 0, do: warning_msg(msg), else: success_msg(msg)

          :unstable_modules ->
            count = length(data.modules)
            msg = "  Unstable Modules: #{count}"
            if count > 0, do: warning_msg(msg), else: success_msg(msg)

          :unused_modules ->
            count = length(data.modules)
            msg = "  Unused Modules: #{count}"
            if count > 0, do: info_msg(msg), else: success_msg(msg)

          :coupling ->
            count = length(data.metrics)
            info_msg("  Coupling Metrics: #{count} modules")

          _ ->
            :ok
        end
      end)

      Mix.shell().info("")
    end
  end

  # Exit code logic for CI/strict mode
  @doc false
  def count_ci_issues(results) do
    Enum.reduce(results, 0, fn {type, data}, acc ->
      acc + count_issues_for_type(type, data)
    end)
  end

  defp count_issues_for_type(:security, %{issues: issues}) do
    issues |> Enum.flat_map(&Map.get(&1, :vulnerabilities, [])) |> length()
  end

  defp count_issues_for_type(:business_logic, data), do: Map.get(data, :total_issues, 0)
  defp count_issues_for_type(:complexity, %{complex_functions: f}), do: length(f)

  defp count_issues_for_type(:smells, %{smells: smells}) do
    case smells do
      %{total_smells: n} -> n
      %{results: r} when is_list(r) -> Enum.flat_map(r, &Map.get(&1, :smells, [])) |> length()
      list when is_list(list) -> length(list)
      _ -> 0
    end
  end

  defp count_issues_for_type(:duplicates, %{duplicates: d}), do: length(d)
  defp count_issues_for_type(:dead_code, %{dead_functions: f}), do: length(f)
  defp count_issues_for_type(:circulars, %{cycles: c}), do: length(c)
  defp count_issues_for_type(:god_modules, %{modules: m}), do: length(m)
  defp count_issues_for_type(:unstable_modules, %{modules: m}), do: length(m)
  defp count_issues_for_type(:unused_modules, %{modules: m}), do: length(m)
  # Coupling and quality are informational, not "issues"
  defp count_issues_for_type(_, _), do: 0

  defp maybe_exit(config, results) do
    if config.ci or config.strict do
      total = count_ci_issues(results)

      if total > 0 do
        System.halt(1)
      end
    end
  end

  # Helper functions for colored output that work with or without CLI modules
  defp header_msg(text) do
    if @has_cli_modules do
      Mix.shell().info(apply(Ragex.CLI.Colors, :header, [text]))
    else
      Mix.shell().info(text)
    end
  end

  defp success_msg(text) do
    if @has_cli_modules do
      Mix.shell().info(apply(Ragex.CLI.Colors, :success, [text]))
    else
      Mix.shell().info(text)
    end
  end

  defp error_msg(text) do
    if @has_cli_modules do
      Mix.shell().info(apply(Ragex.CLI.Colors, :error, [text]))
    else
      Mix.shell().info(text)
    end
  end

  defp warning_msg(text) do
    if @has_cli_modules do
      Mix.shell().info(apply(Ragex.CLI.Colors, :warning, [text]))
    else
      Mix.shell().info(text)
    end
  end

  defp info_msg(text) do
    if @has_cli_modules do
      Mix.shell().info(apply(Ragex.CLI.Colors, :info, [text]))
    else
      Mix.shell().info(text)
    end
  end
end
