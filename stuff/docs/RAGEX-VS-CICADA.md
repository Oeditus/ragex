# Ragex vs Cicada—Comparison Analysis

> Last updated: 2026-09-06 (Ragex v0.30.0)

## Philosophical Difference

The two projects solve overlapping but fundamentally different problems.

- **Cicada** (v0.6.5, Python) is a *read-only context compaction layer*—it builds a pre-indexed map of your codebase so AI assistants stop wasting tokens on blind greps. It answers *"what’s here and why."*
- **Ragex** (v0.30.0, Elixir) is a **Plugin-Driven Orchestration Engine & Hybrid RAG System**—it builds a Knowledge Graph, performs multi-language static analysis, runs parallel non-destructive security & quality checks, ingests remote Git repos/URLs, and safely edits, refactors, and transforms code. It answers *"what’s here, what’s wrong with it, how to fix it, and executes the transformation."*

**Cicada**: 8 MCP tools, laser-focused on search and context compaction.  
**Ragex**: 85+ MCP tools organized into an extensible **Plugin Architecture** spanning static analysis, parallel query scheduling, AST refactoring, security auditing, Git archaeology, remote repo ingestion, REST API, and local ML embeddings.

---

## What They Have In Common

- **MCP Server over stdio & Unix Sockets**—both are MCP-compatible code intelligence servers.
- **AST-level Indexing**—both parse source into structured representations (tree-sitter/SCIP vs. Elixir `Code.string_to_quoted` / Metastatic MetaAST).
- **Semantic & Keyword Search**—both support concept-based search beyond exact string matching.
- **Knowledge Graph & Call-Site Tracking**—both track caller-callee relationships and bidirectional dependency graphs.
- **Dead Code Detection**—both identify unused public functions.
- **Incremental Indexing**—both hash files to avoid re-indexing unchanged code.
- **File Watching**—both support automatic re-indexing on file modifications.
- **Local-First & Privacy-First**—no cloud dependencies for core functionality.
- **Elixir First-Class Support**—both support Elixir parsing and analysis natively.
- **Vector Embeddings**—both support vector similarity search (Ragex via local GPU Bumblebee/Nx; Cicada via Ollama).
- **Hybrid Retrieval**—both combine symbolic graph search and semantic embeddings.
- **Git Archaeology**—both provide line-level authorship blame, file commit history, PR context, and co-change coupling.
- **REST API Bridge**—both expose HTTP endpoints with OpenAPI specifications.
- **Usage Telemetry**—both track per-tool invocation counts and latencies.

---

## What Cicada Lacks (Ragex’s Core Advantages)

### 1. Plugin-Driven Orchestrator Engine (Architectural Leap)
Ragex v0.30.0 introduces a full **Plugin System** (`Ragex.Plugin` & `Ragex.Plugin.Registry`):
- **Topological Dependency Resolution**: Plugins declare dependencies (`dependencies: [:graph_analytics]`) and priority ordering (`priority: 10`), automatically ordered using graph topological sorting (`:digraph`).
- **Domain Plugin Alienation**: Tools are decoupled into specialized plugins (`Ragex.Plugins.GraphAnalytics`, `GitArchaeology`, `CodeQuality`, `SecurityAudit`, `URLAnalyzer`).
- **Dynamic Scaffolding CLI**: `mix ragex.plugin NAME` scaffolds new custom plugins and test files instantly.
- **Hot Enabling & Disabling**: Enable or disable plugins on the fly without restarting OTP.
- Cicada has a static, hardcoded tool set with no plugin extensibility.

