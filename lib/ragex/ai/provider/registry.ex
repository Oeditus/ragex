defmodule Ragex.AI.Provider.Registry do
  @moduledoc """
  Registry for AI providers.

  Manages registration, discovery, and selection of AI providers.
  """

  use GenServer
  require Logger

  alias Ragex.AI.Config, as: AIConfig

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a provider module"
  def register(provider_name, provider_module) do
    GenServer.call(__MODULE__, {:register, provider_name, provider_module})
  end

  @doc "Get provider by name"
  def get(provider_name) do
    GenServer.call(__MODULE__, {:get, provider_name})
  end

  @doc """
  Get provider module by name.

  Alias for `get/1` with more explicit naming.

  ## Parameters
  - `provider_name`: Provider identifier atom (e.g., `:deepseek_r1`, `:openai`, `:anthropic`)

  ## Returns
  - `{:ok, module}` - Provider module if registered
  - `{:error, :not_found}` - Provider not found in registry

  ## Examples

      iex> Registry.get_provider(:deepseek_r1)
      {:ok, Ragex.AI.Provider.DeepSeekR1}

      iex> Registry.get_provider(:unknown)
      {:error, :not_found}
  """
  @spec get_provider(atom()) :: {:ok, module()} | {:error, :not_found}
  def get_provider(provider_name) do
    get(provider_name)
  end

  @doc "List all registered providers"
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Get current active provider from config"
  def current do
    AIConfig.provider()
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Pre-register all known providers
    providers = %{
      deepseek_r1: Ragex.AI.Provider.DeepSeekR1,
      openai: Ragex.AI.Provider.OpenAI,
      anthropic: Ragex.AI.Provider.Anthropic,
      ollama: Ragex.AI.Provider.Ollama
    }

    Logger.info("AI Provider Registry started with #{map_size(providers)} providers")
    {:ok, providers}
  end

  @impl true
  def handle_call({:register, name, module}, _from, providers) do
    {:reply, :ok, Map.put(providers, name, module)}
  end

  @impl true
  def handle_call({:get, name}, _from, providers) do
    case Map.fetch(providers, name) do
      {:ok, module} -> {:reply, {:ok, module}, providers}
      :error -> {:reply, {:error, :not_found}, providers}
    end
  end

  @impl true
  def handle_call(:list, _from, providers) do
    {:reply, providers, providers}
  end
end
