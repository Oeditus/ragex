# Ragex for VS Code

Visual Studio Code extension for [Ragex](https://github.com/Oeditus/ragex) — a
hybrid RAG system that builds a knowledge graph over your codebase and exposes
it over the [Model Context Protocol](https://modelcontextprotocol.io).

The extension brings Ragex's full tool surface (~50 tools) into VS Code:
semantic & hybrid search, call-graph navigation, refactoring, quality and
security analysis, and streaming AI answers.

> This is a from-scratch rewrite located under `editors/vscode/`.

---

## Features

- **Hybrid transport** — reuses a running Ragex server over its per-project
  Unix socket when available, and transparently falls back to spawning
  `bin/ragex-mcp` as a stdio child. Auto-reconnects on failure.
- **Full tool catalog** — every Ragex MCP tool is reachable through a single
  declarative catalog (`Ragex: Tool Menu` / `Ragex: Call Tool…`).
- **QuickPick search results** — jump straight to `file:line` from search hits.
- **Streaming RAG** — `Ragex: Ask a Question` streams tokens into a live panel.
- **Safe refactoring** — rename function/module project-wide with a modal
  confirmation.
- **Editor integration** — context-menu entries, keybindings, an output
  channel, and settings for every knob.

## Requirements

- VS Code 1.90+
- A Ragex checkout with `bin/ragex-mcp` (Elixir 1.18+, Erlang/OTP 27+)

## Getting started

```bash
cd editors/vscode
npm install
npm run compile
```

Then press <kbd>F5</kbd> in VS Code to launch an Extension Development Host, or
package it with `npx vsce package` and install the resulting `.vsix`.

## Configuration

| Setting | Default | Description |
|---|---|---|
| `ragex.binPath` | `""` | Path to `ragex-mcp`. Auto-detected by walking up from the workspace root. |
| `ragex.transport` | `auto` | `auto` \| `socket` \| `stdio`. |
| `ragex.socketPath` | `""` | Override the computed socket path. |
| `ragex.projectRoot` | `""` | Project root passed as `--project`. Defaults to the first workspace folder. |
| `ragex.logLevel` | `info` | Log level passed to the server. |
| `ragex.autoAnalyzeOnSave` | `false` | Re-index the current file on save. |
| `ragex.analyzeOnStartup` | `false` | Analyze the project on activation. |
| `ragex.search.limit` | `30` | Maximum search results. |
| `ragex.search.threshold` | `0.2` | Minimum similarity score. |
| `ragex.search.strategy` | `fusion` | Hybrid search strategy. |
| `ragex.debug` | `false` | Log transport traffic to the Ragex output channel. |

## Commands

| Command | Description |
|---|---|
| `Ragex: Tool Menu` | Interactive category → tool picker |
| `Ragex: Call Tool…` | Call any tool with JSON arguments |
| `Ragex: Show Status` | Connection + graph summary |
| `Ragex: Restart Connection` | Tear down and reconnect |
| `Ragex: Hybrid Search` | Hybrid search with a QuickPick |
| `Ragex: Semantic Search` | Semantic search with a QuickPick |
| `Ragex: Search Word Under Cursor` | Search the word at the caret |
| `Ragex: Analyze Current File` | Index the active file |
| `Ragex: Analyze Project` | Index the workspace |
| `Ragex: Ask a Question (RAG)` | Streaming RAG query |
| `Ragex: Explain Current File (AI)` | Streaming RAG explanation |
| `Ragex: Suggest Improvements (AI)` | Streaming RAG suggestions |
| `Ragex: Rename Function (project-wide)` | Semantic rename |
| `Ragex: Rename Module (project-wide)` | Semantic rename |
| `Ragex: Find Callers` | Callers of a function |
| `Ragex: Graph Statistics` | Knowledge-graph stats |

## Keybindings

| Key | Command |
|---|---|
| <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>R</kbd> <kbd>S</kbd> | Hybrid search |
| <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>R</kbd> <kbd>Q</kbd> | RAG query |
| <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>R</kbd> <kbd>A</kbd> | Analyze file |

(On macOS, use <kbd>Cmd</kbd> instead of <kbd>Ctrl</kbd>.)

## How it works

```
┌────────────────┐   JSON-RPC 2.0   ┌──────────────────────┐
│  VS Code ext   │ ───────────────► │  Unix socket (net)   │──┐
│  (Node)        │                  └──────────────────────┘  │
│                │   JSON-RPC 2.0   ┌──────────────────────┐  │
│                │ ───────────────► │  bin/ragex-mcp (stdio)│──┤
└────────────────┘                  └──────────────────────┘  │
                                                              ▼
                                               ┌───────────────────────────┐
                                               │  Ragex MCP server (BEAM)  │
                                               │  knowledge graph + RAG    │
                                               └───────────────────────────┘
```

The socket path is resolved with the same precedence as the Elixir server and
the Bash launcher:

1. `RAGEX_MCP_SOCK` (verbatim override)
2. `DLLB_PORT` → `/tmp/ragex_mcp_<port>.sock`
3. otherwise → `/tmp/ragex_mcp_<sanitized-project-path>.sock`

## Troubleshooting

**"could not connect" / "ragex-mcp exited"**
The server isn't running and the stdio fallback also failed. Start Ragex
(`bin/ragex-mcp --project /path/to/project`) or run `Ragex: Show Status`.

**Search returns no results**
The project hasn't been indexed. Run `Ragex: Analyze Project` and wait for the
embedding model to warm up.

**RAG tools fail with `:no_results_found`**
The RAG pipeline needs indexed embeddings for the current project. Run
`Ragex: Analyze Project` first, and ensure an AI provider key is configured on
the server side.

## Development

```bash
npm install
npm run compile     # one-shot build
npm run watch       # incremental build
npm run lint        # eslint
node tests/transport.test.js   # headless transport integration test
```

## License

GPL-3.0 (matches the Ragex project).
