defmodule Ragex.AI.Features.Config do
  @moduledoc """
  Configuration management for AI-enhanced features.

  Provides a centralized configuration system for optional AI integrations
  throughout Ragex. Each feature can be individually enabled/disabled, and
  there's a master switch to control all AI features at once.

  ## Configuration

      # config/runtime.exs
      config :ragex, :ai,
        enabled: true,  # Master switch - disables ALL AI features if false
        providers: [:deepseek_r1, :openai],
        default_provider: :deepseek_r1,
        fallback_enabled: true

      config :ragex, :ai_features,
        # Editor features
        validation_error_explanation: true,
        refactor_preview_commentary: true,
        commit_message_generation: true,

        # Analysis features
        dead_code_refinement: true,
        duplication_semantic_analysis: true,
        dependency_insights: true,
        test_suggestions: false,
        complexity_explanation: true

  ## Usage

      # Check if a feature is enabled
      if Config.enabled?(:validation_error_explanation) do
        # Use AI enhancement
      else
        # Fallback to non-AI behavior
      end

      # Check with per-call override
      if Config.enabled?(:refactor_preview_commentary, ai_preview: false) do
        # This will be false due to override
      end

      # Get feature-specific configuration
      config = Config.get_feature_config(:validation_error_explanation)
  """

  require Logger

  @type feature ::
          :validation_error_explanation
          | :refactor_preview_commentary
          | :commit_message_generation
          | :dead_code_refinement
          | :duplication_semantic_analysis
          | :dependency_insights
          | :test_suggestions
          | :complexity_explanation

  @type override :: boolean() | :force

  @doc """
  Check if AI features are enabled globally.

  Returns false if the master `:ai, enabled` flag is false, regardless of
  individual feature flags.

  ## Examples

      iex> Config.ai_enabled?()
      true
  """
  @spec ai_enabled?() :: boolean()
  def ai_enabled? do
    Application.get_env(:ragex, :ai, [])
    |> Keyword.get(:enabled, false)
  end

  @doc """
  Check if a specific AI feature is enabled.

  Respects the master AI switch and individual feature flags. Can be overridden
  with per-call options.

  ## Parameters
  - `feature` - Feature identifier atom
  - `opts` - Keyword list with optional overrides:
    - `:ai_<feature>` - Override for specific feature (e.g., `:ai_preview`)
    - `:force_ai` - Force enable regardless of config (for testing)

  ## Returns
  - `true` if feature should be used
  - `false` if feature should be skipped

  ## Examples

      # Check global + feature config
      Config.enabled?(:validation_error_explanation)

      # With per-call override (disable)
      Config.enabled?(:refactor_preview_commentary, ai_preview: false)

      # With per-call override (force enable)
      Config.enabled?(:test_suggestions, force_ai: true)
  """
  @spec enabled?(feature(), keyword()) :: boolean()
  def enabled?(feature, opts \\ []) do
    cond do
      Keyword.get(opts, :force_ai, false) ->
        Logger.debug("AI feature #{feature} forced enabled")
        true

      not ai_enabled?() ->
        false

      true ->
        feature |> get_override(opts) |> do_boolify_get_override(feature)
    end
  end

  defp do_boolify_get_override(true, _), do: true
  defp do_boolify_get_override(false, _), do: false
  defp do_boolify_get_override(:force, _), do: true
  defp do_boolify_get_override(nil, feature), do: get_feature_enabled(feature)

  @doc """
  Get the configuration map for a specific feature.

  Returns feature-specific settings like timeout, cache TTL, model preferences, etc.

  ## Parameters
  - `feature` - Feature identifier atom

  ## Returns
  - Map of feature configuration options

  ## Examples

      iex> Config.get_feature_config(:validation_error_explanation)
      %{
        enabled: true,
        timeout: 5000,
        cache_ttl: 604_800,  # 7 days
        temperature: 0.7
      }
  """
  @spec get_feature_config(feature()) :: map()
  def get_feature_config(feature) do
    base_config = %{
      enabled: get_feature_enabled(feature),
      timeout: get_timeout(feature),
      cache_ttl: get_cache_ttl(feature),
      temperature: get_temperature(feature),
      max_tokens: get_max_tokens(feature)
    }

    # Merge with any feature-specific overrides from config
    feature_overrides =
      Application.get_env(:ragex, :ai_feature_config, [])
      |> Keyword.get(feature, [])
      |> Enum.into(%{})

    Map.merge(base_config, feature_overrides)
  end

  @doc """
  List all available AI features.

  ## Returns
  - List of feature atoms

  ## Examples

      iex> Config.list_features()
      [:validation_error_explanation, :refactor_preview_commentary, ...]
  """
  @spec list_features() :: [feature()]
  def list_features do
    [
      :validation_error_explanation,
      :refactor_preview_commentary,
      :commit_message_generation,
      :dead_code_refinement,
      :duplication_semantic_analysis,
      :dependency_insights,
      :test_suggestions,
      :complexity_explanation
    ]
  end

  @doc """
  Get status of all AI features.

  Returns a map showing which features are currently enabled.

  ## Returns
  - Map of feature => enabled status

  ## Examples

      iex> Config.status()
      %{
        validation_error_explanation: true,
        refactor_preview_commentary: true,
        test_suggestions: false,
        ...
      }
  """
  @spec status() :: %{feature() => boolean()}
  def status do
    list_features()
    |> Enum.map(fn feature -> {feature, enabled?(feature)} end)
    |> Enum.into(%{})
  end

  # Private functions

  defp get_override(feature, opts) do
    # Look for feature-specific override key
    # E.g., for :refactor_preview_commentary, check :ai_preview
    override_key = feature_to_override_key(feature)

    case Keyword.get(opts, override_key) do
      nil -> nil
      true -> true
      false -> false
      :force -> :force
      other -> other
    end
  end

  defp feature_to_override_key(:validation_error_explanation), do: :ai_explain
  defp feature_to_override_key(:refactor_preview_commentary), do: :ai_preview
  defp feature_to_override_key(:commit_message_generation), do: :ai_commit
  defp feature_to_override_key(:dead_code_refinement), do: :ai_refine
  defp feature_to_override_key(:duplication_semantic_analysis), do: :ai_semantic
  defp feature_to_override_key(:dependency_insights), do: :ai_insights
  defp feature_to_override_key(:test_suggestions), do: :ai_tests
  defp feature_to_override_key(:complexity_explanation), do: :ai_complexity
  defp feature_to_override_key(_), do: :ai_enabled

  defp get_feature_enabled(feature) do
    Application.get_env(:ragex, :ai_features, [])
    |> Keyword.get(feature, default_enabled(feature))
  end

  # Default enabled state for each feature
  defp default_enabled(:validation_error_explanation), do: true
  defp default_enabled(:refactor_preview_commentary), do: true
  defp default_enabled(:commit_message_generation), do: true
  defp default_enabled(:dead_code_refinement), do: true
  defp default_enabled(:duplication_semantic_analysis), do: true
  defp default_enabled(:dependency_insights), do: true
  defp default_enabled(:test_suggestions), do: false
  defp default_enabled(:complexity_explanation), do: true

  # Feature-specific timeout (milliseconds)
  defp get_timeout(:validation_error_explanation), do: 5_000
  defp get_timeout(:refactor_preview_commentary), do: 10_000
  defp get_timeout(:commit_message_generation), do: 5_000
  defp get_timeout(:dead_code_refinement), do: 8_000
  defp get_timeout(:duplication_semantic_analysis), do: 10_000
  defp get_timeout(:dependency_insights), do: 8_000
  defp get_timeout(:test_suggestions), do: 15_000
  defp get_timeout(:complexity_explanation), do: 8_000

  # Feature-specific cache TTL (seconds)
  defp get_cache_ttl(:validation_error_explanation), do: 604_800
  defp get_cache_ttl(:refactor_preview_commentary), do: 3_600
  defp get_cache_ttl(:commit_message_generation), do: 86_400
  defp get_cache_ttl(:dead_code_refinement), do: 86_400
  defp get_cache_ttl(:duplication_semantic_analysis), do: 86_400
  defp get_cache_ttl(:dependency_insights), do: 86_400
  defp get_cache_ttl(:test_suggestions), do: 604_800
  defp get_cache_ttl(:complexity_explanation), do: 86_400

  # Feature-specific temperature
  defp get_temperature(:validation_error_explanation), do: 0.3
  defp get_temperature(:refactor_preview_commentary), do: 0.5
  defp get_temperature(:commit_message_generation), do: 0.4
  defp get_temperature(:dead_code_refinement), do: 0.6
  defp get_temperature(:duplication_semantic_analysis), do: 0.5
  defp get_temperature(:dependency_insights), do: 0.6
  defp get_temperature(:test_suggestions), do: 0.7
  defp get_temperature(:complexity_explanation), do: 0.6

  # Feature-specific max tokens
  defp get_max_tokens(:validation_error_explanation), do: 300
  defp get_max_tokens(:refactor_preview_commentary), do: 500
  defp get_max_tokens(:commit_message_generation), do: 200
  defp get_max_tokens(:dead_code_refinement), do: 400
  defp get_max_tokens(:duplication_semantic_analysis), do: 500
  defp get_max_tokens(:dependency_insights), do: 500
  defp get_max_tokens(:test_suggestions), do: 800
  defp get_max_tokens(:complexity_explanation), do: 500
end
