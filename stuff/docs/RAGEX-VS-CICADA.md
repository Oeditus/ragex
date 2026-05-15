# Ragex vs Cicada -- Comparison Analysis

> Last updated: 2026-05-15 (after Phase E: Git Archaeology and Phase F: Context Compaction)

## Philosophical Difference

The two projects solve overlapping but fundamentally different problems. **Cicada** is a *read-only context compaction layer* -- it builds a pre-indexed map of your codebase so AI assistants stop wasting tokens on blind greps. It answers "what's here and why." **Ragex** is a *read+write hybrid RAG system* -- it builds a knowledge graph, performs deep analysis, and can also edit, refactor, and transform your code. It answers "what's here, what's wrong with it, and how to fix it."

Cicada: 8 MCP tools, laser-focused on search and attribution.
Ragex: ~79 MCP tools spanning analysis, editing, refactoring, security, RAG, git archaeology, and AI features.

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
- **Git blame + history** -- both provide line-level authorship and file history (Cicada via `git_history` unified tool; Ragex via `git_blame`, `git_history`, `co_change_analysis`)
- **PR attribution** -- both can surface PR context (Cicada via PR index; Ragex via `git_pr_info` with `gh`/`glab` CLI)
- **Co-change analysis** -- both track files that change together (Cicada via co-occurrence in commits; Ragex via `Ragex.Git.CoChange` with ETS-backed matrix)
- **Context compaction** -- both optimize token usage (Cicada by design; Ragex via `Ragex.MCP.Formatter` with compact/verbose modes and token budgeting)

---

## What Ragex Lacks (Should Adopt from Cicada)

### 1. Git + PR Attribution -- CLOSED (Phase E)
Cicada's `git_history` tool was their strongest differentiator. Ragex now matches and exceeds it:
- `git_blame` -- line-level blame with optional PR enrichment
- `git_history` -- file history + function evolution via `git log -L`
- `git_pr_info` -- PR details and review comments via `gh`/`glab` CLI
- `co_change_analysis` -- ETS-backed co-occurrence matrix from commit history
- `git_enrich` -- background enrichment of knowledge graph with git metadata
- Dual-backend architecture (egit NIF + CLI fallback) for performance
- Knowledge graph integration: `:authored_by`, `:co_changes_with` edge types

Ragex goes beyond Cicada here by connecting git data to the knowledge graph,
enabling queries like "find dead code that hasn't been touched in 2 years"
and enriching impact analysis with co-change data.

### 2. Context Compaction / Token Efficiency -- CLOSED (Phase F)
Cicada's design was optimized for minimal responses. Ragex now has equivalent
capability via `Ragex.MCP.Formatter`:
- All ~79 tools get automatic compaction (compact by default, `verbose=true` to bypass)
- Token budget enforcement via `max_tokens` parameter
- Smart next-step suggestions (`_suggestions` key) -- tool-aware hints
- Protocol-based (`Ragex.MCP.Formattable`) so custom structs can override
- Truncation metadata tells the AI exactly how many results were omitted

### 3. Broader Language Support via SCIP (Medium Priority)
Cicada supports 17+ languages by leveraging SCIP (Source Code Intelligence Protocol) -- a standardized index format from Sourcegraph. This gives them Go, Rust, Java, Kotlin, Scala, C/C++, Ruby, C#, Dart, PHP with minimal per-language effort.

Ragex supports ~5 languages via custom parsers (Elixir, Erlang, Python, JavaScript/TypeScript) plus Metastatic's MetaAST.

**Recommendation:** Consider SCIP integration as an alternative to writing custom analyzers for Phase 7 (Go, Rust, Java). SCIP tools already exist and produce standardized output. This is orthogonal to -- not a replacement for -- Metastatic's MetaAST which serves cross-language refactoring purposes.

### 4. One-Command Editor Setup (Medium Priority)
`cicada claude`, `cicada cursor`, `cicada zed` -- zero-friction setup for 7+ editors. Cicada auto-creates the correct MCP config file and indexes the project in one step.

Ragex has no editor integration story.

**Recommendation:** Create a `mix ragex.install` task that generates `.mcp.json` / `.cursor/mcp.json` etc. and runs initial indexing. This is a polish feature but important for adoption.

