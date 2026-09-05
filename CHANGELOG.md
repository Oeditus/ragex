# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.29.0]

### Changed

- `bumblebee`, `nx`, `exla`, and `image` are now `optional: true` dependencies
  in `mix.exs`. These are native/NIF-backed libraries that cannot load from
  inside an `mix escript.build` archive (their shared objects are packed in
  the escript zip, not present on a real filesystem path), which previously
  crashed the entire OTP boot chain for any downstream consumer building an
  escript against ragex.
- `Ragex.Application` now skips starting `Ragex.Embeddings.Bumblebee` and
  `Ragex.VectorStore` automatically when `bumblebee`/`nx`/`exla` are absent
  from the build, in addition to the existing `config :ragex, skip_bumblebee:
  true` manual override.
- Added `Ragex.Embeddings.Bumblebee.available?/0` and `Ragex.Image.available?/0`,
  which use `Code.ensure_loaded?/1` to detect the optional ML/image
  dependencies at runtime, mirroring the existing
  `Ragex.Git.Backend.egit_available?/0` pattern for the optional `egit` NIF.
- `mix ragex.models.download` now fails fast with a clear error message
  instead of an `UndefinedFunctionError` when the optional ML dependencies
  are not present in the build.
- `mix ragex.cache.stats` and the `ragex://model/config` MCP resource now
  report embedding-model unavailability clearly instead of raising when the
  embedding server has not started.
- Image MCP tools (`image_*`) now return a clear
  `{:error, "Image processing unavailable..."}` tuple instead of crashing
  when the optional `:image` dependency is absent.
- Fixed a compile-time-only break: `lib/ragex/image.ex` matched on the
  `%Image.Error{}` struct literal, which fails to compile when `:image` is
  not fetched. Replaced with an equivalent plain-map pattern.

### Added

- `scripts/verify_optional_ml_deps.sh` -- verifies, in an isolated temporary
  copy of the repository, that ragex compiles and `Ragex.Application` boots
  successfully with `bumblebee`/`nx`/`exla`/`image` genuinely removed from
  `mix.exs` and `mix.lock` (not just unstarted via configuration).

## [0.11.0]

### Changed

#### `mix ragex.chat` — agent-based RAG via Ragex MCP tools

User queries are now answered exclusively by the agent executor (ReAct loop)
instead of the previous two-path approach (pipeline first, agent fallback).
The AI actively calls Ragex MCP query tools (`hybrid_search`, `semantic_search`,
`read_file`, `query_graph`, `find_callers`, etc.) to retrieve relevant code
context before composing its answer.  This means the AI drives the retrieval
rather than having pre-fetched context injected on its behalf.

Behavioural changes:
- The `--strategy` option is accepted for compatibility but no longer has any
  effect; all queries go through the agent ReAct loop.
- Blocking `Core.chat/3` is always used (not streaming) to ensure tool-call
  responses are captured correctly on providers that mix content and tool_call
  deltas (e.g. DeepSeek R1).
- The conversation system prompt no longer caps tool calls at 2-3 per turn;
  the AI may call as many tools as needed for a thorough answer.
- The old `render_stream` / `Pipeline.stream_query` path has been removed.

#### `mix ragex.audit` — AI report enriched with RAG evidence retrieval

The AI assistant generating the audit report can now call read-only Ragex MCP
query tools to retrieve concrete code-level evidence for its findings (e.g.
quote an actual function body, confirm a circular dependency path, or check
coupling metrics) rather than being limited to the pre-computed statistics
alone.

The tool set passed to the executor is restricted to `ToolSchema.rag_tool_names/0`
(10 read-only tools: `read_file`, `semantic_search`, `hybrid_search`,
`query_graph`, `list_nodes`, `find_callers`, `find_paths`,
`find_circular_dependencies`, `coupling_report`, `graph_stats`).  Heavy
re-analysis tools are excluded so the pipeline is not re-triggered.

### Added

- `ToolSchema.rag_tool_names/0` — returns the list of 10 read-only RAG query
  tool names.
- `ToolSchema.rag_query_tools/1` — returns those tools formatted for a given
  AI provider (`:openai`, `:anthropic`, `:deepseek_r1`, `:ollama`).

