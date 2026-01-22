# Warp AI Coding Preferences for Ragex

This file contains guidelines and preferences for AI coding assistants working on the Ragex project.

## Project Overview

**Ragex** is a Hybrid Retrieval-Augmented Generation (RAG) system for multi-language codebase analysis. It's an MCP (Model Context Protocol) server that combines:
- Static code analysis with AST parsing
- Knowledge graph storage (ETS-based)
- Semantic search using local ML models (Bumblebee)
- Hybrid retrieval (symbolic + semantic)
- Advanced graph algorithms (PageRank, path finding, centrality)
- Safe code editing with atomic operations and validation
- Semantic refactoring with AST-aware transformations

## Technology Stack

- **Language**: Elixir 1.19+
- **Runtime**: Erlang/OTP 27+
- **ML Framework**: Bumblebee (Elixir ML library)
- **Storage**: ETS (in-memory) + file-based caching
- **Protocol**: MCP (Model Context Protocol) over stdio
- **Testing**: ExUnit
- **Supported Analysis**: Elixir, Erlang, Python, JavaScript/TypeScript

## Code Style & Conventions

### Elixir Style

1. **Follow Elixir conventions**:
   - Use `snake_case` for functions and variables
   - Use `PascalCase` for modules
   - Prefer pattern matching over conditionals
   - Use `with` for complex error handling chains

2. **Documentation**:
   - Always add `@moduledoc` for modules
   - Add `@doc` for public functions
   - Include `@spec` for public API functions
   - Use doctests where appropriate

3. **Function organization**:
   - Public functions first, then private
   - Group related functions together
   - Use `# Private functions` comment separator
   - Keep functions small and focused

4. **Error handling**:
   - Return `{:ok, result}` or `{:error, reason}` tuples
   - Use `with` for sequential operations
   - Log errors appropriately (Logger.error, Logger.warning)
   - Never crash on expected errors

### Example Code Style

```elixir
defmodule Ragex.Example do
  @moduledoc """
  Brief module description.
  
  Detailed explanation of what this module does.
  """
  
  alias Ragex.Graph.Store
  require Logger
  
  @doc """
  Public function with clear documentation.
  
  ## Parameters
  - `input`: Description of input
  - `opts`: Keyword list of options (default: [])
  
  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure
  
  ## Examples
  
      iex> Example.do_something("test")
      {:ok, "result"}
  """
  @spec do_something(String.t(), keyword()) :: {:ok, any()} | {:error, atom()}
  def do_something(input, opts \\ []) do
    # Implementation
  end
  
  # Private functions
  
  defp helper_function(arg) do
    # Implementation
  end
end
```

## Project Architecture

### Key Components

1. **MCP Server** (`lib/ragex/mcp/`)
   - Protocol handler (JSON-RPC 2.0)
   - Tool definitions and execution
   - stdio communication
   - Streaming notifications for progress tracking

2. **Analyzers** (`lib/ragex/analyzers/`)
   - Language-specific AST parsers
   - Auto-detection based on file extension
   - Directory traversal and batch processing

3. **Graph Store** (`lib/ragex/graph/`)
   - ETS-based knowledge graph
   - Node types: `:module`, `:function`, `:call`
   - Edge types: `:calls`, `:imports`, `:defines`
   - Algorithms: PageRank, path finding, centrality

4. **Embeddings** (`lib/ragex/embeddings/`)
   - Bumblebee integration (local ML)
   - Model registry (4 pre-configured models)
   - Persistence layer (file-based caching)
   - File tracker (incremental updates)

5. **Vector Store** (`lib/ragex/vector_store.ex`)
   - Cosine similarity search
   - k-NN queries
   - Parallel search

6. **Hybrid Retrieval** (`lib/ragex/retrieval/`)
   - Reciprocal Rank Fusion (RRF)
   - Multiple strategies (fusion, semantic-first, graph-first)

7. **Editor System** (`lib/ragex/editor/`)
   - Atomic file operations with backups
   - Multi-language syntax validation
   - Format integration (mix, rebar3, black, prettier)
   - Multi-file atomic transactions
   - Semantic refactoring (AST-aware)
   - MCP tool integration with progress notifications

## Development Practices

### Testing

