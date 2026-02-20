defmodule Ragex.Agent.Executor do
  @moduledoc """
  ReAct (Reasoning + Acting) execution loop for agent operations.

  Implements the agent loop:
  1. Build prompt with conversation history and available tools
  2. Call LLM with tools enabled
  3. If response has tool_calls: execute tools, add results, repeat
  4. Return final text response

  ## Usage

      alias Ragex.Agent.{Executor, Memory, ToolSchema}

      # Create session and run agent
      {:ok, session} = Memory.new_session(%{project_path: "/my/project"})
      Memory.add_message(session.id, :system, "You are a code analysis assistant...")
      Memory.add_message(session.id, :user, "Analyze this project for issues")

      {:ok, result} = Executor.run(session.id, [
        max_iterations: 10,
        provider: :deepseek_r1
      ])
  """

  require Logger

  alias Ragex.Agent.{Memory, ToolSchema}
  alias Ragex.AI.Config
  alias Ragex.MCP.Handlers.Tools, as: MCPTools

  @default_max_iterations 15
  @default_temperature 0.7
  @default_max_tokens 4096

  @type run_result :: %{
          content: String.t(),
          iterations: non_neg_integer(),
          tool_calls_made: non_neg_integer(),
          usage: map(),
          session_id: String.t()
        }

  @doc """
  Run the agent execution loop.

  ## Parameters

  - `session_id` - Active session ID with conversation history
  - `opts` - Options:
    - `:max_iterations` - Maximum tool call iterations (default: 15)
    - `:provider` - AI provider override (:deepseek_r1, :openai, :anthropic)
    - `:tools` - Custom tool list (default: agent_tools)
    - `:temperature` - LLM temperature (default: 0.7)
    - `:max_tokens` - Max response tokens (default: 4096)
    - `:tool_choice` - Tool selection strategy ("auto", "any", or specific tool)

  ## Returns

  - `{:ok, result}` - Execution completed with final response
  - `{:error, reason}` - Execution failed
  """
  @spec run(String.t(), keyword()) :: {:ok, run_result()} | {:error, term()}
  def run(session_id, opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    provider = get_provider(opts)
    provider_name = get_provider_name(opts)

    tools = get_tools(provider_name, opts)

    state = %{
      session_id: session_id,
      provider: provider,
      provider_name: provider_name,
      tools: tools,
      opts: opts,
      iterations: 0,
      tool_calls_made: 0,
      total_usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    }

    case execute_loop(state, max_iterations) do
      {:ok, final_state, content} ->
        {:ok,
         %{
           content: content,
           iterations: final_state.iterations,
           tool_calls_made: final_state.tool_calls_made,
           usage: final_state.total_usage,
           session_id: session_id
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Execute a single step of the agent loop.

  Useful for debugging or manual step-through.
  """
  @spec step(String.t(), keyword()) ::
          {:continue, map()} | {:done, String.t()} | {:error, term()}
  def step(session_id, opts \\ []) do
    provider = get_provider(opts)
    provider_name = get_provider_name(opts)
    tools = get_tools(provider_name, opts)

    state = %{
      session_id: session_id,
      provider: provider,
      provider_name: provider_name,
      tools: tools,
      opts: opts,
      iterations: 0,
      tool_calls_made: 0,
      total_usage: %{}
    }

    execute_step(state)
  end

  # Private functions

  defp execute_loop(state, max_iterations) when state.iterations >= max_iterations do
    Logger.warning("Agent reached max iterations (#{max_iterations})")
    # Return last assistant message or error
    case Memory.get_messages(state.session_id, limit: 1) do
      {:ok, [%{role: :assistant, content: content}]} when not is_nil(content) ->
        {:ok, state, content}

      _ ->
        {:error, :max_iterations_exceeded}
    end
  end

  defp execute_loop(state, max_iterations) do
    case execute_step(state) do
      {:continue, updated_state} ->
        execute_loop(updated_state, max_iterations)

      {:done, content, updated_state} ->
        {:ok, updated_state, content}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_step(state) do
    with {:ok, messages} <- Memory.get_context(state.session_id, format: state.provider_name),
         {:ok, response} <- call_llm(state, messages) do
      # Update usage tracking
      updated_state = update_usage(state, response.usage)

      case response.tool_calls do
        nil ->
          # No tool calls - we're done
          content = response.content || ""
          # Save assistant response
          Memory.add_message(state.session_id, :assistant, content)
          {:done, content, updated_state}

        [] ->
          # Empty tool calls - we're done
          content = response.content || ""
          Memory.add_message(state.session_id, :assistant, content)
          {:done, content, updated_state}

        tool_calls when is_list(tool_calls) ->
          # Execute tool calls
          Logger.debug("Agent making #{length(tool_calls)} tool call(s)")

          # Save assistant message with tool calls
          Memory.add_message(state.session_id, :assistant, response.content || "",
            tool_calls: tool_calls
          )

          # Execute each tool and add results
          results = execute_tool_calls(tool_calls, state)

          # Add tool results to conversation
          Enum.each(results, fn {tool_call, result} ->
            result_str = format_tool_result(result)

            Memory.add_message(state.session_id, :tool, result_str,
              tool_call_id: tool_call.id,
              name: tool_call.name
            )

            Memory.add_tool_result(state.session_id, tool_call.id, result)
          end)

          # Update state
          updated_state = %{
            updated_state
            | iterations: updated_state.iterations + 1,
              tool_calls_made: updated_state.tool_calls_made + length(tool_calls)
          }

          {:continue, updated_state}
      end
    end
  end

  defp call_llm(state, messages) do
    opts = [
      tools: state.tools,
      temperature: Keyword.get(state.opts, :temperature, @default_temperature),
      max_tokens: Keyword.get(state.opts, :max_tokens, @default_max_tokens),
      tool_choice: Keyword.get(state.opts, :tool_choice, "auto")
    ]

    # Format messages for provider
    formatted_messages = format_messages_for_provider(messages, state.provider_name)

    # Build prompt from messages
    {system_prompt, user_messages} = extract_system_prompt(formatted_messages)

    # Call provider
    prompt = build_prompt_from_messages(user_messages)

    state.provider.generate(prompt, %{messages: user_messages}, [
      {:system_prompt, system_prompt} | opts
    ])
  end

  defp format_messages_for_provider(messages, :anthropic) do
    # Anthropic already handled by Memory.get_context
    messages
  end

  defp format_messages_for_provider(messages, _provider) do
    # OpenAI/DeepSeek format
    messages
  end

  defp extract_system_prompt(messages) do
    case Enum.split_with(messages, &(&1["role"] == "system" or &1[:role] == "system")) do
      {[system | _], others} ->
        {system["content"] || system[:content], others}

      {[], others} ->
        {default_system_prompt(), others}
    end
  end

  defp build_prompt_from_messages(messages) do
    # Get the last user message as the prompt
    case Enum.reverse(messages) do
      [%{"content" => content} | _] when is_binary(content) -> content
      [%{content: content} | _] when is_binary(content) -> content
      _ -> ""
    end
  end

  defp default_system_prompt do
    """
    You are an expert code analysis agent. You have access to tools for analyzing codebases.

    Your goal is to:
    1. Understand the user's request
    2. Use the available tools to gather information
    3. Provide comprehensive, actionable insights

    When analyzing code:
    - Use semantic_search and hybrid_search for finding relevant code
    - Use find_dead_code, find_duplicates, scan_security for issues
    - Use analyze_quality, analyze_dependencies for structure
    - Use suggest_refactorings for improvements

    Always explain your findings clearly and provide specific recommendations.
    """
  end

  defp execute_tool_calls(tool_calls, _state) do
    Enum.map(tool_calls, fn tool_call ->
      Logger.debug("Executing tool: #{tool_call.name}")
      result = execute_single_tool(tool_call.name, tool_call.arguments)
      {tool_call, result}
    end)
  end

  defp execute_single_tool(tool_name, arguments) do
    # Convert string keys to match MCP handler expectations
    args =
      arguments
      |> Enum.map(fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
      |> Enum.into(%{})

    try do
      case MCPTools.call_tool(tool_name, args) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          Logger.warning("Tool #{tool_name} failed: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Tool #{tool_name} raised exception: #{inspect(e)}")
        {:error, {:exception, Exception.message(e)}}
    catch
      kind, value ->
        Logger.error("Tool #{tool_name} threw #{kind}: #{inspect(value)}")
        {:error, {kind, value}}
    end
  end

  defp format_tool_result({:ok, result}) when is_map(result) do
    # Truncate large results
    result_str = Jason.encode!(result, pretty: true)

    if String.length(result_str) > 8000 do
      String.slice(result_str, 0, 8000) <> "\n... (truncated)"
    else
      result_str
    end
  end

  defp format_tool_result({:ok, result}) do
    inspect(result, limit: :infinity, pretty: true)
  end

  defp format_tool_result({:error, reason}) do
    "Error: #{inspect(reason)}"
  end

  defp get_provider(opts) do
    case Keyword.get(opts, :provider) do
      nil -> Config.provider()
      :deepseek_r1 -> Ragex.AI.Provider.DeepSeekR1
      :openai -> Ragex.AI.Provider.OpenAI
      :anthropic -> Ragex.AI.Provider.Anthropic
      :ollama -> Ragex.AI.Provider.Ollama
      module when is_atom(module) -> module
    end
  end

  defp get_provider_name(opts) do
    case Keyword.get(opts, :provider) do
      nil -> Config.provider_name()
      name when is_atom(name) -> name
    end
  end

  defp get_tools(provider_name, opts) do
    case Keyword.get(opts, :tools) do
      nil -> ToolSchema.tools_for_provider(provider_name)
      tools when is_list(tools) -> tools
    end
  end

  defp update_usage(state, nil), do: state

  defp update_usage(state, usage) when is_map(usage) do
    current = state.total_usage

    updated = %{
      prompt_tokens:
        (current[:prompt_tokens] || 0) + (usage[:prompt_tokens] || usage["prompt_tokens"] || 0),
      completion_tokens:
        (current[:completion_tokens] || 0) +
          (usage[:completion_tokens] || usage["completion_tokens"] || 0),
      total_tokens:
        (current[:total_tokens] || 0) + (usage[:total_tokens] || usage["total_tokens"] || 0)
    }

    %{state | total_usage: updated}
  end
end
