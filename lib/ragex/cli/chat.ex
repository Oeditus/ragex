defmodule Ragex.CLI.Chat do
  @moduledoc """
  Interactive terminal chat UI for codebase Q&A using Ragex RAG.

  Uses `Owl.LiveScreen` for real-time streaming output and
  `Owl.IO` for styled user input. Backed by the RAG pipeline
  for retrieval-augmented answers about analyzed codebases.

  ## Usage

      Ragex.CLI.Chat.start(path: "/path/to/project")

  ## Commands

  - `/help`    - Show available commands
  - `/history` - Show conversation history
  - `/clear`   - Clear conversation and start fresh
  - `/sources` - Show sources from last response
  - `/analyze` - Re-analyze the codebase
  - `/status`  - Show session and graph stats
  - `/quit`    - Exit the chat
  """

  require Logger

  alias Ragex.Agent.{Core, Memory}
  alias Ragex.AI.Config, as: AIConfig
  alias Ragex.Analysis.Cache, as: AnalysisCache
  alias Ragex.CLI.{Colors, Progress}
  alias Ragex.Graph.Store
  alias Ragex.RAG.Pipeline

  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  @type state :: %{
          session_id: String.t() | nil,
          path: String.t(),
          provider: atom() | nil,
          model: String.t() | nil,
          strategy: atom(),
          last_sources: [map()],
          message_count: non_neg_integer(),
          analyzed: boolean()
        }

  @doc """
  Start an interactive chat session.

  ## Options

  - `:path` - Project path to analyze (default: cwd)
  - `:provider` - AI provider atom (default: configured default)
  - `:model` - Model name override
  - `:strategy` - Retrieval strategy: :fusion, :semantic_first, :graph_first (default: :fusion)
  - `:skip_analysis` - Skip initial analysis (default: false)
  - `:include_dead_code` - Enable dead code analysis (default: false)
  """
  @spec start(keyword()) :: :ok
  def start(opts \\ []) do
    path = opts |> Keyword.get_lazy(:path, fn -> File.cwd!() end) |> Path.expand()
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)
    strategy = Keyword.get(opts, :strategy, :fusion)
    skip_analysis = Keyword.get(opts, :skip_analysis, false)
    include_dead_code = Keyword.get(opts, :include_dead_code, false)

    debug = Keyword.get(opts, :debug, false)

    state = %{
      session_id: nil,
      path: path,
      provider: provider,
      model: model,
      strategy: strategy,
      last_sources: [],
      message_count: 0,
      analyzed: false,
      include_dead_code: include_dead_code,
      debug: debug
    }

    render_banner(state)

    state =
      if skip_analysis do
        # Check if graph already has data
        stats = Store.stats()

        if stats.nodes > 0 do
          IO.puts(
            Colors.info(
              "Skipping analysis (graph has #{stats.nodes} nodes, #{stats.edges} edges)"
            )
          )

          %{state | analyzed: true}
        else
          IO.puts(Colors.warning("No graph data found. Running initial analysis..."))
          run_analysis(state)
        end
      else
        run_analysis(state)
      end

    IO.puts("")
    IO.puts(Colors.muted("Type your question or /help for commands."))
    IO.puts("")

    chat_loop(state)
  end

  # Private functions

  defp chat_loop(state) do
    prompt = build_prompt(state)

    case IO.gets(prompt) do
      :eof ->
        shutdown(state)

      {:error, _reason} ->
        shutdown(state)

      input when is_binary(input) ->
        input = String.trim(input)
        handle_input(input, state)
    end
  end

  defp handle_input("", state), do: chat_loop(state)
  defp handle_input("/quit", state), do: shutdown(state)
  defp handle_input("/exit", state), do: shutdown(state)
  defp handle_input("/q", state), do: shutdown(state)

  defp handle_input("/help", state) do
    render_help()
    chat_loop(state)
  end

  defp handle_input("/history", state) do
    render_history(state)
    chat_loop(state)
  end

  defp handle_input("/clear", state) do
    if state.session_id, do: Memory.clear_session(state.session_id)
    IO.puts(Colors.info("Conversation cleared."))
    state = %{state | session_id: nil, message_count: 0, last_sources: []}
    chat_loop(state)
  end

  defp handle_input("/sources", state) do
    render_sources(state.last_sources)
    chat_loop(state)
  end

  defp handle_input("/analyze", state) do
    state = run_analysis(state)
    chat_loop(state)
  end

  defp handle_input("/status", state) do
    render_status(state)
    chat_loop(state)
  end

  defp handle_input("/" <> unknown, state) do
    IO.puts(Colors.error("Unknown command: /#{unknown}. Type /help for available commands."))
    chat_loop(state)
  end

  defp handle_input(query, state) do
    state = process_query(query, state)
    chat_loop(state)
  end

  defp process_query(query, state) do
    query_start = System.monotonic_time(:millisecond)

    # Show thinking indicator
    spinner = start_spinner("Searching codebase...")

    opts =
      [strategy: state.strategy, limit: 10, threshold: 0.5]
      |> maybe_add(:provider, state.provider)
      |> maybe_add(:model, state.model)

    result =
      case Pipeline.stream_query(query, opts) do
        {:ok, stream} ->
          stop_spinner(spinner, nil)
          IO.puts("")
          render_stream(stream)

        {:error, :no_results_found} ->
          stop_spinner(spinner, nil)
          # Fall back to agent chat if RAG pipeline finds nothing
          try_agent_chat(query, state)

        {:error, reason} ->
          stop_spinner(spinner, nil)
          {:error, reason}
      end

    elapsed = System.monotonic_time(:millisecond) - query_start

    case result do
      {:ok, response} ->
        IO.puts("")
        render_sources_inline(response.sources)

        IO.puts(
          Colors.success("\u2713") <>
            Colors.muted(" Done (#{Progress.format_elapsed(elapsed)})")
        )

        IO.puts("")

        # Track in session
        state = ensure_session(state)
        Memory.add_message(state.session_id, :user, query)
        Memory.add_message(state.session_id, :assistant, response.content)

        %{
          state
          | last_sources: response.sources,
            message_count: state.message_count + 1
        }

      {:error, {:rate_limited, reason}} ->
        IO.puts("")
        IO.puts(Colors.error("Rate limited: #{reason}"))

        IO.puts(
          Colors.muted("Wait a moment and try again. (#{Progress.format_elapsed(elapsed)})")
        )

        IO.puts("")
        state

      {:error, reason} ->
        IO.puts("")

        IO.puts(
          Colors.error("Error: #{inspect(reason)}") <>
            Colors.muted(" (#{Progress.format_elapsed(elapsed)})")
        )

        IO.puts("")
        state
    end
  end

  defp try_agent_chat(query, state) do
    state = ensure_session(state)

    # Use blocking Core.chat (not stream_chat) because the agent's ReAct loop
    # needs to properly capture tool_calls from the LLM response. The stream
    # parser (StreamConsumer) cannot parse tool_call deltas, so providers like
    # DeepSeek R1 that return content + tool_calls simultaneously have their
    # tool calls silently dropped, truncating the response.
    #
    # Override the system prompt: the session has the report generation prompt
    # ("Do NOT make tool calls") which is wrong for follow-up questions. Replace
    # it with a conversation prompt that directs the AI to use query tools.
    spinner = start_phase_timer("Generating response")

    chat_opts =
      [system_prompt_override: conversation_system_prompt(state.path)]
      |> maybe_add(:provider, state.provider)
      |> maybe_add(:model, state.model)

    if state.debug, do: IO.puts(:stderr, Colors.muted("[debug] agent chat: blocking mode"))

    result = Core.chat(state.session_id, query, chat_opts)
    stop_phase_timer(spinner)

    case result do
      {:ok, %{content: content, tool_calls_made: tc}} ->
        if state.debug do
          IO.puts(:stderr, Colors.muted("[debug] tool calls made: #{tc}"))
          dump_session_messages(state.session_id)
        end

        if content != "" do
          IO.puts("")
          IO.puts(Marcli.render(content))
        end

        {:ok, %{content: content, sources: []}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp render_stream(stream) do
    # Ensure LiveScreen is running for progressive Marcli rendering
    ensure_live_screen()
    live_screen? = live_screen_available?()
    start_time = System.monotonic_time(:millisecond)

    # Non-LiveScreen: start phase timer for visual feedback during waits
    timer_pid = unless live_screen?, do: start_phase_timer("Awaiting response")

    try do
      if live_screen? do
        # Add thinking block (rendered dimmed/faint)
        Owl.LiveScreen.add_block(:thinking,
          state: "",
          render: fn
            "" -> ""
            text -> Owl.Data.tag("[thinking] " <> format_thinking_text(text), :faint)
          end
        )

        # Use LiveScreen for live-updating response block with Marcli rendering
        Owl.LiveScreen.add_block(:response,
          state: "",
          render: fn
            :cleared -> ""
            "" -> Owl.Data.tag("...", :faint)
            text -> Marcli.render(text)
          end
        )

        # Status block with auto-updating elapsed timer
        add_status_block(start_time)
      end

      result =
        Enum.reduce(
          stream,
          %{
            content: "",
            thinking: "",
            sources: [],
            usage: %{},
            phase: :init,
            timer_pid: timer_pid
          },
          fn chunk, acc ->
            case chunk do
              %{thinking: thinking_text, done: false}
              when is_binary(thinking_text) and thinking_text != "" ->
                new_thinking = acc.thinking <> thinking_text
                acc = stop_timer_on_first_output(acc)

                if live_screen? do
                  Owl.LiveScreen.update(:thinking, new_thinking)
                  Owl.LiveScreen.update(:status, "Thinking")
                else
                  # Direct output for non-interactive terminals
                  if acc.phase != :thinking do
                    IO.write(Colors.muted("[thinking] "))
                  end

                  IO.write(Colors.muted(thinking_text))
                end

                %{acc | thinking: new_thinking, phase: :thinking}

              %{content: text, done: false} when is_binary(text) and text != "" ->
                new_content = acc.content <> text
                acc = stop_timer_on_first_output(acc)

                if live_screen? do
                  # When content starts arriving, clear thinking display
                  if acc.thinking != "" and acc.content == "" do
                    Owl.LiveScreen.update(:thinking, "")
                  end

                  Owl.LiveScreen.update(:response, new_content)
                  Owl.LiveScreen.update(:status, "Generating response")
                else
                  # Transition from thinking to answering
                  if acc.phase == :thinking do
                    IO.puts("")
                  end

                  IO.write(text)
                end

                %{acc | content: new_content, phase: :answering}

              %{done: true, metadata: metadata} ->
                if live_screen? do
                  Owl.LiveScreen.update(:thinking, "")
                end

                sources = Map.get(metadata, :sources, [])
                usage = Map.get(metadata, :usage, %{})
                %{acc | sources: sources, usage: usage, phase: :done}

              {:error, reason} ->
                Logger.warning("Stream error: #{inspect(reason)}")
                acc

              _ ->
                acc
            end
          end
        )

      # Cleanup phase timer
      if result.timer_pid, do: stop_phase_timer(result.timer_pid)

      if live_screen? do
        # Clear live blocks before flush to avoid duplicate content;
        # content will be printed statically below for reliable display.
        Owl.LiveScreen.update(:thinking, "")
        Owl.LiveScreen.update(:response, :cleared)
        Owl.LiveScreen.update(:status, "")
        Owl.LiveScreen.flush()
      end

      # Always render final content statically (LiveScreen is ephemeral)
      if result.phase in [:thinking], do: IO.puts("")

      if result.content != "" do
        IO.puts("")
        IO.puts(Marcli.render(result.content))
      end

      # Print thinking summary if any was collected
      if result.thinking != "" do
        thinking_lines = result.thinking |> String.split("\n") |> length()
        IO.puts(Colors.muted("[Thinking: #{thinking_lines} lines]"))
      end

      {:ok, result}
    rescue
      e ->
        stop_phase_timer(timer_pid)
        if live_screen_available?(), do: Owl.LiveScreen.flush()
        {:error, {:stream_error, Exception.message(e)}}
    end
  end

  defp live_screen_available? do
    case Process.whereis(Owl.LiveScreen) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end

  defp ensure_live_screen do
    unless live_screen_available?() do
      Owl.LiveScreen.start_link(name: Owl.LiveScreen, refresh_every: 100)
    end
  end

  defp format_thinking_text(text) do
    # Truncate thinking text for display to last N lines
    lines = String.split(text, "\n")
    max_display_lines = 6

    if length(lines) > max_display_lines do
      displayed = Enum.take(lines, -max_display_lines)
      "...\n" <> Enum.join(displayed, "\n")
    else
      text
    end
  end

  defp run_analysis(state) do
    IO.puts("")

    # Show cache status before analysis
    graph_stats = Store.stats()

    cache_status =
      if graph_stats.nodes > 0 do
        case AnalysisCache.load(state.path) do
          {:ok, _} ->
            IO.puts(
              Colors.info(
                "Cache hit: #{graph_stats.nodes} nodes, #{graph_stats.edges} edges loaded. All files unchanged."
              )
            )

            :fresh

          {:stale, _, changed} ->
            IO.puts(
              Colors.info(
                "Partial cache: #{graph_stats.nodes} nodes loaded. #{length(changed)} files changed, updating..."
              )
            )

            :stale

          _ ->
            :miss
        end
      else
        :miss
      end

    label =
      case cache_status do
        :fresh -> "Restoring from cache..."
        :stale -> "Incremental analysis..."
        :miss -> "Analyzing #{Path.basename(state.path)}..."
      end

    spinner = start_spinner(label)

    # Phase 1: Analysis (skip report generation for streaming)
    analysis_opts = [
      skip_embeddings: false,
      include_dead_code: state.include_dead_code,
      skip_report: true
    ]

    case Core.analyze_project(state.path, analysis_opts) do
      {:ok, result} ->
        stop_spinner(spinner, nil)

        summary_text = format_analysis_summary(result.summary)

        box =
          Owl.Box.new(summary_text,
            title: "Analysis Complete",
            border_style: :solid_rounded,
            border_tag: :green,
            padding_x: 1,
            padding_y: 0
          )

        Owl.IO.puts(box)

        # Phase 2: Stream the AI report generation
        state = stream_initial_report(state, result.issues)

        %{state | analyzed: true}

      {:error, reason} ->
        stop_spinner(spinner, nil)
        IO.puts(Colors.error("Analysis failed: #{inspect(reason)}"))
        IO.puts(Colors.muted("You can still ask questions if the graph has data."))

        # Check existing graph data
        stats = Store.stats()

        if stats.nodes > 0 do
          %{state | analyzed: true}
        else
          state
        end
    end
  end

  defp stream_initial_report(state, issues) do
    report_spinner = start_phase_timer("Generating report")
    {:ok, first_chunk_agent} = Agent.start_link(fn -> false end)

    on_chunk = fn
      %{content: text} when is_binary(text) and text != "" ->
        unless Agent.get(first_chunk_agent, & &1) do
          stop_phase_timer(report_spinner)
          IO.puts("")
          Agent.update(first_chunk_agent, fn _ -> true end)
        end

        IO.write(text)

      _ ->
        :ok
    end

    stream_opts =
      [on_chunk: on_chunk]
      |> maybe_add(:provider, state.provider)
      |> maybe_add(:model, state.model)

    case Core.stream_generate_report(state.path, issues, stream_opts) do
      {:ok, content, _ai_status} ->
        got_chunks = Agent.get(first_chunk_agent, & &1)
        Agent.stop(first_chunk_agent)

        unless got_chunks do
          stop_phase_timer(report_spinner)
        end

        # Re-render with Marcli for proper formatting
        if content != "" do
          IO.puts("\n")
          IO.puts(Marcli.render(content))
          IO.puts("")
        end

        # The stream_generate_report created a session; retrieve its ID
        case Core.list_sessions(limit: 1) do
          [%{id: session_id} | _] -> %{state | session_id: session_id}
          _ -> state
        end

      {:error, reason} ->
        stop_phase_timer(report_spinner)
        Agent.stop(first_chunk_agent)
        IO.puts(Colors.error("Report generation failed: #{inspect(reason)}"))
        state
    end
  end

  defp ensure_session(%{session_id: nil} = state) do
    case Memory.new_session(%{project_path: state.path}) do
      {:ok, session} -> %{state | session_id: session.id}
    end
  end

  defp ensure_session(state), do: state

  # Rendering

  defp render_banner(state) do
    project_name = Path.basename(state.path)

    provider_info =
      if state.provider do
        "Provider: #{state.provider}"
      else
        "Provider: #{AIConfig.provider_name()}"
      end

    model_info =
      if state.model do
        "Model: #{state.model}"
      else
        ""
      end

    info_lines =
      [
        "Project: #{project_name}",
        "Path: #{state.path}",
        provider_info,
        model_info,
        "Strategy: #{state.strategy}"
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    box =
      Owl.Box.new(info_lines,
        title: "Ragex Chat",
        border_style: :solid_rounded,
        border_tag: :cyan,
        padding_x: 1,
        padding_y: 0
      )

    IO.puts("")
    Owl.IO.puts(box)
  end

  defp render_help do
    commands = """
    /help      Show this help message
    /history   Show conversation history
    /clear     Clear conversation and start fresh
    /sources   Show sources from last response
    /analyze   Re-analyze the codebase
    /status    Show session and graph stats
    /quit      Exit the chat
    """

    box =
      Owl.Box.new(commands,
        title: "Commands",
        border_style: :solid_rounded,
        border_tag: :cyan,
        padding_x: 1,
        padding_y: 0
      )

    IO.puts("")
    Owl.IO.puts(box)
    IO.puts("")
  end

  defp render_history(%{session_id: nil}) do
    IO.puts(Colors.muted("No conversation history yet."))
  end

  defp render_history(%{session_id: session_id}) do
    case Memory.get_messages(session_id) do
      {:ok, messages} when messages != [] ->
        IO.puts("")

        Enum.each(messages, fn msg ->
          render_history_message(msg)
        end)

        IO.puts("")

      _ ->
        IO.puts(Colors.muted("No conversation history yet."))
    end
  end

  defp render_history_message(%{role: :user, content: content}) do
    IO.puts(Colors.highlight("You: ") <> (content || ""))
  end

  defp render_history_message(%{role: :assistant, content: content}) do
    IO.puts(Colors.info("Ragex: ") <> (content || ""))
  end

  defp render_history_message(%{role: :system}) do
    # Skip system messages in display
    :ok
  end

  defp render_history_message(%{role: :tool, content: content, name: name}) do
    label = if name, do: "[tool:#{name}]", else: "[tool]"
    IO.puts(Colors.muted(label <> " ") <> (content || ""))
  end

  defp render_history_message(%{role: role, content: content}) do
    IO.puts(Colors.muted("[#{role}] ") <> (content || ""))
  end

  defp render_sources([]) do
    IO.puts(Colors.muted("No sources from last response."))
  end

  defp render_sources(sources) do
    IO.puts("")
    IO.puts(Colors.bold("Sources:"))

    Enum.each(sources, fn source ->
      file = source[:file] || "unknown"
      score = source[:score] || 0.0
      line = source[:line]

      location = if line, do: "#{file}:#{line}", else: file
      score_str = "#{Float.round(score * 100, 1)}%"

      IO.puts(
        "  " <>
          Colors.muted(score_str) <>
          " " <>
          Colors.highlight(Path.relative_to_cwd(location))
      )
    end)

    IO.puts("")
  end

  defp render_sources_inline([]), do: :ok

  defp render_sources_inline(sources) do
    top = Enum.take(sources, 5)

    locations =
      Enum.map_join(top, ", ", fn s ->
        file = s[:file] || "?"
        basename = Path.basename(file)
        if s[:line], do: "#{basename}:#{s[:line]}", else: basename
      end)

    IO.puts(Colors.muted("Sources: #{locations}"))
  end

  defp render_status(state) do
    raw_stats = Store.stats()
    modules = Store.list_nodes(:module)
    functions = Store.list_nodes(:function)

    session_info =
      if state.session_id do
        case Memory.get_session(state.session_id) do
          {:ok, session} -> "Messages: #{length(session.messages)}"
          _ -> "Session: expired"
        end
      else
        "Session: none"
      end

    info = """
    Graph Nodes:  #{raw_stats.nodes}
    Graph Edges:  #{raw_stats.edges}
    Embeddings:   #{raw_stats.embeddings}
    Modules:      #{length(modules)}
    Functions:    #{length(functions)}
    #{session_info}
    Analyzed:     #{state.analyzed}
    """

    box =
      Owl.Box.new(info,
        title: "Status",
        border_style: :solid_rounded,
        border_tag: :cyan,
        padding_x: 1,
        padding_y: 0
      )

    IO.puts("")
    Owl.IO.puts(box)
    IO.puts("")
  end

  defp format_analysis_summary(summary) do
    lines = [
      "Total Issues: #{summary.total_issues}",
      if(Map.get(summary, :quality_files_analyzed, 0) > 0,
        do: "Quality:      #{summary.quality_files_analyzed} files"
      ),
      if(summary.dead_code_count > 0, do: "Dead Code:    #{summary.dead_code_count}"),
      "Duplicates:   #{summary.duplicate_count}",
      "Security:     #{summary.security_count}",
      "Smells:       #{summary.smell_count}",
      "Complexity:   #{summary.complexity_count}"
    ]

    lines
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp build_prompt(state) do
    count =
      if state.message_count > 0 do
        Colors.muted("[#{state.message_count}] ")
      else
        ""
      end

    count <> Colors.highlight("ragex> ")
  end

  defp shutdown(state) do
    IO.puts("")
    IO.puts(Colors.muted("Goodbye!"))

    if state.session_id do
      Logger.debug("Chat session #{state.session_id} ended")
    end

    :ok
  end

  defp start_spinner(label) do
    Progress.start(label)
  end

  defp stop_spinner(pid, message) do
    Progress.stop(pid, message)
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  # Conversation system prompt for follow-up questions

  defp conversation_system_prompt(path) do
    """
    You are an expert code analysis assistant. The project at #{path} has been
    FULLY ANALYZED. The knowledge graph, embeddings, and all metrics are populated.

    CRITICAL RULES FOR ANSWERING FOLLOW-UP QUESTIONS:
    1. The codebase is ALREADY analyzed. Do NOT call analyze_directory or analyze_quality.
       These tools re-run the entire analysis pipeline which is wasteful and slow.
    2. The conversation already contains the complete audit report with all findings.
       Use that data as your primary source.
    3. For additional detail, use these QUERY tools (they read existing data, not re-analyze):
       - read_file: read actual source code from a specific file
       - semantic_search: find code related to a topic by meaning
       - hybrid_search: combined semantic + graph search
       - query_graph: query the knowledge graph for module/function details
       - list_nodes: list modules or functions in the graph
       - find_callers: find what calls a specific function
       - find_paths: find dependency paths between modules
       - find_circular_dependencies: detect circular deps
       - coupling_report: get coupling metrics
       - graph_stats: get knowledge graph statistics
    4. Use at most 2-3 tool calls, then produce your answer.
    5. Be specific: cite file paths, function names, line numbers, code snippets.
    6. Respond in clear Markdown. Do NOT generate a full audit report for follow-up questions.
       Answer the specific question concisely.
    """
  end

  # Debug helpers

  defp dump_session_messages(session_id) do
    case Memory.get_messages(session_id) do
      {:ok, messages} ->
        IO.puts(:stderr, Colors.muted("[debug] Session messages (#{length(messages)}):"))

        Enum.each(messages, fn msg ->
          role = msg.role
          content = msg.content || ""
          preview = content |> String.slice(0, 200) |> String.replace("\n", " ")
          tool_info = if msg[:name], do: " [#{msg[:name]}]", else: ""

          IO.puts(
            :stderr,
            Colors.muted(
              "  [#{role}#{tool_info}] #{preview}#{if String.length(content) > 200, do: "...", else: ""}"
            )
          )
        end)

      _ ->
        :ok
    end
  end

  # Status indicator helpers for streaming progress feedback

  defp add_status_block(start_time, block_name \\ :status) do
    frames = @spinner_frames

    Owl.LiveScreen.add_block(block_name,
      state: "Awaiting response",
      render: fn
        :done ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          Owl.Data.tag("✓ Done (#{Progress.format_elapsed(elapsed)})", :green)

        "" ->
          ""

        phase ->
          elapsed_ms = System.monotonic_time(:millisecond) - start_time
          elapsed_s = div(elapsed_ms, 1000)
          frame_idx = rem(div(elapsed_ms, 80), length(frames))
          frame = Enum.at(frames, frame_idx)
          Owl.Data.tag("#{frame} #{phase}... (#{elapsed_s}s)", :faint)
      end
    )
  end

  defp start_phase_timer(label) do
    if Colors.enabled?() do
      start_time = System.monotonic_time(:millisecond)

      spawn(fn ->
        phase_timer_loop(@spinner_frames, label, start_time, 0)
      end)
    else
      IO.puts(label <> "...")
      nil
    end
  end

  defp stop_phase_timer(nil), do: :ok

  defp stop_phase_timer(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        100 -> :ok
      end

      IO.write("\r\e[K")
    end

    :ok
  end

  defp stop_timer_on_first_output(%{timer_pid: nil} = acc), do: acc

  defp stop_timer_on_first_output(%{timer_pid: pid} = acc) do
    stop_phase_timer(pid)
    %{acc | timer_pid: nil}
  end

  defp phase_timer_loop(frames, phase, start_time, frame_index) do
    frame = Enum.at(frames, rem(frame_index, length(frames)))
    elapsed_ms = System.monotonic_time(:millisecond) - start_time
    elapsed_s = div(elapsed_ms, 1000)

    output = Colors.info(frame) <> " " <> phase <> Colors.muted(" (#{elapsed_s}s)")
    IO.write("\r\e[K" <> output)

    receive do
      {:update_phase, new_phase} ->
        phase_timer_loop(frames, new_phase, start_time, frame_index + 1)

      :stop ->
        :ok
    after
      80 ->
        phase_timer_loop(frames, phase, start_time, frame_index + 1)
    end
  end
end
