defmodule Ragex.Agent.Core do
  @moduledoc """
  Main entry point for Ragex Agent operations.

  Orchestrates the full project analysis pipeline:
  1. Analyze project (build knowledge graph, embeddings)
  2. Discover issues (dead code, duplicates, security, smells, complexity)
  3. Generate AI-polished report (AI may use Ragex MCP RAG tools for evidence)
  4. Enable conversation session for follow-up

  ## Report generation and RAG

  During step 3 the AI assistant is given access to a restricted set of
  read-only Ragex MCP query tools (`ToolSchema.rag_query_tools/1`).  This lets
  the AI look up concrete code details — reading a flagged file, checking
  coupling metrics, or finding callers of a complex function — to produce
  evidence-based findings rather than relying solely on pre-computed statistics.
  Heavy re-analysis tools are excluded so the pipeline is not re-triggered.

  ## Usage

      # Full project analysis with report
      {:ok, result} = Agent.Core.analyze_project("/path/to/project")

      # Skip report generation (e.g. before streaming it separately)
      {:ok, result} = Agent.Core.analyze_project("/path/to/project", skip_report: true)

      # Continue conversation (agent uses full tool set)
      {:ok, response} = Agent.Core.chat(result.session_id, "Tell me more about the security issues")

      # Get just the report
      {:ok, report} = Agent.Core.get_report(result.session_id)
  """

  require Logger

  alias Ragex.Agent.{Executor, Memory, Report, ToolSchema}
  alias Ragex.AI.Config, as: AIConfig
  alias Ragex.Analyzers.Directory

  alias Ragex.Analysis.Cache, as: AnalysisCache

  alias Ragex.Analysis.{
    DeadCode,
    DependencyGraph,
    Duplication,
    Quality,
    Security,
    Smells,
    Suggestions
  }

  alias Ragex.Embeddings.Persistence, as: EmbeddingsPersistence
  alias Ragex.Graph.Persistence, as: GraphPersistence
  alias Ragex.Graph.Store

  @type analysis_result :: %{
          session_id: String.t(),
          report: String.t(),
          issues: map(),
          summary: map()
        }

  @features Application.compile_env(:ragex, :features, [])
  @include_suggestions Keyword.get(@features, :suggestions, true)
  @include_dead_code Keyword.get(@features, :dead_code, false)

  @doc """
  Analyze a project and generate an AI-polished report.

  The AI report is generated using a restricted set of read-only Ragex MCP
  query tools so the AI can retrieve concrete code evidence.  Pass
  `skip_report: true` to skip report generation (e.g. when you intend to
  stream it later via `stream_generate_report/3`).

  ## Parameters

  - `path` - Project root path
  - `opts` - Options:
    - `:provider` - AI provider (:deepseek_r1, :openai, :anthropic, :ollama)
    - `:model` - Model name override
    - `:include_suggestions` - Include refactoring suggestions (default: true)
    - `:max_files` - Maximum files to analyze (default: 500)
    - `:skip_embeddings` - Skip embedding generation (default: false)
    - `:skip_report` - Skip AI report generation (default: false)
    - `:include_dead_code` - Enable dead code analysis (default: false)
    - `:exclude_patterns` - Patterns to exclude (default: standard ignores)

  ## Returns

  - `{:ok, result}` - Analysis completed with session ID and report
  - `{:error, reason}` - Analysis failed
  """
  @spec analyze_project(String.t(), keyword()) :: {:ok, analysis_result()} | {:error, term()}
  def analyze_project(path, opts \\ []) do
    Logger.info("Starting project analysis: #{path}")

    with {:ok, abs_path} <- validate_path(path) do
      # Switch store to the target project: clears stale data and loads
      # the correct per-project cache (graph + embeddings + file tracker).
      Store.load_project(abs_path)

      graph_stats = Store.stats()

      case {graph_stats.nodes > 0, AnalysisCache.load(abs_path)} do
        {true, {:ok, cached_issues}} ->
          # Graph loaded from cache + issues fresh -> skip everything
          Logger.info("Using cached analysis (#{graph_stats.nodes} nodes, all files unchanged)")

          finalize_analysis(abs_path, cached_issues, opts)

        {true, {:stale, _cached_issues, changed_files}} ->
          # Graph loaded but some files changed -> incremental re-analysis
          Logger.info("Incremental analysis: #{length(changed_files)} files changed")

          with {:ok, _} <- analyze_codebase(abs_path, opts),
               {:ok, issues} <- discover_issues(abs_path, opts) do
            persist_all_state(issues, abs_path)
            finalize_analysis(abs_path, issues, opts)
          end

        _ ->
          # No cache or empty graph -> full analysis
          with {:ok, _} <- analyze_codebase(abs_path, opts),
               {:ok, issues} <- discover_issues(abs_path, opts) do
            persist_all_state(issues, abs_path)
            finalize_analysis(abs_path, issues, opts)
          end
      end
    end
  end

  @doc """
  Continue a conversation with the agent in an existing session.

  ## Parameters

  - `session_id` - Active session ID
  - `message` - User message
  - `opts` - Options (same as analyze_project)

  ## Returns

  - `{:ok, response}` - Agent response
  - `{:error, reason}` - Chat failed
  """
  @spec chat(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(session_id, message, opts \\ []) do
    Logger.debug("Agent chat: session=#{session_id}")

    with {:ok, _session} <- Memory.get_session(session_id),
         :ok <- Memory.add_message(session_id, :user, message),
         {:ok, result} <- Executor.run(session_id, opts) do
      {:ok,
       %{
         content: result.content,
         tool_calls_made: result.tool_calls_made,
         usage: result.usage
       }}
    end
  end

  @doc """
  Continue a conversation with streaming support.

  Same as `chat/3` but streams the final AI response in real-time via callbacks.
  Intermediate tool-call steps use blocking calls, but the final text response
  is streamed chunk-by-chunk.

  ## Additional Options

  - `:on_chunk` - `(chunk -> :ok)` callback for real-time content/thinking delivery
  - `:on_phase` - `(:thinking | :answering | :done -> :ok)` phase transition callback
  - `:on_tool_progress` - `(map() -> :ok)` callback when tools are being called

  ## Returns

  Same as `chat/3`.
  """
  @spec stream_chat(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stream_chat(session_id, message, opts \\ []) do
    Logger.debug("Agent stream_chat: session=#{session_id}")

    with {:ok, _session} <- Memory.get_session(session_id),
         :ok <- Memory.add_message(session_id, :user, message),
         {:ok, result} <- Executor.stream_run(session_id, opts) do
      {:ok,
       %{
         content: result.content,
         tool_calls_made: result.tool_calls_made,
         usage: result.usage
       }}
    end
  end

  @doc """
  Get the generated report from a session.

  If not yet generated, generates it on-demand.
  """
  @spec get_report(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_report(session_id, opts \\ []) do
    with {:ok, session} <- Memory.get_session(session_id) do
      case session.metadata[:report] do
        nil ->
          # Generate report from issues
          issues = session.metadata[:issues] || %{}

          {:ok, report, _ai_status} = generate_report(session_id, issues, opts)
          {:ok, report}

        report ->
          {:ok, report}
      end
    end
  end

  @doc """
  Quick analysis - runs all detectors without AI polishing.

  Useful for programmatic access to raw issue data.
  """
  @spec quick_analyze(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def quick_analyze(path, opts \\ []) do
    with {:ok, abs_path} <- validate_path(path),
         {:ok, _} <- analyze_codebase(abs_path, opts),
         {:ok, issues} <- discover_issues(abs_path, opts) do
      {:ok, %{issues: issues, summary: build_summary(issues)}}
    end
  end

  @doc """
  List all active agent sessions.
  """
  @spec list_sessions(keyword()) :: [map()]
  def list_sessions(opts \\ []) do
    Memory.list_sessions(opts)
    |> Enum.map(fn session ->
      %{
        id: session.id,
        project_path: session.metadata[:project_path],
        created_at: session.created_at,
        message_count: length(session.messages)
      }
    end)
  end

  @doc """
  Get session details.
  """
  @spec get_session(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_session(session_id) do
    with {:ok, session} <- Memory.get_session(session_id) do
      {:ok,
       %{
         id: session.id,
         project_path: session.metadata[:project_path],
         created_at: session.created_at,
         updated_at: session.updated_at,
         message_count: length(session.messages),
         has_report: not is_nil(session.metadata[:report]),
         issues_summary: build_summary(session.metadata[:issues] || %{})
       }}
    end
  end

  @doc """
  Clear/end a session.
  """
  @spec clear_session(String.t()) :: :ok
  def clear_session(session_id) do
    Memory.clear_session(session_id)
  end

  # Private functions

  defp finalize_analysis(path, issues, opts) do
    if Keyword.get(opts, :skip_report, false) do
      summary = build_summary(issues)
      Logger.info("Analysis complete (report skipped): #{summary.total_issues} issues found")

      {:ok,
       %{
         session_id: nil,
         report: nil,
         ai_status: %{status: "skipped"},
         issues: issues,
         summary: summary
       }}
    else
      with {:ok, session} <- create_analysis_session(path, issues, opts),
           {:ok, report, ai_status} <- generate_report(session.id, issues, opts) do
        summary = build_summary(issues)
        Logger.info("Project analysis complete: #{summary.total_issues} issues found")

        {:ok,
         %{
           session_id: session.id,
           report: report,
           ai_status: ai_status,
           issues: issues,
           summary: summary
         }}
      end
    end
  end

  defp persist_all_state(issues, path) do
    # Eagerly save state to disk since Mix tasks don't trigger GenServer terminate/2.
    # Use the analyzed path as the cache key so different projects get separate caches.
    AnalysisCache.save(issues, path)
    EmbeddingsPersistence.save(nil, path)
    GraphPersistence.save(path)
  end

  defp validate_path(path) do
    abs_path = Path.expand(path)

    cond do
      not File.exists?(abs_path) ->
        {:error, {:path_not_found, path}}

      not File.dir?(abs_path) ->
        {:error, {:not_a_directory, path}}

      true ->
        {:ok, abs_path}
    end
  end

  defp analyze_codebase(path, opts) do
    Logger.info("Analyzing codebase structure...")

    exclude_patterns =
      Keyword.get(opts, :exclude_patterns, [
        "_build",
        "deps",
        "node_modules",
        ".git",
        ".elixir_ls",
        "cover",
        "priv/static"
      ])

    max_depth = Keyword.get(opts, :max_depth, 20)
    generate_embeddings = not Keyword.get(opts, :skip_embeddings, false)

    case Directory.analyze_directory(path,
           exclude_patterns: exclude_patterns,
           max_depth: max_depth,
           generate_embeddings: generate_embeddings
         ) do
      {:ok, result} ->
        Logger.info("Analyzed #{result.analyzed} files")
        {:ok, result}

      {:error, reason} ->
        Logger.error("Codebase analysis failed: #{inspect(reason)}")
        {:error, {:analysis_failed, reason}}
    end
  end

  defp discover_issues(path, opts) do
    Logger.info("Discovering issues...")

    include_suggestions = Keyword.get(opts, :include_suggestions, @include_suggestions)
    include_dead_code = Keyword.get(opts, :include_dead_code, @include_dead_code)

    # Run MetastaticBridge quality analysis first to populate QualityStore
    # so that find_complex queries below return actual data.
    Logger.info("Running quality analysis (MetastaticBridge)...")
    safe_analyze(&Quality.analyze_directory/2, [path, [store: true]])

    # Collect cyclomatic and cognitive complexity hotspots
    cyclomatic_complex =
      safe_analyze(&Quality.find_complex/1, [[metric: :cyclomatic, threshold: 10]])

    cognitive_complex =
      safe_analyze(&Quality.find_complex/1, [[metric: :cognitive, threshold: 15]])

    # Merge and deduplicate by path
    all_complex =
      (cyclomatic_complex ++ cognitive_complex)
      |> Enum.uniq_by(fn
        %{path: path} -> path
        item -> item
      end)

    issues = %{
      dead_code:
        if(include_dead_code,
          do: safe_analyze(&DeadCode.find_dead_code/0, []),
          else: []
        ),
      duplicates: safe_analyze(&Duplication.detect_in_directory/2, [path, [threshold: 0.8]]),
      security: safe_analyze(&Security.analyze_directory/2, [path, []]),
      smells: safe_analyze(&Smells.detect_smells/2, [path, []]),
      complexity: all_complex,
      circular_deps: safe_analyze(&DependencyGraph.find_cycles/1, [[]]),
      quality_metrics: safe_analyze(&Quality.statistics/0, [])
    }

    issues =
      if include_suggestions do
        Map.put(issues, :suggestions, safe_analyze(&Suggestions.analyze_target/2, [path, []]))
      else
        issues
      end

    {:ok, issues}
  end

  defp safe_analyze(func, args) do
    case apply(func, args) do
      {:ok, result} -> result
      {:error, _} -> []
      result when is_list(result) -> result
      result when is_map(result) -> result
      _ -> []
    end
  rescue
    e ->
      Logger.warning("Analysis function failed: #{Exception.message(e)}")
      []
  catch
    :exit, reason ->
      Logger.warning("Analysis function exited: #{inspect(reason)}")
      []
  end

  defp create_analysis_session(path, issues, _opts) do
    metadata = %{
      project_path: path,
      issues: issues,
      analyzed_at: DateTime.utc_now()
    }

    Memory.new_session(metadata)
  end

  defp generate_report(session_id, issues, opts) do
    Logger.info("Generating AI-polished report...")

    # Get project path from session metadata for path-aware system prompt
    project_path =
      case Memory.get_session(session_id) do
        {:ok, session} -> session.metadata[:project_path]
        _ -> nil
      end

    # Resolve provider info for AI status tracking
    provider_name = Keyword.get(opts, :provider) || AIConfig.provider_name()
    config = AIConfig.api_config(provider_name)

    if is_nil(config.api_key) or config.api_key == "" do
      Logger.info("No API key for #{provider_name}, skipping AI report")

      ai_status = %{
        status: "no_keys",
        provider: to_string(provider_name),
        model: config.model,
        error: "No API key configured for #{provider_name}"
      }

      {:ok, Report.generate_basic_report(issues), ai_status}
    else
      generate_ai_report(session_id, issues, opts, project_path, provider_name, config)
    end
  end

  defp generate_ai_report(session_id, issues, opts, project_path, provider_name, config) do
    setup_report_prompts(session_id, issues, project_path)

    # Restrict the executor to read-only RAG query tools so the AI can retrieve
    # concrete code evidence without re-triggering the heavy analysis pipeline.
    rag_tools = ToolSchema.rag_query_tools(provider_name)
    report_opts = Keyword.put(opts, :tools, rag_tools)

    # Run the agent to generate report
    case Executor.run(session_id, report_opts) do
      {:ok, result} ->
        # Save report to session metadata
        Memory.update_metadata(session_id, %{report: result.content})

        ai_status = %{
          status: "success",
          provider: to_string(provider_name),
          model: config.model,
          chars: String.length(result.content),
          tokens: result.usage
        }

        {:ok, result.content, ai_status}

      {:error, reason} ->
        Logger.error("Report generation failed: #{inspect(reason)}")

        ai_status = %{
          status: "failed",
          provider: to_string(provider_name),
          model: config.model,
          error: inspect(reason)
        }

        error_note = "[AI report generation failed: #{inspect(reason)}]\n\n"
        {:ok, error_note <> Report.generate_basic_report(issues), ai_status}
    end
  end

  defp setup_report_prompts(session_id, issues, project_path) do
    system_prompt = Report.system_prompt(project_path)
    Memory.add_message(session_id, :system, system_prompt)

    graph_stats = Store.stats()
    modules = Store.list_nodes(:module, :infinity)
    functions = Store.list_nodes(:function, :infinity)
    issues_summary = Report.format_issues_for_llm(issues)

    user_prompt = """
    Generate a comprehensive Code Quality Audit Report from the following analysis data.
    All data has been collected by automated static analysis tools.
    Use the provided data as your primary source. You may call RAG query tools
    (read_file, semantic_search, hybrid_search, query_graph, list_nodes, find_callers,
    find_paths, graph_stats) to look up specific code details for evidence-based findings.
    Synthesize everything below into the report structure specified in your instructions.

    ## Codebase Architecture

    - Project path: #{project_path || "unknown"}
    - Knowledge graph: #{graph_stats.nodes} nodes, #{graph_stats.edges} edges
    - Modules: #{length(modules)}
    - Functions: #{length(functions)}
    - Embeddings: #{graph_stats.embeddings}
    - Audit date: #{DateTime.utc_now() |> DateTime.to_date() |> Date.to_string()}

    ## Analysis Results

    #{issues_summary}

    ## Analysis Thresholds Applied

    - Cyclomatic complexity threshold: 10 (flagged if >10)
    - Cognitive complexity threshold: 15 (flagged if >15)
    - Duplication similarity threshold: 80%
    - Dead code minimum confidence: 70%
    """

    Memory.add_message(session_id, :user, user_prompt)
  end

  @doc """
  Generate an AI audit report, optionally notifying a callback when ready.

  Requires the knowledge graph and embeddings to be populated first
  (call `analyze_project/2` with `skip_report: true`).

  The executor runs in blocking mode so that RAG tool calls (read_file,
  semantic_search, hybrid_search, etc.) are executed correctly before the
  final report is written.  Streaming parsers drop `tool_call` deltas, so
  a streaming executor would mis-identify preamble text as the final report
  and never execute the tool calls.

  The `:on_chunk` callback is fired once after the blocking run completes,
  with the full report content, so callers can use it as a completion signal
  (e.g. to stop a spinner).

  ## Options

  - `:on_chunk` - `(chunk -> :ok)` completion callback, fired once with
    `%{content: report_string}` when the report is ready
  - `:provider` - AI provider override
  - `:model` - Model override
  """
  @spec stream_generate_report(String.t(), map(), keyword()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def stream_generate_report(path, issues, opts \\ []) do
    abs_path = Path.expand(path)

    with {:ok, session} <- create_analysis_session(abs_path, issues, opts) do
      provider_name = Keyword.get(opts, :provider) || AIConfig.provider_name()
      config = AIConfig.api_config(provider_name)

      if is_nil(config.api_key) or config.api_key == "" do
        basic = Report.generate_basic_report(issues)
        {:ok, basic, %{status: "no_keys", provider: to_string(provider_name)}}
      else
        setup_report_prompts(session.id, issues, abs_path)

        # Restrict to read-only RAG tools.
        # Use blocking Executor.run (not stream_run): the AI may produce preamble
        # text *and* tool_calls in the same first response.  The streaming parser
        # captures the text but drops the tool_call deltas, so stream_run would
        # exit early with just the preamble, never executing the RAG tool calls.
        rag_tools = ToolSchema.rag_query_tools(provider_name)
        report_opts = opts |> Keyword.put(:tools, rag_tools) |> Keyword.delete(:on_chunk)

        case Executor.run(session.id, report_opts) do
          {:ok, result} ->
            Memory.update_metadata(session.id, %{report: result.content})

            # Notify caller that the report is ready (compatibility with on_chunk interface)
            if on_chunk = Keyword.get(opts, :on_chunk) do
              on_chunk.(%{content: result.content})
            end

            ai_status = %{
              status: "success",
              provider: to_string(provider_name),
              model: config.model,
              chars: String.length(result.content),
              tokens: result.usage
            }

            {:ok, result.content, ai_status}

          {:error, reason} ->
            Logger.error("Report generation failed: #{inspect(reason)}")
            error_note = "[AI report generation failed: #{inspect(reason)}]\n\n"
            basic = error_note <> Report.generate_basic_report(issues)

            if on_chunk = Keyword.get(opts, :on_chunk) do
              on_chunk.(%{content: basic})
            end

            {:ok, basic,
             %{status: "failed", provider: to_string(provider_name), error: inspect(reason)}}
        end
      end
    end
  end

  defp build_summary(issues) when is_map(issues) do
    quality = issues[:quality_metrics] || %{}

    %{
      dead_code_count: count_issues(issues[:dead_code]),
      duplicate_count: count_issues(issues[:duplicates]),
      security_count: count_issues(issues[:security]),
      smell_count: count_issues(issues[:smells]),
      complexity_count: count_issues(issues[:complexity]),
      circular_dep_count: count_issues(issues[:circular_deps]),
      suggestion_count: count_issues(issues[:suggestions]),
      quality_files_analyzed: Map.get(quality, :total_files, 0),
      total_issues:
        count_issues(issues[:dead_code]) +
          count_issues(issues[:duplicates]) +
          count_issues(issues[:security]) +
          count_issues(issues[:smells]) +
          count_issues(issues[:complexity]) +
          count_issues(issues[:circular_deps])
    }
  end

  defp build_summary(_), do: %{total_issues: 0}

  defp count_issues(nil), do: 0
  defp count_issues(issues) when is_list(issues), do: length(issues)
  defp count_issues(%{items: items}) when is_list(items), do: length(items)
  defp count_issues(%{count: count}) when is_integer(count), do: count
  defp count_issues(_), do: 0
end
