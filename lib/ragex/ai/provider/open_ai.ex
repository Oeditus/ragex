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
      stream: true
    }

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

    # Return a stream that will be consumed by the caller
    stream =
      Stream.resource(
        fn ->
          case Req.post(url, json: body, headers: headers, into: :self) do
            {:ok, %{status: 200}} = result ->
              result

            {:ok, %{status: status, body: error_body}} ->
              {:error, {:api_error, status, error_body}}

            {:error, reason} ->
              {:error, {:http_error, reason}}
          end
        end,
        fn
          {:error, reason} ->
            {[{:error, reason}], :halt}

          {:ok, response} ->
            # Parse SSE stream chunks
            case parse_stream_chunk(response.body) do
              {:ok, chunk, done?} ->
                if done? do
                  {[chunk], :halt}
                else
                  {[chunk], {:ok, response}}
                end

              {:error, reason} ->
                {[{:error, reason}], :halt}
            end

          :halt ->
            {:halt, :halt}
        end,
        fn _ -> :ok end
      )

    {:ok, stream}
  end

  defp parse_stream_chunk(chunk) when is_binary(chunk) do
    # OpenAI sends SSE format: "data: {...}\n\n"
    case String.split(chunk, "\n", parts: 2) do
      ["data: " <> json, _rest] ->
        case Jason.decode(json) do
          {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}} ->
            {:ok, %{content: content, done: false, metadata: %{provider: :openai}}, false}

          {:ok, %{"choices" => [%{"finish_reason" => reason} | _]}} when reason != nil ->
            {:ok,
             %{content: "", done: true, metadata: %{finish_reason: reason, provider: :openai}},
             true}

          _ ->
            {:ok, %{content: "", done: false, metadata: %{provider: :openai}}, false}
        end

      _ ->
        {:ok, %{content: "", done: false, metadata: %{provider: :openai}}, false}
    end
  end

  defp parse_stream_chunk(_), do: {:error, :invalid_chunk}
end
