# Taking Back Control of Your AI Coding Harness: Why We Built Ragex

> **The Era of Black-Box AI Coding Tools is Over.**  
> *If you care about codebase privacy, deterministic AST refactoring safety, and sub-100ms hybrid context retrieval, it is time to take back full control of your developer harness.*

---

## The AI Coding Paradox

We are living through a renaissance of AI-assisted software development. Large Language Models can write code, draft tests, and explain complex algorithms in seconds. Yet, ask any senior staff engineer or tech lead about using commercial AI coding tools on large, mission-critical codebases, and you will hear the exact same frustrations:

1. **"The LLM hallucinated a function signature that doesn't exist."**
2. **"It edited file A, forgot to update call sites in files B and C, and broke our build."**
3. **"We cannot send our core IP or client codebases to third-party cloud vector databases."**
4. **"The black-box tool truncated our context window, leaving out crucial dependency definitions."**
5. **"We are trapped in SaaS vendor lock-in with zero visibility into how context is selected."**

Commercial AI coding plugins treat your codebase like a bucket of unstructured text files, slicing them into arbitrary 500-token text chunks and piping them into naive cloud vector stores. **This is fundamentally flawed.** 

Code is not plain prose. Code is a deeply structured, execution-dependent graph of AST nodes, macro expansions, module dependencies, visibility scopes, and call site relationships.

That is why we built **Ragex**—a local-first, high-performance **Hybrid Retrieval-Augmented Generation (RAG) system, Model Context Protocol (MCP) server, and AST-aware refactoring engine** built natively in Elixir.

---

## Why Full Control Over Your AI Harness Matters

When you build or maintain complex software, your AI toolchain should be an extension of your engineering standards—not a black box you hope doesn't break production.

Ragex puts **you** in complete command of every tier of your AI harness:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                 YOUR FULL CONTROL HARNESS                              │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ 1. Vector Search Tier  │ 100% Local (Bumblebee / MiniLM 384d NIFs, No API Costs)       │
│ 2. Graph Engine Tier   │ Native Compiler ASTs + ETS / dllb Rust Multi-Model DB Backend │
│ 3. Retrieval Strategy  │ Reciprocal Rank Fusion (RRF k=60), Graph-First, Semantic-First │
│ 4. AI Provider Choice  │ DeepSeek-R1, Anthropic Claude 3.5, OpenAI GPT-4o, Ollama Local│
│ 5. Code Edit Safety    │ Pre-Syntax Checks, Multi-file Atomic Transactions, Rollbacks  │
│ 6. Protocol Standard   │ Model Context Protocol (MCP stdio/socket) & REST API           │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## The 5 Breakthroughs of Ragex

### 1. 🧠 Hybrid Search: Symbolic Precision Meets Neural Intuition

Pure vector search is great for vague natural language queries (*"where do we calculate discounts?"*), but terrible at structural precision (*"show me every caller of `User.verify/2`"*). Conversely, traditional static analysis understands syntax but fails when you don't know the exact symbol name.

Ragex solves this by combining **Symbolic Compiler AST Analysis**, **ETS/dllb Knowledge Graphs**, and **Local Neural Vector Embeddings** through **Reciprocal Rank Fusion (RRF)**:

```
Natural Language Query ──► Local MiniLM Embeddings ──► Dense Vector Rank (Sub-50ms) ──┐
                                                                                     ├─► RRF Hybrid Fusion
Compiler Symbol Graph  ──► PageRank / Call Chains  ──► Graph Centrality Rank        ──┘    (<100ms Query)
```

With Ragex, when your AI assistant answers a question, it relies on both **semantic similarity** and **mathematical call-graph topology**.

---

### 2. 🛡️ Bulletproof AST Code Refactoring & Atomic Edit Transactions

Raw LLMs are notoriously sloppy editors: they drop trailing brackets, generate syntax errors, and fail to propagate parameter changes across caller files.

Ragex introduces a **Zero-Downtime, Safety-Guaranteed Code Editing Engine**:

* **Pre-Execution Syntax Validation**: Before writing a single byte to disk, Ragex parses the edit using language-native compilers (`Code.string_to_quoted`, `:erl_parse`, Python `ast`, Node.js `vm.Script`). If syntax is invalid, the edit is rejected instantly.
* **Multi-File Atomic Transactions (`edit_files`)**: When refactoring across 10 files, Ragex executes inside an all-or-nothing transaction. If file 9 fails validation, files 1 through 8 are automatically rolled back. Zero partial breakages.
* **Instant Rollbacks & Automatic Backups**: Every edit creates a compressed snapshot in `.ragex/backups/`. Reverting an edit takes a single command (`rollback_edit`).
* **Semantic AST Transformations**: Perform arity-aware function renames, module namespace migrations, parameter signature changes, and function inlining project-wide with full confidence.

