# Ragex for Zed

Curated [Zed](https://zed.dev) configuration bundle for
[Ragex](https://github.com/Oeditus/ragex) — a hybrid RAG system that builds a
knowledge graph over your codebase and exposes it over the
[Model Context Protocol](https://modelcontextprotocol.io).

This bundle wires Ragex into Zed in two ways:

1. **MCP context server** — Zed's Agent Panel can call any of Ragex's ~50 tools
   (analysis, search, RAG, refactoring, quality, security, git archaeology).
2. **Task runner** — Ragex's CLI workflows (`analyze`, `audit`, `chat`,
   `refactor`, `dashboard`, cache management) are available as Zed tasks with
   keybindings.

> This is a from-scratch rewrite located under `editors/zed/`. It supersedes
> the earlier `.zed/*` files, which are now deprecated.

---

## Contents

| File | Purpose |
|---|---|
| `settings.json` | MCP context server registration + a dedicated "Ragex RAG" agent profile + Elixir LSP config |
| `tasks.json` | Ragex CLI tasks (analysis, audits, chat, refactor, dashboard, cache, models) |
| `keymap.json` | Keybindings that spawn the tasks |
| `install.sh` | Copies the bundle into a project's `.zed/`, rewriting paths |

## Install

### Automatic (recommended)

```bash
cd /path/to/ragex/editors/zed
./install.sh /path/to/your/project
```

This copies the three JSON files into `/path/to/your/project/.zed/`, rewrites
the hard-coded Ragex path to match your checkout, and backs up any existing
files as `*.bak`.

### Manual

Copy the files into your project's `.zed/` directory (project-scoped) or merge
them into `~/.config/zed/` (user-wide):

```bash
cp settings.json tasks.json keymap.json /path/to/your/project/.zed/
```

Then edit `settings.json` and `tasks.json`, replacing
`/opt/Proyectos/Oeditus/ragex` with the absolute path to your Ragex checkout.

### User-wide

For system-wide availability, merge the `context_servers` block from
`settings.json` into `~/.config/zed/settings.json` and adjust the path:

```json
{
  "context_servers": {
    "ragex": {
      "command": {
        "path": "/absolute/path/to/ragex/bin/ragex-mcp",
        "args": [],
        "env": { "MIX_ENV": "prod" }
      }
    }
  }
}
```

Omit `--project` for user-wide config so Ragex auto-detects the project from
Zed's working directory; keep `["--project", "."]` for per-project config.

## Verifying the connection

1. Restart Zed (or reload the window).
2. Open the Agent Panel (`Ctrl+?` / the sparkle icon).
3. Open the context-server menu — **ragex** should be listed.
4. Ask: *"Use ragex graph_stats to summarize the indexed codebase."*

If Ragex doesn't appear, check Zed's logs: `Ctrl+Shift+P` → **zed: open logs**,
and search for `ragex`.

## Agent profile

`settings.json` defines a **Ragex RAG** profile that is the default for the
agent. It enables Ragex's read/analysis tools and keeps destructive editing
tools (`edit_file`, `refactor_code`, `advanced_refactor`) **off** by default.
Flip them to `true` in the profile if you want the agent to apply changes.

## Tasks & keybindings

| Keybinding | Task |
|---|---|
| `Ctrl+Alt+R A` | Analyze current file |
| `Ctrl+Alt+R D` | Audit current file |
| `Ctrl+Alt+R C` | Chat (interactive RAG REPL) |
| `Ctrl+Alt+R R` | Refactor (interactive wizard) |
| `Ctrl+Alt+R S` | Status |
| `Ctrl+Alt+R Shift+A` | Analyze project |
| `Ctrl+Alt+R Shift+D` | Audit project |
| `Ctrl+Alt+R Shift+M` | Audit project → `ragex-audit.md` |
| `Ctrl+Alt+R Shift+C` | Cache stats |
| `Ctrl+Alt+R Shift+R` | Cache refresh |
| `Ctrl+Alt+R Shift+S` | Start MCP server |
| `Ctrl+Alt+R Shift+B` | Dashboard |

Tasks use Zed's variables: `$ZED_FILE`, `$ZED_RELATIVE_FILE`,
`$ZED_WORKTREE_ROOT`, `$ZED_ROW`, `$ZED_COLUMN`.

## How it works

```
┌──────────────┐   MCP (stdio)   ┌───────────────────────┐
│  Zed Agent   │ ──────────────► │  bin/ragex-mcp        │
│  Panel       │                 │  (bridges to socket)  │
└──────────────┘                 └──────────┬────────────┘
                                            ▼
                                 ┌───────────────────────────┐
                                 │  Ragex MCP server (BEAM)  │
                                 │  knowledge graph + RAG    │
                                 └───────────────────────────┘
```

Zed launches `bin/ragex-mcp` over stdio. That launcher detects an already-running
Ragex instance via its per-project Unix socket and bridges to it instead of
starting a second BEAM VM — so Zed and, say, a LunarVim session share one warm
server.

## Troubleshooting

**Ragex not listed in context servers**
- Confirm `bin/ragex-mcp` is executable: `chmod +x bin/ragex-mcp bin/ragex-bridge`.
- Test it manually:
  ```bash
  echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | /path/to/ragex/bin/ragex-mcp
  ```
- Check Zed logs for the spawn error.

**Tools return "no results"**
Index the project first: run the **ragex: analyze project** task, then retry.

**RAG tools fail with `:no_results_found`**
The RAG pipeline needs indexed embeddings and a configured AI provider key
(`DEEPSEEK_API_KEY`, etc.) on the server side. Run **ragex: analyze project**
first.

## License

GPL-3.0 (matches the Ragex project).
