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

    url = "#{config.endpoint}/chat/completions"

    headers = [
      {"authorization", "Bearer #{config.api_key}"},
      {"content-type", "application/json"}
    ]

    parent = self()

    task =
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

    stream =
      Stream.resource(
        fn -> %{task: task, buffer: "", usage: %{}, model: config.model, done: false} end,
        fn state ->
          if state.done do
            {:halt, state}
          else
            receive_deepseek_chunks(state)
          end
        end,
        fn state ->
          if Process.alive?(state.task.pid), do: Task.shutdown(state.task, :brutal_kill)
          :ok
        end
      )

    {:ok, stream}
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
        # Optional: test API call - skip for now to avoid startup delay
        :ok
    end
  end

  @impl true
  def info do
    %{
      name: "DeepSeek R1",
      provider: :deepseek_r1,
      models: ["deepseek-chat", "deepseek-reasoner"],
      capabilities: [:generate, :stream, :function_calling, :tool_use],
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
    |> maybe_add_tools(opts)
    |> maybe_add_tool_choice(opts)
  end

  defp maybe_add_tools(body, opts) do
    case Keyword.get(opts, :tools) do
      nil -> body
      [] -> body
      tools when is_list(tools) -> Map.put(body, :tools, tools)
    end
  end

  defp maybe_add_tool_choice(body, opts) do
    case Keyword.get(opts, :tool_choice) do
      nil -> body
      choice -> Map.put(body, :tool_choice, choice)
    end
  end

  defp build_messages(prompt, nil, _opts) do
    [%{role: "user", content: prompt}]
  end

  defp build_messages(prompt, context, opts) when is_map(context) do
    context_content = format_context(context, opts)

    system_prompt = Keyword.get(opts, :system_prompt)

    messages =
      if system_prompt do
        [%{role: "system", content: system_prompt}]
      else
        []
      end

    messages ++
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
      # Already added to messages
      _system_prompt -> body
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
    message = get_in(body, ["choices", Access.at(0), "message"]) || %{}

    content = message["content"]
    tool_calls = parse_tool_calls(message["tool_calls"])

    usage = Map.get(body, "usage", %{})
    model = Map.get(body, "model", "unknown")
    finish_reason = get_in(body, ["choices", Access.at(0), "finish_reason"])

    {:ok,
     %{
       content: content,
       tool_calls: tool_calls,
       model: model,
       usage: usage,
       metadata: %{
         raw_response: body,
         finish_reason: finish_reason
       }
     }}
  end

  defp parse_response(_), do: {:error, "Invalid response format"}

  defp parse_tool_calls(nil), do: nil
  defp parse_tool_calls([]), do: nil

  defp parse_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      arguments =
        case Jason.decode(tc["function"]["arguments"] || "{}") do
          {:ok, args} -> args
          _ -> %{}
        end

      %{
        id: tc["id"],
        name: tc["function"]["name"],
        arguments: arguments
      }
    end)
  end

  defp receive_deepseek_chunks(state) do
    receive do
      {:stream_chunk, data} ->
        new_buffer = state.buffer <> data
        {events, remaining} = extract_sse_events(new_buffer)

        {chunks, new_state} =
          Enum.flat_map_reduce(events, %{state | buffer: remaining}, fn event, acc ->
            case parse_deepseek_event(event) do
              {:chunk, chunk, usage} ->
                updated_acc = if usage, do: %{acc | usage: usage}, else: acc
                {[chunk], updated_acc}

              {:done, finish_reason, usage} ->
                final_usage = usage || acc.usage

                final_chunk = %{
                  content: "",
                  done: true,
                  metadata: %{
                    finish_reason: finish_reason,
                    provider: :deepseek_r1,
                    model: acc.model,
                    usage: final_usage
                  }
                }

                {[final_chunk], %{acc | done: true}}

              :skip ->
                {[], acc}
            end
          end)

        {chunks, new_state}

      :stream_done ->
        if state.done do
          {:halt, state}
        else
          final_chunk = %{
            content: "",
            done: true,
            metadata: %{
              finish_reason: "stop",
              provider: :deepseek_r1,
              model: state.model,
              usage: state.usage
            }
          }

          {[final_chunk], %{state | done: true}}
        end

      {:stream_error, error} ->
        {[{:error, error}], %{state | done: true}}
    after
      30_000 -> {[{:error, :timeout}], %{state | done: true}}
    end
  end

  defp extract_sse_events(buffer) do
    case String.split(buffer, "\n\n") do
      [] ->
        {[], ""}

      [incomplete] ->
        {[], incomplete}

      parts ->
        [incomplete | complete_reversed] = Enum.reverse(parts)
        {Enum.reverse(complete_reversed), incomplete}
    end
  end

  defp parse_deepseek_event("data: [DONE]" <> _), do: {:done, "stop", nil}

  defp parse_deepseek_event("data: " <> json_str) do
    with {:ok, data} <- Jason.decode(String.trim(json_str)),
         %{"choices" => [choice | _]} <- data do
      delta = choice["delta"] || %{}
      content = delta["content"] || ""
      finish_reason = choice["finish_reason"]
      usage = data["usage"]

      cond do
        finish_reason != nil ->
          {:done, finish_reason, usage}

        content != "" ->
          chunk = %{content: content, done: false, metadata: %{provider: :deepseek_r1}}
          {:chunk, chunk, usage}

        true ->
          :skip
      end
    else
      _ -> :skip
    end
  end

  defp parse_deepseek_event(_), do: :skip

  defp valid_endpoint?(endpoint) do
    String.starts_with?(endpoint, "https://api.deepseek.com")
  end

  defp valid_model?(model) when is_binary(model) do
    model in ["deepseek-chat", "deepseek-reasoner"]
  end

  defp valid_model?(_), do: false
end
