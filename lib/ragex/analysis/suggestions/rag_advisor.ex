defmodule Ragex.Analysis.Suggestions.RAGAdvisor do
  @moduledoc """
  RAG-powered advice generation for refactoring suggestions.

  Uses the RAG pipeline to generate context-aware, AI-powered advice for
  each refactoring suggestion, including:
  - Detailed explanations of why the refactoring is beneficial
  - Concrete implementation steps specific to the codebase
  - Code examples from similar patterns in the codebase
  - Potential pitfalls and risks to watch for

  ## Usage

      alias Ragex.Analysis.Suggestions.RAGAdvisor

      {:ok, advice} = RAGAdvisor.generate_advice(suggestion)
      IO.puts(advice)
  """

  alias Ragex.{AI.Config, AI.Registry, RAG.Pipeline}
  require Logger

  @doc """
  Generates AI-powered advice for a suggestion.

  ## Parameters
  - `suggestion` - Scored suggestion with pattern, target, and metrics
  - `opts` - Options:
    - `:provider` - AI provider to use (default: from config)
    - `:temperature` - AI temperature (default: 0.7)
    - `:max_tokens` - Max response tokens (default: 500)

  ## Returns
  - `{:ok, advice_text}` - Generated advice string
  - `{:error, reason}` - Error if generation fails
  """
  def generate_advice(suggestion, opts \\ []) do
    pattern = suggestion[:pattern]

    Logger.debug("Generating RAG advice for #{pattern} suggestion")

    with {:ok, prompt} <- build_prompt(suggestion),
         {:ok, response} <- call_rag_pipeline(prompt, opts) do
      {:ok, response}
    else
      {:error, reason} = error ->
        Logger.warning("Failed to generate RAG advice: #{inspect(reason)}")
        error
    end
  rescue
    e ->
      Logger.error("Exception generating RAG advice: #{inspect(e)}")
      {:error, {:advice_generation_failed, Exception.message(e)}}
  end

  # Private functions

  defp build_prompt(suggestion) do
    pattern = suggestion[:pattern]
    target = suggestion[:target]
    metrics = suggestion[:metrics] || %{}
    reason = suggestion[:reason] || "No specific reason provided"

    base_context = """
    A refactoring opportunity has been detected in the codebase.

    Pattern: #{pattern}
    Target: #{format_target(target)}
    Reason: #{reason}
    Metrics: #{format_metrics(metrics)}
    Priority: #{suggestion[:priority]} (score: #{suggestion[:priority_score]})
    Confidence: #{Float.round(suggestion[:confidence] || 0.5, 2)}
    """

    pattern_specific = build_pattern_specific_prompt(pattern, suggestion)

    prompt = """
    #{base_context}

    #{pattern_specific}

    Based on this codebase context, provide:
    1. A brief explanation of why this refactoring would be beneficial
    2. Specific implementation steps for this codebase (2-3 concrete steps)
    3. Any potential risks or pitfalls to watch for
    4. Estimated complexity (simple/moderate/complex)

    Keep response concise (under 200 words).
    """

    {:ok, prompt}
  end

  defp build_pattern_specific_prompt(:extract_function, suggestion) do
    metrics = suggestion[:metrics] || %{}
    complexity = metrics[:complexity] || 0
    loc = metrics[:loc] || 0

    """
    This function has complexity #{complexity} and #{loc} lines of code.
    Suggest which specific parts should be extracted into separate functions.
    Provide concrete function names and their responsibilities.
    """
  end

  defp build_pattern_specific_prompt(:inline_function, _suggestion) do
    """
    This is a trivial function that could be inlined at call sites.
    Explain when inlining is appropriate and when it might hurt readability.
    """
  end

  defp build_pattern_specific_prompt(:split_module, suggestion) do
    metrics = suggestion[:metrics] || %{}
    function_count = metrics[:function_count] || 0

    """
    This module has #{function_count} functions.
    Suggest how to identify logical groupings and split the module.
    Recommend naming conventions for the new modules.
    """
  end

  defp build_pattern_specific_prompt(:remove_dead_code, suggestion) do
    metrics = suggestion[:metrics] || %{}
    confidence = metrics[:confidence] || 0.5

    """
    This function appears unused (confidence: #{Float.round(confidence, 2)}).
    Explain how to verify it's truly dead code and safe to remove.
    Mention any cases where unused code might still be needed.
    """
  end

  defp build_pattern_specific_prompt(:reduce_coupling, suggestion) do
    metrics = suggestion[:metrics] || %{}
    efferent = metrics[:efferent] || 0

    """
    This module has high coupling (efferent coupling: #{efferent}).
    Suggest specific strategies to reduce dependencies.
    Consider dependency injection, interfaces, or restructuring.
    """
  end

  defp build_pattern_specific_prompt(:simplify_complexity, suggestion) do
    metrics = suggestion[:metrics] || %{}
    complexity = metrics[:cyclomatic_complexity] || 0
    nesting = metrics[:nesting_depth] || 0

    """
    This function has cyclomatic complexity #{complexity} and nesting depth #{nesting}.
    Suggest specific refactoring techniques (guard clauses, early returns, extract methods).
    Prioritize which complexity issues to address first.
    """
  end

  defp build_pattern_specific_prompt(:merge_modules, _suggestion) do
    """
    Suggest when merging modules makes sense and how to do it safely.
    """
  end

  defp build_pattern_specific_prompt(:extract_module, _suggestion) do
    """
    Suggest how to identify related functions that belong together.
    """
  end

  defp build_pattern_specific_prompt(_pattern, _suggestion) do
    "Provide general refactoring advice for this situation."
  end

  defp call_rag_pipeline(prompt, opts) do
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 500)
    provider = Keyword.get(opts, :provider)

    rag_opts = [
      temperature: temperature,
      max_tokens: max_tokens,
      limit: 3,
      threshold: 0.6
    ]

    rag_opts = if provider, do: Keyword.put(rag_opts, :provider, provider), else: rag_opts

    case Pipeline.query(prompt, rag_opts) do
      {:ok, response} ->
        # Extract just the text content
        advice = extract_advice_text(response)
        {:ok, advice}

      {:error, :no_results_found} ->
        # Fallback to non-RAG generation if no relevant code found
        Logger.debug("No RAG results found, using direct AI generation")
        call_direct_ai(prompt, opts)

      {:error, reason} = error ->
        Logger.warning("RAG pipeline failed: #{inspect(reason)}")
        error
    end
  end

  defp call_direct_ai(prompt, opts) do
    # Fallback to direct AI generation without retrieval
    # This uses the AI provider directly
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 500)

    case Config.get_default_provider() do
      {:ok, provider_name} ->
        provider = Registry.get_provider(provider_name)

        case provider.generate(prompt,
               temperature: temperature,
               max_tokens: max_tokens
             ) do
          {:ok, response} -> {:ok, response.content}
          error -> error
        end

      {:error, _reason} ->
        {:error, :no_provider_configured}
    end
  end

  defp extract_advice_text(response) when is_map(response) do
    # Response structure from RAG pipeline
    response[:answer] || response[:content] || "No advice generated"
  end

  defp extract_advice_text(response) when is_binary(response) do
    response
  end

  defp extract_advice_text(_), do: "No advice generated"

  defp format_target(target) when is_map(target) do
    case target[:type] do
      :function ->
        "#{target[:module]}.#{target[:function]}/#{target[:arity]}"

      :module ->
        "#{target[:module]}"

      :files ->
        "#{target[:file1]} and #{target[:file2]}"

      _ ->
        inspect(target)
    end
  end

  defp format_target(target), do: inspect(target)

  defp format_metrics(metrics) when is_map(metrics) do
    Enum.map_join(metrics, ", ", fn {k, v} -> "#{k}: #{format_metric_value(v)}" end)
  end

  defp format_metrics(_), do: "No metrics available"

  defp format_metric_value(v) when is_float(v), do: Float.round(v, 2)
  defp format_metric_value(v), do: inspect(v)

  @doc """
  Generates advice for multiple suggestions in batch.

  More efficient than calling generate_advice/2 multiple times.

  ## Parameters
  - `suggestions` - List of suggestions
  - `opts` - Options (same as generate_advice/2)

  ## Returns
  - `{:ok, suggestions_with_advice}` - Suggestions with added `:rag_advice` field
  - `{:error, reason}` - Error if batch generation fails
  """
  def generate_batch_advice(suggestions, opts \\ []) do
    Logger.info("Generating RAG advice for #{length(suggestions)} suggestions")

    results =
      suggestions
      |> Task.async_stream(
        fn suggestion ->
          case generate_advice(suggestion, opts) do
            {:ok, advice} -> Map.put(suggestion, :rag_advice, advice)
            {:error, _} -> Map.put(suggestion, :rag_advice, nil)
          end
        end,
        timeout: 30_000,
        max_concurrency: 3
      )
      |> Enum.map(fn {:ok, result} -> result end)

    {:ok, results}
  rescue
    e ->
      Logger.error("Failed to generate batch advice: #{inspect(e)}")
      {:error, {:batch_generation_failed, Exception.message(e)}}
  end

  @doc """
  Checks if RAG advice generation is available.

  Returns true if an AI provider is configured, false otherwise.
  """
  def available? do
    case Config.get_default_provider() do
      {:ok, _} -> true
      _ -> false
    end
  end
end
