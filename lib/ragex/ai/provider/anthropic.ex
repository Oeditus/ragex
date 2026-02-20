defmodule Ragex.AI.Provider.Anthropic do
  @moduledoc """
  Anthropic API provider implementation.

  Supports Claude 3 models (Opus, Sonnet, Haiku) via the Anthropic API.

  ## Configuration

      config :ragex, :ai_providers,
        anthropic: [
          endpoint: "https://api.anthropic.com/v1",
          model: "claude-3-sonnet-20240229",
          options: [
            temperature: 0.7,
            max_tokens: 2048
          ]
        ]

  ## Environment Variables

  Requires `ANTHROPIC_API_KEY` to be set.

  ## Supported Models

  - `claude-3-opus-20240229` - Most capable, best for complex tasks
  - `claude-3-sonnet-20240229` - Balanced performance and speed
  - `claude-3-haiku-20240307` - Fastest, most cost-effective

  ## API Documentation

  https://docs.anthropic.com/claude/reference/
  """

  @behaviour Ragex.AI.Behaviour

  require Logger

  @default_endpoint "https://api.anthropic.com/v1"
  @default_model "claude-3-sonnet-20240229"
  @default_temperature 0.7
  @default_max_tokens 2048
  @api_version "2023-06-01"

  @impl true
  def generate(prompt, context \\ nil, opts \\ []) do
    with {:ok, config} <- get_config(opts),
         {:ok, api_key} <- get_api_key(),
         {:ok, messages} <- build_messages(prompt, context, opts),
         {:ok, response} <- call_api(messages, config, api_key, opts) do
      parse_response(response)
    else
      {:error, reason} = error ->
        Logger.error("Anthropic generation failed: #{inspect(reason)}")
        error
    end
  end

  @impl true
  def stream_generate(prompt, context \\ nil, opts \\ []) do
    with {:ok, config} <- get_config(opts),
         {:ok, api_key} <- get_api_key(),
         {:ok, messages} <- build_messages(prompt, context, opts) do
      stream_api(messages, config, api_key, opts)
    else
      {:error, reason} = error ->
        Logger.error("Anthropic streaming failed: #{inspect(reason)}")
        error
    end
  end

  @impl true
  def validate_config do
    case get_api_key() do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        :ok

      {:ok, _} ->
        {:error, "Anthropic API key is empty"}

      {:error, reason} ->
        {:error, "Anthropic API key not configured: #{reason}"}
    end
  end

  @impl true
  def info do
    %{
      name: "Anthropic",
      provider: :anthropic,
      models: [
        "claude-3-opus-20240229",
        "claude-3-sonnet-20240229",
        "claude-3-haiku-20240307"
      ],
      capabilities: [:chat, :streaming, :vision, :tool_use],
      endpoint: get_endpoint(),
      configured: validate_config() == :ok
    }
  end

  # Private functions

  defp get_config(opts) do
    provider_config = Application.get_env(:ragex, :ai_providers, [])[:anthropic] || []

    config = %{
      endpoint:
        Keyword.get(opts, :endpoint) ||
          Keyword.get(provider_config, :endpoint) ||
          @default_endpoint,
      model:
        Keyword.get(opts, :model) ||
          Keyword.get(provider_config, :model) ||
          @default_model,
      temperature:
        Keyword.get(opts, :temperature) ||
          Keyword.get(provider_config, :temperature) ||
          @default_temperature,
      max_tokens:
        Keyword.get(opts, :max_tokens) ||
          Keyword.get(provider_config, :max_tokens) ||
          @default_max_tokens,
      stream: Keyword.get(opts, :stream, false)
    }

    {:ok, config}
  end

  defp get_api_key do
    # Try runtime config first
    case Application.get_env(:ragex, :ai_keys, [])[:anthropic] do
      key when is_binary(key) and byte_size(key) > 0 ->
        {:ok, key}

      _ ->
        # Fallback to environment variable
        case System.get_env("ANTHROPIC_API_KEY") do
          key when is_binary(key) and byte_size(key) > 0 ->
            {:ok, key}

          _ ->
            {:error, :no_api_key}
        end
    end
  end

  defp get_endpoint do
    provider_config = Application.get_env(:ragex, :ai_providers, [])[:anthropic] || []
    Keyword.get(provider_config, :endpoint, @default_endpoint)
  end

  defp build_messages(prompt, nil, opts) do
    system_prompt =
      Keyword.get(opts, :system_prompt, "You are a helpful AI assistant for code analysis.")

    # Anthropic uses system parameter separately from messages
    {:ok, {system_prompt, [%{role: "user", content: prompt}]}}
  end

  defp build_messages(prompt, context, opts) when is_map(context) do
    system_prompt =
      Keyword.get(opts, :system_prompt, "You are a helpful AI assistant for code analysis.")

    context_text = context[:context] || inspect(context)

    user_message = "Context:\n#{context_text}\n\nQuery: #{prompt}"

    {:ok, {system_prompt, [%{role: "user", content: user_message}]}}
  end

  defp call_api({system, messages}, config, api_key, opts) do
    url = "#{config.endpoint}/messages"

    body =
      %{
        model: config.model,
        messages: messages,
        system: system,
        temperature: config.temperature,
        max_tokens: config.max_tokens
      }
      |> maybe_add_tools(opts)
      |> maybe_add_tool_choice(opts)

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]

    case Req.post(url, json: body, headers: headers) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic API error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Anthropic HTTP request failed: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools when is_list(tools) -> Map.put(body, :tools, tools)
    end
  end

  defp maybe_add_tool_choice(body, opts) do
    case Keyword.get(opts, :tool_choice) do
      nil -> body
      # Anthropic uses different format for tool_choice
      "auto" -> Map.put(body, :tool_choice, %{type: "auto"})
      "any" -> Map.put(body, :tool_choice, %{type: "any"})
      %{} = choice -> Map.put(body, :tool_choice, choice)
      _ -> body
    end
  end

  defp parse_response(%{"content" => content_blocks} = body) when is_list(content_blocks) do
    # Extract text content
    content =
      content_blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("", & &1["text"])

    # Extract tool use blocks
    tool_calls = parse_tool_use_blocks(content_blocks)

    usage = body["usage"] || %{}

    response = %{
      content: if(content == "", do: nil, else: content),
      tool_calls: tool_calls,
      model: body["model"],
      usage: %{
        prompt_tokens: usage["input_tokens"] || 0,
        completion_tokens: usage["output_tokens"] || 0,
        total_tokens: (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0)
      },
      metadata: %{
        stop_reason: body["stop_reason"],
        provider: :anthropic
      }
    }

    {:ok, response}
  end

  defp parse_response(body) do
    Logger.error("Unexpected Anthropic response format: #{inspect(body)}")
    {:error, {:invalid_response, body}}
  end

  defp parse_tool_use_blocks(content_blocks) do
    tool_uses =
      content_blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn block ->
        %{
          id: block["id"],
          name: block["name"],
          arguments: block["input"] || %{}
        }
      end)

    case tool_uses do
      [] -> nil
      uses -> uses
    end
  end

  defp stream_api({system, messages}, config, api_key, _opts) do
    url = "#{config.endpoint}/messages"

    body = %{
      model: config.model,
      messages: messages,
      system: system,
      temperature: config.temperature,
      max_tokens: config.max_tokens,
      stream: true
    }

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @api_version},
      {"content-type", "application/json"}
    ]

    # Use Task to handle streaming in separate process
    parent = self()

    task =
      Task.async(fn ->
        case Req.post(url,
               json: body,
               headers: headers,
               into: fn {:data, data}, {req, resp} ->
                 send(parent, {:stream_chunk, data})
                 {:cont, {req, resp}}
               end
             ) do
          {:ok, %{status: 200}} ->
            send(parent, :stream_done)
            :ok

          {:ok, response} ->
            send(parent, {:stream_error, {:api_error, response.status, response.body}})
            {:error, {:api_error, response.status}}

          {:error, reason} ->
            send(parent, {:stream_error, {:http_error, reason}})
            {:error, {:http_error, reason}}
        end
      end)

    # Return a stream that receives messages from the task
    stream =
      Stream.resource(
        fn ->
          # Initial state with usage tracking
          %{
            task: task,
            buffer: "",
            usage: %{input_tokens: 0, output_tokens: 0},
            model: config.model,
            stop_reason: nil,
            done: false
          }
        end,
        fn state ->
          if state.done do
            {:halt, state}
          else
            receive_and_parse_events(state)
          end
        end,
        fn state ->
          # Cleanup: ensure task is terminated
          if Process.alive?(state.task.pid) do
            Task.shutdown(state.task, :brutal_kill)
          end

          :ok
        end
      )

    {:ok, stream}
  end

  defp receive_and_parse_events(state) do
    receive do
      {:stream_chunk, data} ->
        # Append to buffer
        new_buffer = state.buffer <> data
        {events, remaining} = extract_anthropic_events(new_buffer)

        # Parse each event
        {chunks, new_state} =
          Enum.flat_map_reduce(events, %{state | buffer: remaining}, fn event, acc ->
            case parse_anthropic_event(event) do
              {:text, text} ->
                chunk = %{
                  content: text,
                  done: false,
                  metadata: %{provider: :anthropic}
                }

                {[chunk], acc}

              {:usage, usage} ->
                # Update usage tracking
                {[], %{acc | usage: usage}}

              {:message_stop, stop_reason} ->
                # Final chunk with usage stats
                final_chunk = %{
                  content: "",
                  done: true,
                  metadata: %{
                    stop_reason: stop_reason || acc.stop_reason || "end_turn",
                    provider: :anthropic,
                    model: acc.model,
                    usage: %{
                      prompt_tokens: acc.usage.input_tokens,
                      completion_tokens: acc.usage.output_tokens,
                      total_tokens: acc.usage.input_tokens + acc.usage.output_tokens
                    }
                  }
                }

                {[final_chunk], %{acc | done: true, stop_reason: stop_reason}}

              :skip ->
                {[], acc}
            end
          end)

        {chunks, new_state}

      :stream_done ->
        # Stream completed without explicit stop
        if state.done do
          {:halt, state}
        else
          # Send final done chunk
          final_chunk = %{
            content: "",
            done: true,
            metadata: %{
              stop_reason: state.stop_reason || "end_turn",
              provider: :anthropic,
              model: state.model,
              usage: %{
                prompt_tokens: state.usage.input_tokens,
                completion_tokens: state.usage.output_tokens,
                total_tokens: state.usage.input_tokens + state.usage.output_tokens
              }
            }
          }

          {[final_chunk], %{state | done: true}}
        end

      {:stream_error, error} ->
        {[{:error, error}], %{state | done: true}}
    after
      30_000 ->
        # Timeout after 30 seconds
        {[{:error, :timeout}], %{state | done: true}}
    end
  end

  defp extract_anthropic_events(buffer) do
    # Anthropic SSE format: "event: <type>\ndata: <json>\n\n"
    case String.split(buffer, "\n\n") do
      [] ->
        {[], ""}

      [incomplete] ->
        {[], incomplete}

      parts ->
        [incomplete | complete_reversed] = Enum.reverse(parts)
        {Enum.reverse(complete_reversed), incomplete}
    end
  end

  defp parse_anthropic_event(event) do
    lines = String.split(event, "\n", parts: 2)

    case lines do
      ["event: message_start", "data: " <> json] ->
        # Extract usage from message_start
        with {:ok, data} <- Jason.decode(json),
             %{"message" => %{"usage" => usage}} <- data do
          parse_usage_data(usage)
        else
          _ -> :skip
        end

      ["event: content_block_delta", "data: " <> json] ->
        # Extract text delta
        with {:ok, data} <- Jason.decode(json),
             %{"delta" => %{"text" => text}} <- data do
          {:text, text}
        else
          _ -> :skip
        end

      ["event: message_delta", "data: " <> json] ->
        # Extract final usage
        with {:ok, data} <- Jason.decode(json),
             usage when not is_nil(usage) <- get_in(data, ["usage"]) do
          parse_usage_data(usage)
        else
          _ -> :skip
        end

      ["event: message_stop" | _] ->
        {:message_stop, nil}

      _ ->
        :skip
    end
  end

  defp parse_usage_data(usage) when is_map(usage) do
    {:usage,
     %{
       input_tokens: usage["input_tokens"] || 0,
       output_tokens: usage["output_tokens"] || 0
     }}
  end

  defp parse_usage_data(_), do: :skip
end
