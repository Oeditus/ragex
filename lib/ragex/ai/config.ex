defmodule Ragex.AI.Config do
  @moduledoc """
  Manages AI provider configuration.

  Loads settings from:
  1. config/config.exs (compile-time defaults)
  2. config/runtime.exs (runtime env vars)
  3. Function call overrides
  """

  @doc """
  Get the configured AI provider module.
  """
  def provider do
    :ragex
    |> Application.get_env(:ai, [])
    |> Keyword.get(:provider, :deepseek_r1)
    |> provider_module()
  end

  @doc """
  Get API configuration for the active provider.
  """
  def api_config do
    ai_config = Application.get_env(:ragex, :ai, [])

    %{
      api_key: Keyword.get(ai_config, :api_key),
      endpoint: Keyword.get(ai_config, :endpoint, "https://api.deepseek.com"),
      model: Keyword.get(ai_config, :model, "deepseek-chat"),
      options: Keyword.get(ai_config, :options, [])
    }
  end

  @doc """
  Get generation options, merging config with overrides.
  """
  def generation_opts(overrides \\ []) do
    config_opts = api_config().options
    Keyword.merge(config_opts, overrides)
  end

  @doc """
  Validate that required configuration is present.
  """
  def validate! do
    config = api_config()

    cond do
      is_nil(config.api_key) or config.api_key == "" ->
        raise "DEEPSEEK_API_KEY not set. Add to environment or config/runtime.exs"

      is_nil(config.endpoint) ->
        raise "AI endpoint not configured"

      true ->
        :ok
    end
  end

  # Private

  defp provider_module(:deepseek_r1), do: Ragex.AI.Provider.DeepSeekR1
  # defp provider_module(:openai), do: Ragex.AI.Provider.OpenAI
  # defp provider_module(:anthropic), do: Ragex.AI.Provider.Anthropic
  defp provider_module(atom), do: raise("Unknown AI provider: #{atom}")
end
