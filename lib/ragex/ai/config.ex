defmodule Ragex.AI.Config do
  @moduledoc """
  Manages AI provider configuration.

  Supports multiple AI providers with automatic fallback.

  Loads settings from:
  1. config/config.exs (compile-time defaults)
  2. config/runtime.exs (runtime env vars)
  3. Function call overrides

  ## Configuration

      config :ragex, :ai,
        providers: [:openai, :anthropic, :deepseek_r1, :ollama],
        default_provider: :openai,
        fallback_enabled: true

      config :ragex, :ai_providers,
        openai: [endpoint: "https://api.openai.com/v1", model: "gpt-4-turbo"],
        anthropic: [endpoint: "https://api.anthropic.com/v1", model: "claude-3-sonnet-20240229"],
        deepseek_r1: [endpoint: "https://api.deepseek.com", model: "deepseek-chat"],
        ollama: [endpoint: "http://localhost:11434", model: "codellama"]
  """

  @doc """
  Get the configured default AI provider module.
  """
  @spec provider() :: module()
  def provider do
    provider_name() |> provider_module()
  end

  @doc """
  Get the default provider (returns provider name as atom).

  This is an alias for `provider_name/0` with more explicit naming.
  Returns the configured default provider identifier.

  ## Returns
  - Provider name atom (e.g., `:deepseek_r1`, `:openai`, `:anthropic`)

  ## Examples

      iex> Config.get_default_provider()
      :deepseek_r1

  ## Configuration

      config :ragex, :ai,
        default_provider: :openai
  """
  @spec get_default_provider() :: atom()
  def get_default_provider do
    provider_name()
  end

  @doc """
  Get the configured default provider name.
  """
  @spec provider_name() :: atom()
  def provider_name do
    :ragex
    |> Application.get_env(:ai, [])
    |> Keyword.get(:default_provider, :deepseek_r1)
  end

  @doc """
  Get list of all configured providers.
  """
  @spec providers() :: [atom()]
  def providers do
    :ragex
    |> Application.get_env(:ai, [])
    |> Keyword.get(:providers, [:deepseek_r1])
  end

  @doc """
  Check if fallback to alternative providers is enabled.
  """
  @spec fallback_enabled?() :: boolean()
  def fallback_enabled? do
    :ragex
    |> Application.get_env(:ai, [])
    |> Keyword.get(:fallback_enabled, false)
  end

  @doc """
  Get API configuration for a specific provider.
  """
  @spec api_config(atom() | nil) :: map()
  def api_config(provider_name \\ nil) do
    provider_name = provider_name || provider_name()
    provider_config = get_provider_config(provider_name)
    api_keys = Application.get_env(:ragex, :ai_keys, [])

    %{
      api_key: Keyword.get(api_keys, provider_name),
      endpoint: Keyword.get(provider_config, :endpoint),
      model: Keyword.get(provider_config, :model),
      options: Keyword.get(provider_config, :options, [])
    }
  end

  defp get_provider_config(provider_name) do
    Application.get_env(:ragex, :ai_providers, [])
    |> Keyword.get(provider_name, [])
  end

  @doc """
  Get generation options, merging config with overrides.
  """
  @spec generation_opts(keyword(), atom() | nil) :: keyword()
  def generation_opts(overrides \\ [], provider_name \\ nil) do
    config_opts = api_config(provider_name).options
    Keyword.merge(config_opts, overrides)
  end

  @doc """
  Validate that required configuration is present for all providers.
  """
  @spec validate!() :: :ok
  def validate! do
    providers = providers()

    Enum.each(providers, fn provider_name ->
      config = api_config(provider_name)

      # Ollama doesn't require API key (local)
      if provider_name != :ollama do
        if is_nil(config.api_key) or config.api_key == "" do
          raise "API key not set for provider: #{provider_name}"
        end
      end

      if is_nil(config.endpoint) do
        raise "Endpoint not configured for provider: #{provider_name}"
      end
    end)

    :ok
  end

  # Private

  defp provider_module(:deepseek_r1), do: Ragex.AI.Provider.DeepSeekR1
  defp provider_module(:openai), do: Ragex.AI.Provider.OpenAI
  defp provider_module(:anthropic), do: Ragex.AI.Provider.Anthropic
  defp provider_module(:ollama), do: Ragex.AI.Provider.Ollama
  defp provider_module(atom), do: raise("Unknown AI provider: #{atom}")
end
