defmodule Mix.Tasks.Ragex.Analyze do
  @moduledoc """
  Performs comprehensive analysis on a directory.

  Analyzes a directory using all available Ragex analysis features:
  - Security vulnerability scanning
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

  alias Ragex.Analysis.{DeadCode, DependencyGraph, Duplication, Quality, Security, Smells}
  alias Ragex.Analyzers.Directory
  alias Ragex.CLI.{Colors, Output, Progress}

  @shortdoc "Performs comprehensive code analysis on a directory"

  @impl Mix.Task
  def run(args) do
    # Start required applications
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          path: :string,
          output: :string,
          format: :string,
          security: :boolean,
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

    if config.verbose do
      Mix.shell().info(Colors.info("Ragex Comprehensive Analysis"))
      Mix.shell().info("")
    end

    # Step 1: Analyze directory and build knowledge graph
    Mix.shell().info(Colors.header("Step 1: Analyzing directory..."))
    analyze_result = analyze_directory(config)

    if config.verbose do
      Mix.shell().info(
        Colors.success(
          "  ✓ Analyzed #{analyze_result.files_analyzed} files (#{analyze_result.entities_found} entities)"
        )
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
    progress = if config.verbose, do: Progress.start("Analyzing files"), else: nil

    result = Directory.analyze_directory(config.path)

    if progress, do: Progress.stop(progress)

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
        Mix.shell().error(Colors.error("Failed to analyze directory: #{inspect(reason)}"))
        System.halt(1)
    end
  end

  # Run all enabled analyses
  defp run_analyses(config, _analyze_result) do
    results = %{}

    results =
      if config.analyses.security do
        Mix.shell().info(Colors.header("Step 2.1: Security Analysis..."))

        progress =
          if config.verbose, do: Progress.start("Scanning for vulnerabilities"), else: nil

        security_result = run_security_analysis(config)
        if progress, do: Progress.stop(progress)

        if config.verbose do
          Mix.shell().info(
            Colors.success("  ✓ Found #{length(security_result.issues)} security issues")
          )
        end

        Map.put(results, :security, security_result)
      else
        results
      end

    results =
      if config.analyses.complexity do
        Mix.shell().info(Colors.header("Step 2.2: Complexity Analysis..."))
        progress = if config.verbose, do: Progress.start("Analyzing complexity"), else: nil
        complexity_result = run_complexity_analysis(config)
        if progress, do: Progress.stop(progress)

        if config.verbose do
          Mix.shell().info(
            Colors.success(
              "  ✓ Found #{length(complexity_result.complex_functions)} complex functions"
            )
          )
        end

        Map.put(results, :complexity, complexity_result)
      else
        results
      end

    results =
      if config.analyses.smells do
        Mix.shell().info(Colors.header("Step 2.3: Code Smell Detection..."))
        progress = if config.verbose, do: Progress.start("Detecting code smells"), else: nil
        smells_result = run_smells_analysis(config)
        if progress, do: Progress.stop(progress)

        if config.verbose do
          Mix.shell().info(
            Colors.success("  ✓ Found #{length(smells_result.smells)} code smells")
          )
        end

        Map.put(results, :smells, smells_result)
      else
        results
      end

    results =
      if config.analyses.duplicates do
        Mix.shell().info(Colors.header("Step 2.4: Duplication Detection..."))
        progress = if config.verbose, do: Progress.start("Finding duplicates"), else: nil
        duplicates_result = run_duplicates_analysis(config)
        if progress, do: Progress.stop(progress)

        if config.verbose do
          Mix.shell().info(
            Colors.success("  ✓ Found #{length(duplicates_result.duplicates)} duplicate blocks")
          )
        end

        Map.put(results, :duplicates, duplicates_result)
      else
        results
      end

    results =
      if config.analyses.dead_code do
        Mix.shell().info(Colors.header("Step 2.5: Dead Code Analysis..."))
        progress = if config.verbose, do: Progress.start("Finding dead code"), else: nil
        dead_code_result = run_dead_code_analysis(config)
        if progress, do: Progress.stop(progress)

        if config.verbose do
          Mix.shell().info(
            Colors.success("  ✓ Found #{length(dead_code_result.dead_functions)} dead functions")
          )
        end

        Map.put(results, :dead_code, dead_code_result)
      else
        results
      end

    results =
      if config.analyses.dependencies do
        Mix.shell().info(Colors.header("Step 2.6: Dependency Analysis..."))
        progress = if config.verbose, do: Progress.start("Analyzing dependencies"), else: nil
        deps_result = run_dependencies_analysis(config)
        if progress, do: Progress.stop(progress)

        if config.verbose do
          Mix.shell().info(
            Colors.success("  ✓ Analyzed #{map_size(deps_result.modules)} modules")
          )
        end

        Map.put(results, :dependencies, deps_result)
      else
        results
      end

    results =
      if config.analyses.quality do
        Mix.shell().info(Colors.header("Step 2.7: Quality Metrics..."))
        progress = if config.verbose, do: Progress.start("Computing quality metrics"), else: nil
        quality_result = run_quality_analysis(config)
        if progress, do: Progress.stop(progress)

        if config.verbose do
          Mix.shell().info(
            Colors.success("  ✓ Overall quality score: #{quality_result.overall_score}/100")
          )
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
        Mix.shell().info("")
        Mix.shell().info(content)

      file ->
        File.write!(file, content)
        Mix.shell().info(Colors.success("\n✓ Report written to #{file}"))
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
    """
    ## Code Duplicates (#{length(duplicates)})

    #{Enum.map_join(duplicates, "\n", fn dup -> "- #{length(dup.locations)} duplicates (#{dup.similarity * 100}% similar, #{dup.lines} lines)" end)}
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

  # Format as text
  defp format_text(report) do
    Output.format_analysis_report(report)
  end

  # Print summary
  defp print_summary(config, results) do
    if config.verbose do
      Mix.shell().info("")
      Mix.shell().info(Colors.header("Summary:"))

      Enum.each(results, fn {type, data} ->
        case type do
          :security ->
            count = length(data.issues)
            color = if count > 0, do: :error, else: :success
            Mix.shell().info(apply(Colors, color, ["  Security Issues: #{count}"]))

          :complexity ->
            count = length(data.complex_functions)
            color = if count > 0, do: :warning, else: :success
            Mix.shell().info(apply(Colors, color, ["  Complex Functions: #{count}"]))

          :smells ->
            count = length(data.smells)
            color = if count > 0, do: :warning, else: :success
            Mix.shell().info(apply(Colors, color, ["  Code Smells: #{count}"]))

          :duplicates ->
            count = length(data.duplicates)
            color = if count > 0, do: :warning, else: :success
            Mix.shell().info(apply(Colors, color, ["  Duplicate Blocks: #{count}"]))

          :dead_code ->
            count = length(data.dead_functions)
            color = if count > 0, do: :info, else: :success
            Mix.shell().info(apply(Colors, color, ["  Dead Functions: #{count}"]))

          :dependencies ->
            count = map_size(data.modules)
            Mix.shell().info(Colors.info("  Modules Analyzed: #{count}"))

          :quality ->
            score = data.overall_score

            color =
              cond do
                score >= 80 -> :success
                score >= 60 -> :warning
                true -> :error
              end

            Mix.shell().info(apply(Colors, color, ["  Quality Score: #{score}/100"]))

          _ ->
            :ok
        end
      end)

      Mix.shell().info("")
    end
  end
end
