# ragex.nvim

Neovim / LunarVim client for [Ragex](https://github.com/Oeditus/ragex) — a
hybrid RAG system that builds a knowledge graph over your codebase and exposes
it over the [Model Context Protocol](https://modelcontextprotocol.io).

This plugin gives you Ragex's full tool surface (~50 tools) from inside the
editor: semantic & hybrid search, call-graph navigation, refactoring, quality
and security analysis, and streaming AI answers — all without leaving Neovim.

> This is a from-scratch rewrite located under `editors/nvim/`. It supersedes
> the earlier `nvim-plugin/` and `lvim.cfg/` attempts.

---

## Features

- **Hybrid transport** — reuses a running Ragex server over its per-project
  Unix socket when available, and transparently falls back to spawning
  `bin/ragex-mcp` as a stdio child. Auto-reconnects on failure.
- **Full tool catalog** — every Ragex MCP tool is reachable through a single
  declarative catalog (`:Ragex <tool>`), grouped into an interactive menu.
- **Telescope pickers** for search results (graceful `vim.ui.select` fallback
  when Telescope is absent).
- **Streaming RAG** — `rag_query` / `rag_explain` / `rag_suggest` stream tokens
  into a scratch buffer via MCP progress notifications.
- **Safe refactoring** — rename function/module project-wide with preview,
  confirmation, and automatic buffer reload.
- **Zero required dependencies** — works with stock Neovim. Telescope is
  optional; `socat` is only needed for the socket transport.

## Requirements

- Neovim 0.9+ (0.10+ recommended) or LunarVim
- A Ragex checkout with `bin/ragex-mcp` (Elixir 1.18+, Erlang/OTP 27+)
- Optional: `socat` (for the socket transport), `telescope.nvim` (for pickers),
  `jq` (for pretty JSON output)

## Installation

### lazy.nvim

```lua
{
  dir = "/path/to/ragex/editors/nvim",
  config = function()
    require("ragex").setup({
      ragex_bin = "/path/to/ragex/bin/ragex-mcp",
    })
  end,
}
```

### LunarVim (`~/.config/lvim/config.lua`)

```lua
lvim.plugins = {
  {
    dir = "/path/to/ragex/editors/nvim",
    config = function()
      require("ragex").setup({
        ragex_bin = "/path/to/ragex/bin/ragex-mcp",
        keymaps = true,
      })
    end,
  },
}
```

### Manual

Add the plugin directory to your runtimepath and call `setup()`:

```lua
vim.opt.runtimepath:append("/path/to/ragex/editors/nvim")
require("ragex").setup({ ragex_bin = "/path/to/ragex/bin/ragex-mcp" })
```

## Configuration

```lua
require("ragex").setup({
  -- Path to the ragex-mcp launcher. Auto-detected by walking up from cwd
  -- looking for bin/ragex-mcp if omitted.
  ragex_bin = "~/Proyectos/Oeditus/ragex/bin/ragex-mcp",

  -- Project root passed to the server as --project (defaults to cwd).
  project = nil,

  -- Transport: "auto" (live socket if one is listening, else stdio),
  -- "socket", or "stdio". `mode` is accepted as a deprecated alias.
  transport = "auto",

  -- Override the computed socket path (defaults to the Ragex precedence:
  -- RAGEX_MCP_SOCK -> DLLB_PORT -> sanitized project path).
  socket_path = nil,

  enabled = true,
  debug = false,
  log_level = "info",

  -- Re-index the current file on save.
  auto_analyze = false,

  -- Automatically analyze the project on startup. Shows live progress
  -- updates (`Ȝ ragex [X/Y: file]`) on the statusline, and transitions
  -- to `Ȝ ragex` when finished.
  auto_analyze_on_start = true,

  -- Extra directories to analyze on startup.
  auto_analyze_dirs = {},

  -- Default request timeout (ms).
  timeout = 60000,

  -- Install default <leader>r* keymaps.
  keymaps = true,

  -- Show "Ȝ ragex" (and live indexing progress) in the statusline when connected.
  statusline = true,

  search = {
    limit = 30,
    threshold = 0.2,
    strategy = "fusion", -- "fusion" | "semantic_first" | "graph_first"
  },
})
```

## Commands

The plugin exposes dispatcher commands plus convenience commands.

| Command | Description |
|---|---|
| `:Ragex` | Interactive menu of all tools, grouped by category |
| `:Ragex tools` | List every available tool in a buffer |
| `:Ragex status` | Show connection + graph summary |
| `:Ragex search` | Hybrid search with a Telescope picker |
| `:Ragex semantic` | Semantic search with a Telescope picker |
| `:Ragex word` | Search for the word under the cursor |
| `:Ragex analyze` | Analyze the current file |
| `:Ragex analyze_dir` | Analyze the project directory |
| `:Ragex query <text>` | Streaming RAG query |
| `:Ragex explain` | Streaming RAG explanation of the current file |
| `:Ragex suggest` | Streaming RAG suggestions for the current file |
| `:RagexCR [base]` | PR Code Review analysis against `main`/`master` (or `[base]`) |
| `:Ragex rename_function` | Rename a function project-wide |
| `:Ragex rename_module` | Rename a module project-wide |
| `:Ragex auto` | Toggle auto-analysis on save |
| `:Ragex <tool> [k=v ...]` | Call **any** catalog tool directly |

The generic form is the escape hatch for the long tail of tools:

```vim
:Ragex graph_stats
:Ragex find_dead_code scope=exports min_confidence=0.7
:Ragex analyze_impact target=MyApp.Worker.perform/1
:Ragex scan_security path=lib/my_app/auth.ex
```

Values are coerced: `true`/`false` → booleans, numerics → numbers, and
`{...}`/`[...]` → decoded JSON.

## Default keymaps

When `keymaps = true`, the following `<leader>r*` mappings are installed:

| Mapping | Action |
|---|---|
| `<leader>rs` | Semantic search |
| `<leader>rh` | Hybrid search |
| `<leader>rw` | Search word under cursor |
| `<leader>rf` | Find callers |
| `<leader>rp` | Find call paths |
| `<leader>ra` | Analyze current file |
| `<leader>rA` | Analyze project |
| `<leader>rg` | Graph statistics |
| `<leader>rq` | RAG query (streaming) |
| `<leader>re` | RAG explain (streaming) |
| `<leader>rS` | RAG suggest (streaming) |
| `<leader>rr` | Rename function |
| `<leader>rR` | Rename module |
| `<leader>rc` | Security scan (current file) |
| `<leader>rd` | Find dead code |
| `<leader>rm` | MCP telemetry |

Set `keymaps = false` to manage your own.

## Lua API

```lua
local ragex = require("ragex")

ragex.search_semantic("function that parses JSON")
ragex.search_hybrid("database connection pooling")
ragex.analyze_file()
ragex.analyze_directory()
ragex.rag_query("How does authentication work?")
ragex.rename_function()
ragex.graph_stats()
ragex.call("find_dead_code")   -- any catalog tool
```

## Health check

```vim
:checkhealth ragex
```

Verifies the Neovim version, the `ragex-mcp` binary, `socat`, socket presence,
Telescope availability, and performs a live connectivity probe.

## How it works

```
┌──────────────┐   JSON-RPC 2.0   ┌───────────────────────┐
│  ragex.nvim  │ ───────────────► │  Unix socket (socat)  │──┐
│  (client)    │                  └───────────────────────┘  │
│              │   JSON-RPC 2.0   ┌───────────────────────┐  │
│              │ ───────────────► │  bin/ragex-mcp (stdio)│──┤
└──────────────┘                  └───────────────────────┘  │
                                                             ▼
                                              ┌───────────────────────────┐
                                              │  Ragex MCP server (BEAM)  │
                                              │  knowledge graph + RAG    │
                                              └───────────────────────────┘
```

The socket path is resolved with the same precedence as the Elixir server and
the Bash launcher, so the plugin always talks to the correct per-project
instance:

1. `RAGEX_MCP_SOCK` (verbatim override)
2. `DLLB_PORT` → `/tmp/ragex_mcp_<port>.sock`
3. otherwise → `/tmp/ragex_mcp_<sanitized-project-path>.sock`

## Troubleshooting

**"could not connect" / "socket bridge closed"**
The server isn't running and the stdio fallback also failed. Start Ragex
(`bin/ragex-mcp --project /path/to/project`) or check `:Ragex status`.

**Search returns no results**
The project hasn't been indexed, or embeddings aren't loaded yet. Run
`:Ragex analyze_dir` and wait for the embedding model to warm up.

**RAG tools fail with `:no_results_found`**
The RAG pipeline needs indexed embeddings for the current project. Run
`:Ragex analyze_dir` first, and ensure an AI provider key is configured
(`DEEPSEEK_API_KEY`, etc.) on the server side.

**No Telescope pickers**
Install `telescope.nvim`; the plugin falls back to `vim.ui.select` otherwise.

## Tests

```bash
cd /path/to/ragex
nvim --headless -u editors/nvim/tests/minimal_init.lua -l editors/nvim/tests/smoke.lua
```

## License

GPL-3.0 (matches the Ragex project).