---

### 3. 🔒 100% Local-First & Privacy Preserving

Your code never leaves your workstation or private infrastructure without your explicit permission.

* **Local Machine Learning**: Embeddings are computed locally using Elixir's `Bumblebee` (`sentence-transformers/all-MiniLM-L6-v2`) backed by NIFs. No third-party vector database APIs, no cloud indexers.
* **Incremental SHA256 File Tracking**: Re-indexing a modified file takes milliseconds. Changing 1 file in a 10,000-file repository re-indexes *only* that file, consuming <5% processing overhead.
* **Full Offline Mode via Ollama**: Pair Ragex with local LLMs (e.g., `llama3`, `qwen2.5-coder`, `mistral`) via Ollama for a 100% air-gapped, zero-cloud AI development stack.

---

### 4. 📊 Advanced Graph Analytics & Automated Code Quality Audits

Ragex isn't just a search tool—it is a continuous architectural intelligence engine. Built directly into the runtime are advanced graph algorithms and static code analyzers:

* **PageRank & Centrality Scoring**: Instantly detect high-impact "bridge" modules and bottleneck functions using Brandes' Betweenness Centrality.
* **Louvain Architectural Community Detection**: Discover logical subsystem clusters and measure modularity score automatically.
* **Dead Code Detection with AI Refinement**: Graph call traversal identifies unreachable code, while AI refiners filter out false positives caused by dynamic dispatch or framework callbacks.
* **20 Business Logic Analyzers**: Catch silent error swallowing, N+1 queries, unmanaged tasks, callback hell, and missing Telemetry metrics automatically.
* **Security & Secret Scanner**: Detect OWASP Top 10 vulnerabilities, hardcoded JWT/API keys, and unsafe deserialization before committing code.

---

### 5. 🔌 Open MCP Standard: Seamless Integration with Any Tool

Ragex natively implements the **Model Context Protocol (MCP)** JSON-RPC 2.0 standard over stdio and Unix domain sockets.

Whether you use **Claude Desktop**, **Zed Editor**, **Cursor**, **LunarVim**, or a custom terminal workflow (`mix ragex.chat`), Ragex equips your preferred AI workspace with **~50 production-ready tools**, **6 real-time resources (`ragex://`)**, and **guided workflow prompts**.

```
       ┌────────────────┐      ┌────────────────┐      ┌────────────────┐
       │ Claude Desktop │      │   Zed Editor   │      │ Cursor / Neovim│
       └───────┬────────┘      └───────┬────────┘      └───────┬────────┘
               │                       │                       │
               └───────────────────────┼───────────────────────┘
                                       │
                         JSON-RPC 2.0 MCP Protocol
                                       │
                                       ▼
                       ┌───────────────────────────────┐
                       │     Ragex MCP Server Daemon   │
                       │    (Sub-100ms Hybrid Search)  │
                       └───────────────────────────────┘
```

---

## Comparing the Approaches

| Feature | Generic Cloud AI Plugins | Traditional LSP / Grep | **Ragex** |
| :--- | :--- | :--- | :--- |
| **Search Mechanism** | Naive 500-token chunking | Keyword matching / Direct AST | **Hybrid RRF (Vector + Compiler Graph)** |
| **Response Latency** | 2 - 5 seconds (Cloud API) | <10ms (Local Text) | **<100ms (Local Hybrid)** |
| **Privacy & Security** | Code uploaded to cloud | 100% Local | **100% Local (Local ML + Local DB)** |
| **Refactoring Safety** | Dumb text replacement | Manual / Basic IDE | **AST Syntax Validation + Atomic Rollbacks** |
| **Graph Analytics** | None | Limited LSIF | **PageRank, Centralities, Louvain Communities** |
| **AI Provider Flexibility**| Fixed SaaS Provider | N/A | **DeepSeek-R1, OpenAI, Claude, Ollama** |
| **Quality & Security** | None | basic linters | **Dead Code, Duplication I-IV, Security Scan** |

---

## Take Control Today

You don't need to choose between AI power and engineering discipline. With Ragex, you get both.

Experience the power of an AI code intelligence harness that **you** own, **you** configure, and **you** trust.

### Get Started in 3 Steps

1. **Add to `mix.exs`**:
   ```elixir
   {:ragex, "~> 0.30"}
   ```

2. **Configure Your Project**:
   ```bash
   mix deps.get && mix ragex.configure
   ```

3. **Connect Your Favorite Editor**:
   Add `bin/ragex-mcp` to your Claude Desktop or Zed settings, or run `mix ragex.chat` directly in your terminal.

---

*Explore the open source code, documentation, and benchmarks on [GitHub](https://github.com/Oeditus/ragex) or [Hex.pm](https://hex.pm/packages/ragex).*
