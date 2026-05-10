# Zed Editor Integration

Ragex provides first-class integration with the [Zed](https://zed.dev/) editor through three mechanisms:

1. **MCP Context Server** -- Ragex's ~50 tools are available in Zed's Agent Panel
2. **Task Runner** -- All Ragex mix tasks are accessible via `task: spawn`
3. **Keybindings** -- Common operations bound to keyboard shortcuts

## Quick Start

### Prerequisites

- Zed editor installed (`https://zed.dev/`)
- Elixir 1.19+ and Erlang/OTP 27+
- Ragex project compiled (`mix deps.get && mix compile`)
- Elixir extension installed in Zed (search "Elixir" in Extensions)

### 1. Open the Project

```bash
zed /path/to/ragex
```

Zed will automatically pick up the `.zed/settings.json`, `.zed/tasks.json`, and `.zed/keymap.json` from the project root.

### 2. Verify MCP Server

Open the Agent Panel (default: `Ctrl+Shift+?` or from Command Palette: `agent: open agent panel`).

Click the settings gear icon (top-right) and check that **ragex** shows a green status dot. If it shows red, check the troubleshooting section below.

### 3. Start Using

- **Agent Panel**: Ask the AI questions about your codebase -- it will use Ragex tools automatically
- **Task Runner**: Press `Ctrl+Shift+P`, type `task: spawn`, and pick any task
- **Keybindings**: Use the shortcuts listed below for quick access

## MCP Integration

### How It Works

Zed launches `bin/ragex-mcp` as a child process and communicates with it over stdin/stdout using the MCP protocol (JSON-RPC 2.0). Ragex exposes:

- **~50 Tools**: Code analysis, semantic search, RAG queries, refactoring, security scanning, etc.
- **6 Prompts**: Pre-built workflows for architecture analysis, impact analysis, code flow explanation, etc.
- **6 Resources**: Read-only access to graph stats, cache status, model config, project index, etc.

### Agent Profile: "Ragex RAG"

A dedicated agent profile is configured in `.zed/settings.json` that enables only Ragex-relevant tools. To use it:

1. Open the Agent Panel
2. Click the profile selector (top area)
3. Choose "Ragex RAG"

This disables network-fetching tools and enables all Ragex MCP tools for focused codebase analysis.

### Example Prompts

In the Agent Panel, try:

- "Using ragex, analyze the architecture of the lib/ directory"
- "Find all dead code in this project using ragex"
- "What functions call `Ragex.Graph.Store.add_node`?"
- "Search for code similar to 'validate user authentication'"
- "Run a security scan on lib/ragex/mcp/"
- "Show me the coupling report for this project"

### System-Wide Availability

The global Zed config (`~/.config/zed/settings.json`) includes Ragex as a system-wide MCP server pointing to the absolute path of `bin/ragex-mcp`. This means Ragex tools are available in the Agent Panel even when working on **other** projects. Pass `--project /path/to/code` to auto-analyze a specific codebase:

```json
"context_servers": {
  "ragex": {
    "command": {
      "path": "/home/am/Proyectos/Oeditus/ragex/bin/ragex-mcp",
      "args": ["--project", "/path/to/other/project"],
      "env": {}
    }
  }
}
```

## Task Runner

### Available Tasks

All tasks are defined in `.zed/tasks.json`. Access them via `Ctrl+Shift+P` > `task: spawn`.

#### Testing
| Task | Description |
|------|-------------|
| `mix test` | Run all tests |
| `mix test (current file)` | Test current file |
| `mix test (current line)` | Test at current cursor line |
| `mix test --cover` | Tests with coverage |
| `mix test --failed` | Re-run failed tests |

#### Code Quality
| Task | Description |
|------|-------------|
| `mix format` | Format all code |
| `mix format (check)` | Check formatting without changes |
| `mix credo --strict` | Static analysis |
| `mix quality (format + credo)` | Combined quality check |
| `mix dialyzer` | Type checking |

#### Ragex Analysis
| Task | Description |
|------|-------------|
| `ragex: analyze current file` | Analyze the open file |
| `ragex: analyze project` | Analyze entire project |
| `ragex: audit` | AI-powered code audit |
| `ragex: audit (current file)` | Audit the open file |

#### Ragex Cache
| Task | Description |
|------|-------------|
| `ragex: cache stats` | Show cache statistics |
| `ragex: cache refresh` | Incremental refresh |
| `ragex: cache refresh (full)` | Full re-index |
| `ragex: cache clear` | Clear all caches |

#### Ragex ML Models
| Task | Description |
|------|-------------|
| `ragex: download models` | Pre-download Bumblebee models |
| `ragex: migrate embeddings` | Migrate after model change |

#### Ragex Interactive
| Task | Description |
|------|-------------|
| `ragex: chat` | Interactive codebase Q&A |
| `ragex: refactor` | Interactive refactoring wizard |
| `ragex: configure` | Configuration wizard |
| `ragex: dashboard` | Live monitoring TUI |

#### Build
| Task | Description |
|------|-------------|
| `mix deps.get` | Fetch dependencies |
| `mix compile` | Compile project |
| `mix clean` | Clean build artifacts |
| `mix docs` | Generate documentation |

## Keybindings

Defined in `.zed/keymap.json`. These are project-scoped.

### Editor Context (requires open file)

| Shortcut | Action |
|----------|--------|
| `Ctrl+Shift+T` | Test current file |
| `Ctrl+Shift+L` | Test at current line |
| `Ctrl+Shift+Q` | Run quality checks |
| `Ctrl+Shift+F` | Format code |
| `Ctrl+Shift+A` | Analyze current file with Ragex |
| `Ctrl+Shift+R` | Open refactoring wizard |
| `Ctrl+Shift+D` | Open Ragex dashboard |

### Workspace Context (global)

| Shortcut | Action |
|----------|--------|
| `Ctrl+Alt+T` | Run all tests |
| `Ctrl+Alt+A` | Analyze entire project |
| `Ctrl+Alt+C` | Open Ragex chat |
| `Ctrl+Alt+S` | Show cache stats |

## Configuration Files

| File | Purpose |
|------|---------|
| `.zed/settings.json` | MCP server, language config, agent profile |
| `.zed/tasks.json` | All task definitions |
| `.zed/keymap.json` | Keyboard shortcuts |
| `bin/ragex-mcp` | MCP server launcher script |
| `~/.config/zed/settings.json` | Global Zed config (system-wide Ragex) |

## Launcher Script

`bin/ragex-mcp` is the entry point for the MCP server:

```bash
# Basic startup (inside project)
bin/ragex-mcp

# Auto-analyze a specific project
bin/ragex-mcp --project /path/to/code

# Override log level
bin/ragex-mcp --log-level debug

# Environment variable alternatives
RAGEX_PROJECT=/path/to/code bin/ragex-mcp
RAGEX_LOG_LEVEL=debug bin/ragex-mcp
```

The script:
- Sets `MIX_ENV=prod` for performance
- Enables stdio server (`RAGEX_STDIO=1`)
- Compiles silently (output to stderr)
- Runs `mix run --no-halt` for persistent server

## Troubleshooting

### MCP Server Shows Red Dot

1. Check Zed logs: `Ctrl+Shift+P` > `zed: open logs`
2. Look for lines mentioning "ragex"
3. Common causes:
   - `bin/ragex-mcp` not executable: `chmod +x bin/ragex-mcp`
   - Dependencies not compiled: run `mix deps.get && mix compile` first
   - Wrong path in global config: verify the absolute path in `~/.config/zed/settings.json`

### MCP Server Starts But No Tools Visible

- Switch to the "Ragex RAG" agent profile
- Mention "ragex" by name in your prompt to help the model find the tools
- Verify the server is green in Agent Panel settings

### Tasks Not Showing Up

- Make sure you opened the project root (where `.zed/` lives) in Zed
- Try `Ctrl+Shift+P` > `zed: open project tasks` to check if Zed found the tasks file
- Zed requires the project to be opened as a workspace (not individual files)

### Keybindings Not Working

- Project keybindings only apply when the Ragex workspace is active
- Check for conflicts: `Ctrl+Shift+P` > `zed: open keymap`
- Some bindings require Editor context (an open file with focus)

### Slow Startup

First launch compiles the project and downloads ML models (~400MB). Subsequent starts are fast. To pre-warm:

```bash
mix deps.get && mix compile && mix ragex.models.download
```

### Log Location

Ragex logs to `ragex.log` in the project root (configured in `config/config.exs`). Tail it for debugging:

```bash
tail -f ragex.log
```
