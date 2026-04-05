defmodule Ragex.Agent.StreamConsumer do
  @moduledoc """
  Consumes a provider stream and accumulates a response compatible with `generate/3`.

  Forwards chunks to an optional callback in real-time while building
  the final response map. This bridges the gap between streaming providers
  and the Executor's generate-based loop.

  ## Usage

      {:ok, stream} = provider.stream_generate(prompt, context, opts)

      {:ok, response} = StreamConsumer.consume(stream,
        on_chunk: fn chunk -> IO.write(chunk.content) end,
        on_phase: fn phase -> IO.puts("Phase: \#{phase}") end
      )

      # response is compatible with provider.generate/3 return format:
      # %{content: "...", reasoning_content: "...", tool_calls: nil, usage: %{}, ...}
  """

  require Logger

  @type chunk :: %{
          content: String.t(),
          thinking: String.t() | nil,
          done: boolean(),
          metadata: map()
        }

  @type response :: %{
          content: String.t(),
          reasoning_content: String.t() | nil,
          tool_calls: nil,
          model: String.t() | nil,
          usage: map(),
          metadata: map()
        }

  @doc """
  Consume a provider stream, forwarding chunks to callbacks.

  Returns a response map compatible with what `provider.generate/3` returns.

  ## Options

  - `:on_chunk` - `(chunk -> :ok)` callback invoked for each content/thinking chunk
  - `:on_phase` - `(:thinking | :answering | :done -> :ok)` callback on phase transitions
  - `:on_tool_progress` - `(map() -> :ok)` callback for tool-call iteration progress

  ## Returns

  - `{:ok, response}` - Accumulated response (content may be empty if LLM returned tool_calls)
  - `{:error, reason}` - Stream produced an error
  """
  @spec consume(Enumerable.t(), keyword()) :: {:ok, response()} | {:error, term()}
  def consume(stream, opts \\ []) do
    on_chunk = Keyword.get(opts, :on_chunk, fn _chunk -> :ok end)
    on_phase = Keyword.get(opts, :on_phase, fn _phase -> :ok end)

    initial_acc = %{
      content: "",
      thinking: "",
      phase: :init,
      usage: %{},
      model: nil,
      metadata: %{},
      error: nil
    }

    result =
      Enum.reduce(stream, initial_acc, fn chunk, acc ->
        process_chunk(chunk, acc, on_chunk, on_phase)
      end)

    if result.error do
      {:error, result.error}
    else
      {:ok, build_response(result)}
    end
  rescue
    e ->
      Logger.error("StreamConsumer error: #{Exception.message(e)}")
      {:error, {:stream_consumer_error, Exception.message(e)}}
  end

  # Private functions

  defp process_chunk(
         %{thinking: thinking, done: false} = chunk,
         acc,
         on_chunk,
         on_phase
       )
       when is_binary(thinking) and thinking != "" do
    # Notify phase transition
    if acc.phase != :thinking, do: on_phase.(:thinking)

    on_chunk.(chunk)

    %{acc | thinking: acc.thinking <> thinking, phase: :thinking}
  end

  defp process_chunk(
         %{content: content, done: false} = chunk,
         acc,
         on_chunk,
         on_phase
       )
       when is_binary(content) and content != "" do
    # Notify phase transition
    if acc.phase != :answering, do: on_phase.(:answering)

    on_chunk.(chunk)

    %{acc | content: acc.content <> content, phase: :answering}
  end

  defp process_chunk(%{done: true, metadata: metadata}, acc, _on_chunk, on_phase) do
    on_phase.(:done)

    usage = Map.get(metadata, :usage, acc.usage)
    model = Map.get(metadata, :model, acc.model)

    %{acc | usage: usage, model: model, metadata: metadata, phase: :done}
  end

  defp process_chunk({:error, reason}, acc, _on_chunk, _on_phase) do
    Logger.warning("Stream error chunk: #{inspect(reason)}")
    %{acc | error: reason}
  end

  defp process_chunk(_other, acc, _on_chunk, _on_phase), do: acc

  defp build_response(result) do
    %{
      content: if(result.content == "", do: nil, else: result.content),
      reasoning_content: if(result.thinking == "", do: nil, else: result.thinking),
      tool_calls: nil,
      model: result.model,
      usage: normalize_usage(result.usage),
      metadata: Map.put(result.metadata, :streamed, true)
    }
  end

  defp normalize_usage(usage) when is_map(usage) do
    %{
      prompt_tokens: usage[:prompt_tokens] || usage["prompt_tokens"] || 0,
      completion_tokens: usage[:completion_tokens] || usage["completion_tokens"] || 0,
      total_tokens: usage[:total_tokens] || usage["total_tokens"] || 0
    }
  end

  defp normalize_usage(_), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
end