1. **Always write tests** for new features
2. **Run tests before committing**: `mix test`
3. **Test coverage** for core algorithms
4. **Use descriptive test names**: `test "finds all paths between nodes"`
5. **Setup/teardown**: Use `setup` blocks for test isolation

### Performance

1. **Path finding limits**: Always use `max_paths` parameter (Phase 4D)
2. **Early stopping**: Implement early termination for expensive operations
3. **Caching**: Use ETS for in-memory caching
4. **Parallel processing**: Use `Task.async_stream` for batch operations
5. **Logging**: Use appropriate log levels (debug, info, warning, error)

### Git Commits

1. **Format code**: Run `mix format` before committing
2. **Descriptive messages**: Use conventional commit format
   - `feat:` for new features
   - `fix:` for bug fixes
   - `docs:` for documentation
   - `refactor:` for refactoring
   - `test:` for test additions
3. **Co-author attribution**: Include `Co-Authored-By: Warp <agent@warp.dev>` in commit messages when working with AI

## Implementation Phases

### Completed Phases ✅

- **Phase 1**: Foundation (MCP server, Elixir analyzer, graph store)
- **Phase 2**: Multi-language support (Erlang, Python, JavaScript/TypeScript)
- **Phase 3A**: Embeddings foundation (Bumblebee, local ML)
- **Phase 3B**: Vector store (cosine similarity, k-NN)
- **Phase 3C**: Semantic search tools (MCP integration)
- **Phase 3D**: Hybrid retrieval (RRF, multiple strategies)
- **Phase 3E**: Enhanced graph queries (PageRank, path finding, centrality)
- **Phase 4A**: Custom embedding models (model registry, configuration)
- **Phase 4B**: Embedding persistence (automatic caching, project-specific)
- **Phase 4C**: Incremental updates (file tracking, SHA256 hashing)
- **Phase 4D**: Path finding limits (max_paths, early stopping, dense graph warnings)
- **Phase 4E**: Documentation (ALGORITHMS.md, comprehensive guides)
- **Phase 5A**: Core editor infrastructure (atomic operations, backups, rollback)
- **Phase 5B**: Validation pipeline (multi-language syntax checking)
- **Phase 5C**: MCP edit tools + streaming notifications (edit_file, validate_edit, rollback_edit, edit_history, progress tracking)
- **Phase 5D**: Advanced editing (format integration, multi-file transactions)
- **Phase 5E**: Semantic refactoring (rename_function, rename_module via AST)
- **Phase 8**: Advanced graph algorithms (betweenness centrality, closeness centrality, community detection, visualization)
- **Phase 10A**: Enhanced refactoring (8 operations: extract_function, inline_function, convert_visibility, rename_parameter, modify_attributes, change_signature, move_function, extract_module, plus MCP integration)

### Future Work

- **Phase 6**: Production optimizations (performance tuning, caching strategies)
- **Phase 7**: Additional language support (Go, Rust, Java)
- **Phase 10B**: Multi-language refactoring (Erlang, Python, JavaScript/TypeScript)
- **Phase 10C**: Preview/diff generation, conflict detection, undo/redo stack

## Common Tasks

### Adding a New Algorithm

1. Add function to `lib/ragex/graph/algorithms.ex`
2. Write comprehensive tests in `test/graph/algorithms_test.exs`
3. Document in `ALGORITHMS.md` with:
   - Purpose and use cases
   - Parameters and options
   - Usage examples
   - Performance characteristics
4. Optionally expose as MCP tool in `lib/ragex/mcp/handlers/tools.ex`

### Adding a New Language Analyzer

1. Create analyzer module in `lib/ragex/analyzers/`
2. Implement `analyze/2` function returning standard format
3. Add to auto-detection in `lib/ragex/mcp/handlers/tools.ex`
4. Add file extensions to watcher patterns
5. Write tests in `test/analyzers/`
6. Update README.md with new language support

### Adding a New MCP Tool

1. Add tool definition in `list_tools/0` in `lib/ragex/mcp/handlers/tools.ex`
2. Add case clause in `call_tool/2`
3. Implement private handler function
4. Parse and validate parameters
5. Call appropriate backend functions
6. Format response properly
7. Add tests in `test/mcp/`

### Performing Safe Refactoring (Phase 5E)

