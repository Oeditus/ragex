# Using Ragex as a Local MCP Server

Ragex is a self-hosted MCP (Model Context Protocol) server that adds Hybrid RAG capabilities to any MCP-compatible AI client or editor. It runs entirely on your machine — no external services, no data leaving your system.

## Table of Contents

- [What You Get](#what-you-get)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Transport Modes](#transport-modes)
- [Starting the Server](#starting-the-server)
- [Connecting MCP Clients](#connecting-mcp-clients)
  - [Claude Desktop](#claude-desktop)
  - [Cursor](#cursor)
  - [Zed](#zed)
  - [LunarVim / NeoVim](#lunarvim--neovim)
  - [Generic stdio client](#generic-stdio-client)
- [Indexing Your Codebase](#indexing-your-codebase)
- [RAG Queries](#rag-queries)
- [Embedding Models](#embedding-models)
- [AI Providers for RAG](#ai-providers-for-rag)
- [Configuration Reference](#configuration-reference)
- [Keeping the Index Fresh](#keeping-the-index-fresh)
- [Performance Tips](#performance-tips)
- [Troubleshooting](#troubleshooting)

---

## What You Get

Once connected, any attached AI agent gains access to roughly 50 MCP tools covering:

- **Code indexing** — analyze files and directories into a knowledge graph
- **Semantic search** — natural-language queries resolved by local ML embeddings
- **Hybrid search** — symbolic graph + semantic retrieval fused with Reciprocal Rank Fusion
- **RAG pipeline** — `rag_query`, `rag_explain`, `rag_suggest` backed by your configured AI provider
- **Safe editing** — atomic multi-file edits with validation, backup, and rollback
- **Semantic refactoring** — rename functions and modules project-wide with AST awareness
- **Code analysis** — dead code, duplication, coupling, security, smells, quality metrics
- **Graph algorithms** — PageRank, betweenness centrality, community detection

Languages supported for analysis: Elixir, Erlang, Python, Ruby, JavaScript/TypeScript.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Elixir 1.18+ | Check with `elixir --version` |
| Erlang/OTP 27+ | Bundled with Elixir installations from asdf/mise |
| ~500 MB RAM | For the default embedding model at runtime |
| ~200 MB disk | Build artefacts + the first-run model download (~90 MB) |
| Python 3.x | Optional; required only for Python file analysis |
| Node.js | Optional; required only for JavaScript/TypeScript file analysis |

---

## Installation

```bash
git clone https://github.com/Oeditus/ragex.git
cd ragex
mix deps.get
mix compile
```

First compilation takes a few minutes because of the ML dependencies (Nx, EXLA, Bumblebee). The embedding model itself (~90 MB) is downloaded from HuggingFace on the first server start and cached in `~/.cache/huggingface/`.

To pre-download it before the first real use:

```bash
mix ragex.models.download
```

---

## Transport Modes

Ragex speaks MCP over two transports simultaneously:

| Transport | Address | Best for |
|-----------|---------|----------|
| **stdio** | stdin / stdout | Editor integrations (Zed, Cursor, Claude Desktop, Warp) |
| **Unix socket** | `/tmp/ragex_mcp.sock` | Local tooling, LunarVim plugin, `socat` scripts |

Both are active whenever the server is running. The stdio transport is the one MCP specifications require; the socket transport is an extension for clients that cannot manage a long-lived subprocess.

When a second process tries to start Ragex while a socket server is already alive, `bin/ragex-mcp` detects this automatically and launches a lightweight bridge (`bin/ragex-bridge`) instead of spinning up a second BEAM VM with another GPU/ML model allocation.

---

## Starting the Server

### Recommended: use the launcher script

```bash
./bin/ragex-mcp
```

This script:

1. Sets `MIX_ENV=prod` for optimized performance.
2. Sets `RAGEX_STDIO=1` so the server accepts MCP commands on stdin/stdout.
3. Compiles silently (output to stderr so JSON-RPC on stdout stays clean).
4. Detects a running instance via the Unix socket — bridges to it instead of double-starting.
5. Runs `mix run --no-halt` to keep the process alive.

Optional flags:

```bash
# Auto-analyze a project directory on startup
bin/ragex-mcp --project /path/to/your/project

# Override log verbosity
bin/ragex-mcp --log-level debug
```

Equivalent environment variables:

```bash
RAGEX_PROJECT=/path/to/your/project  bin/ragex-mcp
RAGEX_LOG_LEVEL=debug                bin/ragex-mcp
RAGEX_EMBEDDING_MODEL=codebert_base  bin/ragex-mcp
```

### Minimal start (development)

```bash
mix run --no-halt
```

### Background start with logging

```bash
./start_mcp.sh           # writes logs to ragex.log in the project root
./start_server.sh        # writes logs to /tmp/ragex_server.log
```

### Interactive / debug shell

```bash
RAGEX_NO_SERVER=1 iex -S mix
```

This starts an IEx session with the full application loaded but without the MCP server, useful for ad-hoc testing.

---

## Connecting MCP Clients

All MCP clients that communicate over stdio need the path to `bin/ragex-mcp` and the working directory of the Ragex project. Use the absolute path.

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or the equivalent path on Linux (`~/.config/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "ragex": {
      "command": "/absolute/path/to/ragex/bin/ragex-mcp",
      "args": [],
      "env": {}
    }
  }
}
```

To automatically index a project when Claude starts:

```json
{
  "mcpServers": {
    "ragex": {
      "command": "/absolute/path/to/ragex/bin/ragex-mcp",
      "args": ["--project", "/path/to/your/elixir/project"],
      "env": {}
    }
  }
}
```

Restart Claude Desktop after saving. Ragex tools will appear in the tool list.

### Cursor

Create or edit `.cursor/mcp.json` in your home directory or project root:

```json
{
  "mcpServers": {
    "ragex": {
      "command": "/absolute/path/to/ragex/bin/ragex-mcp",
      "args": ["--project", "${workspaceFolder}"],
      "env": {
        "RAGEX_LOG_LEVEL": "warning"
      }
    }
  }
}
```

### Zed

Add to `~/.config/zed/settings.json` for system-wide availability:

```json
{
  "context_servers": {
    "ragex": {
      "command": {
        "path": "/absolute/path/to/ragex/bin/ragex-mcp",
        "args": [],
        "env": {}
      }
    }
  }
}
```

To auto-analyze a specific project when using Ragex from within any other workspace:

```json
{
  "context_servers": {
    "ragex": {
      "command": {
        "path": "/absolute/path/to/ragex/bin/ragex-mcp",
        "args": ["--project", "/path/to/your/project"],
        "env": {}
      }
    }
  }
}
```

For per-project configuration place `.zed/settings.json` in the project root. See [ZED.md](ZED.md) for the full Zed integration guide including task runner and keybindings.

### LunarVim / NeoVim

LunarVim communicates with Ragex through the Unix socket (`/tmp/ragex_mcp.sock`). Start the server first, then use the Lua plugin:

**Step 1 — start the server** (in a terminal, keep it running):

```bash
cd /path/to/ragex
./start_mcp.sh
```

Verify it is alive:

```bash
./test_socket.sh
```

**Step 2 — install the plugin files**

Copy `lvim.cfg/lua/user/` into your LunarVim config directory (typically `~/.config/lvim/lua/user/`) and add the snippet from the main README to your `config.lua`. The plugin communicates with the socket using `socat`.

**Step 3 — verify**

```vim
:lua print(require('ragex').config.socket_path)   -- should print /tmp/ragex_mcp.sock
:Ragex search
```

See `SERVER_GUIDE.md` in the project root for detailed socket-mode troubleshooting.

### Generic stdio client

Any program can speak to Ragex over stdio. Send newline-delimited JSON-RPC 2.0 messages:

```bash
# Initialize
echo '{"jsonrpc":"2.0","method":"initialize","params":{"clientInfo":{"name":"my-client","version":"1.0"}},"id":1}' \
  | bin/ragex-mcp

# List tools
echo '{"jsonrpc":"2.0","method":"tools/list","id":2}' | bin/ragex-mcp
```

From Python:

```python
import json, subprocess

proc = subprocess.Popen(
    ["/path/to/ragex/bin/ragex-mcp"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
)

def call(method, params, id=1):
    req = json.dumps({"jsonrpc": "2.0", "method": "tools/call",
                      "params": {"name": method, "arguments": params}, "id": id})
    proc.stdin.write(req.encode() + b"\n")
    proc.stdin.flush()
    return json.loads(proc.stdout.readline())

call("analyze_directory", {"path": "/my/project", "recursive": True})
```

---

## Indexing Your Codebase

Ragex needs to analyze your codebase before it can answer questions about it. Once the server is running, ask the connected AI to call these tools, or invoke them directly.

### Analyze a directory (MCP tool call)

```json
{
  "name": "analyze_directory",
  "arguments": {
    "path": "/path/to/your/project",
    "recursive": true,
    "generate_embeddings": true
  }
}
```

This populates the in-memory ETS knowledge graph and generates 384-dimensional embeddings for every module and function. Typical throughput is ~100 files per second; a 1,000-file project takes under 30 seconds.

### Auto-analyze on startup

Add directories to index automatically every time Ragex starts:

```elixir
# config/config.exs
config :ragex, :auto_analyze_dirs, [
  "/path/to/project-a",
  "/path/to/project-b"
]
```

Or pass a single path via environment variable / CLI flag:

```bash
RAGEX_AUTO_ANALYZE=/path/to/project bin/ragex-mcp
bin/ragex-mcp --project /path/to/project
```

### Watch for changes

Enable automatic re-indexing whenever files change:

```json
{
  "name": "watch_directory",
  "arguments": {
    "path": "/path/to/your/project"
  }
}
```

Only modified files are re-analyzed (SHA256-based change detection), so incremental updates are fast.

---

## RAG Queries

RAG tools combine local semantic retrieval with an external AI provider to answer questions grounded in your actual code.

### Ask a question

```json
{
  "name": "rag_query",
  "arguments": {
    "query": "How does authentication work in this codebase?",
    "limit": 15,
    "include_code": true
  }
}
```

Ragex retrieves the most relevant functions and modules via hybrid search, formats them as context (up to ~8,000 characters), and sends them together with your question to the configured AI provider.

### Explain a function or file

```json
{
  "name": "rag_explain",
  "arguments": {
    "target": "MyApp.Auth.authenticate_user/2",
    "aspect": "complexity"
  }
}
```

`aspect` can be `purpose`, `complexity`, `dependencies`, or `all`.

### Suggest improvements

```json
{
  "name": "rag_suggest",
  "arguments": {
    "target": "lib/my_app/auth.ex",
    "focus": "security"
  }
}
```

`focus` can be `performance`, `readability`, `testing`, `security`, or `all`.

### Streaming variants

All three tools have streaming counterparts (`rag_query_stream`, `rag_explain_stream`, `rag_suggest_stream`) that emit partial responses as they arrive from the AI provider.

### Interactive chat (CLI)

```bash
mix ragex.chat --provider deepseek_r1
```

Opens a REPL that runs a ReAct agent loop: the AI calls Ragex tools directly to gather evidence before answering.

---

## Embedding Models

Embeddings power semantic and hybrid search. Four models are pre-configured:

| Model ID | Dimensions | Size | Best for |
|----------|-----------|------|----------|
| `all_minilm_l6_v2` | 384 | ~90 MB | Default; fast; good general quality |
| `all_mpnet_base_v2` | 768 | ~420 MB | Highest quality; large codebases |
| `codebert_base` | 768 | ~500 MB | Code-specific queries; API discovery |
| `paraphrase_multilingual` | 384 | ~110 MB | Non-English comments and documentation |

Configure in `config/config.exs`:

```elixir
config :ragex, :embedding_model, :all_minilm_l6_v2
```

Or via environment variable (overrides config):

```bash
export RAGEX_EMBEDDING_MODEL=codebert_base
```

Models with the same number of dimensions are cache-compatible — you can switch between `all_minilm_l6_v2` and `paraphrase_multilingual` without regenerating embeddings. Switching between 384-dim and 768-dim models requires a re-index.

Check current model and cache status:

```bash
mix ragex.embeddings.migrate --check
```

Manage the embedding cache:

```bash
mix ragex.cache.stats          # Show cache statistics
mix ragex.cache.refresh        # Incremental refresh (changed files only)
mix ragex.cache.clear --all    # Clear all cached embeddings
```

---

## AI Providers for RAG

RAG tools (`rag_query`, `rag_explain`, `rag_suggest`) require an external AI provider. Configure via environment variables:

```bash
# DeepSeek (default provider)
export DEEPSEEK_API_KEY="sk-..."

# OpenAI
export OPENAI_API_KEY="sk-..."

# Anthropic
export ANTHROPIC_API_KEY="sk-ant-..."

# Ollama (local, no key needed)
export OLLAMA_HOST="http://localhost:11434"
```

Set the default provider in `config/config.exs`:

```elixir
config :ragex, :ai,
  providers: [:openai, :anthropic, :deepseek_r1, :ollama],
  default_provider: :deepseek_r1,
  fallback_enabled: true
```

Override the provider per-query:

```json
{
  "name": "rag_query",
  "arguments": {
    "query": "What does the supervisor tree look like?",
    "provider": "ollama"
  }
}
```

AI responses are cached (ETS, TTL 1 hour by default) to avoid redundant API calls. Monitor usage:

```json
{"name": "get_ai_usage", "arguments": {}}
{"name": "get_ai_cache_stats", "arguments": {}}
```

Semantic search and hybrid search work entirely offline using local Bumblebee embeddings — no AI provider key is needed for these.

---

## Configuration Reference

The main configuration file is `config/config.exs`. Below are the most relevant sections for MCP server usage.

### Embedding model

```elixir
config :ragex, :embedding_model, :all_minilm_l6_v2
```

### Embedding cache

```elixir
config :ragex, :cache,
  enabled: true,
  dir: Path.expand("~/.cache/ragex"),
  max_age_days: 30
```

### Auto-analyze on startup

```elixir
config :ragex, :auto_analyze_dirs, [
  "/path/to/project-a",
  "/path/to/project-b"
]
```

### AI providers

```elixir
config :ragex, :ai,
  providers: [:openai, :anthropic, :deepseek_r1, :ollama],
  default_provider: :deepseek_r1,
  fallback_enabled: true
```

### AI features (optional)

Enable AI-enhanced analysis features (require an AI provider):

```elixir
config :ragex, :ai_features,
  validation_error_explanation: true,   # AI explanations for syntax errors
  refactor_preview_commentary: true,    # Risk analysis in refactor previews
  dead_code_refinement: true,           # Reduce false positives in dead code reports
  duplication_semantic_analysis: true,  # Semantic Type IV clone detection
  dependency_insights: true             # Architectural insights for coupling analysis
```

### Search thresholds

```elixir
config :ragex, :search,
  default_threshold: 0.2,   # similarity cutoff for semantic_search
  hybrid_threshold: 0.15    # similarity cutoff for hybrid_search (lower = more recall)
```

### Editor / backup settings

```elixir
config :ragex, :editor,
  backup_dir: Path.expand("~/.ragex/backups"),
  backup_retention: 10,
  validate_by_default: true,
  create_backup_by_default: true
```

### Graph algorithm limits

```elixir
config :ragex, :graph,
  max_nodes_betweenness: 10_000,
  max_nodes_export: 10_000
```

---

## Keeping the Index Fresh

Ragex stores the knowledge graph in ETS (in-memory). The state is lost when the server stops. On restart:

1. **Embedding cache** is loaded from disk (`~/.cache/ragex/`) — this makes semantic search available within a few seconds.
2. **Graph nodes/edges** are rebuilt by re-analyzing directories listed in `auto_analyze_dirs`.
3. **File watcher** resumes watching once `watch_directory` is called again (or configured via auto-analyze).

For a project you work on daily, a sensible setup is:

```elixir
# config/config.exs
config :ragex, :auto_analyze_dirs, ["/path/to/my/project"]
```

Combined with watching:

```json
{"name": "watch_directory", "arguments": {"path": "/path/to/my/project"}}
```

This gives you a fully up-to-date graph within seconds of each server start, with no manual re-indexing.

---

## Performance Tips

**First startup is slow** — the ML model loads and JIT-compiles via EXLA. Expect 30–90 seconds. Every subsequent start is fast because the model binary is cached by Bumblebee.

**First analysis is slow** — embedding generation takes ~50 ms per entity. For a 500-function project that is ~25 seconds. The embedding cache makes this a one-time cost.

**Memory** — the default `all_minilm_l6_v2` model requires ~400 MB RAM. Larger models (`all_mpnet_base_v2`, `codebert_base`) need ~800–900 MB. Plan accordingly if running Ragex alongside other memory-intensive processes.

**Search quality vs. speed** — the default similarity threshold of `0.2` favors recall. For precise lookup, raise it to `0.7`+. For exploratory questions, keep it at the default or lower.

**Large codebases (>10,000 entities)** — use incremental cache refresh (`mix ragex.cache.refresh`) instead of full re-analysis on each server restart.

---

## Troubleshooting

### Server won't start

```bash
mix compile                    # check for compilation errors
mix deps.get && mix compile    # fetch missing dependencies
```

### Embedding model download fails

The model is fetched from HuggingFace on first run. If you are behind a proxy or firewall:

```bash
# Set proxy
export HTTPS_PROXY=http://proxy:port

# Or pre-download manually
mix ragex.models.download
```

Model cache location: `~/.cache/huggingface/`

### MCP client shows no tools / red indicator

```bash
# Confirm the binary is executable
chmod +x bin/ragex-mcp bin/ragex-bridge

# Test stdio mode manually
echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | bin/ragex-mcp
# Should print a JSON response with a "result" field containing tool definitions
```

Check editor-specific logs:

- **Zed**: `Ctrl+Shift+P` > "zed: open logs", search for "ragex"
- **Cursor**: Help > Toggle Developer Tools > Console
- **Claude Desktop**: open `~/Library/Logs/Claude/` (macOS)

### Socket server: "connection refused" or hanging

```bash
# Kill stale process and clean up socket
pkill -f "mix run"
rm -f /tmp/ragex_mcp.sock

# Restart
./start_mcp.sh

# Verify
./test_socket.sh
```

### RAG queries return no AI response

Ensure the provider API key is set in the environment where Ragex is launched:

```bash
DEEPSEEK_API_KEY=sk-...  bin/ragex-mcp
```

Check usage and limits:

```json
{"name": "get_ai_usage", "arguments": {}}
```

### Search returns poor results

- Lower the threshold: `"threshold": 0.1`
- Switch retrieval strategy: `"strategy": "semantic_first"` or `"graph_first"`
- Try a different query phrasing
- Verify the codebase is indexed: `{"name": "graph_stats", "arguments": {}}`
- Check embeddings exist: `{"name": "get_embeddings_stats", "arguments": {}}`

### High memory / OOM

Switch to the smaller model:

```elixir
# config/config.exs
config :ragex, :embedding_model, :all_minilm_l6_v2
```

Or set via environment before starting:

```bash
RAGEX_EMBEDDING_MODEL=all_minilm_l6_v2 bin/ragex-mcp
```

### Logs

Ragex logs to `ragex.log` (rotating, max 10 MB, 5 files) in the project root by default. Tail it for real-time diagnostics:

```bash
tail -f ragex.log
```

To increase verbosity:

```bash
LOG_LEVEL=debug bin/ragex-mcp
```

---

## See Also

- [CONFIGURATION.md](CONFIGURATION.md) — full configuration reference including model migration
- [TOOLS.md](TOOLS.md) — complete MCP tools reference with parameters
- [USAGE.md](USAGE.md) — editor-specific integration guides (VIM, LunarVim)
- [ZED.md](ZED.md) — first-class Zed integration (tasks, keybindings, agent profile)
- [PERSISTENCE.md](PERSISTENCE.md) — embedding cache internals and management
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — error messages and analysis issues
- [SERVER_GUIDE.md](../../SERVER_GUIDE.md) — Unix socket server management
