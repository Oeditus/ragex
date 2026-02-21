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
  alias Ragex.CLI.{Colors, Progress}
  alias Ragex.Graph.Store
  alias Ragex.RAG.Pipeline

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
  """
  @spec start(keyword()) :: :ok
  def start(opts \\ []) do
    path = Keyword.get(opts, :path, File.cwd!()) |> Path.expand()
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model)
    strategy = Keyword.get(opts, :strategy, :fusion)
    skip_analysis = Keyword.get(opts, :skip_analysis, false)

    state = %{
      session_id: nil,
      path: path,
      provider: provider,
      model: model,
      strategy: strategy,
      last_sources: [],
      message_count: 0,
      analyzed: false
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

    case result do
      {:ok, response} ->
        IO.puts("")
        render_sources_inline(response.sources)
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
        IO.puts(Colors.muted("Wait a moment and try again."))
        IO.puts("")
        state

      {:error, reason} ->
        IO.puts("")
        IO.puts(Colors.error("Error: #{inspect(reason)}"))
        IO.puts("")
        state
    end
  end

  defp try_agent_chat(query, state) do
    state = ensure_session(state)

    case Core.chat(state.session_id, query) do
      {:ok, %{content: content}} ->
        IO.puts("")
        IO.puts(format_assistant_text(content))
        {:ok, %{content: content, sources: []}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp render_stream(stream) do
    # Use LiveScreen for live-updating response block
    Owl.LiveScreen.add_block(:response,
      state: "",
      render: fn
        "" -> Owl.Data.tag("...", :faint)
        text -> format_assistant_text(text)
      end
    )

    result =
      Enum.reduce(stream, %{content: "", sources: [], usage: %{}}, fn chunk, acc ->
        case chunk do
          %{content: text, done: false} when is_binary(text) ->
            new_content = acc.content <> text
            Owl.LiveScreen.update(:response, new_content)
            %{acc | content: new_content}

          %{done: true, metadata: metadata} ->
            sources = Map.get(metadata, :sources, [])
            usage = Map.get(metadata, :usage, %{})
            %{acc | sources: sources, usage: usage}

          {:error, reason} ->
            Logger.warning("Stream error: #{inspect(reason)}")
            acc

          _ ->
            acc
        end
      end)

    # Flush the live block and print final content statically
    Owl.LiveScreen.flush()

    {:ok, result}
  rescue
    e ->
      Owl.LiveScreen.flush()
      {:error, {:stream_error, Exception.message(e)}}
  end

  defp run_analysis(state) do
    IO.puts("")

    spinner =
      start_spinner("Analyzing #{Path.basename(state.path)}...")

    case Core.analyze_project(state.path, skip_embeddings: false) do
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

        %{state | session_id: result.session_id, analyzed: true}

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
    IO.puts(Colors.highlight("You: ") <> truncate(content, 120))
  end

  defp render_history_message(%{role: :assistant, content: content}) do
    IO.puts(Colors.info("Ragex: ") <> truncate(content, 120))
  end

  defp render_history_message(%{role: :system}) do
    # Skip system messages in display
    :ok
  end

  defp render_history_message(%{role: role, content: content}) do
    IO.puts(Colors.muted("[#{role}] ") <> truncate(content, 120))
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

  defp format_assistant_text(text) do
    # Apply basic styling: dim code fences, keep content readable
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      cond do
        String.starts_with?(line, "```") ->
          Colors.muted(line)

        String.starts_with?(line, "#") ->
          Colors.bold(line)

        String.starts_with?(line, "- ") or String.starts_with?(line, "* ") ->
          Colors.info("  " <> line)

        true ->
          line
      end
    end)
  end

  defp format_analysis_summary(summary) do
    [
      "Total Issues: #{summary.total_issues}",
      "Dead Code:    #{summary.dead_code_count}",
      "Duplicates:   #{summary.duplicate_count}",
      "Security:     #{summary.security_count}",
      "Smells:       #{summary.smell_count}",
      "Complexity:   #{summary.complexity_count}"
    ]
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

  defp truncate(text, max) when byte_size(text) > max do
    String.slice(text, 0, max - 3) <> "..."
  end

  defp truncate(text, _max), do: text
end
