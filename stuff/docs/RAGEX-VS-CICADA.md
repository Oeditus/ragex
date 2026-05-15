# Ragex vs Cicada -- Comparison Analysis

> Last updated: 2026-05-15 (after Phases E-K complete: all gap-closing phases done)

## Philosophical Difference

The two projects solve overlapping but fundamentally different problems. **Cicada** (v0.6.5, Python) is a *read-only context compaction layer* -- it builds a pre-indexed map of your codebase so AI assistants stop wasting tokens on blind greps. It answers "what's here and why." **Ragex** (v0.14.1, Elixir) is a *read+write hybrid RAG system* -- it builds a knowledge graph, performs deep analysis, and can also edit, refactor, and transform your code. It answers "what's here, what's wrong with it, and how to fix it."

Cicada: 8 MCP tools, laser-focused on search and attribution.
Ragex: 83 MCP tools spanning analysis, editing, refactoring, security, RAG, git archaeology, REST API, and AI features.

---

## What They Have In Common

- **MCP server over stdio** -- both are MCP-compatible code intelligence servers
- **AST-level indexing** -- both parse source into structured representations (tree-sitter / SCIP vs. Elixir's `Code.string_to_quoted` / Metastatic)
- **Semantic/keyword search** -- both support concept-based search beyond exact string matching
- **Knowledge graph / call-site tracking** -- both track what-calls-what, bidirectional dependency analysis
- **Dead code detection** -- both identify unused public functions (Cicada with confidence tiers, Ragex with interprocedural + intraprocedural analysis)
- **Incremental indexing** -- both hash files to avoid re-indexing unchanged code
- **File watching** -- both support automatic re-indexing on file changes
- **Local-first / privacy-first** -- no cloud dependencies for core functionality, no telemetry
- **Elixir as a primary citizen** -- both have first-class Elixir support (Cicada started Elixir-only; Ragex is written in Elixir)
- **Embeddings** -- both support vector similarity search (Ragex via Bumblebee; Cicada via Ollama)
- **Hybrid retrieval** -- both combine symbolic and semantic search strategies
- **Git blame + history** -- both provide line-level authorship and file history
- **PR attribution** -- both can surface PR context
- **Co-change analysis** -- both track files that change together
- **Context compaction** -- both optimize token usage with compact-by-default responses
- **String/comment indexing** -- both index string literals and inline comments with keyword boosting
- **REST API** -- both expose tools over HTTP with OpenAPI specs
- **Editor CLI setup** -- both offer one-command editor configuration
- **Usage telemetry** -- both track per-tool invocation counts and latencies
- **SCIP language support** -- both can ingest SCIP indexes for additional languages

---

## Former Gaps -- All Closed (Phases E-K)

### 1. Git + PR Attribution -- CLOSED (Phase E)
Cicada's `git_history` tool was their strongest differentiator. Ragex now matches and exceeds it:
- `git_blame`, `git_history`, `git_pr_info`, `co_change_analysis`, `git_enrich` (5 tools)
- Dual-backend architecture (egit NIF + CLI fallback) for performance
- Knowledge graph integration: `:authored_by`, `:co_changes_with` edge types
- Connects git data to impact analysis -- "find dead code last touched 2 years ago"

### 2. Context Compaction / Token Efficiency -- CLOSED (Phase F)
- All 83 tools get automatic compaction (compact by default, `verbose=true` to bypass)
- Token budget enforcement via `max_tokens` parameter
- Smart next-step suggestions (`_suggestions` key)
- Protocol-based (`Ragex.MCP.Formattable`) for extensibility

### 3. SCIP Bridge for Multi-Language Expansion -- CLOSED (Phase G)
- `Ragex.Analyzers.SCIP.Parser` -- JSON-based parser (no protobuf dep)
- `Ragex.Analyzers.SCIP.Registry` -- 10 languages pre-configured
- `Ragex.Analyzers.SCIP.Adapter` -- maps SCIP symbols to Ragex graph nodes
- `scip_status`, `scip_index` MCP tools
- Complementary to Metastatic's MetaAST (SCIP for read-only analysis, MetaAST for refactoring)

### 4. Editor Integration CLI -- CLOSED (Phase H)
- `mix ragex.setup` -- interactive, detects 7 editors (NeoVim, LunarVim, Emacs, VS Code, Zed, Helix, Sublime Text)
- `mix ragex.status` -- health check (index counts, embedding status, editor configs found)
- `Ragex.CLI.EditorConfig` -- generates correct MCP config per editor

Cicada covers: Claude Code, Cursor, VS Code, Gemini, Codex, OpenCode, Zed, Kimi.
Ragex covers: NeoVim, LunarVim, Emacs, VS Code, Zed, Helix, Sublime Text.
Different editor sets -- each covers editors the other doesn't.

### 5. Deeper Indexing (Strings, Comments, Keywords) -- CLOSED (Phase I)
- `Ragex.Analyzers.DeeperIndexing` -- extracts string literals and comments from Elixir/Erlang/Python/JS
- `Ragex.Search.Keywords` -- weighted keyword extraction (doc 1.5x > names 1.0x > specs 0.9x > strings 0.8x > comments 0.6x)
- `search_strings` MCP tool for substring search across indexed literals
- `match_source` parameter on `semantic_search` (all/docs/strings/comments/names)
- Automatic enrichment during `analyze_file`

Cicada has equivalent string/comment indexing with a 1.2x comment boost.
Ragex uses a more granular 5-tier boosting system.

### 6. MCP Usage Telemetry -- CLOSED (Phase J)
- `Ragex.MCP.Telemetry` GenServer with ETS-backed stats
- Per-tool: count, avg/p50/p95/p99/max latency, error rate
- ETF persistence across restarts
- `mcp_stats`, `mcp_stats_reset` MCP tools

### 7. REST API Bridge -- CLOSED (Phase K)
- Bandit HTTP server with Plug.Router
- `POST /api/tools/:tool_name`, `GET /api/tools`, `GET /api/health`, `GET /api/openapi.json`
- Optional Bearer token auth via `RAGEX_API_KEY`
- Auto-generated OpenAPI 3.0 spec from tool definitions
- `mix ragex.serve --port 4321`

---

## Remaining Cicada Feature Not Adopted

### jq-like Raw Index Querying (Not Planned)
Cicada's `query_jq` allows direct jq queries against the raw JSON index.
Ragex has `query_graph` (structured/typed) and 83 specialized tools that cover
the same use cases more ergonomically. The flat JSON index is an artifact of
Cicada's architecture, not a deliberate feature advantage.

---

## What Cicada Lacks (Ragex's Advantages)

### 1. Code Editing (Massive Gap)
Cicada is strictly read-only. Ragex has:
- Atomic file editing with automatic backups
- Multi-file transactions (all-or-nothing)
- Syntax validation before/after edits
- Format integration (mix, rebar3, black, prettier)
- Rollback to any previous version
- Concurrent modification detection

### 2. Semantic Refactoring (Massive Gap)
Ragex has 10+ AST-aware refactoring operations:
- rename_function, rename_module (project-wide, arity-aware)
- extract_function, inline_function, move_function, extract_module
- change_signature, convert_visibility, rename_parameter, modify_attributes
- Preview with diff, conflict detection, undo/redo stack
- AI-enhanced preview with risk assessment

Cicada can find where things are called but cannot *change* them.

### 3. Security Analysis (Major Gap)
Ragex has 13 CWE-based security analyzers (SQL injection, XSS, SSRF, path traversal, IDOR, CSRF, etc.), plus secret scanning and security auditing. Cicada has nothing.

### 4. Deep Code Quality Analysis (Major Gap)
Ragex provides: complexity analysis (cyclomatic/cognitive/nesting/Halstead), code smell detection, 33 business logic analyzers, coupling metrics, circular dependency detection, quality reports. Cicada only has basic dead code detection.

### 5. Code Duplication Detection (Significant Gap)
Ragex detects Type I-IV clones (exact, renamed, near-miss, semantic) using AST analysis + embedding similarity. Not present in Cicada.

### 6. Impact Analysis + Refactoring Suggestions (Significant Gap)
Risk scoring, effort estimation, test discovery, automated refactoring suggestions with priority ranking, RAG-powered advice. Cicada requires the AI to figure all this out from raw search results.

### 7. Graph Algorithms (Significant Gap)
PageRank, betweenness/closeness centrality, community detection (Louvain, label propagation), path finding with limits. Cicada has a flat JSON index; Ragex has a proper ETS-backed graph with O(1) lookups and algorithmic analysis.

### 8. Graph Visualization (Moderate Gap)
Graphviz DOT, D3 JSON, ASCII export for impact analysis and architecture visualization. Not in Cicada.

### 9. AI-Enhanced Features (Moderate Gap)
ValidationAI, AIPreview, AIRefiner (false positive reduction), AIAnalyzer (semantic clone detection), AIInsights. These are "AI-on-top-of-analysis" features that add interpretive value. Cicada delegates all interpretation to the consuming AI assistant.

### 10. RAG Pipeline (Moderate Gap)
Full retrieval-augmented generation with streaming, context-aware suggestions, query expansion, multi-provider support (DeepSeek R1, OpenAI, Anthropic, Ollama). Cicada returns structured data; Ragex can synthesize answers.

### 11. Cross-Language Semantic Analysis (Moderate Gap)
MetaAST search, cross-language alternatives ("show me the Python equivalent of this Elixir function"), OpKind-based semantic domain extraction (7 domains: db, http, auth, cache, queue, file, external_api). Unique to Ragex via Metastatic integration.

### 12. Comprehensive Analysis Tool (Minor Gap)
`comprehensive_analyze` runs all analysis passes (security, business logic, complexity, smells, duplicates, dead code, dependencies, quality) in one invocation. `mix ragex.analyze` delegates to the running server. Cicada has no equivalent batch analysis.

---

## Where Cicada Still Has Edge

### Language Breadth via SCIP
Cicada: 17+ languages with mature SCIP indexer auto-installation.
Ragex: 6 native languages (Elixir, Erlang, Python, JS/TS, Ruby) + SCIP bridge
(10 languages configured, but indexer auto-install not yet implemented).

Cicada's auto-download of SCIP binaries (`scip-go`, `rust-analyzer`, etc.) is
more polished. Ragex's SCIP bridge requires manual indexer installation.

### Zero-Install Distribution
Cicada: `uvx cicada-mcp` -- runs without installation via uv tool.
Ragex: requires Elixir/OTP runtime and GPU for embeddings.

This is an inherent architectural difference. Ragex's Bumblebee/EXLA-based
embeddings run locally on GPU, providing better quality but requiring more setup.
Cicada's Ollama-based embeddings are optional and simpler.

### Published Benchmarks
Cicada: public token/time comparisons (3127 tokens -> 550 tokens).
Ragex: no published benchmarks yet.

---

## Gap Status Summary

| Gap | Priority | Status |
|-----|----------|--------|
| Git/PR attribution | High | CLOSED (Phase E) |
| Context compaction | High | CLOSED (Phase F) |
| SCIP multi-language | Medium | CLOSED (Phase G) |
| Editor integration CLI | Medium | CLOSED (Phase H) |
| String/comment indexing | Low-Medium | CLOSED (Phase I) |
| MCP usage telemetry | Low | CLOSED (Phase J) |
| REST API server | Low | CLOSED (Phase K) |
| jq-like raw querying | Low | Not planned (query_graph + 83 tools suffice) |

**All actionable gaps are closed.** Ragex is now feature-complete relative to
Cicada, with substantial additional capabilities in code editing, refactoring,
security analysis, quality analysis, graph algorithms, AI features, and RAG.

### By the Numbers

| Metric | Ragex | Cicada |
|--------|-------|--------|
| MCP tools | 83 | 8 |
| Native language analyzers | 6 | 1 (Elixir; rest via SCIP) |
| SCIP languages configured | 10 | 17 |
| Security analyzers (CWE) | 13 | 0 |
| Business logic analyzers | 33 | 0 |
| Refactoring operations | 10 | 0 |
| Graph algorithms | 7 | 0 |
| AI feature modules | 6 | 0 |
| Codebase | ~30k lines Elixir | ~15k lines Python |
| Runtime | BEAM (Elixir/OTP 27+) | CPython 3.10+ |
| Embeddings | Bumblebee (local GPU) | Ollama (optional) |
| License | GPL-3.0 | MIT |
