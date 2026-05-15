# Deeper Indexing: Strings, Comments, Keywords

Phase I enriches the Ragex knowledge graph with metadata extracted from string
literals, inline comments, and derived keywords. This enables searching for SQL
queries, error messages, TODO markers, and domain-specific terms embedded in code.

## Architecture

```
Source Code
     |
     v
DeeperIndexing.extract/3  -- extracts strings & comments per function
     |
     v
Keywords.extract/1         -- derives weighted keywords from all sources
     |
     v
Store.update_node_metadata -- merges into graph function nodes
     |
     v
TextGenerator.function_text/1  -- includes strings/keywords in embedding text
```

## Modules

### `Ragex.Analyzers.DeeperIndexing`

Post-processing pass that runs after the primary language analyzer. Language-aware
extraction for Elixir, Erlang, Python, and JavaScript/TypeScript.

- `extract/3` -- returns `%{strings: %{func_key => [str, ...]}, comments: %{...}}`
- `merge_into_analysis/2` -- merges enrichment into the analysis result
- `extract_strings/2` -- public, language-specific string extraction
- `extract_comments/2` -- public, language-specific comment extraction

### `Ragex.Search.Keywords`

Extracts weighted keywords from multiple sources with differential boosting:

- Documentation: 1.5x
- Function/module names: 1.0x
- Type specs: 0.9x
- String literals: 0.8x
- Comments: 0.6x

### `Store.update_node_metadata/3`

Merges additional metadata into existing graph nodes without replacing the node.

## MCP Tools

### `search_strings`

Search for string literals across the indexed codebase.

```json
{
  "name": "search_strings",
  "arguments": {
    "query": "INSERT INTO",
    "limit": 20
  }
}
```

Returns matching strings with their enclosing function, file, and line number.

### `match_source` parameter

Added to `semantic_search` and `hybrid_search`:

```json
{
  "name": "semantic_search",
  "arguments": {
    "query": "database query",
    "match_source": "strings"
  }
}
```

Values: `all` (default), `docs`, `strings`, `comments`, `names`.

## Integration with Embeddings

When a file is analyzed via `analyze_file`, the deeper indexing pass:

1. Extracts strings and comments from the source
2. Associates them with the nearest function by line proximity
3. Derives keywords with boosted weights
4. Stores metadata in graph nodes via `Store.update_node_metadata/3`
5. The enriched metadata feeds into `TextGenerator.function_text/1` for
   embedding generation, improving semantic search relevance

## Supported Languages

- **Elixir**: regex-based string extraction; `#`-style comment extraction
- **Erlang**: double-quoted string regex; `%`-style comments
- **Python**: single/double/triple-quoted strings; `#`-style comments
- **JavaScript/TypeScript**: template literals, quoted strings; `//` and `/* */` comments
