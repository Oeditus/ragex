# Context Compaction

Ragex's context compaction system makes all MCP tool responses
token-efficient by default, reducing the context window pressure on AI
assistants by up to 50-70% for typical queries.

## How It Works

Every tool response passes through `Ragex.MCP.Formatter` before JSON
encoding. The formatter applies three transformations:

1. **Compaction** -- truncates long lists, strips verbose fields (docs,
   specs, long strings), removes bulk from nested items.
2. **Token budget** -- if `max_tokens` is specified, progressively reduces
   list sizes until the response fits the budget.
3. **Smart suggestions** -- appends `_suggestions` with actionable
   next-step hints based on the tool and result shape.

## Usage

All tools support two optional parameters (no changes to existing schemas required):

```json
{
  "name": "semantic_search",
  "arguments": {
    "query": "authentication",
    "verbose": false,
    "max_tokens": 500
  }
}
```

- `verbose` (boolean, default `false`) -- if `true`, skip compaction entirely.
  Returns the full result as before Phase F.
- `max_tokens` (integer, optional) -- approximate token budget. The formatter
  will progressively truncate to fit.

## Compact vs Verbose

### Compact (default)

- Lists capped at 10 items (configurable)
- Truncation metadata: `"truncated": {"results": 15}`
- Long strings (>200 chars) trimmed with `...`
- Nested items stripped of `:doc`, `:moduledoc`, `:specs`, `:body`
- `_suggestions` appended with next-step hints

### Verbose (`verbose: true`)

- Full result, unchanged from previous behavior
- No truncation, no stripping, no suggestions
- Use when you need complete detail for a specific query

## Smart Suggestions

In compact mode, results include `_suggestions` -- a list of actionable
strings telling the AI what to do next:

```json
{
  "results": [...],
  "truncated": {"results": 15},
  "_suggestions": [
    "15 more results -- use verbose=true to see all",
    "Use find_callers for 'MyModule.create_user/2' to see what depends on it"
  ]
}
```

Suggestions are tool-aware:

- `semantic_search` / `hybrid_search` -> suggest `find_callers`
- `find_callers` -> suggest `analyze_impact`
- `query_graph` (found) -> suggest `git_blame`
- `git_blame` -> suggest `git_history`
- `git_history` -> suggest `git_blame`
- `co_change_analysis` -> suggest `analyze_impact`
- `graph_stats` -> suggest `betweenness_centrality`, `detect_communities`
- `list_nodes` (partial) -> suggest increasing limit
- `find_dead_code` -> suggest `git_history`
- `analyze_quality` -> suggest `find_complex_code`

## Token Budget

When `max_tokens` is set, the formatter:

1. Estimates current token count (~4 chars/token heuristic)
2. If over budget, re-compacts with progressively smaller `max_items` (5, 3, 1)
3. Returns the smallest version that fits

This is a best-effort mechanism -- the estimate is approximate.

## Architecture

```
  MCP Client
      |
      v
  Server.handle_tools_call/2
      |
      |  1. Tools.call_tool(name, args)
      |     -> {:ok, raw_result}
      |
      |  2. Formatter.format(raw_result, name, opts)
      |     -> compacted_result
      |
      |  3. result_to_json -> :json.encode
      |     -> JSON text
      |
      v
  MCP Response
```

The formatter is protocol-based (`Ragex.MCP.Formattable`), so custom
structs can implement their own compaction logic:

```elixir
defimpl Ragex.MCP.Formattable, for: MyCustomResult do
  def compact(result, opts) do
    max = Keyword.get(opts, :max_items, 10)
    %{summary: result.summary, top: Enum.take(result.items, max)}
  end
end
```

## Configuration

No configuration required. The formatter is always active.
Use `verbose: true` per-request to bypass it.

## Backward Compatibility

- Existing tools work unchanged -- the formatter only adds behavior,
  never removes data when `verbose: true`.
- The `_suggestions` key uses a leading underscore to avoid collisions
  with existing result keys.
- Small results (no long lists, no verbose fields) pass through
  effectively unchanged even in compact mode.
