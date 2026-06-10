defmodule Ragex.Editor.Refactor.AIPreview do
  @moduledoc """
  AI-enhanced refactoring preview commentary.

  Provides natural language summaries, risk assessments, and recommendations
  for refactoring operations before they are executed.

  ## Features

  - Natural language summary of what will change
  - Risk assessment based on impact analysis
  - Actionable recommendations
  - Learning from similar refactorings in the codebase

  ## Usage

      alias Ragex.Editor.Refactor.AIPreview

      # Generate commentary for a refactoring operation
      preview_data = %{
        operation: :rename_function,
        params: %{module: :MyModule, old_name: :old_func, new_name: :new_func},
        affected_files: ["lib/my_module.ex", "test/my_module_test.exs"],
        diff: "..."
      }

      case AIPreview.generate_commentary(preview_data) do
        {:ok, commentary} ->
          IO.puts("Summary: \#{commentary.summary}")
          IO.puts("Risk Level: \#{commentary.risk_level}")
          Enum.each(commentary.recommendations, &IO.puts("- \#{&1}"))

        {:error, reason} ->
          Logger.warning("Failed to generate AI commentary: \#{reason}")
      end

  ## Configuration

      # config/runtime.exs
      config :ragex, :ai_features,
        refactor_preview_commentary: true

      # Disable for specific call
      AIPreview.generate_commentary(preview_data, ai_preview: false)
  """

  alias Ragex.AI.Features.{Cache, Config, Context}
  alias Ragex.AI.Registry
  alias Ragex.RAG.Pipeline

  require Logger

  @type preview_data :: %{
          required(:operation) => atom(),
          required(:params) => map(),
          required(:affected_files) => [String.t()],
          optional(:diff) => String.t(),
          optional(:stats) => map()
        }

  @type commentary :: %{
          summary: String.t(),
          risk_level: :low | :medium | :high | :critical,
          risks: [String.t()],
          recommendations: [String.t()],
          estimated_impact: String.t(),
          confidence: float()
        }

  @doc """
  Generate AI commentary for a refactoring preview.

  Analyzes the refactoring operation and generates natural language
  explanations, risk assessments, and recommendations.

  ## Parameters
  - `preview_data` - Map containing operation details
  - `opts` - Options:
    - `:ai_preview` - Enable/disable AI (default: from config)
    - `:provider` - AI provider override
    - `:timeout` - AI timeout in ms (default: from feature config)
    - `:include_recommendations` - Include recommendations (default: true)

  ## Returns
  - `{:ok, commentary}` - Generated commentary
  - `{:error, reason}` - Error if generation fails

  ## Examples

      preview = %{
        operation: :rename_function,
        params: %{module: :MyModule, old_name: :old, new_name: :new, arity: 2},
        affected_files: ["lib/my_module.ex"],
        stats: %{lines_changed: 5, files_affected: 1}
      }

      {:ok, commentary} = AIPreview.generate_commentary(preview)
  """
  @spec generate_commentary(preview_data(), keyword()) :: {:ok, commentary()} | {:error, term()}
  def generate_commentary(preview_data, opts \\ []) do
    # Check if AI preview is enabled
    if Config.enabled?(:refactor_preview_commentary, opts) do
      do_generate_commentary(preview_data, opts)
    else
      {:error, :ai_preview_disabled}
    end
  end

  @doc """
  Check if AI preview commentary is currently enabled.

  Takes into account config and optional overrides.
  """
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    Config.enabled?(:refactor_preview_commentary, opts)
  end

  @doc """
  Clear the preview commentary cache.

  Useful for testing or when you want fresh commentaries.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    Cache.clear(:refactor_preview_commentary)
  end

  # Private functions

  defp do_generate_commentary(preview_data, opts) do
    operation = preview_data.operation
    params = preview_data.params
    affected_files = preview_data.affected_files

    # Build context for AI
    context = Context.for_refactor_preview(operation, params, affected_files, opts)

    # Try to get commentary from cache or generate
    Cache.fetch(
      :refactor_preview_commentary,
      {operation, params},
      context,
      fn ->
        generate_with_ai(preview_data, context, opts)
      end,
      opts
    )
  end

  defp generate_with_ai(preview_data, context, opts) do
    # Build prompt for AI
    prompt = build_preview_prompt(preview_data, context)

    # Get feature config
    feature_config = Config.get_feature_config(:refactor_preview_commentary)

    # Prepare RAG query options
    rag_opts =
      [
        temperature: feature_config.temperature,
        max_tokens: feature_config.max_tokens,
        limit: 5,
        threshold: 0.6,
        system_prompt: preview_system_prompt()
      ]
      |> maybe_add_provider(opts)

    # Call RAG pipeline
    case Pipeline.query(prompt, rag_opts) do
      {:ok, response} ->
        parse_commentary_response(response, preview_data)

      {:error, :no_results_found} ->
        # Fallback to direct AI without RAG context
        Logger.debug("No RAG results for refactor preview, using direct AI")
        call_direct_ai_for_commentary(prompt, rag_opts, preview_data)

      {:error, reason} = error ->
        Logger.warning("RAG query failed for refactor preview: #{inspect(reason)}")
        error
    end
  rescue
    e ->
      Logger.error("Exception generating refactor commentary: #{inspect(e)}")
      {:error, {:commentary_failed, Exception.message(e)}}
  end

  defp call_direct_ai_for_commentary(prompt, opts, preview_data) do
    # Fallback to direct AI provider call
    with {:ok, provider} <- Registry.get_provider_or_default(opts[:provider]) do
      ai_opts = [
        temperature: opts[:temperature] || 0.5,
        max_tokens: opts[:max_tokens] || 500
      ]

      case provider.generate(prompt, ai_opts) do
        {:ok, response} ->
          parse_commentary_response(%{answer: response.content}, preview_data)

        error ->
          error
      end
    end
  end

  defp build_preview_prompt(preview_data, context) do
    context_str = Context.to_prompt_string(context)

    operation_desc = describe_operation(preview_data.operation, preview_data.params)
    files_desc = "#{length(preview_data.affected_files)} file(s)"
    stats_desc = describe_stats(preview_data[:stats])

    diff_section =
      if preview_data[:diff] do
        """

        ## Code Changes

        ```diff
        #{String.slice(preview_data.diff, 0, 1000)}
        ```
        """
      else
        ""
      end

    """
    #{context_str}

    ## Refactoring Operation

    **Operation**: #{operation_desc}
    **Files Affected**: #{files_desc}
    #{if stats_desc, do: "**Stats**: #{stats_desc}", else: ""}#{diff_section}

    ## Task

    Analyze this refactoring and provide:

    1. **SUMMARY**: A clear 1-2 sentence summary of what this refactoring does
    2. **RISK_LEVEL**: One of: low, medium, high, critical
    3. **RISKS**: Specific risks or concerns (2-3 bullet points, or "None" if safe)
    4. **RECOMMENDATIONS**: Actionable recommendations (2-3 bullet points)
    5. **IMPACT**: Brief impact assessment (1 sentence)

    Format your response as:

    SUMMARY: <summary text>
    RISK_LEVEL: <risk level>
    RISKS:
    - <risk 1>
    - <risk 2>
    RECOMMENDATIONS:
    - <recommendation 1>
    - <recommendation 2>
    IMPACT: <impact text>

    Be specific to this codebase. Focus on practical concerns and advice.
    """
  end

  defp preview_system_prompt do
    """
    You are a refactoring assistant helping developers safely transform their code.

    Your role:
    - Explain refactorings clearly and concisely
    - Assess risks realistically (be cautious but not alarmist)
    - Provide actionable recommendations
    - Reference codebase context when available
    - Be specific, not generic

    Keep responses concise and practical.
    """
  end

  defp describe_operation(:rename_function, params) do
    "Rename function #{params[:module]}.#{params[:old_name]}/#{params[:arity]} to #{params[:new_name]}"
  end

  defp describe_operation(:rename_module, params) do
    "Rename module #{params[:old_module]} to #{params[:new_module]}"
  end

  defp describe_operation(:extract_function, params) do
    "Extract lines #{elem(params[:line_range] || {0, 0}, 0)}-#{elem(params[:line_range] || {0, 0}, 1)} from #{params[:module]}.#{params[:source_function]} into #{params[:new_function]}"
  end

  defp describe_operation(:inline_function, params) do
    "Inline function #{params[:module]}.#{params[:function]}/#{params[:arity]}"
  end

  defp describe_operation(:change_signature, params) do
    changes = length(params[:changes] || [])

    "Change signature of #{params[:module]}.#{params[:function]}/#{params[:arity]} (#{changes} parameter changes)"
  end

  defp describe_operation(operation, _params) do
    operation
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp describe_stats(nil), do: nil

  defp describe_stats(stats) do
    parts = []

    parts =
      if stats[:lines_changed] do
        parts ++ ["#{stats.lines_changed} lines"]
      else
        parts
      end

    parts =
      if stats[:files_affected] do
        parts ++ ["#{stats.files_affected} files"]
      else
        parts
      end

    parts =
      if stats[:functions_affected] do
        parts ++ ["#{stats.functions_affected} functions"]
      else
        parts
      end

    if parts != [], do: Enum.join(parts, ", "), else: nil
  end

  defp parse_commentary_response(response, preview_data) when is_map(response) do
    text = response[:answer] || response[:content] || ""
    parse_commentary_text(text, preview_data)
  end

  defp parse_commentary_text(text, preview_data) do
    # Extract structured sections
    summary = extract_section(text, "SUMMARY")
    risk_level_str = extract_section(text, "RISK_LEVEL")
    risks = extract_list_section(text, "RISKS")
    recommendations = extract_list_section(text, "RECOMMENDATIONS")
    impact = extract_section(text, "IMPACT")

    # Parse risk level
    risk_level = parse_risk_level(risk_level_str)

    # Calculate confidence based on response quality
    confidence = calculate_confidence(summary, risks, recommendations)

    # Fallback to reasonable defaults if parsing failed
    summary = summary || generate_fallback_summary(preview_data)
    impact = impact || "Changes #{length(preview_data.affected_files)} file(s)"
    risks = if risks == [], do: ["No specific risks identified"], else: risks

    recommendations =
      if recommendations == [],
        do: ["Test thoroughly after applying", "Review changes before committing"],
        else: recommendations

    {:ok,
     %{
       summary: summary,
       risk_level: risk_level,
       risks: risks,
       recommendations: recommendations,
       estimated_impact: impact,
       confidence: confidence,
       generated_at: DateTime.utc_now()
     }}
  end

  defp extract_section(text, section_name) do
    # Try to extract content after "SECTION_NAME:"
    case Regex.run(~r/#{section_name}:\s*(.+?)(?=\n[A-Z_]+:|$)/s, text) do
      [_, content] -> String.trim(content)
      _ -> nil
    end
  end

  defp extract_list_section(text, section_name) do
    # Extract bullet list after "SECTION_NAME:"
    case Regex.run(~r/#{section_name}:\s*\n((?:[-*•]\s*.+\n?)+)/s, text) do
      [_, list_text] ->
        list_text
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&String.starts_with?(&1, ["-", "*", "•"]))
        |> Enum.map(fn line ->
          line
          |> String.trim_leading("-")
          |> String.trim_leading("*")
          |> String.trim_leading("•")
          |> String.trim()
        end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        # Fallback: try to find any bullet points
        text
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(String.trim(&1), ["-", "*", "•"]))
        |> Enum.map(fn line ->
          line
          |> String.trim()
          |> String.trim_leading("-")
          |> String.trim_leading("*")
          |> String.trim_leading("•")
          |> String.trim()
        end)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp parse_risk_level(nil), do: :medium

  defp parse_risk_level(str) when is_binary(str) do
    str_lower = String.downcase(String.trim(str))

    cond do
      String.contains?(str_lower, "critical") -> :critical
      String.contains?(str_lower, "high") -> :high
      String.contains?(str_lower, "medium") -> :medium
      String.contains?(str_lower, "low") -> :low
      true -> :medium
    end
  end

  defp calculate_confidence(summary, risks, recommendations) do
    # Simple heuristic: more detailed response = higher confidence
    score = 0.5

    score = if summary && String.length(summary) > 20, do: score + 0.2, else: score
    score = if match?([_ | _], risks), do: score + 0.15, else: score
    score = if match?([_ | _], recommendations), do: score + 0.15, else: score

    min(1.0, score)
  end

  defp generate_fallback_summary(preview_data) do
    operation_name =
      preview_data.operation
      |> Atom.to_string()
      |> String.replace("_", " ")

    "This refactoring performs a #{operation_name} operation affecting #{length(preview_data.affected_files)} file(s)."
  end

  defp maybe_add_provider(opts, call_opts) do
    case Keyword.get(call_opts, :provider) do
      nil -> opts
      provider -> Keyword.put(opts, :provider, provider)
    end
  end
end
