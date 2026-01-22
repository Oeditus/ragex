# Streaming Responses in Ragex

This document explains the streaming response functionality added in Phase 5A.

## Overview

Ragex now supports streaming responses from all four AI providers:
- **OpenAI**: GPT-4, GPT-4-turbo, GPT-3.5-turbo (SSE format)
- **Anthropic**: Claude 3 Opus/Sonnet/Haiku (SSE format with event types)
- **DeepSeek**: deepseek-chat, deepseek-reasoner (SSE format, OpenAI-compatible)
- **Ollama**: Local LLMs (NDJSON format)

Streaming provides real-time response generation, allowing for:
- Progressive UI updates as content arrives
- Lower perceived latency for long responses
- Better user experience for interactive applications
- Token usage tracking in real-time

## Architecture

### Provider Level (lib/ragex/ai/provider/)

Each provider implements the `stream_generate/3` callback defined in `Ragex.AI.Behaviour`:

```elixir
@callback stream_generate(prompt :: String.t(), context :: map() | nil, opts) ::
            {:ok, Enumerable.t(chunk())} | {:error, term()}
```

**Chunk format:**
```elixir
%{
  content: String.t(),     # Incremental content
  done: boolean(),          # true for final chunk
  metadata: map()           # Provider info, usage stats (on final chunk)
}
```

**Implementation pattern:**
1. Initiate HTTP streaming request with `Req.post(..., into: fn {:data, data}, {req, resp} -> ...)`
2. Use `Task.async` to handle streaming in separate process
3. Use `Stream.resource` to create Elixir stream from HTTP chunks
4. Parse SSE/NDJSON events and extract content deltas
5. Track token usage and include in final chunk metadata

**Error handling:**
- HTTP errors: `{:error, {:api_error, status, body}}`
- Network errors: `{:error, {:http_error, reason}}`
- Timeouts: 30-second receive timeout per provider

### Pipeline Level (lib/ragex/rag/pipeline.ex)

Three new streaming functions:

```elixir
# Query with streaming
Pipeline.stream_query(user_query, opts)

# Explain with streaming
Pipeline.stream_explain(target, aspect, opts)

# Suggest with streaming
Pipeline.stream_suggest(target, focus, opts)
```

**Features:**
- Automatic usage tracking (records tokens on final chunk)
- Source attribution (added to final chunk metadata)
- Rate limiting (checked before starting stream)
- Retrieval context injection (same as non-streaming)

**Options:**
- `:stream_metadata` - Include sources in every chunk (default: false)
- All standard RAG options (`:limit`, `:threshold`, `:provider`, etc.)

### MCP Tools Level (lib/ragex/mcp/handlers/tools.ex)

Three new MCP tools:

```text
rag_query_stream    - Streaming version of rag_query
rag_explain_stream  - Streaming version of rag_explain
rag_suggest_stream  - Streaming version of rag_suggest
```

**Current behavior (Phase 5A):**
- Collects all chunks internally
- Returns complete response (non-streaming from MCP perspective)
- Optional `show_chunks` parameter for debugging

**Future (Phase 5C):**
- Full MCP notification protocol support
- Real-time chunk delivery to MCP clients
- Cancellation via MCP protocol

## Usage Examples

### Direct Provider Usage

```elixir
alias Ragex.AI.Provider.OpenAI

# Start streaming
{:ok, stream} = OpenAI.stream_generate(
  "Explain this code",
  %{context: "def foo, do: :bar"},
  temperature: 0.7
)

# Consume stream
Enum.each(stream, fn
  %{done: false, content: chunk} ->
    IO.write(chunk)  # Print as it arrives
  
  %{done: true, metadata: meta} ->
    IO.puts("\n\nUsage: #{inspect(meta.usage)}")
  
  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end)
```

### RAG Pipeline Usage

```elixir
alias Ragex.RAG.Pipeline

# Stream a query
{:ok, stream} = Pipeline.stream_query("How does auth work?", limit: 5)

# Accumulate content
content = 
  stream
  |> Stream.filter(fn %{done: done} -> not done end)
  |> Stream.map(fn %{content: c} -> c end)
  |> Enum.join()

# Get final metadata
final_chunk = 
  stream
  |> Enum.find(fn %{done: done} -> done end)

IO.puts("Response: #{content}")
IO.puts("Sources: #{length(final_chunk.metadata.sources)}")
```

### MCP Tool Usage

Via MCP client:

```json
{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "params": {
    "name": "rag_query_stream",
    "arguments": {
      "query": "Explain the authentication flow",
      "limit": 5,
      "provider": "openai",
      "show_chunks": true
    }
  }
}
```

