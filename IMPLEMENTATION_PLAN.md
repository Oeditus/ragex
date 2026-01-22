# Metastatic + DeepSeek RAG Integration - Detailed Implementation Plan

## Implementation Status

**Status**: ✅ **COMPLETE** (Phases 1-3)  
**Completed**: January 22, 2026  
**Actual Effort**: 1 day (AI-assisted implementation)  
**Test Results**: 343 tests passing, 0 failures

All core features have been implemented and tested. See [RAG_IMPLEMENTATION_SUMMARY.md](RAG_IMPLEMENTATION_SUMMARY.md) for the comprehensive summary of what was built.

---

## Executive Summary

This document provides a comprehensive, step-by-step implementation plan for integrating:
1. **Metastatic MetaAST** library for enhanced cross-language code analysis
2. **DeepSeek R1 API** as the first AI provider in an extensible, provider-agnostic architecture

**Original Estimated Effort**: 5-8 days  
**Actual Effort**: 1 day (with AI assistance)  
**Phases**: 4 (Phases 1-3 complete, Phase 4 optional)
**Risk Level**: Low-Medium

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Phase 1: AI Provider Abstraction Layer](#phase-1-ai-provider-abstraction-layer)
3. [Phase 2: Metastatic Integration](#phase-2-metastatic-integration)
4. [Phase 3: RAG Pipeline](#phase-3-rag-pipeline)
5. [Phase 4: MetaAST-Enhanced Retrieval](#phase-4-metaast-enhanced-retrieval)
6. [Testing Plan](#testing-plan)
7. [Deployment Checklist](#deployment-checklist)
8. [Rollback Strategy](#rollback-strategy)

---

## Prerequisites

### Environment Setup

```bash
# 1. Ensure you're in the correct directory
cd /opt/Proyectos/Oeditus/ragex

# 2. Set DeepSeek API key
export DEEPSEEK_API_KEY="your-key-here"
echo 'export DEEPSEEK_API_KEY="your-key-here"' >> ~/.zshrc

# 3. Verify metastatic is accessible
ls -la ../metastatic/mix.exs
```

### Dependencies to Add

Edit `ragex/mix.exs`:

```elixir
defp deps do
  [
    # ... existing deps ...
    
    # AI Provider
    {:req, "~> 0.5"},
    
    # Metastatic MetaAST
    {:metastatic, path: "../metastatic"}
  ]
end
```

Then run:

```bash
cd /opt/Proyectos/Oeditus/ragex
mix deps.get
mix deps.compile
```

### Configuration Files

Create `config/runtime.exs` if it doesn't exist:

```elixir
import Config

# Runtime configuration loaded at application start
if config_env() == :prod do
  config :ragex, :ai,
    api_key: System.fetch_env!("DEEPSEEK_API_KEY")
else
  # Dev/test: use env var or fail gracefully
  config :ragex, :ai,
    api_key: System.get_env("DEEPSEEK_API_KEY", "test-key")
end
```

Update `config/config.exs`:

```elixir
# Add AI configuration
config :ragex, :ai,
  provider: :deepseek_r1,
  endpoint: "https://api.deepseek.com",
  model: "deepseek-chat",  # or "deepseek-reasoner" for thinking mode
  options: [
    temperature: 0.7,
    max_tokens: 2048,
    stream: false
  ]

# Add Metastatic feature flag
config :ragex, :features,
  use_metastatic: true,
  fallback_to_native_analyzers: true
```

---

## Phase 1: AI Provider Abstraction Layer

**Estimated Time**: 2-3 days  
**Goal**: Create a clean, extensible abstraction for AI providers

### Step 1.1: AI Behaviour Definition

**File**: `lib/ragex/ai/behaviour.ex`

```elixir
defmodule Ragex.AI.Behaviour do
  @moduledoc """
  Defines the behaviour for AI provider implementations.
  
  This abstraction allows Ragex to support multiple AI providers
  (DeepSeek, OpenAI, Anthropic, local LLMs) with a unified interface.
  """

  @typedoc "AI provider response"
  @type response :: %{
          content: String.t(),
          model: String.t(),
          usage: map(),
          metadata: map()
        }

  @typedoc "Streaming chunk from AI provider"
  @type chunk :: %{
          content: String.t(),
          done: boolean(),
          metadata: map()
        }

  @typedoc "Generation options"
  @type opts :: keyword()

  @doc """
  Generate a response from the AI provider.
  
  ## Parameters
  
  - `prompt` - User query or instruction
  - `context` - Retrieved code context (optional)
  - `opts` - Provider-specific options
  
  ## Options
  
  - `:temperature` - Sampling temperature (0.0-2.0)
  - `:max_tokens` - Maximum response length
  - `:system_prompt` - System instructions
  - `:model` - Model override
  
  ## Returns
  
  - `{:ok, response}` - Successful generation
  - `{:error, reason}` - API error, rate limit, etc.
  """
  @callback generate(prompt :: String.t(), context :: map() | nil, opts) ::
              {:ok, response()} | {:error, term()}

  @doc """
  Stream a response from the AI provider.
  
  Returns a stream of chunks that can be consumed incrementally.
  Useful for real-time UI updates in MCP clients.
  """
  @callback stream_generate(prompt :: String.t(), context :: map() | nil, opts) ::
              {:ok, Enumerable.t(chunk())} | {:error, term()}

  @doc """
  Validate provider configuration.
  
  Called at application startup to ensure API keys, endpoints, etc. are valid.
  """
  @callback validate_config() :: :ok | {:error, String.t()}

  @doc """
  Get provider information (name, models, capabilities).
  """
  @callback info() :: map()
end
```

**Test File**: `test/ragex/ai/behaviour_test.exs`

```elixir
defmodule Ragex.AI.BehaviourTest do
  use ExUnit.Case, async: true

  defmodule MockProvider do
    @behaviour Ragex.AI.Behaviour

    @impl true
    def generate(prompt, _context, _opts) do
      {:ok,
       %{
         content: "Mock response to: #{prompt}",
         model: "mock-model",
         usage: %{prompt_tokens: 10, completion_tokens: 20},
         metadata: %{}
       }}
    end

    @impl true
    def stream_generate(_prompt, _context, _opts) do
      chunks = [
        %{content: "Hello", done: false, metadata: %{}},
        %{content: " world", done: true, metadata: %{}}
      ]

      {:ok, Stream.map(chunks, & &1)}
    end

    @impl true
    def validate_config, do: :ok

    @impl true
    def info do
      %{name: "Mock Provider", models: ["mock-model"], capabilities: [:generate, :stream]}
    end
  end

  test "mock provider implements behaviour" do
    assert {:ok, response} = MockProvider.generate("test", nil, [])
    assert response.content =~ "Mock response"
  end

  test "mock provider streams" do
    assert {:ok, stream} = MockProvider.stream_generate("test", nil, [])
    chunks = Enum.to_list(stream)
    assert length(chunks) == 2
    assert List.last(chunks).done == true
  end
end
```

### Step 1.2: Configuration Module

**File**: `lib/ragex/ai/config.ex`

```elixir
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
    provider_atom = Application.get_env(:ragex, :ai)[:provider] || :deepseek_r1
    provider_module(provider_atom)
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
  defp provider_module(:openai), do: Ragex.AI.Provider.OpenAI
  defp provider_module(:anthropic), do: Ragex.AI.Provider.Anthropic
  defp provider_module(atom), do: raise("Unknown AI provider: #{atom}")
end
```

**Test File**: `test/ragex/ai/config_test.exs`

```elixir
defmodule Ragex.AI.ConfigTest do
  use ExUnit.Case, async: false

  alias Ragex.AI.Config

  setup do
    # Store original config
    original_config = Application.get_env(:ragex, :ai)

    on_exit(fn ->
      if original_config do
        Application.put_env(:ragex, :ai, original_config)
      end
    end)

    :ok
  end

  test "loads provider from config" do
    Application.put_env(:ragex, :ai, provider: :deepseek_r1)
    assert Config.provider() == Ragex.AI.Provider.DeepSeekR1
  end

  test "loads API config" do
    Application.put_env(:ragex, :ai,
      api_key: "test-key",
      endpoint: "https://test.com",
      model: "test-model"
    )

    config = Config.api_config()
    assert config.api_key == "test-key"
    assert config.endpoint == "https://test.com"
    assert config.model == "test-model"
  end

  test "merges generation opts" do
    Application.put_env(:ragex, :ai, options: [temperature: 0.5, max_tokens: 1000])

    opts = Config.generation_opts(max_tokens: 2000, stream: true)
    assert opts[:temperature] == 0.5
    assert opts[:max_tokens] == 2000
    assert opts[:stream] == true
  end
end
```

### Step 1.3: DeepSeek Provider Implementation

**File**: `lib/ragex/ai/provider/deep_seek_r1.ex`

```elixir
defmodule Ragex.AI.Provider.DeepSeekR1 do
  @moduledoc """
  DeepSeek R1 API provider implementation.
  
  Uses the DeepSeek API (OpenAI-compatible):
  - Base URL: https://api.deepseek.com
  - Models: deepseek-chat (non-thinking), deepseek-reasoner (thinking)
  - API Docs: https://api-docs.deepseek.com/
  
  ## Configuration
  
  In config/runtime.exs:
      config :ragex, :ai,
        api_key: System.fetch_env!("DEEPSEEK_API_KEY")
  
  In config/config.exs:
      config :ragex, :ai,
        provider: :deepseek_r1,
        endpoint: "https://api.deepseek.com",
        model: "deepseek-chat"
  """

  @behaviour Ragex.AI.Behaviour

  require Logger
  alias Ragex.AI.Config

  @impl true
  def generate(prompt, context, opts \\ []) do
    config = Config.api_config()
    opts = Config.generation_opts(opts)

    # Build request body
    body = build_request_body(prompt, context, opts, config.model)

    # Make HTTP request using Req
    case make_request(config, body, stream: false) do
      {:ok, response} ->
        parse_response(response)

      {:error, reason} ->
        Logger.error("DeepSeek API error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def stream_generate(prompt, context, opts \\ []) do
    config = Config.api_config()
    opts = Config.generation_opts(Keyword.put(opts, :stream, true))

    body = build_request_body(prompt, context, opts, config.model)

    case make_request(config, body, stream: true) do
      {:ok, stream} ->
        {:ok, Stream.map(stream, &parse_stream_chunk/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def validate_config do
    config = Config.api_config()

    cond do
      is_nil(config.api_key) or config.api_key == "" ->
        {:error, "DEEPSEEK_API_KEY not set"}

      not valid_endpoint?(config.endpoint) ->
        {:error, "Invalid endpoint: #{config.endpoint}"}

      not valid_model?(config.model) ->
        {:error, "Invalid model: #{config.model}"}

      true ->
        # Optional: test API call
        test_api_connection(config)
    end
  end

  @impl true
  def info do
    %{
      name: "DeepSeek R1",
      provider: :deepseek_r1,
      models: ["deepseek-chat", "deepseek-reasoner"],
      capabilities: [:generate, :stream, :function_calling],
      api_version: "v1",
      docs_url: "https://api-docs.deepseek.com/"
    }
  end

  # Private functions

  defp build_request_body(prompt, context, opts, model) do
    messages = build_messages(prompt, context, opts)

    %{
      model: Keyword.get(opts, :model, model),
      messages: messages,
      temperature: Keyword.get(opts, :temperature, 0.7),
      max_tokens: Keyword.get(opts, :max_tokens, 2048),
      stream: Keyword.get(opts, :stream, false)
    }
    |> maybe_add_system_prompt(opts)
  end

  defp build_messages(prompt, nil, _opts) do
    [%{role: "user", content: prompt}]
  end

  defp build_messages(prompt, context, opts) when is_map(context) do
    context_content = format_context(context, opts)

    [
      %{role: "user", content: context_content},
      %{role: "user", content: prompt}
    ]
  end

  defp format_context(context, _opts) do
    """
    # Code Context

    #{format_code_snippets(context)}

    #{format_metadata(context)}
    """
  end

  defp format_code_snippets(%{results: results}) when is_list(results) do
    results
    |> Enum.take(10)
    |> Enum.map_join("\n\n", fn result ->
      """
      ## #{result[:node_id]}
      File: #{result[:file] || "unknown"}
      Score: #{Float.round(result[:score] || 0.0, 3)}

      ```#{result[:language] || ""}
      #{result[:code] || result[:text] || "No code available"}
      ```
      """
    end)
  end

  defp format_code_snippets(_), do: ""

  defp format_metadata(%{metadata: meta}) when is_map(meta) do
    """
    ## Metadata
    #{inspect(meta, pretty: true, limit: :infinity)}
    """
  end

  defp format_metadata(_), do: ""

  defp maybe_add_system_prompt(body, opts) do
    case Keyword.get(opts, :system_prompt) do
      nil -> body
      system_prompt -> Map.put(body, :system, system_prompt)
    end
  end

  defp make_request(config, body, opts) do
    url = "#{config.endpoint}/chat/completions"

    headers = [
      {"authorization", "Bearer #{config.api_key}"},
      {"content-type", "application/json"}
    ]

    req_opts = [
      url: url,
      method: :post,
      headers: headers,
      json: body,
      receive_timeout: 60_000
    ]

    req_opts =
      if opts[:stream] do
        Keyword.put(req_opts, :into, :self)
      else
        req_opts
      end

    case Req.request(req_opts) do
      {:ok, %{status: 200} = response} ->
        if opts[:stream] do
          {:ok, response.body}
        else
          {:ok, response}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(%{body: body}) when is_map(body) do
    content =
      body
      |> get_in(["choices", Access.at(0), "message", "content"])
      |> to_string()

    usage = Map.get(body, "usage", %{})
    model = Map.get(body, "model", "unknown")

    {:ok,
     %{
       content: content,
       model: model,
       usage: usage,
       metadata: %{raw_response: body}
     }}
  end

  defp parse_response(_), do: {:error, "Invalid response format"}

  defp parse_stream_chunk(chunk) when is_binary(chunk) do
    # SSE format: "data: {...}\n\n"
    with "data: " <> json_str <- String.trim(chunk),
         {:ok, data} <- Jason.decode(json_str) do
      delta = get_in(data, ["choices", Access.at(0), "delta", "content"]) || ""
      done = get_in(data, ["choices", Access.at(0), "finish_reason"]) != nil

      %{content: delta, done: done, metadata: data}
    else
      _ -> %{content: "", done: false, metadata: %{}}
    end
  end

  defp valid_endpoint?(endpoint) do
    String.starts_with?(endpoint, "https://api.deepseek.com")
  end

  defp valid_model?(model) when is_binary(model) do
    model in ["deepseek-chat", "deepseek-reasoner"]
  end

  defp valid_model?(_), do: false

  defp test_api_connection(config) do
    # Simple test request
    body = %{
      model: config.model,
      messages: [%{role: "user", content: "test"}],
      max_tokens: 5
    }

    case make_request(config, body, stream: false) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "API connection test failed: #{inspect(reason)}"}
    end
  end
end
```

**Test File**: `test/ragex/ai/provider/deep_seek_r1_test.exs`

```elixir
defmodule Ragex.AI.Provider.DeepSeekR1Test do
  use ExUnit.Case, async: false

  alias Ragex.AI.Provider.DeepSeekR1

  @moduletag :external_api

  setup do
    # Skip if no API key
    unless System.get_env("DEEPSEEK_API_KEY") do
      :skip
    else
      :ok
    end
  end

  describe "generate/3" do
    @tag timeout: 30_000
    test "generates response" do
      assert {:ok, response} = DeepSeekR1.generate("Say 'hello'", nil, max_tokens: 10)
      assert is_binary(response.content)
      assert response.content =~ ~r/hello/i
      assert response.model =~ "deepseek"
    end

    @tag timeout: 30_000
    test "generates with context" do
      context = %{
        results: [
          %{
            node_id: "MyModule.test/1",
            file: "test.ex",
            score: 0.95,
            code: "def test(x), do: x + 1"
          }
        ]
      }

      assert {:ok, response} =
               DeepSeekR1.generate("What does this function do?", context, max_tokens: 50)

      assert is_binary(response.content)
    end
  end

  describe "stream_generate/3" do
    @tag timeout: 30_000
    test "streams response" do
      assert {:ok, stream} = DeepSeekR1.stream_generate("Count to 5", nil, max_tokens: 20)
      chunks = Enum.to_list(stream)

      assert length(chunks) > 0
      assert List.last(chunks).done == true

      full_content = chunks |> Enum.map(& &1.content) |> Enum.join()
      assert String.length(full_content) > 0
    end
  end

  describe "validate_config/0" do
    test "validates configuration" do
      Application.put_env(:ragex, :ai,
        api_key: System.get_env("DEEPSEEK_API_KEY"),
        endpoint: "https://api.deepseek.com",
        model: "deepseek-chat"
      )

      assert DeepSeekR1.validate_config() == :ok
    end

    test "fails with invalid config" do
      Application.put_env(:ragex, :ai, api_key: nil)
      assert {:error, _} = DeepSeekR1.validate_config()
    end
  end

  describe "info/0" do
    test "returns provider info" do
      info = DeepSeekR1.info()
      assert info.name == "DeepSeek R1"
      assert "deepseek-chat" in info.models
      assert :generate in info.capabilities
    end
  end
end
```

### Step 1.4: Provider Registry

**File**: `lib/ragex/ai/provider/registry.ex`

```elixir
defmodule Ragex.AI.Provider.Registry do
  @moduledoc """
  Registry for AI providers.
  
  Manages registration, discovery, and selection of AI providers.
  """

  use GenServer
  require Logger

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

  @doc "List all registered providers"
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc "Get current active provider from config"
  def current do
    Ragex.AI.Config.provider()
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Pre-register known providers
    providers = %{
      deepseek_r1: Ragex.AI.Provider.DeepSeekR1
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
```

### Step 1.5: Integration Test

**File**: `test/ragex/ai/integration_test.exs`

```elixir
defmodule Ragex.AI.IntegrationTest do
  use ExUnit.Case, async: false

  alias Ragex.AI.{Config, Provider.DeepSeekR1}

  @moduletag :integration

  setup do
    # Ensure config is set
    Application.put_env(:ragex, :ai,
      provider: :deepseek_r1,
      api_key: System.get_env("DEEPSEEK_API_KEY", "test-key"),
      endpoint: "https://api.deepseek.com",
      model: "deepseek-chat",
      options: [temperature: 0.7, max_tokens: 100]
    )

    :ok
  end

  test "end-to-end: config -> provider -> generate" do
    # Skip if no real API key
    unless System.get_env("DEEPSEEK_API_KEY") do
      :skip
    else
      provider = Config.provider()
      assert provider == DeepSeekR1

      assert {:ok, response} = provider.generate("Say hello", nil, max_tokens: 10)
      assert is_binary(response.content)
      assert byte_size(response.content) > 0
    end
  end
end
```

### Step 1.6: Update Application Supervisor

**File**: `lib/ragex/application.ex` (modify)

```elixir
defmodule Ragex.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Validate AI config on startup
    if Application.get_env(:ragex, :start_server, true) do
      try do
        Ragex.AI.Config.validate!()
        Logger.info("AI configuration validated successfully")
      rescue
        e ->
          Logger.warning("AI configuration validation failed: #{Exception.message(e)}")
          Logger.warning("AI features will be disabled")
      end
    end

    children = [
      # ... existing children ...
      
      # AI Provider Registry
      Ragex.AI.Provider.Registry
    ]

    opts = [strategy: :one_for_one, name: Ragex.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

---

## Phase 2: Metastatic Integration

**Estimated Time**: 2-3 days  
**Goal**: Replace native analyzers with Metastatic-powered versions

### Step 2.1: Metastatic Analyzer Wrapper

**File**: `lib/ragex/analyzers/metastatic.ex`

```elixir
defmodule Ragex.Analyzers.Metastatic do
  @moduledoc """
  Analyzer implementation using Metastatic MetaAST library.
  
  Provides richer semantic analysis compared to native regex-based parsers:
  - Cross-language semantic equivalence
  - Purity analysis
  - Complexity metrics
  - Three-layer MetaAST (M2.1/M2.2/M2.3)
  """

  @behaviour Ragex.Analyzers.Behaviour

  require Logger
  alias Metastatic.{Builder, Document}
  alias Metastatic.Analysis.{Purity, Complexity}
  alias Ragex.Analyzers.MetaASTExtractor

  @impl true
  def analyze(source, file_path) do
    language = detect_language(file_path)

    with {:ok, doc} <- Builder.from_source(source, language),
         {:ok, analysis} <- extract_analysis(doc, file_path) do
      {:ok, enrich_with_metastatic_data(analysis, doc)}
    else
      {:error, reason} ->
        Logger.warning(
          "Metastatic analysis failed for #{file_path}: #{inspect(reason)}. " <>
            "Falling back to native analyzer."
        )

        fallback_analyze(source, file_path, language)
    end
  end

  @impl true
  def supported_extensions do
    # Metastatic supports these languages
    [".ex", ".exs", ".erl", ".hrl", ".py", ".rb"]
  end

  # Private

  defp detect_language(file_path) do
    case Metastatic.Adapter.detect_language(file_path) do
      {:ok, lang} -> lang
      {:error, _} -> :unknown
    end
  end

  defp extract_analysis(%Document{ast: meta_ast, language: language}, file_path) do
    analysis = %{
      modules: MetaASTExtractor.extract_modules(meta_ast, file_path),
      functions: MetaASTExtractor.extract_functions(meta_ast, file_path),
      calls: MetaASTExtractor.extract_calls(meta_ast),
      imports: MetaASTExtractor.extract_imports(meta_ast)
    }

    {:ok, analysis}
  end

  defp enrich_with_metastatic_data(analysis, %Document{} = doc) do
    # Add purity analysis
    purity_results =
      Enum.map(analysis.functions, fn func ->
        case Purity.analyze(doc) do
          {:ok, purity} -> {func.name, purity}
          _ -> {func.name, nil}
        end
      end)
      |> Map.new()

    # Add complexity metrics
    complexity_results =
      Enum.map(analysis.functions, fn func ->
        case Complexity.analyze(doc) do
          {:ok, complexity} -> {func.name, complexity}
          _ -> {func.name, nil}
        end
      end)
      |> Map.new()

    # Enrich functions with metadata
    enriched_functions =
      Enum.map(analysis.functions, fn func ->
        func
        |> Map.put(:purity, purity_results[func.name])
        |> Map.put(:complexity, complexity_results[func.name])
        |> Map.put(:meta_ast_layer, detect_meta_ast_layer(func))
      end)

    %{analysis | functions: enriched_functions}
  end

  defp detect_meta_ast_layer(_func) do
    # TODO: Implement layer detection based on MetaAST node types
    # M2.1 (Core), M2.2 (Extended), M2.3 (Native)
    :core
  end

  defp fallback_analyze(source, file_path, language) do
    # Fall back to native analyzers if feature flag is enabled
    if Application.get_env(:ragex, :features)[:fallback_to_native_analyzers] do
      case language do
        :elixir -> Ragex.Analyzers.Elixir.analyze(source, file_path)
        :erlang -> Ragex.Analyzers.Erlang.analyze(source, file_path)
        :python -> Ragex.Analyzers.Python.analyze(source, file_path)
        _ -> {:error, :no_fallback_analyzer}
      end
    else
      {:error, :metastatic_failed_no_fallback}
    end
  end
end
```

### Step 2.2: MetaAST Extractor Helper

**File**: `lib/ragex/analyzers/meta_ast_extractor.ex`

```elixir
defmodule Ragex.Analyzers.MetaASTExtractor do
  @moduledoc """
  Extracts Ragex-compatible analysis data from Metastatic MetaAST.
  
  Maps MetaAST nodes to Ragex knowledge graph schema.
  """

  @doc """
  Extract module information from MetaAST.
  """
  def extract_modules(meta_ast, file_path) do
    # TODO: Walk MetaAST and find module definitions
    # This depends on MetaAST structure for different languages
    walk_ast(meta_ast, [], fn node, acc ->
      case node do
        {:module_def, name, body, metadata} ->
          module_info = %{
            name: name,
            file: file_path,
            line: metadata[:line] || 1,
            doc: metadata[:doc],
            metadata: metadata
          }

          [module_info | acc]

        _ ->
          acc
      end
    end)
  end

  @doc """
  Extract function information from MetaAST.
  """
  def extract_functions(meta_ast, file_path) do
    walk_ast(meta_ast, [], fn node, acc ->
      case node do
        {:function_def, name, params, body, metadata} ->
          func_info = %{
            name: name,
            arity: length(params),
            module: metadata[:module],
            file: file_path,
            line: metadata[:line] || 1,
            doc: metadata[:doc],
            visibility: metadata[:visibility] || :public,
            metadata: %{
              params: params,
              return_type: metadata[:return_type],
              meta_ast_node: node
            }
          }

          [func_info | acc]

        _ ->
          acc
      end
    end)
  end

  @doc """
  Extract function calls from MetaAST.
  """
  def extract_calls(meta_ast) do
    walk_ast(meta_ast, [], fn node, acc ->
      case node do
        {:function_call, target, args, metadata} ->
          call_info = %{
            from_module: metadata[:current_module],
            from_function: metadata[:current_function],
            from_arity: metadata[:current_arity],
            to_module: extract_module_from_target(target),
            to_function: extract_function_from_target(target),
            to_arity: length(args),
            line: metadata[:line] || 1
          }

          [call_info | acc]

        _ ->
          acc
      end
    end)
  end

  @doc """
  Extract import/require/use statements from MetaAST.
  """
  def extract_imports(meta_ast) do
    walk_ast(meta_ast, [], fn node, acc ->
      case node do
        {:import, module, opts, metadata} ->
          import_info = %{
            from_module: metadata[:current_module],
            to_module: module,
            type: :import
          }

          [import_info | acc]

        {:require, module, opts, metadata} ->
          import_info = %{
            from_module: metadata[:current_module],
            to_module: module,
            type: :require
          }

          [import_info | acc]

        _ ->
          acc
      end
    end)
  end

  @doc """
  Generate natural language description for a MetaAST node.
  """
  def generate_description({:function_def, name, params, _body, metadata}) do
    """
    Function #{name}/#{length(params)}
    Parameters: #{format_params(params)}
    #{if metadata[:doc], do: "Documentation: #{metadata[:doc]}", else: ""}
    """
  end

  def generate_description({:binary_op, category, op, _left, _right, _metadata}) do
    "#{category} operation: #{op}"
  end

  def generate_description(_node), do: "Code element"

  # Private helpers

  defp walk_ast(ast, acc, fun) when is_tuple(ast) do
    acc = fun.(ast, acc)

    ast
    |> Tuple.to_list()
    |> Enum.reduce(acc, fn child, acc -> walk_ast(child, acc, fun) end)
  end

  defp walk_ast(ast, acc, fun) when is_list(ast) do
    Enum.reduce(ast, acc, fn child, acc -> walk_ast(child, acc, fun) end)
  end

  defp walk_ast(_ast, acc, _fun), do: acc

  defp extract_module_from_target({:module_ref, module}), do: module
  defp extract_module_from_target(_), do: nil

  defp extract_function_from_target({:function_ref, _, func}), do: func
  defp extract_function_from_target(_), do: nil

  defp format_params(params) do
    params
    |> Enum.map(fn
      {:param, name, type, _default} -> "#{name}: #{type}"
      {:param, name, nil, _default} -> "#{name}"
    end)
    |> Enum.join(", ")
  end
end
```

### Step 2.3: Update Analyzer Selection Logic

**File**: `lib/ragex/mcp/handlers/tools.ex` (modify `analyze_file/1`)

```elixir
# In get_analyzer/2 function, add Metastatic option:

defp get_analyzer(language, path) do
  use_metastatic = Application.get_env(:ragex, :features)[:use_metastatic]

  if use_metastatic and metastatic_supports?(path) do
    Ragex.Analyzers.Metastatic
  else
    native_analyzer(language, path)
  end
end

defp metastatic_supports?(path) do
  ext = Path.extname(path)
  ext in Ragex.Analyzers.Metastatic.supported_extensions()
end

defp native_analyzer("elixir", _), do: Ragex.Analyzers.Elixir
defp native_analyzer("erlang", _), do: Ragex.Analyzers.Erlang
defp native_analyzer("python", _), do: Ragex.Analyzers.Python
defp native_analyzer("javascript", _), do: Ragex.Analyzers.JavaScript
defp native_analyzer("typescript", _), do: Ragex.Analyzers.JavaScript
defp native_analyzer("auto", path), do: get_analyzer(detect_language(path), path)
```

---

## Phase 3: RAG Pipeline

**Estimated Time**: 2-3 days  
**Goal**: Build end-to-end RAG with retrieval + generation

### Step 3.1: RAG Pipeline Orchestrator

**File**: `lib/ragex/rag/pipeline.ex`

```elixir
defmodule Ragex.RAG.Pipeline do
  @moduledoc """
  Orchestrates the RAG pipeline: Retrieval → Augmentation → Generation.
  
  ## Pipeline Steps
  
  1. **Retrieval**: Query knowledge graph and vector store (hybrid search)
  2. **Context Building**: Format retrieved code for AI consumption
  3. **Prompt Engineering**: Apply templates and inject context
  4. **Generation**: Call AI provider with augmented prompt
  5. **Post-processing**: Parse response, add sources, format output
  """

  require Logger

  alias Ragex.AI.Config
  alias Ragex.RAG.{ContextBuilder, PromptTemplate}
  alias Ragex.Retrieval.Hybrid

  @doc """
  Execute RAG query pipeline.
  
  ## Options
  
  - `:limit` - Max retrieval results (default: 10)
  - `:threshold` - Similarity threshold (default: 0.7)
  - `:strategy` - Retrieval strategy: :fusion, :semantic_first, :graph_first
  - `:include_code` - Include full code snippets (default: true)
  - `:provider` - Override AI provider
  - `:system_prompt` - Custom system prompt
  - `:temperature` - AI temperature (default: 0.7)
  """
  def query(user_query, opts \\\\ []) do
    Logger.info("RAG Pipeline: query='#{user_query}'")

    with {:ok, retrieval_results} <- retrieve(user_query, opts),
         {:ok, context} <- build_context(retrieval_results, opts),
         {:ok, prompt} <- build_prompt(user_query, context, opts),
         {:ok, response} <- generate(prompt, context, opts) do
      format_response(response, retrieval_results)
    end
  end

  @doc """
  Explain code using RAG.
  """
  def explain(target, aspect, opts \\\\ []) do
    query_text = build_explain_query(target, aspect)
    
    opts =
      opts
      |> Keyword.put(:system_prompt, explain_system_prompt())
      |> Keyword.put(:limit, 5)

    query(query_text, opts)
  end

  @doc """
  Suggest improvements using RAG.
  """
  def suggest(target, focus, opts \\\\ []) do
    query_text = build_suggest_query(target, focus)

    opts =
      opts
      |> Keyword.put(:system_prompt, suggest_system_prompt())
      |> Keyword.put(:limit, 3)

    query(query_text, opts)
  end

  # Private

  defp retrieve(query, opts) do
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.7)
    strategy = Keyword.get(opts, :strategy, :fusion)

    case Hybrid.search(query, limit: limit, threshold: threshold, strategy: strategy) do
      {:ok, results} when is_list(results) and length(results) > 0 ->
        {:ok, results}

      {:ok, []} ->
        {:error, :no_results_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_context(results, opts) do
    ContextBuilder.build_context(results, opts)
  end

  defp build_prompt(user_query, context, opts) do
    system_prompt = Keyword.get(opts, :system_prompt, default_system_prompt())
    
    prompt =
      PromptTemplate.render(:query, %{
        system_prompt: system_prompt,
        context: context,
        query: user_query
      })

    {:ok, prompt}
  end

  defp generate(prompt, context, opts) do
    provider = get_provider(opts)

    ai_opts = [
      temperature: Keyword.get(opts, :temperature, 0.7),
      max_tokens: Keyword.get(opts, :max_tokens, 2048)
    ]

    provider.generate(prompt, %{context: context}, ai_opts)
  end

  defp format_response({:ok, ai_response}, retrieval_results) do
    {:ok,
     %{
       content: ai_response.content,
       sources: format_sources(retrieval_results),
       model: ai_response.model,
       usage: ai_response.usage,
       metadata: %{
         retrieval_count: length(retrieval_results),
         timestamp: DateTime.utc_now()
       }
     }}
  end

  defp format_response({:error, reason}, _results) do
    {:error, reason}
  end

  defp format_sources(results) do
    Enum.map(results, fn result ->
      %{
        file: result[:file],
        node_id: result[:node_id],
        score: Float.round(result[:score] || 0.0, 3),
        line: result[:line]
      }
    end)
  end

  defp get_provider(opts) do
    case Keyword.get(opts, :provider) do
      nil -> Config.provider()
      provider_atom when is_atom(provider_atom) -> provider_module(provider_atom)
    end
  end

  defp provider_module(:deepseek_r1), do: Ragex.AI.Provider.DeepSeekR1
  defp provider_module(_), do: Config.provider()

  defp default_system_prompt do
    """
    You are an expert code assistant with deep knowledge of software engineering.
    You have access to a codebase and can answer questions about its structure,
    functionality, and best practices.

    Your responses should be:
    - Accurate and based on the provided code context
    - Concise but comprehensive
    - Include specific file/function references when relevant
    - Suggest improvements when appropriate
    """
  end

  defp explain_system_prompt do
    """
    You are a code documentation expert. Explain the provided code clearly and thoroughly.
    Focus on: purpose, behavior, dependencies, and potential issues.
    Use simple language suitable for both beginners and experts.
    """
  end

  defp suggest_system_prompt do
    """
    You are a code reviewer focused on suggesting improvements.
    Provide actionable, specific recommendations with examples.
    Consider: performance, readability, maintainability, and testing.
    """
  end

  defp build_explain_query(target, aspect) do
    "Explain the #{aspect} of #{target}"
  end

  defp build_suggest_query(target, focus) do
    "Suggest #{focus} improvements for #{target}"
  end
end
```

### Step 3.2: Context Builder

**File**: `lib/ragex/rag/context_builder.ex`

```elixir
defmodule Ragex.RAG.ContextBuilder do
  @moduledoc """
  Formats retrieved code for AI consumption.
  
  Handles:
  - Context window limits
  - Code snippet formatting
  - Metadata inclusion
  - Summarization for large contexts
  """

  @max_context_length 8000  # characters

  def build_context(results, opts \\\\ []) do
    include_code = Keyword.get(opts, :include_code, true)
    max_length = Keyword.get(opts, :max_context_length, @max_context_length)

    context =
      results
      |> Enum.map(&format_result(&1, include_code))
      |> Enum.join("\n\n---\n\n")
      |> truncate_if_needed(max_length)

    {:ok, context}
  end

  defp format_result(result, include_code) do
    """
    ## #{result[:node_id] || "Unknown"}
    
    **File**: #{result[:file] || "unknown"}
    **Line**: #{result[:line] || "N/A"}
    **Score**: #{Float.round(result[:score] || 0.0, 3)}
    #{if result[:complexity], do: "**Complexity**: #{inspect(result[:complexity])}", else: ""}
    #{if result[:purity], do: "**Purity**: #{if result[:purity].pure?, do: "Pure", else: "Impure"}", else: ""}

    #{if include_code and result[:code] do
      """
      ```#{result[:language] || ""}
      #{result[:code]}
      ```
      """
    else
      result[:text] || result[:doc] || "No description available"
    end}
    """
  end

  defp truncate_if_needed(context, max_length) when byte_size(context) > max_length do
    truncated = String.slice(context, 0, max_length)
    truncated <> "\n\n... (context truncated)"
  end

  defp truncate_if_needed(context, _max_length), do: context
end
```

### Step 3.3: Prompt Template

**File**: `lib/ragex/rag/prompt_template.ex`

```elixir
defmodule Ragex.RAG.PromptTemplate do
  @moduledoc """
  Manages prompt engineering templates.
  """

  def render(:query, vars) do
    """
    #{vars.system_prompt}

    # Code Context

    #{vars.context}

    # User Query

    #{vars.query}

    Please provide a detailed answer based on the code context above.
    Include specific references to files and functions when relevant.
    """
  end

  def render(:explain, vars) do
    """
    Explain the following code in detail:

    #{vars.context}

    Focus on: #{vars.aspect}
    """
  end

  def render(:suggest, vars) do
    """
    Review the following code and suggest improvements:

    #{vars.context}

    Focus area: #{vars.focus}

    Provide specific, actionable recommendations.
    """
  end
end
```

### Step 3.4: MCP Tools for RAG

**File**: `lib/ragex/mcp/handlers/tools.ex` (add new tools)

```elixir
# Add to list_tools():

%{
  name: "rag_query",
  description: "Query codebase using RAG (Retrieval-Augmented Generation)",
  inputSchema: %{
    type: "object",
    properties: %{
      query: %{
        type: "string",
        description: "Natural language query about the codebase"
      },
      limit: %{
        type: "integer",
        description: "Maximum number of code snippets to retrieve",
        default: 10
      },
      include_code: %{
        type: "boolean",
        description: "Include full code snippets in context",
        default: true
      },
      provider: %{
        type: "string",
        description: "AI provider override (deepseek_r1, openai, etc.)",
        enum: ["deepseek_r1"]
      }
    },
    required: ["query"]
  }
},

%{
  name: "rag_explain",
  description: "Explain code using RAG",
  inputSchema: %{
    type: "object",
    properties: %{
      target: %{
        type: "string",
        description: "File path or function identifier (e.g., 'MyModule.function/2')"
      },
      aspect: %{
        type: "string",
        description: "What to explain",
        enum: ["purpose", "complexity", "dependencies", "all"],
        default: "all"
      }
    },
    required: ["target"]
  }
},

%{
  name: "rag_suggest",
  description: "Suggest code improvements using RAG",
  inputSchema: %{
    type: "object",
    properties: %{
      target: %{
        type: "string",
        description: "File path or function identifier"
      },
      focus: %{
        type: "string",
        description: "Improvement focus area",
        enum: ["performance", "readability", "testing", "security", "all"],
        default: "all"
      }
    },
    required: ["target"]
  }
}

# Add to call_tool/2:

"rag_query" ->
  rag_query_tool(arguments)

"rag_explain" ->
  rag_explain_tool(arguments)

"rag_suggest" ->
  rag_suggest_tool(arguments)

# Implement handlers:

defp rag_query_tool(%{"query" => query} = params) do
  opts = [
    limit: Map.get(params, "limit", 10),
    include_code: Map.get(params, "include_code", true),
    provider: parse_provider(Map.get(params, "provider"))
  ]

  case Ragex.RAG.Pipeline.query(query, opts) do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, "RAG query failed: #{inspect(reason)}"}
  end
end

defp rag_explain_tool(%{"target" => target} = params) do
  aspect = Map.get(params, "aspect", "all")

  case Ragex.RAG.Pipeline.explain(target, aspect) do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, "Explanation failed: #{inspect(reason)}"}
  end
end

defp rag_suggest_tool(%{"target" => target} = params) do
  focus = Map.get(params, "focus", "all")

  case Ragex.RAG.Pipeline.suggest(target, focus) do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, "Suggestion failed: #{inspect(reason)}"}
  end
end

defp parse_provider(nil), do: nil
defp parse_provider("deepseek_r1"), do: :deepseek_r1
defp parse_provider(_), do: nil
```

---

## Phase 4: MetaAST-Enhanced Retrieval (Optional)

**Estimated Time**: 1-2 days  
**Goal**: Use MetaAST for cross-language semantic matching

This phase is optional but provides powerful capabilities. Implementation details to be added based on Phase 1-3 completion.

Key enhancements:
- MetaAST fingerprinting for code clone detection
- Cross-language equivalence in retrieval
- Semantic complexity filtering

---

## Testing Plan

### Unit Tests

```bash
# Run specific test suites
mix test test/ragex/ai/
mix test test/ragex/analyzers/metastatic_test.exs
mix test test/ragex/rag/
```

### Integration Tests

```bash
# With real API (requires DEEPSEEK_API_KEY)
DEEPSEEK_API_KEY=your-key mix test --only external_api

# Full integration
mix test --only integration
```

### Manual Testing

```bash
# Start IEx with Ragex loaded
RAGEX_NO_SERVER=1 iex -S mix

# Test AI provider
iex> Ragex.AI.Config.validate!()
iex> provider = Ragex.AI.Config.provider()
iex> provider.generate("Say hello", nil, max_tokens: 10)

# Test Metastatic analyzer
iex> source = "def test(x), do: x + 1"
iex> Ragex.Analyzers.Metastatic.analyze(source, "test.ex")

# Test RAG pipeline
iex> Ragex.RAG.Pipeline.query("What does the test function do?")
```

---

## Deployment Checklist

### Pre-deployment

- [ ] All tests passing
- [ ] `DEEPSEEK_API_KEY` set in production environment
- [ ] `config/runtime.exs` properly configured
- [ ] `.gitignore` excludes secrets
- [ ] Documentation updated
- [ ] Mix deps compiled

### Deployment

```bash
# Production build
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix compile

# Start server
MIX_ENV=prod DEEPSEEK_API_KEY=xxx mix run --no-halt
```

### Post-deployment Validation

```bash
# Test MCP tool availability
echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | ./start_mcp.sh

# Test RAG query
# (Use your MCP client - LunarVim)
```

---

## Rollback Strategy

### If Phase 1 fails:
- Remove AI provider modules
- Revert `config/config.exs` and `config/runtime.exs`
- Continue with existing Ragex functionality

### If Phase 2 fails:
- Set `config :ragex, :features, use_metastatic: false`
- Fall back to native analyzers automatically

### If Phase 3 fails:
- AI features unavailable but retrieval still works
- Remove new MCP tools from handlers

### Complete Rollback

```bash
cd /opt/Proyectos/Oeditus/ragex
git checkout main  # or your stable branch
mix deps.get
mix compile
```

---

## Success Criteria

- [ ] Phase 1: AI provider abstraction with DeepSeek working
  - Can generate responses from simple prompts
  - Configuration loads correctly
  - Error handling works
  
- [ ] Phase 2: Metastatic integration functional
  - Elixir/Erlang/Python files analyzed with MetaAST
  - Purity and complexity data extracted
  - Fallback to native analyzers works
  
- [ ] Phase 3: End-to-end RAG working
  - `rag_query` tool returns AI-generated answers
  - Context includes relevant code snippets
  - Sources properly attributed

---

## Next Steps After Implementation

1. **Performance tuning**: Optimize retrieval and context building
2. **Add more providers**: OpenAI, Anthropic, Ollama
3. **Enhanced MetaAST features**: Phase 4 implementation
4. **User feedback**: Gather usage data from LunarVim integration
5. **Documentation**: User guide, API reference, examples

---

## Questions & Clarifications

- DeepSeek rate limits? (Need to add backoff/retry)
- Context window size for deepseek-chat vs deepseek-reasoner?
- Should we support streaming responses in MCP tools?
- MetaAST extractor: Need examples of actual MetaAST structure for each language

---

## Appendix: File Structure

```
ragex/
├── config/
│   ├── config.exs          # AI provider config
│   └── runtime.exs         # NEW: API keys from env
├── lib/
│   ├── ragex/
│   │   ├── ai/             # NEW: Phase 1
│   │   │   ├── behaviour.ex
│   │   │   ├── config.ex
│   │   │   └── provider/
│   │   │       ├── deep_seek_r1.ex
│   │   │       └── registry.ex
│   │   ├── analyzers/
│   │   │   ├── metastatic.ex        # NEW: Phase 2
│   │   │   └── meta_ast_extractor.ex # NEW: Phase 2
│   │   ├── rag/            # NEW: Phase 3
│   │   │   ├── pipeline.ex
│   │   │   ├── context_builder.ex
│   │   │   └── prompt_template.ex
│   │   └── ...
│   └── ragex.ex
├── mix.exs                 # MODIFIED: Add deps
├── test/
│   ├── ragex/
│   │   ├── ai/
│   │   │   ├── behaviour_test.exs
│   │   │   ├── config_test.exs
│   │   │   ├── provider/
│   │   │   │   └── deep_seek_r1_test.exs
│   │   │   └── integration_test.exs
│   │   ├── analyzers/
│   │   │   └── metastatic_test.exs
│   │   └── rag/
│   │       ├── pipeline_test.exs
│   │       └── context_builder_test.exs
│   └── ...
└── IMPLEMENTATION_PLAN.md  # THIS FILE
```
