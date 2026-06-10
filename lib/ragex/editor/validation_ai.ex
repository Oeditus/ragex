defmodule Ragex.Editor.ValidationAI do
  @moduledoc """
  AI-enhanced validation error explanation and fix suggestions.

  Wraps the standard Validator with optional AI explanations that provide:
  - Human-readable error explanations
  - Specific fix suggestions
  - Similar patterns from the codebase
  - Learning from past fixes

  ## Usage

      alias Ragex.Editor.ValidationAI

      # Validate with AI explanations
      case ValidationAI.validate_with_explanation(content, path: "lib/file.ex") do
        {:ok, :valid} -> 
          :ok
        
        {:error, errors} ->
          # Errors enriched with ai_explanation and ai_suggestion fields
          Enum.each(errors, fn error ->
            IO.puts("Error: \#{error.message}")
            if error[:ai_explanation] do
              IO.puts("Why: \#{error.ai_explanation}")
              IO.puts("Fix: \#{error.ai_suggestion}")
            end
          end)
      end

      # Or enrich existing validation errors
      {:error, errors} = Validator.validate(content, opts)
      enriched = ValidationAI.explain_errors(errors, content, opts)

  ## Configuration

      # config/runtime.exs
      config :ragex, :ai_features,
        validation_error_explanation: true

      # Disable for specific call
      ValidationAI.validate_with_explanation(content, 
        path: "test.ex", 
        ai_explain: false
      )
  """

  alias Ragex.AI.Features.{Cache, Config, Context}
  alias Ragex.AI.Registry
  alias Ragex.Editor.{Types, Validator}
  alias Ragex.RAG.Pipeline

  require Logger

  @type validation_result :: {:ok, :valid | :no_validator} | {:error, [Types.validation_error()]}
  @type enriched_error :: Types.validation_error()

  @doc """
  Validate code with AI-enhanced error explanations.

  This is the main entry point for AI-enhanced validation. It performs
  standard validation and optionally enriches errors with AI explanations.

  ## Parameters
  - `content` - Code content to validate
  - `opts` - Options:
    - `:path` - File path (for language detection)
    - `:language` - Explicit language override
    - `:ai_explain` - Enable/disable AI (default: from config)
    - `:surrounding_lines` - Lines of context around error (default: 3)
    - `:timeout` - AI timeout in ms (default: from feature config)

  ## Returns
  - `{:ok, :valid}` if validation passes
  - `{:ok, :no_validator}` if no validator available
  - `{:error, [enriched_error]}` if validation fails (with AI explanations)

  ## Examples

      # Basic usage
      ValidationAI.validate_with_explanation(code, path: "lib/module.ex")

      # Disable AI for this call
      ValidationAI.validate_with_explanation(code, 
        path: "lib/module.ex",
        ai_explain: false
      )

      # Custom timeout
      ValidationAI.validate_with_explanation(code,
        path: "lib/module.ex",
        timeout: 10_000
      )
  """
  @spec validate_with_explanation(String.t(), keyword()) :: validation_result()
  def validate_with_explanation(content, opts \\ []) do
    # First, perform standard validation
    case Validator.validate(content, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, errors} ->
        # Check if AI explanation is enabled
        if Config.enabled?(:validation_error_explanation, opts) do
          enriched_errors = explain_errors(errors, content, opts)
          {:error, enriched_errors}
        else
          {:error, errors}
        end
    end
  end

  @doc """
  Enrich existing validation errors with AI explanations.

  Takes errors from standard validation and adds AI-generated explanations
  and fix suggestions.

  ## Parameters
  - `errors` - List of validation errors from Validator
  - `content` - Original code content
  - `opts` - Options (same as validate_with_explanation/2)

  ## Returns
  - List of enriched errors with `:ai_explanation` and `:ai_suggestion` fields

  ## Examples

      {:error, errors} = Validator.validate(content, path: "lib/file.ex")
      enriched = ValidationAI.explain_errors(errors, content, 
        path: "lib/file.ex"
      )
  """
  @spec explain_errors([Types.validation_error()], String.t(), keyword()) :: [enriched_error()]
  def explain_errors(errors, content, opts \\ []) do
    file_path = Keyword.get(opts, :path, "unknown")
    surrounding_lines = Keyword.get(opts, :surrounding_lines, 3)

    # Process errors in parallel for better performance
    errors
    |> Task.async_stream(
      fn error ->
        explain_single_error(error, content, file_path, surrounding_lines, opts)
      end,
      timeout: get_timeout(opts),
      max_concurrency: 3
    )
    |> Enum.map(fn
      {:ok, enriched_error} -> enriched_error
      {:exit, _reason} -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Explain a single validation error.

  Lower-level function for explaining one error at a time.

  ## Parameters
  - `error` - Single validation error
  - `content` - Code content
  - `file_path` - Path to file
  - `surrounding_lines` - Lines of context (default: 3)
  - `opts` - Additional options

  ## Returns
  - Enriched error with AI fields
  """
  @spec explain_single_error(
          Types.validation_error(),
          String.t(),
          String.t(),
          non_neg_integer(),
          keyword()
        ) :: enriched_error()
  def explain_single_error(error, content, file_path, surrounding_lines \\ 3, opts \\ []) do
    # Extract surrounding code for context
    surrounding_code = extract_surrounding_code(content, error[:line], surrounding_lines)

    # Build context for AI
    context = Context.for_validation_error(error, file_path, surrounding_code, opts)

    # Try to get explanation from cache or generate
    case generate_explanation(error, context, opts) do
      {:ok, explanation} ->
        Map.merge(error, explanation)

      {:error, reason} ->
        Logger.warning("Failed to generate AI explanation: #{inspect(reason)}")
        # Return original error if AI fails
        error
    end
  end

  @doc """
  Clear the explanation cache.

  Useful for testing or when you want fresh explanations.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    Cache.clear(:validation_error_explanation)
  end

  @doc """
  Check if AI explanations are currently enabled.

  Takes into account config and optional overrides.
  """
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    Config.enabled?(:validation_error_explanation, opts)
  end

  # Private functions

  defp extract_surrounding_code(content, nil, _lines), do: content

  defp extract_surrounding_code(content, line_num, context_lines) do
    lines = String.split(content, "\n")
    total_lines = length(lines)

    start_line = max(1, line_num - context_lines)
    end_line = min(total_lines, line_num + context_lines)

    lines
    |> Enum.slice((start_line - 1)..(end_line - 1))
    |> Enum.with_index(start_line)
    |> Enum.map_join("\n", fn {line, num} ->
      marker = if num == line_num, do: ">>> ", else: "    "
      "#{marker}#{num}: #{line}"
    end)
  end

  defp generate_explanation(error, context, opts) do
    # Use cache with fetch pattern
    Cache.fetch(
      :validation_error_explanation,
      error,
      context,
      fn ->
        call_ai_for_explanation(error, context, opts)
      end,
      opts
    )
  end

  defp call_ai_for_explanation(error, context, opts) do
    # Build prompt for AI
    prompt = build_explanation_prompt(error, context)

    # Get feature config
    feature_config = Config.get_feature_config(:validation_error_explanation)

    # Prepare RAG query options
    rag_opts =
      [
        temperature: feature_config.temperature,
        max_tokens: feature_config.max_tokens,
        limit: 3,
        threshold: 0.5,
        system_prompt: validation_system_prompt()
      ]
      |> maybe_add_provider(opts)
      |> maybe_add_timeout(opts, feature_config)

    # Call RAG pipeline
    case Pipeline.query(prompt, rag_opts) do
      {:ok, response} ->
        parse_explanation_response(response)

      {:error, :no_results_found} ->
        # Fallback to direct AI without RAG context
        Logger.debug("No RAG results for validation error, using direct AI")
        call_direct_ai_for_explanation(prompt, rag_opts)

      {:error, reason} = error ->
        Logger.warning("RAG query failed for validation error: #{inspect(reason)}")
        error
    end
  rescue
    e ->
      Logger.error("Exception generating validation explanation: #{inspect(e)}")
      {:error, {:explanation_failed, Exception.message(e)}}
  end

  defp call_direct_ai_for_explanation(prompt, opts) do
    # Fallback to direct AI provider call
    with {:ok, provider} <- Registry.get_provider_or_default(opts[:provider]) do
      ai_opts = [
        temperature: opts[:temperature] || 0.3,
        max_tokens: opts[:max_tokens] || 300
      ]

      case provider.generate(prompt, ai_opts) do
        {:ok, response} ->
          parse_explanation_response(%{answer: response.content})

        error ->
          error
      end
    end
  end

  defp build_explanation_prompt(_error, context) do
    context_str = Context.to_prompt_string(context)

    """
    #{context_str}

    ## Task

    Analyze this validation error and provide:
    1. A clear, concise explanation of what's wrong (1-2 sentences)
    2. A specific fix suggestion with code if applicable (1-2 sentences)

    Keep your response brief and actionable. Format as:

    EXPLANATION: <explanation text>
    SUGGESTION: <suggestion text>

    Focus on being helpful and specific to this codebase context.
    """
  end

  defp validation_system_prompt do
    """
    You are a code validation assistant helping developers fix syntax and compilation errors.

    Your role:
    - Explain errors clearly and concisely
    - Provide actionable fix suggestions
    - Reference similar patterns from the codebase when available
    - Be specific, not generic

    Keep responses brief (under 100 words total).
    """
  end

  defp parse_explanation_response(response) when is_map(response) do
    text = response[:answer] || response[:content] || ""
    parse_explanation_text(text)
  end

  defp parse_explanation_text(text) do
    # Extract EXPLANATION and SUGGESTION sections
    explanation =
      case Regex.run(~r/EXPLANATION:\s*(.+?)(?=SUGGESTION:|$)/s, text) do
        [_, expl] -> String.trim(expl)
        _ -> nil
      end

    suggestion =
      case Regex.run(~r/SUGGESTION:\s*(.+?)$/s, text) do
        [_, sugg] -> String.trim(sugg)
        _ -> nil
      end

    cond do
      explanation && suggestion ->
        {:ok,
         %{
           ai_explanation: explanation,
           ai_suggestion: suggestion,
           ai_generated_at: DateTime.utc_now()
         }}

      explanation ->
        # If only explanation found, use it for both
        {:ok,
         %{
           ai_explanation: explanation,
           ai_suggestion: explanation,
           ai_generated_at: DateTime.utc_now()
         }}

      true ->
        # Fallback: use the whole text
        {:ok,
         %{
           ai_explanation: String.trim(text),
           ai_suggestion: "See explanation above",
           ai_generated_at: DateTime.utc_now()
         }}
    end
  end

  defp maybe_add_provider(opts, call_opts) do
    case Keyword.get(call_opts, :provider) do
      nil -> opts
      provider -> Keyword.put(opts, :provider, provider)
    end
  end

  defp maybe_add_timeout(opts, call_opts, feature_config) do
    timeout = Keyword.get(call_opts, :timeout, feature_config.timeout)
    # Note: RAG pipeline doesn't directly support timeout in opts,
    # but we respect it for the AI call itself
    Keyword.put(opts, :timeout, timeout)
  end

  defp get_timeout(opts) do
    feature_config = Config.get_feature_config(:validation_error_explanation)
    Keyword.get(opts, :timeout, feature_config.timeout)
  end
end
