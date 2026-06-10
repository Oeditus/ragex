defmodule Ragex.Analysis.Duplication.AIAnalyzer do
  @moduledoc """
  AI-powered semantic analysis for code duplication detection.

  Uses AI to evaluate Type IV clones (different syntax, same semantics) by
  asking the AI to determine if code snippets are semantically equivalent
  and providing consolidation recommendations.

  ## Features

  - Semantic equivalence detection for Type IV clones
  - False positive reduction for near-miss clones
  - Consolidation strategy recommendations
  - Confidence scoring for duplication claims
  - Batch processing for efficiency

  ## Usage

      alias Ragex.Analysis.Duplication.AIAnalyzer

      # Analyze a single clone pair
      clone_pair = %{
        type: :type_iv,
        snippets: [snippet1, snippet2],
        similarity: 0.65
      }

      {:ok, analysis} = AIAnalyzer.analyze_clone_pair(clone_pair)
      # => %{
      #   semantically_equivalent: true,
      #   confidence: 0.85,
      #   reasoning: "Both implement the same validation logic...",
      #   consolidation_strategy: "Extract common validation function..."
      # }

      # Batch analyze multiple clone pairs
      {:ok, analyzed} = AIAnalyzer.analyze_batch(clone_pairs)

  ## Configuration

      config :ragex, :ai_features,
        duplication_semantic_analysis: true
  """

  alias Ragex.AI.Features.{Cache, Config, Context}
  alias Ragex.AI.Registry
  alias Ragex.RAG.Pipeline

  require Logger

  @type clone_pair :: map()
  @type analysis_result :: %{
          semantically_equivalent: boolean(),
          confidence: float(),
          reasoning: String.t(),
          consolidation_strategy: String.t() | nil,
          duplicate_lines: pos_integer() | nil
        }

  @doc """
  Analyze whether a clone pair is semantically equivalent.

  Uses AI to perform deep semantic analysis of code snippets to determine
  if they implement the same logic despite syntactic differences.

  ## Parameters
  - `clone_pair` - Clone detection result with snippets
  - `opts` - Options:
    - `:ai_analyze` - Enable/disable AI (default: from config)
    - `:min_confidence` - Minimum confidence to report (default: 0.6)

  ## Returns
  - `{:ok, analysis_result}` - Semantic analysis with recommendations
  - `{:error, reason}` - Error if analysis fails

  ## Examples

      clone_pair = %{
        type: :type_iv,
        snippets: [
          %{code: "if x > 0, do: x, else: 0", location: "lib/a.ex:10"},
          %{code: "max(x, 0)", location: "lib/b.ex:25"}
        ],
        similarity: 0.45
      }

      {:ok, analysis} = AIAnalyzer.analyze_clone_pair(clone_pair)
      # => %{
      #   semantically_equivalent: true,
      #   confidence: 0.9,
      #   reasoning: "Both compute max(x, 0)...",
      #   consolidation_strategy: "Use Elixir's max/2 function consistently"
      # }
  """
  @spec analyze_clone_pair(clone_pair(), keyword()) ::
          {:ok, analysis_result()} | {:error, term()}
  def analyze_clone_pair(clone_pair, opts \\ []) do
    if Config.enabled?(:duplication_semantic_analysis, opts) do
      do_analyze_clone_pair(clone_pair, opts)
    else
      {:error, :ai_analyze_disabled}
    end
  end

  @doc """
  Analyze multiple clone pairs in batch.

  More efficient than calling analyze_clone_pair/2 multiple times.

  ## Parameters
  - `clone_pairs` - List of clone detection results
  - `opts` - Options (same as analyze_clone_pair/2)

  ## Returns
  - `{:ok, analyzed_list}` - List of analysis results
  """
  @spec analyze_batch([clone_pair()], keyword()) ::
          {:ok, [analysis_result()]} | {:error, term()}
  def analyze_batch(clone_pairs, opts \\ []) do
    results =
      clone_pairs
      |> Task.async_stream(
        fn pair ->
          case analyze_clone_pair(pair, opts) do
            {:ok, analysis} -> Map.merge(pair, %{ai_analysis: analysis})
            {:error, _} -> pair
          end
        end,
        timeout: get_timeout(opts) * length(clone_pairs),
        max_concurrency: 3
      )
      |> Enum.map(fn {:ok, result} -> result end)

    {:ok, results}
  end

  @doc """
  Check if AI semantic analysis is currently enabled.
  """
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    Config.enabled?(:duplication_semantic_analysis, opts)
  end

  @doc """
  Clear the analysis cache.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    Cache.clear(:duplication_semantic_analysis)
  end

  # Private functions

  defp do_analyze_clone_pair(clone_pair, opts) do
    # Generate cache key from snippets
    cache_key = generate_cache_key(clone_pair)

    # Extract code snippets
    snippets = clone_pair[:snippets] || []
    code1 = get_snippet_code(Enum.at(snippets, 0))
    code2 = get_snippet_code(Enum.at(snippets, 1))
    similarity = clone_pair[:similarity] || 0.0

    # Build context for AI
    context_opts =
      opts
      |> Keyword.put(:location1, Enum.at(snippets, 0))
      |> Keyword.put(:location2, Enum.at(snippets, 1))

    context = Context.for_duplication_analysis(code1, code2, similarity, context_opts)

    # Try to get analysis from cache or generate
    Cache.fetch(
      :duplication_semantic_analysis,
      cache_key,
      context,
      fn ->
        generate_analysis(clone_pair, context, opts)
      end,
      opts
    )
  end

  defp generate_analysis(clone_pair, context, opts) do
    # Build prompt for AI
    prompt = build_analysis_prompt(clone_pair, context)

    # Get feature config
    feature_config = Config.get_feature_config(:duplication_semantic_analysis)

    # Prepare RAG query options
    rag_opts =
      [
        temperature: feature_config.temperature,
        max_tokens: feature_config.max_tokens,
        limit: 5,
        threshold: 0.6,
        system_prompt: analysis_system_prompt()
      ]
      |> maybe_add_provider(opts)

    # Call RAG pipeline
    case Pipeline.query(prompt, rag_opts) do
      {:ok, response} ->
        parse_analysis_response(response, clone_pair)

      {:error, :no_results_found} ->
        # Fallback to direct AI
        Logger.debug("No RAG results for duplication analysis, using direct AI")
        call_direct_ai_for_analysis(prompt, rag_opts, clone_pair)

      {:error, reason} = error ->
        Logger.warning("RAG query failed for duplication analysis: #{inspect(reason)}")
        error
    end
  rescue
    e ->
      Logger.error("Exception generating duplication analysis: #{inspect(e)}")
      {:error, {:analysis_failed, Exception.message(e)}}
  end

  defp call_direct_ai_for_analysis(prompt, opts, clone_pair) do
    with {:ok, provider} <- Registry.get_provider_or_default(opts[:provider]) do
      ai_opts = [
        temperature: opts[:temperature] || 0.5,
        max_tokens: opts[:max_tokens] || 600
      ]

      case provider.generate(prompt, ai_opts) do
        {:ok, response} ->
          parse_analysis_response(%{answer: response.content}, clone_pair)

        error ->
          error
      end
    end
  end

  defp build_analysis_prompt(clone_pair, context) do
    context_str = Context.to_prompt_string(context)

    snippets = clone_pair[:snippets] || []
    clone_type = clone_pair[:type] || :unknown
    similarity = clone_pair[:similarity] || 0.0

    snippet_strs =
      snippets
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {snippet, idx} ->
        location = snippet[:location] || snippet[:file] || "unknown"
        code = snippet[:code] || snippet[:text] || ""

        """
        ### Snippet #{idx}
        **Location**: #{location}
        ```elixir
        #{code}
        ```
        """
      end)

    """
    #{context_str}

    ## Code Duplication Analysis

    **Clone Type**: #{clone_type}
    **Similarity Score**: #{Float.round(similarity, 2)}

    #{snippet_strs}

    ## Task

    Analyze whether these code snippets are semantically equivalent:
    - Do they implement the same logic/algorithm?
    - Are syntactic differences superficial (variable names, formatting)?
    - Is this true duplication or coincidental similarity?

    Consider:
    - Domain logic equivalence
    - Error handling equivalence
    - Edge case behavior
    - Performance implications

    Provide:
    1. **EQUIVALENT**: Are they semantically equivalent? (YES/NO)
    2. **CONFIDENCE**: How confident are you? (0.0-1.0)
    3. **REASONING**: Why? (2-4 sentences, specific to these snippets)
    4. **STRATEGY**: If equivalent, how to consolidate? (1-2 sentences, or "N/A")
    5. **LINES**: Estimated duplicate line count (integer, or "N/A")

    Format as:

    EQUIVALENT: <YES/NO>
    CONFIDENCE: <0.0-1.0>
    REASONING: <reasoning text>
    STRATEGY: <consolidation strategy or N/A>
    LINES: <number or N/A>

    Be specific to this codebase. Consider language idioms and common patterns.
    """
  end

  defp analysis_system_prompt do
    """
    You are a code analysis assistant helping identify semantic code duplication.

    Your role:
    - Distinguish true semantic equivalence from superficial similarity
    - Recognize language-specific idioms (Elixir pipes, pattern matching, etc.)
    - Consider both correctness and maintainability
    - Provide actionable consolidation strategies
    - Be precise - false positives waste developer time

    Focus on semantic meaning, not syntax. Two snippets with different code
    structure may still be semantically equivalent (Type IV clones).
    """
  end

  defp parse_analysis_response(response, _clone_pair) when is_map(response) do
    text = response[:answer] || response[:content] || ""
    parse_analysis_text(text)
  end

  defp parse_analysis_text(text) do
    # Extract structured sections
    equivalent = extract_equivalent(text)
    confidence_str = extract_section(text, "CONFIDENCE")
    reasoning = extract_section(text, "REASONING")
    strategy = extract_section(text, "STRATEGY")
    lines_str = extract_section(text, "LINES")

    # Parse values
    confidence = parse_confidence(confidence_str)
    duplicate_lines = parse_lines(lines_str)

    # Clean up strategy
    strategy =
      case strategy do
        nil -> nil
        "N/A" -> nil
        str -> String.trim(str)
      end

    # Fallback reasoning if parsing failed
    reasoning =
      reasoning || generate_fallback_reasoning(equivalent, confidence)

    {:ok,
     %{
       semantically_equivalent: equivalent,
       confidence: confidence,
       reasoning: reasoning,
       consolidation_strategy: strategy,
       duplicate_lines: duplicate_lines,
       analyzed_at: DateTime.utc_now()
     }}
  end

  defp extract_equivalent(text) do
    case Regex.run(~r/EQUIVALENT:\s*(YES|NO)/i, text) do
      [_, "YES"] -> true
      [_, "NO"] -> false
      _ -> false
    end
  end

  defp extract_section(text, section_name) do
    case Regex.run(~r/#{section_name}:\s*(.+?)(?=\n[A-Z]+:|$)/s, text) do
      [_, content] -> String.trim(content)
      _ -> nil
    end
  end

  defp parse_confidence(nil), do: 0.5

  defp parse_confidence(str) when is_binary(str) do
    case Float.parse(String.trim(str)) do
      {confidence, _} -> max(0.0, min(1.0, confidence))
      :error -> 0.5
    end
  end

  defp parse_lines(nil), do: nil
  defp parse_lines("N/A"), do: nil

  defp parse_lines(str) when is_binary(str) do
    case Integer.parse(String.trim(str)) do
      {lines, _} when lines > 0 -> lines
      _ -> nil
    end
  end

  defp generate_fallback_reasoning(equivalent, confidence) do
    if equivalent do
      "Semantic analysis suggests these snippets are equivalent (confidence: #{Float.round(confidence, 2)})."
    else
      "Semantic analysis suggests these snippets are not equivalent (confidence: #{Float.round(confidence, 2)})."
    end
  end

  defp get_snippet_code(nil), do: ""

  defp get_snippet_code(snippet) when is_map(snippet) do
    snippet[:code] || snippet[:text] || ""
  end

  defp get_snippet_code(_), do: ""

  defp generate_cache_key(clone_pair) do
    # Generate stable cache key from snippet content
    snippets = clone_pair[:snippets] || []

    codes =
      snippets
      |> Enum.map(&get_snippet_code/1)
      |> Enum.sort()
      |> Enum.join("||")

    :crypto.hash(:sha256, codes)
    |> Base.encode16(case: :lower)
    |> String.slice(0..15)
  end

  defp maybe_add_provider(opts, call_opts) do
    case Keyword.get(call_opts, :provider) do
      nil -> opts
      provider -> Keyword.put(opts, :provider, provider)
    end
  end

  defp get_timeout(opts) do
    feature_config = Config.get_feature_config(:duplication_semantic_analysis)
    Keyword.get(opts, :timeout, feature_config.timeout)
  end
end
