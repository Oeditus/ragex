defmodule Ragex.RAG.Pipeline do
  @moduledoc """
  Orchestrates the RAG pipeline: Retrieval → Augmentation → Generation.

  ## Pipeline Steps

  1. **Retrieval**: Query knowledge graph and vector store (hybrid search)
  2. **Context Building**: Format retrieved code for AI consumption
  3. **Prompt Engineering**: Apply templates and inject context
  4. **Generation**: Call AI provider with augmented prompt
  5. **Post-processing**: Parse response, add sources, format output
  """

  require Logger

  alias Ragex.AI.{Cache, Config, Usage}
  alias Ragex.RAG.{ContextBuilder, PromptTemplate}
  alias Ragex.Retrieval.Hybrid

  @doc """
  Execute RAG query pipeline.

  ## Options

  - `:limit` - Max retrieval results (default: 10)
  - `:threshold` - Similarity threshold (default: 0.7)
  - `:strategy` - Retrieval strategy: :fusion, :semantic_first, :graph_first
  - `:include_code` - Include full code snippets (default: true)
  - `:provider` - Override AI provider
  - `:system_prompt` - Custom system prompt
  - `:temperature` - AI temperature (default: 0.7)
  """
  def query(user_query, opts \\ []) do
    Logger.info("RAG Pipeline: query='#{user_query}'")

    with {:ok, retrieval_results} <- retrieve(user_query, opts),
         {:ok, context} <- build_context(retrieval_results, opts),
         {:ok, prompt} <- build_prompt(user_query, context, opts),
         {:ok, response} <- generate_with_cache(:query, prompt, context, opts) do
      format_response(response, retrieval_results)
    end
  end

  @doc """
  Explain code using RAG.
  """
  def explain(target, aspect, opts \\ []) do
    query_text = build_explain_query(target, aspect)

    opts =
      opts
      |> Keyword.put(:system_prompt, explain_system_prompt())
      |> Keyword.put(:limit, 5)
      |> Keyword.put(:operation, :explain)

    query(query_text, opts)
  end

  @doc """
  Suggest improvements using RAG.
  """
  def suggest(target, focus, opts \\ []) do
    query_text = build_suggest_query(target, focus)

    opts =
      opts
      |> Keyword.put(:system_prompt, suggest_system_prompt())
      |> Keyword.put(:limit, 3)
      |> Keyword.put(:operation, :suggest)

    query(query_text, opts)
  end

  @doc """
  Execute RAG query pipeline with streaming response.

  Returns `{:ok, stream}` where stream emits chunks as they arrive from the AI provider.
  The final chunk will include usage statistics and sources.

  ## Options

  Same as `query/2` plus:
  - `:stream_metadata` - Include sources in every chunk (default: false)
  """
  def stream_query(user_query, opts \\ []) do
    Logger.info("RAG Pipeline (streaming): query='#{user_query}'")

    with {:ok, retrieval_results} <- retrieve(user_query, opts),
         {:ok, context} <- build_context(retrieval_results, opts),
         {:ok, prompt} <- build_prompt(user_query, context, opts),
         {:ok, stream} <- stream_generate(:query, prompt, context, retrieval_results, opts) do
      {:ok, stream}
    end
  end

  @doc """
  Explain code using RAG with streaming response.
  """
  def stream_explain(target, aspect, opts \\ []) do
    query_text = build_explain_query(target, aspect)

    opts =
      opts
      |> Keyword.put(:system_prompt, explain_system_prompt())
      |> Keyword.put(:limit, 5)
      |> Keyword.put(:operation, :explain)

    stream_query(query_text, opts)
  end

  @doc """
  Suggest improvements using RAG with streaming response.
  """
  def stream_suggest(target, focus, opts \\ []) do
    query_text = build_suggest_query(target, focus)

    opts =
      opts
      |> Keyword.put(:system_prompt, suggest_system_prompt())
      |> Keyword.put(:limit, 3)
      |> Keyword.put(:operation, :suggest)

    stream_query(query_text, opts)
  end

  # Private

  defp retrieve(query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.7)
    strategy = Keyword.get(opts, :strategy, :fusion)

    case Hybrid.search(query, limit: limit, threshold: threshold, strategy: strategy) do
      {:ok, [_ | _] = results} ->
        {:ok, results}

      {:ok, []} ->
        {:error, :no_results_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_context(results, opts) do
    ContextBuilder.build_context(results, opts)
  end

  defp build_prompt(user_query, context, opts) do
    system_prompt = Keyword.get(opts, :system_prompt, default_system_prompt())

    prompt =
      PromptTemplate.render(:query, %{
        system_prompt: system_prompt,
        context: context,
        query: user_query
      })

    {:ok, prompt}
  end

  defp generate_with_cache(operation, prompt, context, opts) do
    provider = get_provider(opts)
    provider_name = get_provider_name(opts)

    # Check rate limiting first
    case Usage.check_rate_limit(provider_name) do
      :ok ->
        # Try cache - pass provider/model in cache_opts
        cache_opts = [
          provider: provider_name,
          model: get_model_name(provider, opts),
          temperature: Keyword.get(opts, :temperature, 0.7),
          max_tokens: Keyword.get(opts, :max_tokens, 2048)
        ]

        case Cache.get(operation, prompt, context, cache_opts) do
          {:ok, cached_response} ->
            Logger.debug("Cache hit for #{operation} operation")
            {:ok, cached_response}

          {:error, :not_found} ->
            Logger.debug("Cache miss for #{operation} operation")
            # Generate and cache
            case generate_with_tracking(provider, provider_name, prompt, context, opts) do
              {:ok, response} = result ->
                Cache.put(operation, prompt, context, response, cache_opts)
                result

              error ->
                error
            end
        end

      {:error, reason} ->
        Logger.warning("Rate limit exceeded: #{reason}")
        {:error, {:rate_limited, reason}}
    end
  end

  defp generate_with_tracking(provider, provider_name, prompt, context, opts) do
    ai_opts = ai_generation_opts(opts)
    model = get_model_name(provider, opts)

    case provider.generate(prompt, %{context: context}, ai_opts) do
      {:ok, response} = result ->
        # Track usage
        prompt_tokens = get_in(response, [:usage, :prompt_tokens]) || 0
        completion_tokens = get_in(response, [:usage, :completion_tokens]) || 0
        Usage.record_request(provider_name, model, prompt_tokens, completion_tokens)

        result

      error ->
        error
    end
  end

  defp stream_generate(_operation, prompt, context, retrieval_results, opts) do
    provider = get_provider(opts)
    provider_name = get_provider_name(opts)

    # Check rate limiting first
    case Usage.check_rate_limit(provider_name) do
      :ok ->
        # Note: Streaming responses are not cached (real-time nature)
        ai_opts = ai_generation_opts(opts)
        model = get_model_name(provider, opts)
        include_metadata = Keyword.get(opts, :stream_metadata, false)
        sources = format_sources(retrieval_results)

        case provider.stream_generate(prompt, %{context: context}, ai_opts) do
          {:ok, base_stream} ->
            # Wrap the provider stream to add usage tracking and sources
            wrapped_stream =
              base_stream
              |> Stream.map(fn chunk ->
                case chunk do
                  %{done: true, metadata: metadata} = final_chunk ->
                    # Track usage on final chunk
                    usage = metadata[:usage] || %{}
                    prompt_tokens = usage[:prompt_tokens] || 0
                    completion_tokens = usage[:completion_tokens] || 0

                    if prompt_tokens > 0 or completion_tokens > 0 do
                      Usage.record_request(provider_name, model, prompt_tokens, completion_tokens)
                    end

                    # Add sources to final chunk
                    updated_metadata =
                      metadata
                      |> Map.put(:sources, sources)
                      |> Map.put(:retrieval_count, length(retrieval_results))
                      |> Map.put(:timestamp, DateTime.utc_now())

                    %{final_chunk | metadata: updated_metadata}

                  %{done: false} = content_chunk ->
                    # Optionally include sources in every chunk
                    if include_metadata do
                      put_in(content_chunk, [:metadata, :sources], sources)
                    else
                      content_chunk
                    end

                  {:error, _reason} = error ->
                    error

                  other ->
                    other
                end
              end)

            {:ok, wrapped_stream}

          {:error, reason} = error ->
            Logger.error("Streaming generation failed: #{inspect(reason)}")
            error
        end

      {:error, reason} ->
        Logger.warning("Rate limit exceeded: #{reason}")
        {:error, {:rate_limited, reason}}
    end
  end

  defp ai_generation_opts(opts) do
    [
      temperature: Keyword.get(opts, :temperature, 0.7),
      max_tokens: Keyword.get(opts, :max_tokens, 2048)
    ]
  end

  defp format_response({:ok, ai_response}, retrieval_results) do
    {:ok,
     %{
       content: ai_response.content,
       sources: format_sources(retrieval_results),
       model: ai_response.model,
       usage: ai_response.usage,
       metadata: %{
         retrieval_count: length(retrieval_results),
         timestamp: DateTime.utc_now()
       }
     }}
  end

  defp format_response({:error, reason}, _results) do
    {:error, reason}
  end

  defp format_sources(results) do
    Enum.map(results, fn result ->
      %{
        file: result[:file],
        node_id: result[:node_id],
        score: Float.round(result[:score] || 0.0, 3),
        line: result[:line]
      }
    end)
  end

  defp get_provider(opts) do
    case Keyword.get(opts, :provider) do
      nil -> Config.provider()
      provider_atom when is_atom(provider_atom) -> provider_module(provider_atom)
    end
  end

  defp get_provider_name(opts) do
    case Keyword.get(opts, :provider) do
      nil -> Config.provider_name()
      provider_atom when is_atom(provider_atom) -> provider_atom
    end
  end

  defp get_model_name(provider, opts) do
    case Keyword.get(opts, :model) do
      nil ->
        # Get default model from provider
        case provider do
          Ragex.AI.Provider.OpenAI -> "gpt-4-turbo"
          Ragex.AI.Provider.Anthropic -> "claude-3-sonnet-20240229"
          Ragex.AI.Provider.Ollama -> "codellama"
          Ragex.AI.Provider.DeepSeekR1 -> "deepseek-chat"
          _ -> "unknown"
        end

      model when is_binary(model) ->
        model
    end
  end

  defp provider_module(:deepseek_r1), do: Ragex.AI.Provider.DeepSeekR1
  defp provider_module(:openai), do: Ragex.AI.Provider.OpenAI
  defp provider_module(:anthropic), do: Ragex.AI.Provider.Anthropic
  defp provider_module(:ollama), do: Ragex.AI.Provider.Ollama
  defp provider_module(_), do: Config.provider()

  defp default_system_prompt do
    """
    You are an expert code assistant with deep knowledge of software engineering.
    You have access to a codebase and can answer questions about its structure,
    functionality, and best practices.

    Your responses should be:
    - Accurate and based on the provided code context
    - Concise but comprehensive
    - Include specific file/function references when relevant
    - Suggest improvements when appropriate
    """
  end

  defp explain_system_prompt do
    """
    You are a code documentation expert. Explain the provided code clearly and thoroughly.
    Focus on: purpose, behavior, dependencies, and potential issues.
    Use simple language suitable for both beginners and experts.
    """
  end

  defp suggest_system_prompt do
    """
    You are a code reviewer focused on suggesting improvements.
    Provide actionable, specific recommendations with examples.
    Consider: performance, readability, maintainability, and testing.
    """
  end

  defp build_explain_query(target, aspect) do
    "Explain the #{aspect} of #{target}"
  end

  defp build_suggest_query(target, focus) do
    "Suggest #{focus} improvements for #{target}"
  end
end
