defmodule Ragex.Analysis.DeadCode.AIRefiner do
  @moduledoc """
  AI-powered refinement of dead code confidence scores.

  Uses semantic analysis to reduce false positives by evaluating whether
  "unused" functions are actually callback functions, hooks, or entry points
  that heuristics might miss.

  ## Features

  - Semantic function name analysis
  - Behavior pattern detection
  - Documentation hint analysis
  - Similar pattern matching from codebase
  - Confidence score adjustment with reasoning

  ## Usage

      alias Ragex.Analysis.DeadCode.AIRefiner

      # Refine a single dead code result
      dead_func = %{
        function: {:function, MyModule, :handle_custom, 2},
        confidence: 0.7,
        reason: "No callers found"
      }

      {:ok, refined} = AIRefiner.refine_confidence(dead_func)
      # => %{
      #   confidence: 0.2,  # Lowered - likely a callback
      #   ai_reasoning: "Function name 'handle_custom' suggests...",
      #   original_confidence: 0.7
      # }

      # Refine multiple results
      {:ok, refined_list} = AIRefiner.refine_batch(dead_functions)

  ## Configuration

      config :ragex, :ai_features,
        dead_code_refinement: true
  """

  alias Ragex.AI.Features.{Cache, Config, Context}
  alias Ragex.AI.Registry
  alias Ragex.RAG.Pipeline

  require Logger

  @type dead_function :: map()
  @type refined_result :: %{
          confidence: float(),
          ai_reasoning: String.t(),
          original_confidence: float(),
          adjustment: float()
        }

  @doc """
  Refine confidence score for a dead code detection result.

  Uses AI to analyze whether the function is truly dead or likely a
  callback/hook/entry point that the heuristic missed.

  ## Parameters
  - `dead_func` - Dead code detection result with function info
  - `opts` - Options:
    - `:ai_refine` - Enable/disable AI (default: from config)
    - `:min_adjustment` - Minimum confidence change to report (default: 0.1)

  ## Returns
  - `{:ok, refined_result}` - Updated confidence with reasoning
  - `{:error, reason}` - Error if refinement fails

  ## Examples

      dead_func = %{
        function: {:function, MyModule, :init, 1},
        confidence: 0.8,
        reason: "No callers found",
        visibility: :public,
        module: MyModule
      }

      {:ok, refined} = AIRefiner.refine_confidence(dead_func)
      # => %{
      #   confidence: 0.1,
      #   ai_reasoning: "init/1 is a standard GenServer callback...",
      #   original_confidence: 0.8,
      #   adjustment: -0.7
      # }
  """
  @spec refine_confidence(dead_function(), keyword()) ::
          {:ok, refined_result()} | {:error, term()}
  def refine_confidence(dead_func, opts \\ []) do
    if Config.enabled?(:dead_code_refinement, opts) do
      do_refine_confidence(dead_func, opts)
    else
      {:error, :ai_refine_disabled}
    end
  end

  @doc """
  Refine confidence scores for multiple dead code results in batch.

  More efficient than calling refine_confidence/2 multiple times.

  ## Parameters
  - `dead_functions` - List of dead code results
  - `opts` - Options (same as refine_confidence/2)

  ## Returns
  - `{:ok, refined_list}` - List of refined results
  """
  @spec refine_batch([dead_function()], keyword()) ::
          {:ok, [refined_result()]} | {:error, term()}
  def refine_batch(dead_functions, opts \\ []) do
    results =
      dead_functions
      |> Task.async_stream(
        fn dead_func ->
          case refine_confidence(dead_func, opts) do
            {:ok, refined} -> Map.merge(dead_func, refined)
            {:error, _} -> dead_func
          end
        end,
        timeout: get_timeout(opts) * length(dead_functions),
        max_concurrency: 3
      )
      |> Enum.map(fn {:ok, result} -> result end)

    {:ok, results}
  end

  @doc """
  Check if AI refinement is currently enabled.
  """
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    Config.enabled?(:dead_code_refinement, opts)
  end

  @doc """
  Clear the refinement cache.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    Cache.clear(:dead_code_refinement)
  end

  # Private functions

  defp do_refine_confidence(dead_func, opts) do
    function_ref = dead_func[:function]

    # Build context for AI
    context = Context.for_dead_code_analysis(function_ref, opts)

    # Try to get refinement from cache or generate
    Cache.fetch(
      :dead_code_refinement,
      function_ref,
      context,
      fn ->
        generate_refinement(dead_func, context, opts)
      end,
      opts
    )
  end

  defp generate_refinement(dead_func, context, opts) do
    # Build prompt for AI
    prompt = build_refinement_prompt(dead_func, context)

    # Get feature config
    feature_config = Config.get_feature_config(:dead_code_refinement)

    # Prepare RAG query options
    rag_opts =
      [
        temperature: feature_config.temperature,
        max_tokens: feature_config.max_tokens,
        limit: 5,
        threshold: 0.5,
        system_prompt: refinement_system_prompt()
      ]
      |> maybe_add_provider(opts)

    # Call RAG pipeline
    case Pipeline.query(prompt, rag_opts) do
      {:ok, response} ->
        parse_refinement_response(response, dead_func)

      {:error, :no_results_found} ->
        # Fallback to direct AI
        Logger.debug("No RAG results for dead code refinement, using direct AI")
        call_direct_ai_for_refinement(prompt, rag_opts, dead_func)

      {:error, reason} = error ->
        Logger.warning("RAG query failed for dead code refinement: #{inspect(reason)}")
        error
    end
  rescue
    e ->
      Logger.error("Exception generating dead code refinement: #{inspect(e)}")
      {:error, {:refinement_failed, Exception.message(e)}}
  end

  defp call_direct_ai_for_refinement(prompt, opts, dead_func) do
    with {:ok, provider} <- Registry.get_provider_or_default(opts[:provider]) do
      ai_opts = [
        temperature: opts[:temperature] || 0.6,
        max_tokens: opts[:max_tokens] || 400
      ]

      case provider.generate(prompt, ai_opts) do
        {:ok, response} ->
          parse_refinement_response(%{answer: response.content}, dead_func)

        error ->
          error
      end
    end
  end

  defp build_refinement_prompt(dead_func, context) do
    context_str = Context.to_prompt_string(context)

    {:function, module, name, arity} = dead_func[:function]
    original_confidence = dead_func[:confidence] || 0.5
    original_reason = dead_func[:reason] || "No callers found"
    visibility = dead_func[:visibility] || :unknown

    """
    #{context_str}

    ## Dead Code Analysis

    **Function**: #{module}.#{name}/#{arity}
    **Visibility**: #{visibility}
    **Current Confidence**: #{Float.round(original_confidence, 2)} (that this is dead code)
    **Reason**: #{original_reason}

    ## Task

    Analyze whether this function is TRULY dead code or if it's likely a:
    - Callback function (GenServer, Supervisor, Phoenix, etc.)
    - Hook or entry point
    - Dynamically called function
    - Test helper or fixture
    - Exported API meant for external use

    Provide:
    1. **ASSESSMENT**: Is this likely dead code? (YES/NO/UNCERTAIN)
    2. **REASONING**: Why? (2-3 sentences, specific to this function)
    3. **CONFIDENCE**: New confidence score (0.0 = definitely not dead, 1.0 = definitely dead)

    Format as:

    ASSESSMENT: <YES/NO/UNCERTAIN>
    REASONING: <reasoning text>
    CONFIDENCE: <0.0-1.0>

    Be specific to this codebase. Consider function name patterns, behaviors, and similar code.
    """
  end

  defp refinement_system_prompt do
    """
    You are a code analysis assistant helping identify dead code accurately.

    Your role:
    - Distinguish real dead code from callbacks and hooks
    - Recognize common patterns (GenServer, Supervisor, Phoenix LiveView, etc.)
    - Consider function naming conventions
    - Be cautious - false positives harm more than false negatives
    - Provide clear, actionable reasoning

    When uncertain, favor lower confidence (safer to keep code than delete needed code).
    """
  end

  defp parse_refinement_response(response, dead_func) when is_map(response) do
    text = response[:answer] || response[:content] || ""
    parse_refinement_text(text, dead_func)
  end

  defp parse_refinement_text(text, dead_func) do
    # Extract structured sections
    assessment = extract_assessment(text)
    reasoning = extract_section(text, "REASONING")
    confidence_str = extract_section(text, "CONFIDENCE")

    # Parse confidence
    new_confidence = parse_confidence(confidence_str, assessment)

    # Calculate adjustment
    original_confidence = dead_func[:confidence] || 0.5
    adjustment = new_confidence - original_confidence

    # Fallback reasoning if parsing failed
    reasoning =
      reasoning ||
        generate_fallback_reasoning(assessment, new_confidence, original_confidence)

    {:ok,
     %{
       confidence: new_confidence,
       ai_reasoning: reasoning,
       original_confidence: original_confidence,
       adjustment: Float.round(adjustment, 2),
       assessment: assessment,
       refined_at: DateTime.utc_now()
     }}
  end

  defp extract_assessment(text) do
    case Regex.run(~r/ASSESSMENT:\s*(YES|NO|UNCERTAIN)/i, text) do
      [_, "YES"] -> :likely_dead
      [_, "NO"] -> :likely_not_dead
      [_, "UNCERTAIN"] -> :uncertain
      _ -> :uncertain
    end
  end

  defp extract_section(text, section_name) do
    case Regex.run(~r/#{section_name}:\s*(.+?)(?=\n[A-Z]+:|$)/s, text) do
      [_, content] -> String.trim(content)
      _ -> nil
    end
  end

  defp parse_confidence(nil, assessment) do
    # Fallback based on assessment
    case assessment do
      :likely_dead -> 0.8
      :likely_not_dead -> 0.2
      :uncertain -> 0.5
    end
  end

  defp parse_confidence(str, _assessment) when is_binary(str) do
    # Try to extract float
    case Float.parse(String.trim(str)) do
      {confidence, _} -> max(0.0, min(1.0, confidence))
      :error -> 0.5
    end
  end

  defp generate_fallback_reasoning(assessment, new_conf, original_conf) do
    direction = if new_conf < original_conf, do: "decreased", else: "increased"

    case assessment do
      :likely_dead ->
        "Confidence #{direction} to #{Float.round(new_conf, 2)}. Analysis suggests this is likely dead code."

      :likely_not_dead ->
        "Confidence #{direction} to #{Float.round(new_conf, 2)}. Analysis suggests this function is likely still in use."

      :uncertain ->
        "Confidence adjusted to #{Float.round(new_conf, 2)}. Uncertain whether this is dead code."
    end
  end

  defp maybe_add_provider(opts, call_opts) do
    case Keyword.get(call_opts, :provider) do
      nil -> opts
      provider -> Keyword.put(opts, :provider, provider)
    end
  end

  defp get_timeout(opts) do
    feature_config = Config.get_feature_config(:dead_code_refinement)
    Keyword.get(opts, :timeout, feature_config.timeout)
  end
end
