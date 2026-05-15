# Ragex vs Cicada—Comparison Analysis

> Last updated: 2026-05-16

## Philosophical Difference

The two projects solve overlapping but fundamentally different problems. **Cicada** (v0.6.5, Python) is a *read-only context compaction layer*—it builds a pre-indexed map of your codebase so AI assistants stop wasting tokens on blind greps. It answers “what’s here and why.” **Ragex** (v0.14.1, Elixir) is a *read+write hybrid RAG system*—it builds a knowledge graph, performs deep analysis, and can also edit, refactor, and transform your code. It answers “what’s here, what’s wrong with it, and how to fix it.”

Cicada: 8 MCP tools, laser-focused on search and attribution.
Ragex: 83 MCP tools spanning analysis, editing, refactoring, security, RAG, git archaeology, REST API, and AI features.

---

## What They Have In Common

- **MCP server over stdio**—both are MCP-compatible code intelligence servers
- **AST-level indexing**—both parse source into structured representations (tree-sitter / SCIP vs. Elixir’s `Code.string_to_quoted` / Metastatic)
- **Semantic/keyword search**—both support concept-based search beyond exact string matching
- **Knowledge graph / call-site tracking**—both track what-calls-what, bidirectional dependency analysis
- **Dead code detection**—both identify unused public functions (Cicada with confidence tiers, Ragex with interprocedural + intraprocedural analysis)
- **Incremental indexing**—both hash files to avoid re-indexing unchanged code
- **File watching**—both support automatic re-indexing on file changes
- **Local-first / privacy-first**—no cloud dependencies for core functionality, no telemetry
- **Elixir as a primary citizen**—both have first-class Elixir support (Cicada started Elixir-only; Ragex is written in Elixir)
- **Embeddings**—both support vector similarity search (Ragex via Bumblebee; Cicada via Ollama)
- **Hybrid retrieval**—both combine symbolic and semantic search strategies
- **Git blame + history**—both provide line-level authorship and file history
- **PR attribution**—both can surface PR context
- **Co-change analysis**—both track files that change together
- **Context compaction**—both optimize token usage with compact-by-default responses
- **String/comment indexing**—both index string literals and inline comments with keyword boosting
- **REST API**—both expose tools over HTTP with OpenAPI specs
- **Editor CLI setup**—both offer one-command editor configuration
- **Usage telemetry**—both track per-tool invocation counts and latencies
- **SCIP language support**—both can ingest SCIP indexes for additional languages

---

## What Ragex lacks (Cicada’s Advantages)

### jq-like Raw Index Querying (Not Planned in Ragex)
Cicada’s `query_jq` allows direct jq queries against the raw JSON index.
Ragex has `query_graph` (structured/typed) and 83 specialized tools that cover
the same use cases more ergonomically. The flat JSON index is an artifact of
Cicada’s architecture, not a deliberate feature advantage.

---

## What Cicada Lacks (Ragex’s Advantages)

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
ValidationAI, AIPreview, AIRefiner (false positive reduction), AIAnalyzer (semantic clone detection), AIInsights. These are “AI-on-top-of-analysis” features that add interpretive value. Cicada delegates all interpretation to the consuming AI assistant.

### 10. RAG Pipeline (Moderate Gap)
Full retrieval-augmented generation with streaming, context-aware suggestions, query expansion, multi-provider support (DeepSeek R1, OpenAI, Anthropic, Ollama). Cicada returns structured data; Ragex can synthesize answers.

### 11. Cross-Language Semantic Analysis (Moderate Gap)
MetaAST search, cross-language alternatives (“show me the Python equivalent of this Elixir function”), OpKind-based semantic domain extraction (7 domains: db, http, auth, cache, queue, file, external_api). Unique to Ragex via Metastatic integration.

### 12. Comprehensive Analysis Tool (Minor Gap)
`comprehensive_analyze` runs all analysis passes (security, business logic, complexity, smells, duplicates, dead code, dependencies, quality) in one invocation. `mix ragex.analyze` delegates to the running server. Cicada has no equivalent batch analysis.

---

## Where Cicada Still Has Edge

### Language Breadth via SCIP
Cicada: 17+ languages with mature SCIP indexer auto-installation.
Ragex: 6 native languages (Elixir, Erlang, Ruby, Python, JS/TS) + SCIP bridge
(10 languages configured, but indexer auto-install not yet implemented).

Cicada’s auto-download of SCIP binaries (`scip-go`, `rust-analyzer`, etc.) is
more polished. Ragex’s SCIP bridge requires manual indexer installation.

### Zero-Install Distribution
Cicada: `uvx cicada-mcp`—runs without installation via uv tool.
Ragex: requires Elixir/OTP runtime and GPU for embeddings.

This is an inherent architectural difference. Ragex’s Bumblebee/EXLA-based
embeddings run locally on GPU, providing better quality but requiring more setup.
Cicada’s Ollama-based embeddings are optional and simpler.

### Published Benchmarks
Cicada: public token/time comparisons (3127 tokens -> 550 tokens).
Ragex: no published benchmarks yet.

---

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
