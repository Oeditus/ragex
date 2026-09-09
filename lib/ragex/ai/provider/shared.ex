defmodule Ragex.AI.Provider.Shared do
  @moduledoc """
  Helpers shared by the AI provider implementations
  (`Ragex.AI.Provider.Anthropic`, `Ragex.AI.Provider.OpenAI`,
  `Ragex.AI.Provider.DeepSeekR1`).

  Extracted because `mix credo --strict` (`Credo.Check.Design.DuplicatedCode`)
  found each of these pieces of logic copy-pasted near-identically across two
  or three provider modules:

  - `resolve_config/3` / `resolve_api_key/2`: the `opts > provider config >
    default` resolution used by Anthropic and OpenAI's private `get_config/1`
    and `get_api_key/0` functions.
  - `to_api_message/1`, `format_api_tool_calls/1`: the OpenAI-compatible chat
    message/tool-call formatting duplicated byte-for-byte between OpenAI and
    DeepSeekR1.
  - `start_streaming_task/3`: the `Task.async` + `Req.post(..., into: ...)`
    SSE launcher duplicated across all three providers' `stream_api`/
    `stream_generate` implementations.

  Each provider still owns its own event-parsing loop (Anthropic, OpenAI, and
  DeepSeek use different SSE payload shapes), so only the genuinely identical
  plumbing lives here.
  """

  @type provider_config :: %{
          endpoint: String.t(),
          model: String.t(),
          temperature: float(),
          max_tokens: pos_integer(),
          stream: boolean()
        }

  @doc """
  Resolves provider request config with `opts > application provider config >
  defaults` precedence, matching the pattern previously duplicated in each
  provider's private `get_config/1`.
  """
  @spec resolve_config(atom(), keyword(), provider_config()) :: provider_config()
  def resolve_config(provider_key, opts, defaults) when is_atom(provider_key) do
    provider_config = Application.get_env(:ragex, :ai_providers, [])[provider_key] || []

    %{
      endpoint:
        Keyword.get(opts, :endpoint) ||
          Keyword.get(provider_config, :endpoint) ||
          defaults.endpoint,
      model:
        Keyword.get(opts, :model) ||
          Keyword.get(provider_config, :model) ||
          defaults.model,
      temperature:
        Keyword.get(opts, :temperature) ||
          Keyword.get(provider_config, :temperature) ||
          defaults.temperature,
      max_tokens:
        Keyword.get(opts, :max_tokens) ||
          Keyword.get(provider_config, :max_tokens) ||
          defaults.max_tokens,
      stream: Keyword.get(opts, :stream, false)
    }
  end

  @doc """
  Resolves this provider's API key: runtime `:ai_keys` config first, falling
  back to the given environment variable.
  """
  @spec resolve_api_key(atom(), String.t()) :: {:ok, String.t()} | {:error, :no_api_key}
  def resolve_api_key(provider_key, env_var) when is_atom(provider_key) and is_binary(env_var) do
    case Application.get_env(:ragex, :ai_keys, [])[provider_key] do
      key when is_binary(key) and byte_size(key) > 0 ->
        {:ok, key}

      _ ->
        case System.get_env(env_var) do
          key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
          _ -> {:error, :no_api_key}
        end
    end
  end

  @doc "Converts a generic (atom- or string-keyed) message map into OpenAI-compatible API format."
  @spec to_api_message(map()) :: map()
  def to_api_message(msg) do
    role = msg[:role] || msg["role"]
    content = msg[:content] || msg["content"]
    tool_calls = msg[:tool_calls] || msg["tool_calls"]
    tool_call_id = msg[:tool_call_id] || msg["tool_call_id"]
    name = msg[:name] || msg["name"]

    api_msg = %{
      role: to_string(role),
      content: content || ""
    }

    api_msg =
      if tool_calls do
        Map.put(api_msg, :tool_calls, format_api_tool_calls(tool_calls))
      else
        api_msg
      end

    api_msg =
      if tool_call_id do
        Map.put(api_msg, :tool_call_id, tool_call_id)
      else
        api_msg
      end

    if name do
      Map.put(api_msg, :name, name)
    else
      api_msg
    end
  end

  @doc "Formats tool-call structs (atom- or string-keyed) into OpenAI-compatible API format."
  @spec format_api_tool_calls([map()]) :: [map()]
  def format_api_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        id: tc[:id] || tc["id"],
        type: "function",
        function: %{
          name: tc[:name] || tc["name"] || tc[:function][:name] || tc["function"]["name"],
          arguments:
            format_api_tool_args(
              tc[:arguments] || tc["arguments"] || tc[:function][:arguments] ||
                tc["function"]["arguments"]
            )
        }
      }
    end)
  end

  defp format_api_tool_args(args) when is_binary(args), do: args
  defp format_api_tool_args(args) when is_map(args), do: Jason.encode!(args)
  defp format_api_tool_args(_), do: "{}"

  @doc """
  Launches a background `Task` that POSTs an SSE request and forwards each
  chunk to the calling process as `{:stream_chunk, data}`, followed by either
  `:stream_done` or `{:stream_error, reason}`.

  Callers are expected to build their own `Stream.resource/3` around
  `receive`, since each provider parses a different SSE event shape.
  """
  @spec start_streaming_task(String.t(), map(), keyword()) :: Task.t()
  def start_streaming_task(url, body, headers) do
    parent = self()

    Task.async(fn ->
      case Req.post(url,
             json: body,
             headers: headers,
             into: fn {:data, data}, {req, resp} ->
               send(parent, {:stream_chunk, data})
               {:cont, {req, resp}}
             end
           ) do
        {:ok, %{status: 200}} ->
          send(parent, :stream_done)
          :ok

        {:ok, response} ->
          send(parent, {:stream_error, {:api_error, response.status, response.body}})
          {:error, {:api_error, response.status}}

        {:error, reason} ->
          send(parent, {:stream_error, {:http_error, reason}})
          {:error, {:http_error, reason}}
      end
    end)
  end
end
