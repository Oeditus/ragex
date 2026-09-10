# Ragex editor integrations

First-class editor clients for the [Ragex](../README.md) MCP server, built from
scratch under `editors/`.

| Editor | Directory | Language | Transport | UI |
|---|---|---|---|---|
| Neovim / LunarVim | [`nvim/`](nvim/) | Lua | socket + stdio (hybrid) | Telescope + floats (optional) |
| VS Code | [`vscode/`](vscode/) | TypeScript | socket + stdio (hybrid) | QuickPick + virtual docs |
| Zed | [`zed/`](zed/) | JSON bundle | stdio (via `bin/ragex-mcp`) | Agent Panel + tasks |

## Shared design

All three integrations follow the same principles:

- **Hybrid transport.** Prefer a running Ragex server over its per-project Unix
  socket (reusing the warm VM: graph, embeddings, dllb pool); fall back to
  spawning `bin/ragex-mcp` as a stdio child. Reconnect lazily on failure.
- **One socket-path rule.** The path is resolved with identical precedence in
  every client (and in the Elixir server + Bash launcher):
  1. `RAGEX_MCP_SOCK` — verbatim override
  2. `DLLB_PORT` — `/tmp/ragex_mcp_<port>.sock`
  3. otherwise — `/tmp/ragex_mcp_<sanitized-project-path>.sock`
- **Full tool catalog.** Every MCP tool is reachable through a declarative
  catalog, so the whole ~50-tool surface is exposed without per-tool plumbing.
- **Streaming RAG.** `rag_query` / `rag_explain` / `rag_suggest` stream tokens
  via MCP `notifications/progress`.

## Install

Each directory has its own README with detailed instructions:

- [Neovim / LunarVim](nvim/README.md)
- [VS Code](vscode/README.md)
- [Zed](zed/README.md)

## Verifying

```bash
# Neovim
nvim --headless -u editors/nvim/tests/minimal_init.lua -l editors/nvim/tests/smoke.lua

# VS Code
cd editors/vscode && npm install && npm run compile && node tests/transport.test.js

# Zed
cd editors/zed && ./install.sh /path/to/your/project
```

## Deprecated

The earlier attempts at `nvim-plugin/`, `lvim.cfg/`, and the root `.zed/*`
files predate many Ragex features and are superseded by this directory. They
are retained for reference only.
