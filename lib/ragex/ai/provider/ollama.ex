defmodule Ragex.AI.Provider.Ollama do
  @moduledoc """
  Ollama provider for running local LLMs.

  Supports local Ollama server for models like llama2, mistral, codellama, etc.

  ## Configuration

      config :ragex, :ai_providers,
        ollama: [
          endpoint: "http://localhost:11434",
          model: "codellama",
          options: [
            temperature: 0.7
          ]
        ]

  ## No API Key Required

  Ollama runs locally, so no API key is needed.

  ## Supported Models

  Any model installed in your local Ollama instance:
  - `llama2` - Meta's Llama 2
  - `mistral` - Mistral AI's model
  - `codellama` - Code-specialized Llama
  - `phi` - Microsoft's small language model
  - And many more from https://ollama.ai/library

  ## Installation

  Install Ollama from https://ollama.ai and pull a model:

      ollama pull codellama

  ## API Documentation

  https://github.com/ollama/ollama/blob/main/docs/api.md
  """

  @behaviour Ragex.AI.Behaviour

  require Logger

  @default_endpoint "http://localhost:11434"
  @default_model "codellama"
  @default_temperature 0.7

  @impl true
  def generate(prompt, context \\ nil, opts \\ []) do
    with {:ok, config} <- get_config(opts),
         {:ok, full_prompt} <- build_prompt(prompt, context, opts),
         {:ok, response} <- call_api(full_prompt, config) do
      parse_response(response)
    else
      {:error, reason} = error ->
        Logger.error("Ollama generation failed: #{inspect(reason)}")
        error
    end
  end

  @impl true
  def stream_generate(prompt, context \\ nil, opts \\ []) do
    with {:ok, config} <- get_config(opts),
         {:ok, full_prompt} <- build_prompt(prompt, context, opts) do
      stream_api(full_prompt, config)
    else
      {:error, reason} = error ->
        Logger.error("Ollama streaming failed: #{inspect(reason)}")
        error
    end
  end

  @impl true
  def validate_config do
    # Check if Ollama server is accessible
    {:ok, config} = get_config([])
    check_server(config.endpoint)
  end

  @impl true
  def info do
    config = get_config([])

    endpoint =
      case config do
        {:ok, %{endpoint: ep}} -> ep
        _ -> @default_endpoint
      end

    %{
      name: "Ollama",
      provider: :ollama,
      models: list_available_models(endpoint),
      capabilities: [:chat, :streaming, :local],
      endpoint: endpoint,
      configured: validate_config() == :ok
    }
  end

  # Private functions

  defp get_config(opts) do
    provider_config = Application.get_env(:ragex, :ai_providers, [])[:ollama] || []

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
      stream: Keyword.get(opts, :stream, false)
    }

    {:ok, config}
  end

  defp check_server(endpoint) do
    # Try to ping Ollama server
    case Req.get("#{endpoint}/api/tags") do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} ->
        {:error, "Ollama server returned status #{status}"}

      {:error, reason} ->
        {:error, "Cannot connect to Ollama server: #{inspect(reason)}"}
    end
  end

  defp list_available_models(endpoint) do
    case Req.get("#{endpoint}/api/tags") do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        Enum.map(models, fn %{"name" => name} -> name end)

      _ ->
        # Return common models if server is not accessible
        ["llama2", "mistral", "codellama", "phi"]
    end
  end

  defp build_prompt(prompt, nil, opts) do
    system_prompt =
      Keyword.get(opts, :system_prompt, "You are a helpful AI assistant for code analysis.")

    full_prompt = "#{system_prompt}\n\nUser: #{prompt}\nAssistant:"
    {:ok, full_prompt}
  end

  defp build_prompt(prompt, context, opts) when is_map(context) do
    system_prompt =
      Keyword.get(opts, :system_prompt, "You are a helpful AI assistant for code analysis.")

    context_text = context[:context] || inspect(context)

    full_prompt = """
    #{system_prompt}

    Context:
    #{context_text}

    User: #{prompt}
    Assistant:
    """

    {:ok, full_prompt}
  end

  defp call_api(prompt, config) do
    url = "#{config.endpoint}/api/generate"

    body = %{
      model: config.model,
      prompt: prompt,
      temperature: config.temperature,
      stream: false
    }

    case Req.post(url, json: body) do
      {:ok, %{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Ollama API error: #{status} - #{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Ollama HTTP request failed: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  defp parse_response(%{"response" => content, "model" => model} = body) do
    # Ollama doesn't provide token counts in non-streaming mode by default
    # Estimate tokens (very rough: 1 token ≈ 4 characters)
    estimated_tokens = div(String.length(content), 4)

    response = %{
      content: content,
      model: model,
      usage: %{
        # Not provided by Ollama
        prompt_tokens: 0,
        completion_tokens: estimated_tokens,
        total_tokens: estimated_tokens
      },
      metadata: %{
        done: body["done"],
        provider: :ollama,
        local: true
      }
    }

    {:ok, response}
  end

  defp parse_response(body) do
    Logger.error("Unexpected Ollama response format: #{inspect(body)}")
    {:error, {:invalid_response, body}}
  end

  defp stream_api(prompt, config) do
    url = "#{config.endpoint}/api/generate"

    body = %{
      model: config.model,
      prompt: prompt,
      temperature: config.temperature,
      stream: true
    }

    parent = self()

    task =
      Task.async(fn ->
        case Req.post(url,
               json: body,
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

    stream =
      Stream.resource(
        fn -> %{task: task, buffer: "", model: config.model, done: false, total_content: ""} end,
        fn state ->
          if state.done do
            {:halt, state}
          else
            receive_ollama_chunks(state)
          end
        end,
        fn state ->
          if Process.alive?(state.task.pid), do: Task.shutdown(state.task, :brutal_kill)
          :ok
        end
      )

    {:ok, stream}
  end

  defp receive_ollama_chunks(state) do
    receive do
      {:stream_chunk, data} ->
        # Ollama sends NDJSON (newline-delimited JSON)
        new_buffer = state.buffer <> data
        {lines, remaining} = extract_ndjson_lines(new_buffer)

        {chunks, new_state} =
          Enum.flat_map_reduce(lines, %{state | buffer: remaining}, fn line, acc ->
            case Jason.decode(line) do
              {:ok, %{"response" => content, "done" => false}} ->
                chunk = %{
                  content: content,
                  done: false,
                  metadata: %{provider: :ollama, local: true}
                }

                {[chunk], %{acc | total_content: acc.total_content <> content}}

              {:ok, %{"done" => true} = data} ->
                # Final chunk with token estimation
                est_tokens = div(String.length(acc.total_content), 4)

                final_chunk = %{
                  content: "",
                  done: true,
                  metadata: %{
                    provider: :ollama,
                    local: true,
                    model: data["model"] || acc.model,
                    usage: %{
                      prompt_tokens: 0,
                      completion_tokens: est_tokens,
                      total_tokens: est_tokens
                    }
                  }
                }

                {[final_chunk], %{acc | done: true}}

              {:ok, %{"response" => content}} ->
                chunk = %{
                  content: content,
                  done: false,
                  metadata: %{provider: :ollama, local: true}
                }

                {[chunk], %{acc | total_content: acc.total_content <> content}}

              _ ->
                {[], acc}
            end
          end)

        {chunks, new_state}

      :stream_done ->
        if state.done do
          {:halt, state}
        else
          est_tokens = div(String.length(state.total_content), 4)

          final_chunk = %{
            content: "",
            done: true,
            metadata: %{
              provider: :ollama,
              local: true,
              model: state.model,
              usage: %{
                prompt_tokens: 0,
                completion_tokens: est_tokens,
                total_tokens: est_tokens
              }
            }
          }

          {[final_chunk], %{state | done: true}}
        end

      {:stream_error, error} ->
        {[{:error, error}], %{state | done: true}}
    after
      30_000 -> {[{:error, :timeout}], %{state | done: true}}
    end
  end

  defp extract_ndjson_lines(buffer) do
    case String.split(buffer, "\n") do
      [] ->
        {[], ""}

      [incomplete] ->
        {[], incomplete}

      parts ->
        [incomplete | complete_reversed] = Enum.reverse(parts)
        complete = Enum.reverse(complete_reversed) |> Enum.reject(&(&1 == ""))
        {complete, incomplete}
    end
  end
end