### 5. REST API Server (Medium Priority)
`cicada serve` exposes all MCP tools as HTTP endpoints with OpenAPI docs. Useful for non-MCP integrations, web dashboards, CI pipelines.

**Recommendation:** Add `mix ragex.serve` using Phoenix or Bandit. Ragex is already a Phoenix-ecosystem project; this would be natural.

### 6. String Literal + Comment Indexing (Low-Medium Priority)
Cicada indexes string literals (SQL queries, error messages) and inline comments, boosting search results with those keywords. This means searching for "insert engine" finds the function that contains `INSERT INTO engines ...` in a string.

Ragex indexes function names, module names, specs, and docs -- but not string content or comments.

**Recommendation:** Add `match_source: "strings" | "comments" | "docs"` filtering to search tools.

### 7. Token/Usage Statistics (Low Priority)
`cicada stats` tracks per-tool invocation count, token usage, and execution times. Useful for optimizing prompt strategies.

**Recommendation:** Low effort, high visibility. Add an `mcp_stats` tool that reports invocation counts and latencies.

### 8. jq-like Raw Index Querying (Low Priority)
Cicada's `query_jq` allows direct jq queries against the raw index for ad-hoc analysis not covered by specialized tools.

Ragex has `query_graph` but it's structured/typed. A more free-form query interface could be useful for power users.

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
Ragex provides: complexity analysis, code smell detection, 33 business logic analyzers, coupling metrics, circular dependency detection, quality reports. Cicada only has basic dead code detection.

### 5. Code Duplication Detection (Significant Gap)
Ragex detects Type I-IV clones (exact, renamed, near-miss, semantic) using AST analysis + embedding similarity. Not present in Cicada.

### 6. Impact Analysis + Refactoring Suggestions (Significant Gap)
Risk scoring, effort estimation, test discovery, automated refactoring suggestions with priority ranking. Cicada requires the AI to figure all this out from raw search results.

### 7. Graph Algorithms (Significant Gap)
PageRank, betweenness/closeness centrality, community detection (Louvain, label propagation), path finding with limits. Cicada has a flat index; Ragex has a proper graph with algorithmic analysis.

### 8. Graph Visualization (Moderate Gap)
Graphviz DOT, D3 JSON, ASCII export for impact analysis and architecture visualization. Not in Cicada.

### 9. AI-Enhanced Features (Moderate Gap)
ValidationAI, AIPreview, AIRefiner (false positive reduction), AIAnalyzer (semantic clone detection), AIInsights. These are "AI-on-top-of-analysis" features that add interpretive value. Cicada delegates all interpretation to the consuming AI assistant.

### 10. RAG Pipeline (Moderate Gap)
Full retrieval-augmented generation with streaming, context-aware suggestions, query expansion. Cicada returns structured data; Ragex can synthesize answers.

### 11. Cross-Language Semantic Analysis (Moderate Gap)
MetaAST search, cross-language alternatives ("show me the Python equivalent of this Elixir function"), OpKind-based semantic domain extraction. Unique to Ragex via Metastatic integration.

---

## Strategic Summary

**Ragex is much deeper; Cicada is wider in language support.** With Phases E and F implemented, Ragex now matches Cicada on git attribution and context compaction -- the two areas where Cicada previously had clear advantages.

### Gap Status

| Gap | Priority | Status |
|-----|----------|--------|
| Git/PR attribution | High | CLOSED (Phase E) |
| Context compaction | High | CLOSED (Phase F) |
| SCIP multi-language | Medium | Planned (Phase G) |
| Editor integration CLI | Medium | Planned (Phase H) |
| String/comment indexing | Low-Medium | Planned (Phase I) |
| REST API server | Medium | Planned (Phase K) |
| Token/usage statistics | Low | Planned (Phase J) |
| jq-like raw querying | Low | Not planned (query_graph suffices) |

### Where Ragex now leads across the board

With the two high-priority gaps closed, Ragex is strictly dominant for any
use case where the user needs more than read-only search. Cicada retains an
advantage only in:
- **Language breadth** (17 via SCIP vs. Ragex's 6)
- **Zero-friction editor setup** (one-command install)
- **Published benchmarks** (Cicada has public token/time comparisons)

These are addressable via Phases G, H, and future benchmarking work.