### Planned
- Additional language support (Go, Rust, Java)
- Cross-language refactoring via Metastatic
- Production optimizations
- Enhanced semantic analysis for advanced refactoring operations

## [0.2.0] - 2026-01-27

### Added
- Comprehensive library packaging for Hex publication
- ExDoc documentation generation with logo and assets
- Module grouping and documentation extras
- Quality aliases for CI/CD integration
- Dialyzer configuration with ignore patterns

### Changed
- Updated project structure to library format
- Enhanced mix.exs with package metadata
- Improved dependency management
- Updated Metastatic dependency to `~> 0.5`

## [0.1.0] - 2026-01-24

### Added

#### Core Features
- MCP Server Protocol: JSON-RPC 2.0 over stdio and socket
- Multi-language code analysis (Elixir, Erlang, Python, JavaScript/TypeScript)
- Knowledge graph with ETS-based storage
- Local ML embeddings via Bumblebee (sentence-transformers/all-MiniLM-L6-v2)
- Semantic search and hybrid retrieval (RRF)
- Advanced graph algorithms (PageRank, centrality, community detection)

#### Code Editing Capabilities
- Safe file editing with atomic operations and backups
- Multi-language syntax validation
- Multi-file atomic transactions
- Semantic refactoring (rename function/module)
- Advanced refactoring operations (8 types: extract_function, inline_function, etc.)
- Format integration (mix, rebar3, black, prettier)

#### Analysis & Quality
- Code duplication detection (AST-based Type I-IV clones)
- Dead code detection (interprocedural + intraprocedural)
- Dependency analysis and coupling metrics
- Impact analysis with risk scoring
- Automated refactoring suggestions with RAG-powered advice

#### AI Features
- AI-enhanced validation error explanations
- Refactoring preview with risk assessment
- Dead code false positive reduction
- Semantic Type IV clone detection
- Architectural insights for coupling/dependencies
- Feature flags with graceful degradation
- Automatic caching (3-7 day TTLs)

#### Production Features
- Custom embedding models (4 pre-configured)
- Embedding persistence and caching
- Incremental updates with file tracking
- Path finding limits for dense graphs
- MCP streaming notifications
- Graph visualization (Graphviz DOT, D3.js JSON)

#### MCP Tools (15 total)
- Code analysis: analyze_file, analyze_directory, query_graph, list_nodes
- Semantic search: semantic_search, hybrid_search, get_embeddings_stats
- Graph algorithms: find_paths, graph_stats, betweenness_centrality, closeness_centrality, detect_communities, export_graph
- Code editing: edit_file, validate_edit, rollback_edit, edit_history, edit_files, refactor_code, advanced_refactor
- Analysis: find_duplicates, find_similar_code, find_dead_code, analyze_dead_code_patterns
- Quality: analyze_dependencies, find_circular_dependencies, coupling_report, analyze_quality, quality_report, find_complex_code
- Impact: analyze_impact, estimate_refactoring_effort, risk_assessment
- Suggestions: suggest_refactorings, explain_suggestion
- AI features: validate_with_ai, preview_refactor (AI-enhanced)

#### MCP Resources
- Graph statistics, cache status, model configuration
- Project index, algorithm catalog, analysis summary

#### MCP Prompts
- Analyze Architecture (shallow/deep)
- Find Impact, Explain Code Flow

### Documentation
- Comprehensive README with features overview
- ALGORITHMS.md: Graph algorithm reference
- ANALYSIS.md: Code analysis guide
- SUGGESTIONS.md: Refactoring suggestions guide
- CONFIGURATION.md: Configuration reference
- PERSISTENCE.md: Caching and persistence
- PROMPTS.md: MCP prompts guide
- RESOURCES.md: MCP resources reference
- STREAMING.md: Streaming notifications guide
- USAGE.md: Usage examples

[0.29.0]: https://github.com/Oeditus/ragex/releases/tag/v0.29.0
[0.11.0]: https://github.com/Oeditus/ragex/releases/tag/v0.11.0
[0.2.0]: https://github.com/Oeditus/ragex/releases/tag/v0.2.0
[0.1.0]: https://github.com/Oeditus/ragex/releases/tag/v0.1.0
