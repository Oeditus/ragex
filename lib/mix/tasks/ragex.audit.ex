defmodule Mix.Tasks.Ragex.Audit do
  @moduledoc """
  Generates an AI-powered code audit report.

  Combines comprehensive static analysis with an AI-generated professional
  code audit report. By default outputs a JSON document containing all structured
  analysis results plus an `"audit"` field with the AI-generated Markdown report.

  ## Usage

      mix ragex.audit [options]

  ## Options

    * `--path PATH` - Directory to analyze (default: current directory)
    * `--format FORMAT` - Output format: `json` (default) or `markdown`
    * `--output FILE` - Write output to file instead of stdout
    * `--dead-code` - Include dead code analysis (disabled by default, can be slow)
    * `--provider PROVIDER` - AI provider: deepseek_r1, openai, anthropic, ollama
    * `--model MODEL` - Model name override
    * `--verbose` - Show progress on stderr
    * `--with-empty` - Include empty result categories in output (default: false)
    * `--help` - Show this help

  ## Examples

      # Audit current directory (JSON to stdout)
      mix ragex.audit

      # Render AI audit report in terminal
      mix ragex.audit --format markdown

      # Save rendered markdown to file (ANSI escape sequences stripped)
      mix ragex.audit --format markdown --output report.md

      # Audit specific directory, save JSON to file
      mix ragex.audit --path lib/ --output audit.json

      # Include dead code analysis with progress
      mix ragex.audit --dead-code --verbose --output report.json

  ## Output Format

  ### JSON (default)

  JSON with the following top-level keys:

    * `timestamp` - ISO 8601 audit timestamp
    * `path` - Analyzed directory path
    * `audit` - AI-generated Markdown audit report (string)
    * `graph` - Knowledge graph statistics (nodes, edges, modules, functions, embeddings)
    * `results` - Structured analysis results (compatible with `mix ragex.analyze --format json`)
    * `summary` - Issue counts by category
    * `config` - Analysis configuration used

  ### Markdown (`--format markdown`)

  Renders only the AI-generated audit report. When printed to stdout, uses
  ANSI-styled Markdown (via Marcli). When written to a file (`--output`),
  escape sequences are stripped for clean readable Markdown.
  """

  @shortdoc "Generates AI-powered code audit report"

  use Mix.Task

  alias Ragex.Agent.Core
  alias Ragex.Analysis.{BusinessLogic, DependencyGraph, Quality}
  alias Ragex.CLI.Progress
  alias Ragex.Graph.Store

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          path: :string,
          format: :string,
          output: :string,
          dead_code: :boolean,
          provider: :string,
          model: :string,
          verbose: :boolean,
          with_empty: :boolean,
          help: :boolean
        ],
        aliases: [p: :path, f: :format, o: :output, m: :model, h: :help]
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
    format = Keyword.get(opts, :format, "json")
    output_file = Keyword.get(opts, :output)

    # Show progress for interactive use (markdown to stdout) or when verbose
    show_progress = verbose or (format == "markdown" and is_nil(output_file))

    # Disable MCP server for non-interactive JSON output
    Application.put_env(:ragex, :start_server, false)

    # Suppress logger for clean output unless verbose
    unless verbose, do: Logger.configure(level: :emergency)

    Mix.Task.run("app.start")

    if verbose do
      Logger.configure(level: :info)
      progress("Starting audit: #{path}")
    end

    # For interactive markdown to stdout, use two-phase streaming
    if format == "markdown" and is_nil(output_file) do
      run_streaming_markdown(path, opts, show_progress)
    else
      run_batch(path, opts, format, output_file, verbose, show_progress)
    end
  end

  # Two-phase streaming for interactive markdown output:
  # Phase 1: Analysis with animated spinner (skip_report: true)
  # Phase 2: Stream report via on_chunk callback
  defp run_streaming_markdown(path, opts, show_progress) do
    audit_start = System.monotonic_time(:millisecond)
    spinner = if show_progress, do: start_stderr_spinner("Analyzing #{Path.basename(path)}")

    core_opts =
      [
        include_dead_code: Keyword.get(opts, :dead_code, false),
        skip_embeddings: false,
        skip_report: true,
        verbose: false
      ]
      |> maybe_put(:provider, parse_provider(opts[:provider]))
      |> maybe_put(:model, opts[:model])

    case Core.analyze_project(path, core_opts) do
      {:ok, result} ->
        stop_stderr_spinner(spinner)
        analysis_elapsed = System.monotonic_time(:millisecond) - audit_start

        if show_progress do
          IO.write(
            :stderr,
            "\u2713 Analysis complete (#{Progress.format_elapsed(analysis_elapsed)})\n"
          )
        end

        # Phase 2: Stream the AI report
        stream_audit_report(path, result.issues, opts, show_progress, audit_start)

      {:error, reason} ->
        stop_stderr_spinner(spinner)
        IO.puts(:stderr, "Audit failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp stream_audit_report(path, issues, opts, show_progress, audit_start) do
    report_spinner = if show_progress, do: start_stderr_spinner("Generating report")
    {:ok, first_chunk_agent} = Agent.start_link(fn -> false end)

    on_chunk = fn
      %{content: text} when is_binary(text) and text != "" ->
        unless Agent.get(first_chunk_agent, & &1) do
          stop_stderr_spinner(report_spinner)
          Agent.update(first_chunk_agent, fn _ -> true end)
        end

        IO.write(text)

      _ ->
        :ok
    end

    stream_opts =
      [on_chunk: on_chunk, verbose: false]
      |> maybe_put(:provider, parse_provider(opts[:provider]))
      |> maybe_put(:model, opts[:model])

    case Core.stream_generate_report(path, issues, stream_opts) do
      {:ok, content, _ai_status} ->
        got_chunks = Agent.get(first_chunk_agent, & &1)
        Agent.stop(first_chunk_agent)

        unless got_chunks do
          # No streaming chunks arrived (e.g., cached/basic report) - render now
          stop_stderr_spinner(report_spinner)
          IO.puts(Marcli.render(content))
        else
          # Streaming happened - re-render cleanly with Marcli
          IO.write("\n")
          IO.puts(Marcli.render(content))
        end

        total_elapsed = System.monotonic_time(:millisecond) - audit_start

        if show_progress do
          IO.write(:stderr, "\u2713 Done (#{Progress.format_elapsed(total_elapsed)})\n")
        end

      {:error, reason} ->
        stop_stderr_spinner(report_spinner)
        Agent.stop(first_chunk_agent)
        IO.puts(:stderr, "Report generation failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Batch mode: blocking analysis + report, then output
  defp run_batch(path, opts, format, output_file, verbose, show_progress) do
    audit_start = System.monotonic_time(:millisecond)
    spinner = if show_progress, do: start_stderr_spinner("Analyzing #{Path.basename(path)}")

    core_opts =
      [
        include_dead_code: Keyword.get(opts, :dead_code, false),
        skip_embeddings: false,
        verbose: false
      ]
      |> maybe_put(:provider, parse_provider(opts[:provider]))
      |> maybe_put(:model, opts[:model])

    case Core.analyze_project(path, core_opts) do
      {:ok, result} ->
        stop_stderr_spinner(spinner)
        elapsed = System.monotonic_time(:millisecond) - audit_start

        if show_progress do
          IO.write(:stderr, "\u2713 Done (#{Progress.format_elapsed(elapsed)})\n")
        end

        case format do
          "markdown" ->
            output_markdown(result.report, output_file, verbose)

          _ ->
            if verbose, do: progress("Running supplementary analyses...")

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
        end

      {:error, reason} ->
        stop_stderr_spinner(spinner)
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
      |> then(fn r ->
        if with_empty, do: r, else: r |> filter_empty_within_results() |> filter_non_empty()
      end)

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
  defp empty_result?(%{total_issues: 0, results: []}), do: true
  defp empty_result?(%{total_issues: 0}), do: true
  defp empty_result?(%{modules: m}) when map_size(m) == 0, do: true
  defp empty_result?(%{overall_score: _}), do: false
  defp empty_result?(m) when m == %{}, do: true
  defp empty_result?(_), do: false

  defp filter_empty_within_results(results) do
    Map.new(results, fn {key, value} -> {key, filter_empty_nodes(key, value)} end)
  end

  defp filter_empty_nodes(:security, %{issues: issues} = data) do
    filtered =
      Enum.reject(issues, fn issue ->
        Map.get(issue, :has_vulnerabilities?, true) == false and
          Enum.empty?(Map.get(issue, :vulnerabilities, []))
      end)

    %{data | issues: filtered}
  end

  defp filter_empty_nodes(:business_logic, %{results: results} = data) do
    filtered =
      Enum.reject(results, fn result ->
        Map.get(result, :has_issues?, true) == false and
          Enum.empty?(Map.get(result, :issues, []))
      end)

    %{data | results: filtered}
  end

  defp filter_empty_nodes(:smells, %{smells: smells} = data) do
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

  defp filter_empty_nodes(_key, data), do: data

  defp output_markdown(nil, _output_file, _verbose) do
    IO.puts(:stderr, "No AI report was generated.")
    System.halt(1)
  end

  defp output_markdown("", _output_file, _verbose) do
    IO.puts(:stderr, "AI report is empty.")
    System.halt(1)
  end

  defp output_markdown(report, nil, _verbose) do
    IO.puts(Marcli.render(report))
  end

  defp output_markdown(report, file, verbose) do
    rendered = Marcli.render(report, escape_sequences: false)
    File.write!(file, rendered)
    if verbose, do: progress("Markdown report written to #{file}")
  end

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

  # Stderr-based progress indicators (safe for stdout piping)

  @spinner_frames [
    "\u280b",
    "\u2819",
    "\u2839",
    "\u2838",
    "\u283c",
    "\u2834",
    "\u2826",
    "\u2827",
    "\u2807",
    "\u280f"
  ]

  defp start_stderr_spinner(label) do
    start_time = System.monotonic_time(:millisecond)

    spawn(fn ->
      stderr_spinner_loop(label, start_time, 0)
    end)
  end

  defp stop_stderr_spinner(nil), do: :ok

  defp stop_stderr_spinner(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        100 -> :ok
      end

      IO.write(:stderr, "\r\e[K")
    end

    :ok
  end

  defp stderr_spinner_loop(label, start_time, frame_index) do
    frame = Enum.at(@spinner_frames, rem(frame_index, length(@spinner_frames)))
    elapsed_ms = System.monotonic_time(:millisecond) - start_time
    elapsed_s = div(elapsed_ms, 1000)

    IO.write(:stderr, "\r\e[K#{frame} #{label} (#{elapsed_s}s)")

    receive do
      :stop -> :ok
    after
      80 -> stderr_spinner_loop(label, start_time, frame_index + 1)
    end
  end
end
