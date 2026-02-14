defmodule Ragex.AI.Registry do
  @moduledoc """
  Convenience wrapper for AI provider registry operations.

  This module provides a simpler API by delegating to `Ragex.AI.Provider.Registry`.

  ## Usage

      alias Ragex.AI.Registry

      # Get provider module
      {:ok, provider} = Registry.get_provider(:deepseek_r1)

      # List all providers
      providers = Registry.list()

      # Get current active provider
      current = Registry.current()
  """

  alias Ragex.AI.Provider.Registry, as: ProviderRegistry

  @doc """
  Get the default AI provider module from configuration.

  Returns the configured default provider without requiring a provider name.
  This is the primary method for checking if AI features are available.

  ## Returns
  - `{:ok, module}` - Default provider module if configured
  - `:error` - No provider configured or provider not found

  ## Examples

      # Check if AI provider is available
      case Registry.get_provider() do
        {:ok, provider} -> provider.generate("query", context, [])
        :error -> {:error, "No AI provider configured"}
      end

      # Use with pattern matching
      if match?({:ok, _}, Registry.get_provider()) do
        # AI features available
      end

  ## Configuration

      config :ragex, :ai,
        default_provider: :openai  # or nil to disable
  """
  @spec get_provider() :: {:ok, module()} | :error
  def get_provider do
    case Ragex.AI.Config.get_default_provider() do
      nil ->
        :error

      provider_name when is_atom(provider_name) ->
        case ProviderRegistry.get_provider(provider_name) do
          {:ok, module} -> {:ok, module}
          {:error, :not_found} -> :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Get provider module by name.

  Retrieves a registered AI provider module from the registry.

  ## Parameters
  - `provider_name`: Provider identifier atom (e.g., `:deepseek_r1`, `:openai`, `:anthropic`)

  ## Returns
  - `{:ok, module}` - Provider module if registered
  - `{:error, :not_found}` - Provider not found in registry

  ## Examples

      # Get DeepSeek R1 provider
      {:ok, DeepSeekR1} = Registry.get_provider(:deepseek_r1)

      # Try to get unregistered provider
      {:error, :not_found} = Registry.get_provider(:unknown)

      # Use the provider module
      {:ok, provider} = Registry.get_provider(:deepseek_r1)
      {:ok, response} = provider.generate("Explain code", context, opts)
  """
  @spec get_provider(atom()) :: {:ok, module()} | {:error, :not_found}
  def get_provider(provider_name) do
    ProviderRegistry.get_provider(provider_name)
  end

  @doc """
  Register a new provider module.

  ## Parameters
  - `provider_name`: Provider identifier atom
  - `provider_module`: Module implementing `Ragex.AI.Behaviour`

  ## Examples

      Registry.register(:custom_provider, MyApp.CustomProvider)
  """
  @spec register(atom(), module()) :: :ok
  def register(provider_name, provider_module) do
    ProviderRegistry.register(provider_name, provider_module)
  end

  @doc """
  List all registered providers.

  ## Returns
  - Map of provider_name => provider_module

  ## Examples

      providers = Registry.list()
      # => %{deepseek_r1: Ragex.AI.Provider.DeepSeekR1, ...}
  """
  @spec list() :: %{atom() => module()}
  def list do
    ProviderRegistry.list()
  end

  @doc """
  Get the current active provider module from configuration.

  Returns the provider module configured as the default in application config.

  ## Returns
  - Provider module (e.g., `Ragex.AI.Provider.DeepSeekR1`)

  ## Examples

      current = Registry.current()
      {:ok, response} = current.generate("query", context, [])
  """
  @spec current() :: module()
  def current do
    ProviderRegistry.current()
  end

  @doc """
  Check if an AI provider is available.

  Boolean convenience wrapper around `get_provider/0`.

  ## Returns
  - `true` - A provider is configured and available
  - `false` - No provider configured

  ## Examples

      if Registry.provider_available?() do
        # Use AI features
      else
        # Skip AI features
      end
  """
  @spec provider_available?() :: boolean()
  def provider_available? do
    match?({:ok, _}, get_provider())
  end

  @doc """
  Get provider module by name, with fallback to configured default.

  If the specified provider is not found, returns the default provider
  configured in the application config.

  ## Parameters
  - `provider_name`: Provider identifier atom (optional)

  ## Returns
  - `{:ok, module}` - Provider module

  ## Examples

      # Get specific provider with fallback
      {:ok, provider} = Registry.get_provider_or_default(:openai)

      # Get default provider
      {:ok, provider} = Registry.get_provider_or_default(nil)
  """
  @spec get_provider_or_default(atom() | nil) :: {:ok, module()}
  def get_provider_or_default(nil) do
    {:ok, current()}
  end

  def get_provider_or_default(provider_name) do
    case get_provider(provider_name) do
      {:ok, module} -> {:ok, module}
      {:error, :not_found} -> {:ok, current()}
    end
  end
end
