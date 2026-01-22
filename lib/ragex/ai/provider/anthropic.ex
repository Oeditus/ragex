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
      capabilities: [:chat, :streaming, :vision],
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

  defp call_api({system, messages}, config, api_key, _opts) do
    url = "#{config.endpoint}/messages"

    body = %{
      model: config.model,
      messages: messages,
      system: system,
      temperature: config.temperature,
      max_tokens: config.max_tokens
    }

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

  defp parse_response(%{"content" => [%{"text" => content} | _]} = body) do
    usage = body["usage"] || %{}

    response = %{
      content: content,
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
    # Anthropic sends SSE format with event types
    case String.split(chunk, "\n", parts: 3) do
      ["event: content_block_delta", "data: " <> json, _rest] ->
        case Jason.decode(json) do
          {:ok, %{"delta" => %{"text" => text}}} ->
            {:ok, %{content: text, done: false, metadata: %{provider: :anthropic}}, false}

          _ ->
            {:ok, %{content: "", done: false, metadata: %{provider: :anthropic}}, false}
        end

      ["event: message_stop", _data, _rest] ->
        {:ok, %{content: "", done: true, metadata: %{provider: :anthropic}}, true}

      _ ->
        {:ok, %{content: "", done: false, metadata: %{provider: :anthropic}}, false}
    end
  end

  defp parse_stream_chunk(_), do: {:error, :invalid_chunk}
end
