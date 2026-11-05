# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Languages are now plug-in, not hardcoded.** Ragex no longer keeps its own
  language lists. The new `Ragex.Languages` registry **derives** from
  `Metastatic.Languages` (which discovers adapters at compile time) and merges a
  small Ragex-local overlay for the concerns Metastatic does not know about:
  validators, native fallback analyzers, and SCIP indexers. This replaces four
  independent hardcoded registries that had drifted apart:
  - `Ragex.LanguageSupport`'s `@extension_map` / `@adapter_map` /
    `@metastatic_extensions` / `@documentation_languages`
  - `Ragex.Editor.Validator.list_validators/0` (plus the `:typescript ->
    :javascript` special-case, now expressed as overlay data)
  - `Ragex.Analyzers.Metastatic.fallback_analyze/3`'s `case language do … end`
    chain
  - `Ragex.Analyzers.SCIP.Registry`'s `@languages` table

  Adding a language Metastatic already supports now requires **no Ragex change**
  at all; only the Ragex-specific extras (validator/analyzer/SCIP) are declared,
  as data, in `Ragex.Languages`. All existing public functions on
  `Ragex.LanguageSupport` keep their exact contract and now delegate to the
  registry.

- **Duplicated subprocess validators collapsed into one generic validator.**
  `Ragex.Editor.Validators.Subprocess` implements the shared "write temp file →
  run the toolchain → parse `line:col:message`" shape once. The Python, Ruby and
  JavaScript validators are now thin specs (extension, command, error parser)
  over it; Elixir/Erlang stay in-process, and Agda/Cure keep their custom
  callbacks. Behaviour is unchanged.

### Added

- **`Ragex.Language`** -- struct describing a language (adapter, validator,
  native analyzer, SCIP indexer, extensions, documentation/experimental flags).
- **`Ragex.Languages`** -- the derived registry, with `detect_language/1`,
  `get_adapter/1`, `validator/1`, `native_analyzer/1`, `scip_languages/0`,
  `validators/0`, `native_analyzers/0`, and documentation-language helpers.
- **`LOCAL_METASTATIC=1`** -- points the `metastatic` dependency at the sibling
  `../metastatic` checkout, mirroring the existing `LOCAL_METACREDO` switch, so
  the two projects can be developed together.

- **Minimum Elixir is now 1.20** (was 1.18). This is the version that ships the
  set-theoretic type system Ragex's optional type inference reads back out of
### Added

- **Cure compiler discovery is no longer limited to `PATH`/`CURE_HOME`.**
  `Ragex.Cure.Loader.find_executable/0` now checks, in order: `CURE_HOME`
  (`bin/cure`, then `cure`), `PATH`, the new `CURE_ESCRIPT` variable, and
  `cure-lang/cure` / `cure/cure` in the checkout or any of its ancestors. A
  candidate is only accepted when it really is an escript (BEAM magic or a
  shebang), so an unrelated file named `cure` is ignored. This makes a local
  compiler checkout work without exporting anything.

