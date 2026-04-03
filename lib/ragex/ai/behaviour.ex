defmodule Ragex.AI.Behaviour do
  @moduledoc """
  Defines the behaviour for AI provider implementations.

  This abstraction allows Ragex to support multiple AI providers
  (DeepSeek, OpenAI, Anthropic, local LLMs) with a unified interface.
  """

  @typedoc "AI provider response"
  @type response :: %{
          content: String.t(),
          reasoning_content: String.t() | nil,
          model: String.t(),
          usage: map(),
          metadata: map()
        }

  @typedoc "Streaming chunk from AI provider"
  @type chunk :: %{
          content: String.t(),
          thinking: String.t() | nil,
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
