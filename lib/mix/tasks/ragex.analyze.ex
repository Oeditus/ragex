# credo:disable-for-this-file Credo.Check.Refactor.Apply

defmodule Mix.Tasks.Ragex.Analyze do
  @moduledoc """
  Performs comprehensive analysis on a directory.

  Analyzes a directory using all available Ragex analysis features:
  - Security vulnerability scanning
  - Business logic analysis (20 analyzers)
  - Code complexity metrics
  - Code smell detection
  - Code duplication detection
  - Dead code analysis
  - Dependency analysis
  - Quality metrics

  ## Usage

      mix ragex.analyze [options]

  ## Options

    * `--path PATH` - Directory to analyze (default: current directory)
    * `--output FILE` - Output file for results (default: stdout)
    * `--format FORMAT` - Output format: text, json, markdown (default: text)
    * `--security` - Include security analysis
    * `--business-logic` - Include business logic analysis (20 analyzers)
    * `--complexity` - Include complexity analysis
    * `--smells` - Include code smell detection
    * `--duplicates` - Include duplication detection
    * `--dead-code` - Include dead code analysis
    * `--dependencies` - Include dependency analysis
    * `--quality` - Include quality metrics
    * `--all` - Include all analyses (default)
    * `--severity LEVEL` - Minimum severity for issues: low, medium, high, critical (default: medium)
    * `--threshold FLOAT` - Duplication threshold 0.0-1.0 (default: 0.85)
    * `--min-complexity INT` - Minimum complexity to report (default: 10)
    * `--verbose` - Show detailed progress information

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

  """

  use Mix.Task

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

  @shortdoc "Performs comprehensive code analysis on a directory"

  # Check if CLI modules are available (not available when installed as archive)
  @has_cli_modules Code.ensure_loaded?(Ragex.CLI.Colors)

  @impl Mix.Task
  def run(args) do
    # Start required applications
    Mix.Task.run("app.start")

    # Parse options early to check format
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
          all: :boolean,
          severity: :string,
          threshold: :float,
          min_complexity: :integer,
          verbose: :boolean
        ]
      )

    config = build_config(opts)

    # Only show progress messages if not JSON format
    show_progress = config.format != "json"

    # Suppress all logger output when outputting JSON
    if config.format == "json" do
      Logger.configure(level: :emergency)
    end

    if config.verbose and show_progress do
      info_msg("Ragex Comprehensive Analysis")
      Mix.shell().info("")
    end

    # Step 1: Analyze directory and build knowledge graph
    if show_progress, do: header_msg("Step 1: Analyzing directory...")
    analyze_result = analyze_directory(config)

    if config.verbose and show_progress do
      success_msg(
        "  ✓ Analyzed #{analyze_result.files_analyzed} files (#{analyze_result.entities_found} entities)"
      )

      Mix.shell().info("")
    end

    # Step 2: Run analyses
    results = run_analyses(config, analyze_result)

    # Step 3: Generate report
    report = generate_report(config, analyze_result, results)

    # Step 4: Output results
    output_results(config, report)

    # Step 5: Summary
    print_summary(config, results)

    :ok
  end

  # Build configuration from options
  defp build_config(opts) do
    path = Keyword.get(opts, :path, File.cwd!())
    all_analyses = Keyword.get(opts, :all, true)

    # If no specific analyses are selected and --all is not specified, enable all
    specific_analyses =
      Keyword.take(opts, [
        :security,
        :business_logic,
        :complexity,
        :smells,
        :duplicates,
        :dead_code,
        :dependencies,
        :quality
      ])

    enable_all = all_analyses or Enum.empty?(specific_analyses)

    %{
      path: path,
      output: Keyword.get(opts, :output),
      format: Keyword.get(opts, :format, "text"),
      verbose: Keyword.get(opts, :verbose, false),
      severity: parse_severity(Keyword.get(opts, :severity, "medium")),
      threshold: Keyword.get(opts, :threshold, 0.85),
      min_complexity: Keyword.get(opts, :min_complexity, 10),
      analyses: %{
        security: enable_all or Keyword.get(opts, :security, false),
        business_logic: enable_all or Keyword.get(opts, :business_logic, false),
        complexity: enable_all or Keyword.get(opts, :complexity, false),
        smells: enable_all or Keyword.get(opts, :smells, false),
        duplicates: enable_all or Keyword.get(opts, :duplicates, false),
        dead_code: enable_all or Keyword.get(opts, :dead_code, false),
        dependencies: enable_all or Keyword.get(opts, :dependencies, false),
        quality: enable_all or Keyword.get(opts, :quality, false)
      }
    }
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

  # Analyze directory
  defp analyze_directory(config) do
    result = Directory.analyze_directory(config.path)

    case result do
      {:ok, stats} ->
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

      {:error, reason} ->
        error_msg("Failed to analyze directory: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Run all enabled analyses
  defp run_analyses(config, _analyze_result) do
    results = %{}
    show_progress = config.format != "json"

    results =
      if config.analyses.security do
        if show_progress, do: header_msg("Step 2.1: Security Analysis...")

        security_result = run_security_analysis(config)

        if config.verbose and show_progress do
          success_msg("  ✓ Found #{length(security_result.issues)} security issues")
        end

        Map.put(results, :security, security_result)
      else
        results
      end

    results =
      if config.analyses.business_logic do
        if show_progress, do: header_msg("Step 2.2: Business Logic Analysis...")

        bl_result = run_business_logic_analysis(config)

        if config.verbose and show_progress do
          success_msg("  ✓ Found #{bl_result.total_issues} business logic issues")
        end

        Map.put(results, :business_logic, bl_result)
      else
        results
      end

    results =
      if config.analyses.complexity do
        if show_progress, do: header_msg("Step 2.3: Complexity Analysis...")
        complexity_result = run_complexity_analysis(config)

        if config.verbose and show_progress do
          success_msg(
            "  ✓ Found #{length(complexity_result.complex_functions)} complex functions"
          )
        end

        Map.put(results, :complexity, complexity_result)
      else
        results
      end

    results =
      if config.analyses.smells do
        if show_progress, do: header_msg("Step 2.4: Code Smell Detection...")
        smells_result = run_smells_analysis(config)

        if config.verbose and show_progress do
          success_msg("  ✓ Found #{length(smells_result.smells)} code smells")
        end

        Map.put(results, :smells, smells_result)
      else
        results
      end

    results =
      if config.analyses.duplicates do
        if show_progress, do: header_msg("Step 2.5: Duplication Detection...")
        duplicates_result = run_duplicates_analysis(config)

        if config.verbose and show_progress do
          success_msg("  ✓ Found #{length(duplicates_result.duplicates)} duplicate blocks")
        end

        Map.put(results, :duplicates, duplicates_result)
      else
        results
      end

    results =
      if config.analyses.dead_code do
        if show_progress, do: header_msg("Step 2.6: Dead Code Analysis...")
        dead_code_result = run_dead_code_analysis(config)

        if config.verbose and show_progress do
          success_msg("  ✓ Found #{length(dead_code_result.dead_functions)} dead functions")
        end

        Map.put(results, :dead_code, dead_code_result)
      else
        results
      end

    results =
      if config.analyses.dependencies do
        if show_progress, do: header_msg("Step 2.7: Dependency Analysis...")
        deps_result = run_dependencies_analysis(config)

        if config.verbose and show_progress do
          success_msg("  ✓ Analyzed #{map_size(deps_result.modules)} modules")
        end

        Map.put(results, :dependencies, deps_result)
      else
        results
      end

    results =
      if config.analyses.quality do
        if show_progress, do: header_msg("Step 2.8: Quality Metrics...")
        quality_result = run_quality_analysis(config)

        if config.verbose and show_progress do
          success_msg("  ✓ Overall quality score: #{quality_result.overall_score}/100")
        end

        Map.put(results, :quality, quality_result)
      else
        results
      end

    results
  end

  # Individual analysis runners
  defp run_security_analysis(config) do
    case Security.analyze_directory(config.path, severity: config.severity) do
      {:ok, issues} -> %{issues: issues}
      {:error, _} -> %{issues: []}
    end
  end

  defp run_business_logic_analysis(config) do
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

  defp run_complexity_analysis(config) do
    case Quality.find_complex_code(config.path, min_complexity: config.min_complexity) do
      {:ok, functions} -> %{complex_functions: functions}
      {:error, _} -> %{complex_functions: []}
    end
  end

  defp run_smells_analysis(config) do
    case Smells.detect_smells(config.path) do
      {:ok, smells} -> %{smells: smells}
      {:error, _} -> %{smells: []}
    end
  end

  defp run_duplicates_analysis(config) do
    case Duplication.find_duplicates(config.path, threshold: config.threshold) do
      {:ok, duplicates} -> %{duplicates: duplicates}
      {:error, _} -> %{duplicates: []}
    end
  end

  defp run_dead_code_analysis(_config) do
    case DeadCode.find_dead_code() do
      {:ok, dead_functions} -> %{dead_functions: dead_functions}
      {:error, _} -> %{dead_functions: []}
    end
  end

  defp run_dependencies_analysis(_config) do
    case DependencyGraph.analyze_all_dependencies() do
      # {:error, _} -> %{modules: %{}}
      {:ok, analysis} -> analysis
    end
  end

  defp run_quality_analysis(config) do
    case Quality.analyze_quality(config.path) do
      {:ok, metrics} -> metrics
      {:error, _} -> %{overall_score: 0}
    end
  end

  # Generate report
  defp generate_report(config, analyze_result, results) do
    %{
      timestamp: DateTime.utc_now(),
      path: config.path,
      files_analyzed: analyze_result.files_analyzed,
      entities: analyze_result.entities_found,
      results: results,
      config: %{
        severity: config.severity,
        threshold: config.threshold,
        min_complexity: config.min_complexity
      }
    }
  end

  # Output results
  defp output_results(config, report) do
    content =
      case config.format do
        "json" -> format_json(report)
        "markdown" -> format_markdown(report)
        _ -> format_text(report)
      end

    case config.output do
      nil ->
        # Only add blank line for non-JSON output
        if config.format != "json", do: Mix.shell().info("")
        Mix.shell().info(content)

      file ->
        File.write!(file, content)
        if config.format != "json", do: success_msg("\n✓ Report written to #{file}")
    end
  end

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
    if config.verbose do
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
            count = length(data.smells)
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

          _ ->
            :ok
        end
      end)

      Mix.shell().info("")
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