### 2. Parallel Scheduler & Safety Metadata (`destruction_level`)
Ragex classifies tools by `:destruction_level` (`:none`, `:low`, `:medium`, `:high`, `:full`):
- **Parallel Dispatching**: Non-destructive tools (`destruction_level: :none`) run concurrently in parallel via [`Ragex.Plugin.TaskSupervisor`](file:///home/am/Proyectos/Oeditus/ragex/lib/ragex/application.ex#L61).
- **Multi-Tool Batch Execution**: `call_tools/1` and `dispatch_tools/2` execute multiple query tools simultaneously, drastically reducing overall latency.
- Cicada executes tool calls sequentially.

### 3. Remote URL & Git Repository Ingestion (`analyze_url`)
Ragex includes [`Ragex.URLAnalyzer`](file:///home/am/Proyectos/Oeditus/ragex/lib/ragex/url_analyzer.ex):
- Automatically classifies remote targets (`:git_repo`, `:web_page`, `:raw_code`, `:api_spec`).
- Performs shallow cloning (`git clone --depth 1`) of remote GitHub/GitLab repositories, executes AST analysis, extracts architecture entry points, and ingests findings directly into the Knowledge Graph.
- Fetches and cleans web pages, documentation, and OpenAPI schemas.
- Cicada requires local filesystem access for all indexed projects.

### 4. Inter-Plugin Event & Hook Bus (`Ragex.Plugin.EventBus`)
Ragex features a Pub/Sub event bus (`Ragex.Plugin.EventBus`):
- Plugins subscribe to system lifecycle events (`:file_indexed`, `:code_edited`, `:security_alert`, `:graph_mutated`) by implementing `@callback handle_event/2`.
- Enables real-time reactivity across custom third-party plugins.

### 5. Atomic Code Editing & Multi-File Transactions
Cicada is strictly read-only. Ragex provides:
- Atomic file edits with automatic backups.
- Multi-file transactional edits (all-or-nothing rollback).
- Pre/post syntax validation and code formatters (`mix`, `prettier`, `black`, `rebar3`).
- Rollback history stack.

### 6. AST-Aware Refactoring Suite
Ragex provides 10+ semantic refactoring operations:
- Project-wide, arity-aware `rename_function` and `rename_module`.
- `extract_function`, `inline_function`, `move_function`, `extract_module`.
- Diff previews, conflict detection, and risk assessment before committing edits.

### 7. Security & Business Logic Auditing
Ragex features 13 CWE-based security analyzers (SQL injection, XSS, SSRF, path traversal, IDOR, CSRF), secret scanners, and 33 business logic auditors. Cicada offers no security auditing.

### 8. Code Quality, Smells, and Clone Detection
Ragex detects cyclomatic/cognitive complexity, code smells, dead code, and Type I–IV AST/semantic duplicate clones.

### 9. Knowledge Graph & Graph Algorithms
Ragex uses an ETS/dllb-backed Knowledge Graph with native Erlang graph algorithms:
- Betweenness and closeness centrality to discover bottleneck modules.
- Community detection (Louvain, label propagation).
- Path finding and Graphviz DOT / D3 JSON visualizers.

---

## Metric Comparison

| Feature / Metric | Ragex (v0.30.0) | Cicada (v0.6.5) |
|---|---|---|
| **Architecture** | **Plugin-Driven Orchestrator** | Read-only Context Compactor |
| **MCP Tools** | **85+** (extensible via plugins) | 8 (fixed) |
| **Plugin Extensibility** | ✅ `Ragex.Plugin` & `mix ragex.plugin` | ❌ None |
| **Parallel Execution** | ✅ TaskSupervisor + `:destruction_level` | ❌ Sequential |
| **Remote Repo & URL Analyzer** | ✅ `analyze_url` (shallow clone & HTML parse) | ❌ Local filesystem only |
| **Inter-Plugin Event Bus** | ✅ `Ragex.Plugin.EventBus` (`handle_event/2`) | ❌ None |
| **Code Editing & Refactoring** | ✅ Atomic edits, transactions, 10+ refactors | ❌ Read-only |
| **Security Auditing** | ✅ 13 CWE scanners & secret check | ❌ None |
| **Graph Centrality & Community** | ✅ PageRank, betweenness, Louvain | ❌ Flat index |
| **Native Languages** | 6 (Elixir, Erlang, Ruby, Python, JS/TS) | 1 (Elixir; rest via SCIP) |
| **Runtime Engine** | BEAM (Elixir/OTP 27+) | CPython 3.10+ |
| **Embeddings** | Bumblebee (local GPU / Nx) | Ollama (optional) |
| **License** | GPL-3.0 | MIT |

---

## Conclusion

**Cicada** is a light, read-only token minimizer for Python-centric workflows.  
**Ragex** is a full-fledged **Extensible Code Intelligence & Orchestration Platform**. With v0.30.0's plugin framework, parallel non-destructive execution, and remote repository analyzer, Ragex provides an unconstrained foundation for building AI coding agents, security compliance tools, and automated refactoring pipelines.
