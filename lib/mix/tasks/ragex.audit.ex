defmodule Mix.Tasks.Ragex.Audit do
  @moduledoc """
  Generates an AI-powered code audit report as JSON.

  Combines comprehensive static analysis with an AI-generated professional
  code audit report. The output is a JSON document containing all structured
  analysis results plus an `"audit"` field with the AI-generated Markdown report.

  ## Usage

      mix ragex.audit [options]

  ## Options

    * `--path PATH` - Directory to analyze (default: current directory)
    * `--output FILE` - Output file (default: stdout)
    * `--dead-code` - Include dead code analysis (disabled by default, can be slow)
    * `--provider PROVIDER` - AI provider: deepseek_r1, openai, anthropic, ollama
    * `--model MODEL` - Model name override
    * `--verbose` - Show progress on stderr
    * `--with-empty` - Include empty result categories in output (default: false)
    * `--help` - Show this help

  ## Examples

      # Audit current directory
      mix ragex.audit

      # Audit specific directory, save to file
      mix ragex.audit --path lib/ --output audit.json

      # Include dead code analysis with progress
      mix ragex.audit --dead-code --verbose --output report.json

  ## Output Format

  JSON with the following top-level keys:

    * `timestamp` - ISO 8601 audit timestamp
    * `path` - Analyzed directory path
    * `audit` - AI-generated Markdown audit report (string)
    * `graph` - Knowledge graph statistics (nodes, edges, modules, functions, embeddings)
    * `results` - Structured analysis results (compatible with `mix ragex.analyze --format json`)
    * `summary` - Issue counts by category
    * `config` - Analysis configuration used
  """

  @shortdoc "Generates AI-powered code audit report as JSON"

  use Mix.Task

  require Logger

  alias Ragex.Agent.Core
  alias Ragex.Analysis.{BusinessLogic, DependencyGraph, Quality}
  alias Ragex.Graph.Store

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          path: :string,
          output: :string,
          dead_code: :boolean,
          provider: :string,
          model: :string,
          verbose: :boolean,
          with_empty: :boolean,
          help: :boolean
        ],
        aliases: [p: :path, o: :output, m: :model, h: :help]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      run_audit(opts)
    end
  end

  # Private functions

  defp run_audit(opts) do
    verbose = Keyword.get(opts, :verbose, false)
    path = Keyword.get(opts, :path, File.cwd!()) |> Path.expand()
    output_file = Keyword.get(opts, :output)

    # Disable MCP server for non-interactive JSON output
    Application.put_env(:ragex, :start_server, false)

    # Suppress logger for clean output unless verbose
    unless verbose, do: Logger.configure(level: :emergency)

    Mix.Task.run("app.start")

    if verbose do
      Logger.configure(level: :info)
      progress("Starting audit: #{path}")
    end

    # Always suppress Executor's stdout printing to keep JSON output clean.
    # Progress is reported via Logger (stderr) when --verbose.
    core_opts =
      [
        include_dead_code: Keyword.get(opts, :dead_code, false),
        skip_embeddings: false,
        verbose: false
      ]
      |> maybe_put(:provider, parse_provider(opts[:provider]))
      |> maybe_put(:model, opts[:model])

    if verbose, do: progress("Running analysis pipeline...")

    case Core.analyze_project(path, core_opts) do
      {:ok, result} ->
        if verbose, do: progress("AI report generated. Running supplementary analyses...")

        supplementary = run_supplementary(path)
        graph_stats = Store.stats()
        modules = Store.list_nodes(:module, :infinity)
        functions = Store.list_nodes(:function, :infinity)

        json_report =
          build_json(path, result, supplementary, graph_stats, modules, functions, opts)

        encoded = Jason.encode!(json_report, pretty: true)

        case output_file do
          nil ->
            IO.puts(encoded)

          file ->
            File.write!(file, encoded)
            if verbose, do: progress("Audit report written to #{file}")
        end

      {:error, reason} ->
        IO.puts(:stderr, "Audit failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run_supplementary(path) do
    %{
      business_logic:
        safe_run(fn -> BusinessLogic.analyze_directory(path, min_severity: :medium) end),
      dependencies: safe_run(fn -> DependencyGraph.analyze_all_dependencies() end),
      quality_score: safe_run(fn -> Quality.analyze_quality(path) end)
    }
  end

  defp build_json(path, result, supplementary, graph_stats, modules, functions, opts) do
    with_empty = Keyword.get(opts, :with_empty, false)

    quality_metrics =
      case result.issues[:quality_metrics] do
        m when is_map(m) and map_size(m) > 0 -> m
        _ -> %{}
      end

    results =
      %{
        security: %{issues: result.issues[:security] || []},
        complexity: %{complex_functions: result.issues[:complexity] || []},
        smells: %{smells: result.issues[:smells] || []},
        duplicates: %{duplicates: result.issues[:duplicates] || []},
        dead_code: %{dead_functions: result.issues[:dead_code] || []},
        circular_dependencies: %{cycles: result.issues[:circular_deps] || []},
        quality_metrics: quality_metrics,
        suggestions: %{items: result.issues[:suggestions] || []},
        business_logic: supplementary.business_logic || %{total_issues: 0, results: []},
        dependencies: supplementary.dependencies || %{modules: %{}},
        quality: supplementary.quality_score || %{overall_score: 0}
      }
      |> then(fn r -> if with_empty, do: r, else: filter_non_empty(r) end)

    %{
      timestamp: DateTime.utc_now(),
      path: path,
      audit: result.report,
      ai_status: result[:ai_status] || %{status: "unknown"},
      graph: %{
        nodes: graph_stats.nodes,
        edges: graph_stats.edges,
        embeddings: graph_stats.embeddings,
        modules: length(modules),
        functions: length(functions)
      },
      results: results,
      summary: result.summary,
      config: %{
        dead_code: Keyword.get(opts, :dead_code, false),
        provider: opts[:provider] || "default"
      }
    }
  end

  defp filter_non_empty(results) do
    results
    |> Enum.reject(fn {_key, value} -> empty_result?(value) end)
    |> Map.new()
  end

  defp empty_result?(%{issues: []}), do: true
  defp empty_result?(%{complex_functions: []}), do: true
  defp empty_result?(%{smells: []}), do: true
  defp empty_result?(%{duplicates: []}), do: true
  defp empty_result?(%{dead_functions: []}), do: true
  defp empty_result?(%{cycles: []}), do: true
  defp empty_result?(%{items: []}), do: true
  defp empty_result?(%{total_issues: 0}), do: true
  defp empty_result?(%{modules: m}) when map_size(m) == 0, do: true
  defp empty_result?(%{overall_score: _}), do: false
  defp empty_result?(m) when m == %{}, do: true
  defp empty_result?(_), do: false

  # Helpers

  defp safe_run(func) do
    case func.() do
      {:ok, result} -> result
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp parse_provider(nil), do: nil
  defp parse_provider(name), do: String.to_existing_atom(name)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp progress(msg), do: IO.puts(:stderr, msg)
end
