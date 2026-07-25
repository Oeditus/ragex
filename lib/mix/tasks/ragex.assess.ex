defmodule Mix.Tasks.Ragex.Assess do
  @shortdoc "Evaluates a pull request (git branch) using static analysis and AI"

  @moduledoc """
  Evaluates a pull request or git branch using both static analysis and AI.

  By default, outputs a Markdown report assessing the changes.

  ## Usage

      mix ragex.assess [branch_name] [options]

  If no branch name is provided, it defaults to the current active git branch.

  ## Options

    * `--base REF` - Base git ref to diff against (default: origin/main)
    * `--format FORMAT` - Output format: `markdown` or `json` (default: markdown)
    * `--output FILE` - Write assessment report to file instead of stdout
    * `--provider PROVIDER` - AI provider: deepseek_r1, openai, anthropic, ollama
    * `--model MODEL` - Model name override
    * `--verbose` - Show detailed progress on stderr
    * `--severity LEVEL` - Minimum severity for issues: low, medium, high, critical (default: medium)
    * `--help` - Show this help

  ## Examples

      # Assess current branch against origin/main
      mix ragex.assess

      # Assess specific branch against main
      mix ragex.assess feat/my-feature --base main

      # Output markdown report to file
      mix ragex.assess --output assessment.md
  """

  use Mix.Task

  alias Ragex.Agent.{Core, Executor, Memory, Report, ToolSchema}
  alias Ragex.AI.Config, as: AIConfig
  alias Ragex.Analysis.Runner
  alias Ragex.CLI.Progress
  alias Ragex.Git.Repo
  alias Ragex.MCP.Client

  # Check if CLI modules are available (not available when installed as archive)
  @has_cli_modules match?({:ok, _}, Code.ensure_compiled(Ragex.CLI.Colors))

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          base: :string,
          format: :string,
          output: :string,
          provider: :string,
          model: :string,
          verbose: :boolean,
          severity: :string,
          help: :boolean
        ],
        aliases: [b: :base, f: :format, o: :output, m: :model, h: :help, v: :verbose]
      )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      run_assess(opts, positional)
    end
  end

  # Private functions

  defp run_assess(opts, positional) do
    verbose = Keyword.get(opts, :verbose, false)
    repo_root = File.cwd!() |> Path.expand()
    format = Keyword.get(opts, :format, "markdown")
    output_file = Keyword.get(opts, :output)

    # Disable MCP server for non-interactive output
    Application.put_env(:ragex, :start_server, false)

    # If a Ragex server is already running, skip Bumblebee to avoid CUDA OOM.
    if Client.server_running?() do
      Application.put_env(:ragex, :skip_bumblebee, true)
    end

    # Suppress logger for clean output unless verbose
    unless verbose, do: Logger.configure(level: :emergency)

    Mix.Task.run("app.start")

    if verbose do
      Logger.configure(level: :info)
      progress("Starting PR assessment...")
    end

    # Resolve base and head branch/refs
    base = opts[:base] || "origin/main"

    head =
      case positional do
        [branch | _] ->
          branch

        [] ->
          case Repo.current_branch(repo_root) do
            {:ok, branch} ->
              branch

            {:error, reason} ->
              IO.puts(:stderr, "Error resolving current branch: #{inspect(reason)}")
              System.halt(1)
          end
      end

    # Show start message if printing to stdout
    show_progress = format != "json" and is_nil(output_file)

    if show_progress do
      header_msg("Ragex PR Assessment: diffing #{base} and #{head}")
    end

    # Step 1: Get changed files
    case get_git_changed_files(repo_root, base, head) do
      {:ok, []} ->
        if show_progress do
          warning_msg("No files changed between #{base} and #{head}.")
        end

        :ok

      {:ok, changed_files} ->
        run_analysis_and_report(
          repo_root,
          base,
          head,
          changed_files,
          opts,
          format,
          output_file,
          show_progress,
          verbose
        )

      {:error, reason} ->
        IO.puts(:stderr, "Error resolving changed files: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # credo:disable-for-next-line
  defp run_analysis_and_report(
         repo_root,
         base,
         head,
         changed_files,
         opts,
         format,
         output_file,
         show_progress,
         verbose
       ) do
    assess_start = System.monotonic_time(:millisecond)

    # Step 2: Analyze codebase & load graph (incremental)
    spinner = if show_progress, do: start_stderr_spinner("Analyzing project changes")

    # Build core options
    core_opts = [
      skip_report: true,
      verbose: false
    ]

    # We want to analyze the project (this handles cache loading & update graph for changed files on disk)
    case Core.analyze_project(repo_root, core_opts) do
      {:ok, result} ->
        stop_stderr_spinner(spinner)
        analysis_elapsed = System.monotonic_time(:millisecond) - assess_start

        if show_progress do
          success_msg(
            "✓ Project analysis complete (#{Progress.format_elapsed(analysis_elapsed)})"
          )
        end

        # Filter the issues detected to only those in the changed files of the PR/branch
        changed_files_set = MapSet.new(changed_files)
        filtered_issues = Runner.filter_results_by_files(result.issues, changed_files_set)

        # Step 3: Get Git Diff content
        diff_spinner = if show_progress, do: start_stderr_spinner("Fetching git diff")

        diff_text =
          case get_git_diff(repo_root, base, head) do
            {:ok, diff} ->
              stop_stderr_spinner(diff_spinner)
              truncate_diff(diff)

            {:error, reason} ->
              stop_stderr_spinner(diff_spinner)
              IO.puts(:stderr, "Failed to get git diff: #{inspect(reason)}")
              ""
          end

        # Step 4: Generate assessment (JSON or Markdown)
        if format == "json" do
          # Build a clean JSON output
          json_data = %{
            timestamp: DateTime.utc_now(),
            base: base,
            head: head,
            changed_files: changed_files,
            issues: filtered_issues,
            summary: build_summary(filtered_issues)
          }

          encoded = Jason.encode!(json_data, pretty: true)

          case output_file do
            nil ->
              IO.puts(encoded)

            file ->
              File.write!(file, encoded)
              if verbose, do: progress("Assessment report written to #{file}")
          end
        else
          # Generate AI Markdown assessment
          ai_spinner = if show_progress, do: start_stderr_spinner("Generating AI PR assessment")

          case generate_ai_assessment(
                 repo_root,
                 base,
                 head,
                 changed_files,
                 filtered_issues,
                 diff_text,
                 opts
               ) do
            {:ok, markdown_report} ->
              stop_stderr_spinner(ai_spinner)
              total_elapsed = System.monotonic_time(:millisecond) - assess_start

              if show_progress do
                success_msg("✓ Assessment complete (#{Progress.format_elapsed(total_elapsed)})\n")
              end

              output_markdown(markdown_report, output_file, verbose)

            {:error, reason} ->
              stop_stderr_spinner(ai_spinner)
              IO.puts(:stderr, "AI Assessment failed: #{inspect(reason)}")
              System.halt(1)
          end
        end

      {:error, reason} ->
        stop_stderr_spinner(spinner)
        IO.puts(:stderr, "Analysis failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp get_git_diff(repo_root, base, head) do
    case System.cmd("git", ["diff", "#{base}...#{head}"], cd: repo_root) do
      {diff, 0} -> {:ok, diff}
      {err, _} -> {:error, err}
    end
  end

  defp get_git_changed_files(repo_root, base, head) do
    args = ["diff", "--name-only", "--diff-filter=ACMR", "#{base}...#{head}"]

    case System.cmd("git", args, cd: repo_root) do
      {output, 0} ->
        files = String.split(output, "\n", trim: true)
        {:ok, files}

      {err, _} ->
        {:error, err}
    end
  end

  defp truncate_diff(diff, max_chars \\ 80_000) do
    if String.length(diff) > max_chars do
      String.slice(diff, 0, max_chars) <> "\n\n[... Diff truncated due to size limit ...]\n"
    else
      diff
    end
  end

  defp generate_ai_assessment(
         repo_root,
         base,
         head,
         changed_files,
         filtered_issues,
         diff_text,
         opts
       ) do
    provider_name = parse_provider(opts[:provider]) || AIConfig.provider_name()
    config = AIConfig.api_config(provider_name)

    if is_nil(config.api_key) or config.api_key == "" do
      # Fallback basic report
      {:ok, Report.generate_basic_report(filtered_issues)}
    else
      # Create session and setup prompts
      metadata = %{
        project_path: repo_root,
        issues: filtered_issues,
        analyzed_at: DateTime.utc_now()
      }

      case Memory.new_session(metadata) do
        {:ok, session} ->
          system_prompt = pr_assess_system_prompt(repo_root)
          Memory.add_message(session.id, :system, system_prompt)

          user_prompt =
            pr_assess_user_prompt(base, head, changed_files, filtered_issues, diff_text)

          Memory.add_message(session.id, :user, user_prompt)

          # Equip the agent with read-only RAG/MCP tools so it can query the codebase context
          rag_tools = ToolSchema.rag_query_tools(provider_name)

          # Limit to 4 iterations to allow targeted tool calls while preventing reasoning loops.
          # If the agent reaches this limit without returning a text response, the executor
          # will automatically compile all gathered context and force the final report.
          report_opts =
            opts
            |> Keyword.put(:tools, rag_tools)
            |> Keyword.put(:max_iterations, 4)
            |> Keyword.put(:context_max_chars, 128_000)
            |> maybe_put(:provider, parse_provider(opts[:provider]))
            |> maybe_put(:model, opts[:model])

          case Executor.run(session.id, report_opts) do
            {:ok, result} ->
              # Cleanup session
              Memory.clear_session(session.id)
              {:ok, result.content}

            {:error, reason} ->
              Memory.clear_session(session.id)
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp pr_assess_system_prompt(project_path) do
    path_constraint =
      if project_path do
        """

        PROJECT CONTEXT:
        The project being analyzed is located at: #{project_path}
        """
      else
        ""
      end

    """
    You are a senior software architect performing a pull request (PR) code review and assessment.
    Your deliverable is a comprehensive, constructive, and detailed PR Assessment Report.
    Write as a professional reviewer: precise, evidence-based, and highly actionable.
    #{path_constraint}
    IMPORTANT RULES:
    1. You have access to RAG/MCP search tools (like `read_file`, `semantic_search`, `query_graph`, etc.) to query the codebase if you need to fetch extra context (such as function definitions or callers of code changed in the PR). Use them selectively if critical details are missing. Do NOT loop calling tools repeatedly. If you have enough information, synthesize it and output your final assessment report directly.
    2. Be constructive. Highlight good patterns, but focus heavily on identifying bugs, code smells, complexity issues, security concerns, or architectural misalignment introduced by the changes.
    3. Be specific: cite filenames, line numbers, function names, and quote code blocks from the diff if necessary.
    4. Your entire response must be the Markdown report.

    REPORT STRUCTURE (mandatory sections):

    1. **PR Overview & Summary**
       - Table of metadata: head branch, base branch, total files changed, lines added/removed (estimate from diff if not explicit).
       - A concise summary of the purpose and scope of changes.

    2. **Static Analysis Findings**
       - Table/summary of the static analysis issues detected *only* in the changed files (security, complexity, smells, duplicates, dead code, etc.). If none, explicitly state "No static analysis issues detected in the changed files."

    3. **AI Code Review & Risk Assessment**
       - Detailed walkthrough of the diff.
       - Highlight any design risks, architectural impact (e.g. coupling, module instability, circular dependencies), or potential bugs (race conditions, error handling, off-by-one errors) introduced by this PR.
       - Comment on specific files/lines.

    4. **Actionable Suggestions & Refactoring Recommendations**
       - Detailed suggestions for improving the PR code.
       - Differentiate between:
         - *Blocking*: Must fix before merging (e.g. security vulnerabilities, critical bugs).
         - *Non-blocking / Optional*: Improvements or refactorings that can be done now or later.

    5. **Verdict & Score**
       - Verdict: Approved, Approve with Suggestions, or Changes Requested.
       - Overall code change quality score: 1 to 10 with a concise justification.
    """
  end

  defp pr_assess_user_prompt(base, head, changed_files, filtered_issues, diff_text) do
    issues_summary = Report.format_issues_for_llm(filtered_issues)

    """
    Below is the pull request metadata, static analysis findings, and code diff.

    ## Pull Request Metadata
    - Base branch/ref: #{base}
    - Head branch/ref: #{head}
    - Changed files:
    #{Enum.map_join(changed_files, "\n", &"- `#{&1}`")}

    ## Static Analysis Findings in Changed Files
    #{issues_summary}

    ## Git Diff (Changes)
    ```diff
    #{diff_text}
    ```
    """
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

  # Helpers for colored output
  defp header_msg(text) do
    if @has_cli_modules do
      colored_info(:header, [text])
    else
      Mix.shell().info(text)
    end
  end

  defp success_msg(text) do
    if @has_cli_modules do
      colored_info(:success, [text])
    else
      Mix.shell().info(text)
    end
  end

  defp warning_msg(text) do
    if @has_cli_modules do
      colored_info(:warning, [text])
    else
      Mix.shell().info(text)
    end
  end

  defp colored_info(type, text) do
    # credo:disable-for-next-line
    Mix.shell().info(apply(Ragex.CLI.Colors, type, [text]))
  end

  defp build_summary(issues) when is_map(issues) do
    %{
      dead_code_count: count_issues(issues[:dead_code]),
      duplicate_count: count_issues(issues[:duplicates]),
      security_count: count_issues(issues[:security]),
      smell_count: count_issues(issues[:smells]),
      complexity_count: count_issues(issues[:complexity]),
      circular_dep_count: count_issues(issues[:circular_deps]),
      suggestion_count: count_issues(issues[:suggestions]),
      total_issues:
        count_issues(issues[:dead_code]) +
          count_issues(issues[:duplicates]) +
          count_issues(issues[:security]) +
          count_issues(issues[:smells]) +
          count_issues(issues[:complexity]) +
          count_issues(issues[:circular_deps])
    }
  end

  defp count_issues(nil), do: 0
  defp count_issues(issues) when is_list(issues), do: length(issues)
  defp count_issues(%{items: items}) when is_list(items), do: length(items)
  defp count_issues(%{count: count}) when is_integer(count), do: count
  defp count_issues(_), do: 0
end