**When to use semantic refactoring:**
- Renaming functions/modules across multiple files
- Need to update all call sites automatically
- Want AST-aware transformations (not regex)
- Require validation before and after

**Workflow:**
1. Ensure code is analyzed and in knowledge graph
2. Use `Refactor.rename_function/5` or `Refactor.rename_module/3`
3. Specify scope (`:module` or `:project`)
4. Enable validation and formatting (recommended)
5. Check result for success or rollback status

**Limitations:**
- Currently Elixir-only (Erlang/Python/JS planned)
- Requires files to be in knowledge graph
- AST manipulation may lose some formatting (use `:format` option)

### Safe Code Editing (Phase 5)

**Core Principles:**
- Always create backups before editing (unless explicitly disabled)
- Use atomic operations (write to temp file, then rename)
- Validate syntax before applying changes
- Check for concurrent modifications
- Support rollback to any previous version
- Format code after editing (optional)
- Support multi-file atomic transactions
- Enable semantic refactoring via AST manipulation

**Using the Editor API:**

```elixir
alias Ragex.Editor.{Core, Types, Transaction, Refactor}

# Single file edit with validation and formatting
changes = [Types.replace(10, 15, "new content")]
Core.edit_file("path/to/file.ex", changes, validate: true, format: true)

# Insert at line 20
changes = [Types.insert(20, "inserted content")]
Core.edit_file("path/to/file.ex", changes)

# Delete lines 5-8
changes = [Types.delete(5, 8)]
Core.edit_file("path/to/file.ex", changes)

# Multi-file atomic transaction
txn = Transaction.new(validate: true, format: true)
  |> Transaction.add("lib/file1.ex", changes1)
  |> Transaction.add("lib/file2.ex", changes2)
  |> Transaction.add("test/file_test.exs", changes3)

case Transaction.commit(txn) do
  {:ok, result} -> IO.puts("Edited #{result.files_edited} files")
  {:error, result} -> IO.puts("Rolled back, errors: #{inspect(result.errors)}")
end

# Semantic refactoring - rename function across project
Refactor.rename_function(:MyModule, :old_func, :new_func, 2)

# Rename function only within module
Refactor.rename_function(:MyModule, :old_func, :new_func, 2, scope: :module)

# Rename module
Refactor.rename_module(:OldModule, :NewModule)

# Rollback last edit
Core.rollback("path/to/file.ex")

# View history
{:ok, history} = Core.history("path/to/file.ex")
```

**Safety Guidelines:**
1. **Always validate** before writing (default behavior)
2. **Create backups** for all non-trivial edits (default behavior)
3. **Check file mtime** to detect concurrent changes
4. **Use temp files** for atomic writes
5. **Test changes** in isolation before applying
6. **Provide rollback** option to users
7. **Use transactions** for coordinated multi-file changes
8. **Validate AST** for semantic refactoring operations

**When to Skip Validation:**
- Never skip for user-facing edits
- Only skip for generated code you control
- Only skip when performance is critical AND you're certain code is valid
- Always log when validation is skipped

**Backup Management:**
- Backups stored in `~/.ragex/backups/<project_hash>/`
- Default retention: 10 backups per file
- Automatic cleanup of old backups
- Optional compression (disabled by default)