Response:

```json
{
  "status": "success",
  "query": "Explain the authentication flow",
  "response": "The authentication flow consists of...",
  "sources_count": 3,
  "model_used": "gpt-4-turbo",
  "streaming": true,
  "chunks_count": 12,
  "chunks": [...]  // Only if show_chunks: true
}
```

## Protocol Details

### OpenAI SSE Format

```text
data: {"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}

data: {"choices":[{"delta":{"content":" world"},"finish_reason":null}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5}}

data: [DONE]
```

### Anthropic SSE Format

```text
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

event: content_block_delta
data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}

event: content_block_delta
data: {"type":"content_block_delta","delta":{"type":"text_delta","text":" world"}}

event: message_delta
data: {"type":"message_delta","usage":{"output_tokens":5}}

event: message_stop
data: {"type":"message_stop"}
```

### Ollama NDJSON Format

```json
{"model":"codellama","response":"Hello","done":false}
{"model":"codellama","response":" world","done":false}
{"model":"codellama","response":"","done":true}
```

## Performance Characteristics

**Latency:**
- First chunk: ~200-500ms (same as non-streaming)
- Subsequent chunks: ~50-100ms intervals
- Total time: Same as non-streaming (no overhead)

**Token Usage:**
- Tracked identically to non-streaming
- Reported in final chunk metadata
- Recorded via Usage module for cost tracking

**Memory:**
- Constant memory per stream (buffering only incomplete events)
- No accumulation until explicitly collected

**Cancellation:**
- Streams can be stopped early by halting enumeration
- Task cleanup via Stream.resource cleanup function
- 30-second receive timeout prevents hanging

## Error Scenarios

| Error | When | Handling |
|-------|------|----------|
| API Error (4xx/5xx) | HTTP status != 200 | `{:error, {:api_error, status, body}}` |
| Network Error | Connection lost | `{:error, {:http_error, reason}}` |
| Timeout | No data for 30s | `{:error, :timeout}` in stream |
| Rate Limit | Before request | `{:error, {:rate_limited, reason}}` |
| Invalid JSON | SSE/NDJSON parse | Skip chunk, continue stream |

## Configuration

No additional configuration required. Streaming uses the same provider settings as non-streaming:

```elixir
config :ragex, :ai_providers,
  openai: [
    endpoint: "https://api.openai.com/v1",
    model: "gpt-4-turbo",
    options: [
      temperature: 0.7,
      max_tokens: 2048
    ]
  ]
```

## Future Enhancements (Phase 5C)

1. **Full MCP Streaming Protocol**
   - Emit JSON-RPC notifications for each chunk
   - Cancellation support via MCP protocol
   - Progress indicators

2. **Advanced Features**
   - Stream caching (cache reconstructed from chunks)
   - Concurrent multi-provider streaming (race/merge strategies)
   - Stream transformations (filtering, augmentation)

3. **Performance Optimizations**
   - Adaptive buffering based on chunk size
   - Connection pooling for multiple streams
   - Predictive prefetching

## Limitations

**Current (Phase 5A):**
- MCP tools collect all chunks before returning (no real-time emission)
- Streaming responses not cached (cache lookup still happens)
- No built-in cancellation API (must drop stream reference)

**Protocol:**
- OpenAI: Requires `stream_options: %{include_usage: true}` for token counts
- Anthropic: Usage split across message_start and message_delta events
- Ollama: Token counts are estimated (not provided by API)

## Troubleshooting

**Stream hangs or times out:**
- Check network connectivity
- Verify API key is valid
- Increase timeout if needed (modify receive after clause)

**Chunks arrive slowly:**
- Normal behavior (depends on model response time)
- Larger prompts take longer to process
- Use faster models (gpt-3.5-turbo vs gpt-4)

**Missing final chunk:**
- Check for errors in stream
- Ensure stream is fully consumed
- Look for `:stream_done` or `:stream_error` messages

**Token counts are zero:**
- OpenAI: Ensure API supports stream_options
- Anthropic: Check for message_delta event
- Ollama: Counts are estimated, may be rough

## See Also

- `lib/ragex/ai/behaviour.ex` - Streaming callback definition
- `lib/ragex/ai/provider/*` - Provider implementations
- `lib/ragex/rag/pipeline.ex` - Pipeline streaming functions
- `lib/ragex/mcp/handlers/tools.ex` - MCP streaming tools
- `PHASE5A_COMPLETE.md` - Phase 5A completion summary