- **Markdown as a first-class language** (`.md`, `.markdown`), following
  Metastatic 0.35's NL-MetaAST support. Ragex treats Markdown as a
  *documentation* language: it is discovered, parsed, validated and indexed,
  but kept out of passes that assume callable entities (dead code, duplication,
  refactoring, directory source discovery).

  - `Ragex.LanguageSupport` maps `.md`/`.markdown` to `:markdown`, resolves
    `Metastatic.Adapters.Markdown`, and gains `documentation_language?/1`,
    `documentation_file?/1`, `documentation_extension?/1` plus an
    `include_documentation: false` option on `find_source_files/2`.
  - `Ragex.Analyzers.Metastatic` materialises a single document entity for
    Markdown files (named after the file's base name), so documentation lands
    in the knowledge graph instead of silently vanishing from an analysis run.
  - `Ragex.Analyzers.DeeperIndexing` indexes link/image destinations and bare
    URLs as strings and headings as structural markers, skipping fenced,
    indented and inline code so documentation is never polluted by the code
    samples it embeds.
  - `Ragex.Editor.Validators.Markdown` validates by round-tripping through the
    adapter and reports unclosed fenced code blocks as warnings.
  - Prose linting, readability metrics and semantic enrichment apply to
    Markdown through the existing MetaCredo bridge, with no special-casing.

- **Optional expression-level type inference**
### Added

- **Optional expression-level type inference** (`Ragex.Analysis.TypeInfo`),
  bridging to [Typle](https://typle.hexdocs.pm). Off by default; enable with
  `config :ragex, type_inference: :enabled` or `RAGEX_TYPE_INFERENCE=1`. Every
  entry point is guarded and returns `{:error, :unavailable}` rather than
  raising, so the dependency stays `optional: true`.
- **`mix ragex.typle.spike`** -- measures Typle's usefulness on a codebase
  (crash rate and the share of expressions that come back `dynamic()`), so the
  decision to enable type inference is reproducible rather than anecdotal.

  A spike against this repository (40 files, Elixir 1.20.4 / OTP 29, Typle
  0.4.0) found **82.5% of inferred expressions are `dynamic()`**, and only
  ~5% are genuinely informative (the rest are empty types or bare `map()`),
  so type inference stays off; re-run the task after a Typle release to see
  whether the numbers moved.

  Getting even that number required fixing two crashes, both released in
  Typle 0.4.0: `Typle.Inference.Expr.infer/2` had no clause for the
  struct-update node `%{struct | key: value}` (20% of files here crashed), and
  Typle pinned ExPanda `~> 0.2`, whose walker spliced `with`/`for` body options
  into the positional argument list and produced AST that `Macro.to_string/1`
  cannot even print. With both fixed the crash rate on this repository is 0%.
- **Full macro expansion for the Elixir analyzer** via
  `Ragex.Analyzers.Elixir.MacroExpander`, backed by [ExPanda](https://hexdocs.pm/ex_panda)
  `~> 0.3`. `:partial` (the default) now genuinely expands core macros and `use`
  for modules loaded in the running VM; `:full` expands with the caller's
  `Macro.Env` so project-local macros resolve too. Expansion never raises:
  unresolvable macros keep their original node and are reported through the new
  `:unexpanded` key on the analysis result, so callers can surface a confidence
  signal instead of silently degrading.
- **`prisma_analyze` MCP tool** (`Ragex.Analysis.Prisma`), a bridge to
  [Prisma](https://prisma.hexdocs.pm), the hybrid success/gradual type analyzer for
  Erlang and Elixir. It reports `@spec`-vs-inferred type discrepancies and proves
  dead code (unreachable clauses, impossible guards, unused private functions)
  from compiled beams -- things source-level analysis cannot establish. Prisma
  ships no library API and its Mix task calls `erlang:halt/1`, so it is invoked as
  a subprocess with `--format json`. Optional: returns an actionable error when
  the package or `.pplt` files are missing.

### Fixed

- **`:full` macro expansion was dead code.**
  `Ragex.Analyzers.Elixir.expand_with_compilation/2` built a `%Macro.Env{}` with
  empty `requires`/`aliases`/`functions`/`macros` and called `Macro.expand/2` on
  the top-level `defmodule` node, which returns the AST unchanged -- so `:full`
  was silently identical to `:none`. It now expands via ExPanda.
- **Piped calls recorded arity 0.** `d |> Repo.insert()` parses with the
  remote-call node holding zero arguments (the piped value comes from `|>`), so
  every piped call was recorded as `Repo.insert/0`, corrupting call-graph edges,
  `find_callers` and arity-based refactoring. Expansion desugars the pipe into
  an equivalent direct call before traversal.
- **Operator encodings polluted the call graph.** Expanding control flow turns
  `if a == b` into `case :erlang.==(a, b)` and `&&`/`||` into
  `:erlang.andalso/orelse`, so `:erlang` "calls" that are really just the
  compiler's encoding of an operator were recorded as dependency edges -- 114 of
  142 `:erlang` edges in Ragex's own analyzer. They are now filtered out, leaving
  the genuine BIFs (`is_binary/1`, `length/1`, `binary_to_atom/1`, ...) that *are*
  worth recording.
- **Dropped the manual `defdelegate` rewrite.** ExPanda 0.3.0 expands
  `defdelegate` natively (0.2.x raised inside `:elixir_bootstrap.def/2`), so the
  analyzer's hand-rolled fallback pass is gone.
- **`use`-injected definitions were invisible.** `use GenServer` contributed no
  `child_spec/1` or callbacks, and every DSL-generated definition was lost. They
  are now visible and tagged `metadata.injected: true`, so callers can still
  distinguish them from user-authored code (`child_spec/1` proving a module is a
  supervisor child, for example).
- **`use` edges were lost once expansion was enabled**, because ExPanda rewrites
  `use X` into `require X` plus the injected body. The `:use` targets are now
  recovered from the surface AST, and the synthetic `require` is suppressed so the
  edge is not duplicated.
- **Semantic operation analysis silently returned zero operations.**
  Metastatic registers its `OpKind` pattern tables from a bare
  `Metastatic.Semantic.Domains.*.register_all()` call at the bottom of each
  domain module. Elixir only evaluates that side effect while the module is
  being compiled, so in any build that loads beams from disk (releases, a
  clean `_build`, precompiled deps) the tables were empty:
  `Enricher.enrich_tree/2` attached no `:op_kind` metadata, and
  `analyze_semantic_operations`, `semantic_operations`, `extract_operations`
  and `MetastaticBridge.parse_file(enrich: true)` all reported nothing, with
  no error surfaced anywhere. `ensure_semantic_patterns/0` is now called from
  `Ragex.Application.start/2` and from `LanguageSupport.parse_document/3`, so
  every parse path is covered.
- **`Ragex.Editor.Formatter` ran `mix format` from the wrong directory.**
  `mix format` resolves `.formatter.exs` relative to the working directory and
  refuses to run outside a Mix project, but the formatter was invoked with
  whatever cwd the editor happened to have. `detect_formatter/2` now returns
  `{command, args, cmd_opts}` and passes `:cd` pointing at the project root
  (falling back to the file's directory), with the path made relative to it.
- **`Ragex.Analysis.MetaCredoBridge` skipped files with invalid UTF-8**,
  returning `{:error, {:invalid_utf8, path}}`, while `MetastaticBridge` and
  `Analyzers.Directory` sanitise the same input by substituting U+FFFD. The
  same file was therefore analysed by one code path and silently ignored by
  another. `MetaCredoBridge` now sanitises too.
- **`Ragex.Embeddings.TextGenerator` emitted no enrichment hint.**
  `metastatic_hint/1` looked for `:async`, `:is_macro`, `:guards`,
  `:decorators` and `:multi_clause`, none of which
  `Ragex.Analyzers.Metastatic` ever produces, so the hint was always `nil`. It
  now summarises the metrics that are actually written (`:cyclomatic`,
  `:cognitive`, `:max_nesting`, `:function_metrics.statement_count`,
  `:loc.logical`).
- **`Ragex.Retrieval.MetaASTRanker` applied a uniform, meaningless boost.**
  It read `:level`, `:purity` and `:complexity` from `meta_ast_metadata`, which
  in practice holds the adapter's per-document map
  (`%{arity:, function:, module:, visibility:}`). `get_meta_level/1` therefore
  always returned `:core`, multiplying every result by the same factor and
  changing no ordering. The accessors now accept the keys that can actually
  appear (including `:cyclomatic`) and treat unknown metadata as neutral.
- **Stale `Metastatic.Analysis.*` references.** That namespace was removed in
  Metastatic 0.31 (analysis moved to MetaCredo); docs in `dead_code.ex`,
  `smells.ex`, `duplication.ex`, `metastatic_bridge.ex` and
  `location_preservation.ex` still pointed at it.
- **Editor startup and `ragex-prime` indexing timeouts on large projects**:
  - `Ragex.Graph.Store.init/1` no longer loads the on-disk graph/embedding
    cache (and bootstraps the per-project `dllb` backend) synchronously
    during application startup. Loading is now deferred to
    `handle_continue/2`, so the `Store` GenServer -- and every child started
    after it in the supervision tree, including the MCP socket and stdio
    servers editors connect to -- registers and becomes reachable
    immediately, even for projects with a large existing cache.
  - Reordered `Ragex.Application`'s supervision tree so the MCP socket and
    stdio servers start right after `Ragex.Graph.Store`, ahead of slower,
    independently-looked-up subsystems (embedding model loading, the file
    watcher, AI subsystems, the plugin registry, git enrichment). Editors
    now get a fast `initialize` response regardless of how long those
    subsystems take to finish starting.
  - `bin/ragex-prime` no longer causes the background daemon it launches to
    also auto-analyze the target project on startup (`RAGEX_SKIP_AUTO_ANALYZE=1`).
    Previously, the daemon's own startup auto-analysis and `ragex-prime`'s
    explicit `analyze_directory` call raced each other, indexing the same
    large project twice concurrently, which could exceed the priming
    client's indexing timeout and fail with `Daemon indexing failed:
    :timeout`.
  - `mix ragex.prime` no longer imposes a fixed one-hour ceiling on the
    daemon-delegated `analyze_directory` call; a first-time full index of a
    large project now runs to completion regardless of how long it
    legitimately takes.

### Removed

- `Ragex.Analysis.LocationPreservation.with_locations/3` -- a stub that ignored
  its `analysis_fn` argument entirely and always returned `{:ok, %{}}`. It had
  no callers. `merge_locations/4` and `merge_location_into_issue/4` remain.

## [0.30.0]

### Added

- **URL Analyzer Engine (`Ragex.URLAnalyzer`)**:
  - Automatically classifies input URLs (`:git_repo`, `:web_page`, `:raw_code`, `:api_spec`).
  - Supports shallow cloning of remote GitHub/GitLab repositories with full AST and directory analysis.
  - Fetches web documentation, OpenAPI specs, and raw files, formatting machine-understandable JSON reports (`ragex.url_analysis.v1`) and indexing resources into the Knowledge Graph.
- **Extended Plugin Architecture (`Ragex.Plugin` & `Ragex.Plugin.Registry`)**:
  - Converts Ragex into an Orchestrator Core supported by modular domain plugins.
  - Implements topological graph sorting (`:digraph`) for plugin initialization based on `dependencies` and `priority`.
  - Built-in domain plugins: `Ragex.Plugins.GraphAnalytics`, `Ragex.Plugins.GitArchaeology`, `Ragex.Plugins.CodeQuality`, `Ragex.Plugins.SecurityAudit`, and `Ragex.Plugins.URLAnalyzer`.
- **Parallel Execution & Safety Classification (`destruction_level`)**:
  - Tools declare a `:destruction_level` (`:none`, `:low`, `:medium`, `:high`, `:full`).
  - Non-destructive tools (`destruction_level: :none`) run concurrently in parallel via `Task.Supervisor` (`Ragex.Plugin.TaskSupervisor`).
  - Multi-tool batch execution API `dispatch_tools/2` and `call_tools/1`.
- **Inter-Plugin Event Bus (`Ragex.Plugin.EventBus`)**:
  - Asynchronous and synchronous event broadcasting (`broadcast/2`, `sync_broadcast/2`) to plugins implementing `@callback handle_event/2`.
- **Plugin Scaffold Generator (`mix ragex.plugin`)**:
  - Mix task `mix ragex.plugin NAME` generates plugin module and unit test scaffolds out of the box.
- **HexDocs Documentation Guide**:
  - Published comprehensive "Writing Custom Plugins" guide in `docs/WRITING_CUSTOM_PLUGINS.md`.

## [0.29.0]

### Changed

- `bumblebee`, `nx`, `exla`, and `image` are now `optional: true` dependencies
  in `mix.exs`. These are native/NIF-backed libraries that cannot load from
  inside an `mix escript.build` archive (their shared objects are packed in
  the escript zip, not present on a real filesystem path), which previously
  crashed the entire OTP boot chain for any downstream consumer building an
  escript against ragex.
- Ragex’ Application now skips starting `Ragex.Embeddings.Bumblebee` and
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
  copy of the repository, that ragex compiles and Application boots
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
