defmodule Ragex.AI.Provider.OpenAI do
  @moduledoc """
  OpenAI API provider implementation.

  Supports GPT-4, GPT-4-turbo, and GPT-3.5-turbo models via the OpenAI API.

  ## Configuration

      config :ragex, :ai_providers,
        openai: [
          endpoint: "https://api.openai.com/v1",
          model: "gpt-4-turbo",
          options: [
            temperature: 0.7,
            max_tokens: 2048
          ]
        ]

  ## Environment Variables

  Requires `OPENAI_API_KEY` to be set.

  ## Supported Models

  - `gpt-4` - Most capable model, best for complex tasks
  - `gpt-4-turbo` - Faster and cheaper than GPT-4, optimized for chat
  - `gpt-4-turbo-preview` - Latest preview features
  - `gpt-3.5-turbo` - Fast and cost-effective for simpler tasks
  - `gpt-3.5-turbo-16k` - Extended context window

  ## API Documentation

  https://platform.openai.com/docs/api-reference/chat
  """

  @behaviour Ragex.AI.Behaviour

  require Logger

  @default_endpoint "https://api.openai.com/v1"
  @default_model "gpt-4-turbo"
  @default_temperature 0.7
  @default_max_tokens 2048

  @impl true
  def generate(prompt, context \\ nil, opts \\ []) do
    with {:ok, config} <- get_config(opts),
         {:ok, api_key} <- get_api_key(),
         {:ok, messages} <- build_messages(prompt, context, opts),
         {:ok, response} <- call_api(messages, config, api_key) do
      parse_response(response)
    else
      {:error, reason} = error ->
        Logger.error("OpenAI generation failed: #{inspect(reason)}")
        error
    end
  end

  @impl true
  def stream_generate(prompt, context \\ nil, opts \\ []) do
    with {:ok, config} <- get_config(opts),
         {:ok, api_key} <- get_api_key(),
         {:ok, messages} <- build_messages(prompt, context, opts) do
      stream_api(messages, config, api_key)
    else
      {:error, reason} = error ->
        Logger.error("OpenAI streaming failed: #{inspect(reason)}")
        error
    end
  end

  @impl true
  def validate_config do
    case get_api_key() do
      {:ok, key} when is_binary(key) and byte_size(key) > 0 ->
        :ok

      {:ok, _} ->
        {:error, "OpenAI API key is empty"}

      {:error, reason} ->
        {:error, "OpenAI API key not configured: #{reason}"}
    end
  end

  @impl true
  def info do
    %{
      name: "OpenAI",
      provider: :openai,
      models: [
        "gpt-4",
        "gpt-4-turbo",
        "gpt-4-turbo-preview",
        "gpt-3.5-turbo",
        "gpt-3.5-turbo-16k"
      ],
      capabilities: [:chat, :streaming, :function_calling],
      endpoint: get_endpoint(),
      configured: validate_config() == :ok
    }
  end

  # Private functions

  defp get_config(opts) do
    provider_config = Application.get_env(:ragex, :ai_providers, [])[:openai] || []

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
    case Application.get_env(:ragex, :ai_keys, [])[:openai] do
      key when is_binary(key) and byte_size(key) > 0 ->
        {:ok, key}

      _ ->
        # Fallback to environment variable
        case System.get_env("OPENAI_API_KEY") do
          key when is_binary(key) and byte_size(key) > 0 ->
            {:ok, key}

          _ ->
            {:error, :no_api_key}
        end
    end
  end

  defp get_endpoint do
    provider_config = Application.get_env(:ragex, :ai_providers, [])[:openai] || []
    Keyword.get(provider_config, :endpoint, @default_endpoint)
  end

  defp build_messages(prompt, nil, opts) do
    system_prompt =
      Keyword.get(opts, :system_prompt, "You are a helpful AI assistant for code analysis.")

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: prompt}
    ]

    {:ok, messages}
  end

  defp build_messages(prompt, context, opts) when is_map(context) do
    system_prompt =
      Keyword.get(opts, :system_prompt, "You are a helpful AI assistant for code analysis.")

    context_text = context[:context] || inspect(context)

    messages = [
      %{role: "system", content: system_prompt},
      %{role: "user", content: "Context:\n#{context_text}\n\nQuery: #{prompt}"}
    ]

    {:ok, messages}
  end

  defp call_api(messages, config, api_key) do
    url = "#{config.endpoint}/chat/completions"

    body = %{
      model: config.model,
      messages: messages,
      temperature: config.temperature,
      max_tokens: config.max_tokens
    }

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    case Req.post(url, json: body, headers: headers) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenAI API error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("OpenAI HTTP request failed: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  defp parse_response(%{"choices" => [%{"message" => %{"content" => content}} | _]} = body) do
    usage = body["usage"] || %{}

    response = %{
      content: content,
      model: body["model"],
      usage: %{
        prompt_tokens: usage["prompt_tokens"] || 0,
        completion_tokens: usage["completion_tokens"] || 0,
        total_tokens: usage["total_tokens"] || 0
      },
      metadata: %{
        finish_reason: get_in(body, ["choices", Access.at(0), "finish_reason"]),
        provider: :openai
      }
    }

    {:ok, response}
  end

  defp parse_response(body) do
    Logger.error("Unexpected OpenAI response format: #{inspect(body)}")
    {:error, {:invalid_response, body}}
  end

  defp stream_api(messages, config, api_key) do
    url = "#{config.endpoint}/chat/completions"

    body = %{
      model: config.model,
      messages: messages,
      temperature: config.temperature,
      max_tokens: config.max_tokens,
      stream: true,
      stream_options: %{include_usage: true}
    }

    headers = [
      {"authorization", "Bearer #{api_key}"},
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
                 # Send chunks to parent
                 send(parent, {:stream_chunk, data})
                 {:cont, {req, resp}}
               end
             ) do
          {:ok, %{status: 200}} ->
            # Signal completion
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
            usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0},
            model: config.model,
            done: false
          }
        end,
        fn state ->
          if state.done do
            {:halt, state}
          else
            receive_and_parse_chunks(state)
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

  defp receive_and_parse_chunks(state) do
    receive do
      {:stream_chunk, data} ->
        # Append to buffer
        new_buffer = state.buffer <> data
        {events, remaining} = extract_sse_events(new_buffer)

        # Parse each event
        {chunks, new_usage} =
          Enum.flat_map_reduce(events, state.usage, fn event, usage_acc ->
            case parse_sse_event(event, state.model) do
              {:chunk, chunk, usage_update} ->
                updated_usage = merge_usage(usage_acc, usage_update)
                {[chunk], updated_usage}

              {:done, finish_reason, usage_update} ->
                final_usage = merge_usage(usage_acc, usage_update)

                final_chunk = %{
                  content: "",
                  done: true,
                  metadata: %{
                    finish_reason: finish_reason,
                    provider: :openai,
                    model: state.model,
                    usage: final_usage
                  }
                }

                {[final_chunk], final_usage}

              :skip ->
                {[], usage_acc}
            end
          end)

        # Check if we got a done chunk
        done? = Enum.any?(chunks, & &1.done)
        new_state = %{state | buffer: remaining, usage: new_usage, done: done?}
        {chunks, new_state}

      :stream_done ->
        # Stream completed without explicit done chunk
        if state.done do
          {:halt, state}
        else
          # Send final done chunk
          final_chunk = %{
            content: "",
            done: true,
            metadata: %{
              finish_reason: "stop",
              provider: :openai,
              model: state.model,
              usage: state.usage
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

  defp extract_sse_events(buffer) do
    # SSE events are separated by double newlines
    case String.split(buffer, "\n\n") do
      [] ->
        {[], ""}

      [incomplete] ->
        # Only one part, might be incomplete
        {[], incomplete}

      parts ->
        # Last part might be incomplete
        [incomplete | complete_reversed] = Enum.reverse(parts)
        {Enum.reverse(complete_reversed), incomplete}
    end
  end

  defp parse_sse_event("data: [DONE]" <> _, _model) do
    {:done, "stop", nil}
  end

  defp parse_sse_event("data: " <> json_str, _model) do
    with {:ok, data} <- Jason.decode(String.trim(json_str)),
         %{"choices" => [choice | _]} <- data do
      delta = choice["delta"] || %{}
      content = delta["content"] || ""
      finish_reason = choice["finish_reason"]
      usage = extract_usage(data)

      cond do
        finish_reason != nil ->
          {:done, finish_reason, usage}

        content != "" ->
          chunk = %{
            content: content,
            done: false,
            metadata: %{provider: :openai}
          }

          {:chunk, chunk, usage}

        true ->
          :skip
      end
    else
      _ -> :skip
    end
  end

  defp parse_sse_event(_, _model), do: :skip

  defp extract_usage(%{"usage" => usage}) when is_map(usage) do
    %{
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0
    }
  end

  defp extract_usage(_), do: nil

  defp merge_usage(current, nil), do: current

  defp merge_usage(_current, new) when is_map(new), do: new
end