**Format Integration:**
- Automatic formatter detection (mix, rebar3, black, prettier)
- Project-aware (finds project root for context)
- Graceful degradation (format failures don't break edits)

**Multi-File Transactions:**
- All-or-nothing atomicity
- Coordinated backups
- Pre-validation of all files
- Automatic rollback on any failure
- Per-file option overrides

**Semantic Refactoring:**
- AST-aware transformations (Elixir)
- Knowledge graph integration for call site discovery
- Project-wide or module-scoped
- Automatic call site updates
- Arity-aware renaming

### Advanced Refactoring Operations (Phase 10A)

**Phase 10A adds 8 sophisticated refactoring operations accessible via the `advanced_refactor` MCP tool:**

1. **Extract Function**: Extract code range into new function with automatic parameter inference
2. **Inline Function**: Replace all calls with function body, remove definition
3. **Convert Visibility**: Toggle between `def` and `defp` (public/private)
4. **Rename Parameter**: Rename parameter within function scope
5. **Modify Attributes**: Add/remove/update module attributes
6. **Change Signature**: Add/remove/reorder/rename parameters with call site updates
7. **Move Function**: Move function between modules with reference updates
8. **Extract Module**: Extract multiple functions into new module with file creation

**Using via MCP Tool:**
```json
{
  "name": "advanced_refactor",
  "arguments": {
    "operation": "extract_function",
    "params": {
      "module": "MyModule",
      "source_function": "process",
      "source_arity": 2,
      "new_function": "validate",
      "line_start": 45,
      "line_end": 52
    },
    "validate": true,
    "format": true
  }
}
```

**Using via API:**
```elixir
alias Ragex.Editor.Refactor

# Extract function
Refactor.extract_function(:MyModule, :process, 2, :validate, {45, 52})

# Inline function
Refactor.inline_function(:MyModule, :helper, 1)

# Convert visibility
Refactor.convert_visibility(:MyModule, :process, 2, :private)

# Rename parameter
Refactor.rename_parameter(:MyModule, :process, 2, "data", "input")

# Modify attributes
Refactor.modify_attributes(:MyModule, [
  {:add, :behaviour, "GenServer"},
  {:update, :moduledoc, "New docs"}
])

# Change signature
Refactor.change_signature(:MyModule, :process, 2, [
  {:add, "opts", 2, []}
])

# Move function
Refactor.move_function(:SourceModule, :TargetModule, :helper, 1)

# Extract module
Refactor.extract_module(:MyModule, :MyModule.Helpers, [
  {:helper1, 1},
  {:helper2, 2}
])
```

**Key Features:**
- All operations use atomic transactions with automatic rollback
- AST-aware transformations preserve code structure
- Knowledge graph integration for cross-file updates
- Optional validation and formatting
- Comprehensive error reporting with rollback details
- See `ADVANCED_REFACTOR_MCP.md` for detailed documentation

### MCP Streaming Notifications (Phase 5C)

**Overview:**
The MCP server supports streaming notifications for real-time progress tracking during long-running operations.

**Notification Methods:**
- `editor/progress`: Progress events for edit operations
- `analyzer/progress`: Progress events for directory analysis

**Editor Progress Events:**
- `transaction_start`: Multi-file transaction initiated
- `validation_start`: Validation phase starting
- `validation_complete`: Validation finished
- `apply_start`: Starting to apply edits
- `apply_file`: Processing individual file (includes current/total)
- `rollback_start`: Starting rollback
- `rollback_file`: Rolling back individual file
- `rollback_complete`: Rollback finished

**Analyzer Progress Events:**
- `analysis_start`: Directory analysis initiated (includes file counts)
- `analysis_file`: Processing individual file (includes current/total, status)
- `analysis_complete`: Analysis finished (includes success/error counts)

**Example Notification:**
```json
{
  "jsonrpc": "2.0",
  "method": "editor/progress",
  "params": {
    "event": "apply_file",
    "params": {
      "path": "lib/file1.ex",
      "current": 1,
      "total": 3
    },
    "timestamp": "2026-01-22T16:54:30Z"
  }
}
```

**Implementation:**
- Notifications sent asynchronously via GenServer cast
- No blocking on delivery
- Graceful degradation if MCP server not running
- See PHASE5C_COMPLETE.md for full details

### Advanced Graph Algorithms (Phase 8)

**Centrality Metrics:**
- **Betweenness centrality**: Identify bridge/bottleneck functions
  - Uses Brandes' algorithm (O(nm) complexity)
  - Configurable max_nodes limit for large graphs
  - Normalized scores (0-1 range)
- **Closeness centrality**: Identify central functions
  - Average distance-based metric
  - Handles disconnected components

**Community Detection:**
- **Louvain method**: Modularity optimization
  - Discovers architectural modules/clusters
  - Hierarchical structure support
  - Configurable resolution parameter
- **Label propagation**: Fast alternative
  - O(m) per iteration
  - Deterministic with random seed
  - Converges quickly (typically <10 iterations)

**Weighted Edges:**
- Edge weight support in Store (default: 1.0)
- Call frequency tracking
- Weighted algorithms (modularity, centrality)

**Visualization Export:**
- **Graphviz DOT format**: For visualization tools
  - Community clustering as subgraphs
  - Node coloring by centrality metrics
  - Edge thickness by weight
- **D3.js JSON format**: For web visualization
  - Force-directed graph format
  - Node/edge attributes with metrics
  - Community metadata

**Usage:**
```elixir
# Compute betweenness centrality
scores = Algorithms.betweenness_centrality(max_nodes: 100)

# Detect communities with Louvain
communities = Algorithms.detect_communities(hierarchical: true)

# Export graph visualization
{:ok, dot} = Algorithms.export_graphviz(color_by: :betweenness)
{:ok, json} = Algorithms.export_d3_json(include_communities: true)
```

**MCP Tools:**
- `betweenness_centrality`: Compute betweenness scores
- `closeness_centrality`: Compute closeness scores
- `detect_communities`: Run community detection
- `export_graph`: Export in Graphviz/D3 format

## Performance Considerations

### Dense Graphs

When working with dense graphs (nodes with many edges):
- Always use `max_paths` limits (default: 100)
- Set `max_depth` conservatively (default: 10)
- Enable `warn_dense` for user feedback
- Consider using `graph_stats` to check density first

### Large Codebases

For large codebases (>10,000 entities):
- Use incremental updates (Phase 4C)
- Enable caching (Phase 4B)
- Batch operations with parallel processing
- Consider filtering before expensive operations

### Memory Management

- ETS tables are memory-efficient but grow linearly
- Embeddings: ~400 bytes per entity (384 dimensions)
- Cache files: ~15MB per 1,000 entities
- ML model: ~400MB RAM footprint

## Documentation Standards

### When to Document

1. **Always**:
   - New algorithms or complex logic
   - Public API functions
   - Configuration options
   - Breaking changes

2. **Update**:
   - README.md for major features
   - Phase completion docs (PHASE*_COMPLETE.md)
   - ALGORITHMS.md for algorithm changes
   - CONFIGURATION.md for config changes
   - PERSISTENCE.md for caching changes
   - WARP.md when completing phases or adding capabilities

### Documentation Format

- Use Markdown
- Include code examples
- Add performance characteristics
- Provide usage scenarios
- Link related documentation

## Common Pitfalls to Avoid

1. **Don't** modify graph while iterating
2. **Don't** use unlimited path finding on dense graphs
3. **Don't** assume file encoding (use binary mode for hashing)
4. **Don't** forget to track files after analysis (Phase 4C)
5. **Don't** cache embeddings without model validation (Phase 4B)
6. **Don't** use blocking operations in the MCP server loop

## Helpful Commands

```bash
# Run all tests
mix test

# Run specific test file
mix test test/graph/algorithms_test.exs

# Run with coverage
mix test --cover

# Format code
mix format

# Check code quality
mix credo

# Generate documentation
mix docs

# Analyze directory
mix ragex.cache.refresh --path /path/to/code

# Check cache status
mix ragex.cache.stats

# Clear cache
mix ragex.cache.clear
```

## External Resources

- [MCP Protocol Specification](https://spec.modelcontextprotocol.io/)
- [Elixir Documentation](https://hexdocs.pm/elixir/)
- [Bumblebee Documentation](https://hexdocs.pm/bumblebee/)
- [Sentence Transformers](https://www.sbert.net/)
- [PageRank Algorithm](https://en.wikipedia.org/wiki/PageRank)

## Questions or Issues?

For architectural decisions or complex changes:
1. Check existing phase completion documents (PHASE*_COMPLETE.md)
2. Review ALGORITHMS.md for algorithm details
3. Check CONFIGURATION.md for config options
4. Read PERSISTENCE.md for caching behavior
5. Refer to test files for usage examples

## Project Philosophy

1. **Local-first**: No external API dependencies for core functionality
2. **Performance**: Sub-100ms queries for typical operations
3. **Incremental**: Smart caching and differential updates
4. **Extensible**: Easy to add new languages and algorithms
5. **Well-tested**: Comprehensive test coverage
6. **Documented**: Clear documentation with examples
7. **Production-ready**: Robust error handling and performance optimizations

---

**Last Updated**: January 1, 2026  
**Ragex Version**: 0.2.0  
**Status**: Production-ready (Phases 1-5, 8 complete)
