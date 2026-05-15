# Editor Setup

Zero-friction MCP configuration for AI editors.

## Quick Start

```bash
# Interactive setup (detects your editor)
mix ragex.setup

# Specific editor
mix ragex.setup --editor claude
mix ragex.setup --editor neovim
mix ragex.setup --editor cursor

# All detected editors
mix ragex.setup --all

# List supported editors
mix ragex.setup --list
```

## Supported Editors

| Editor          | Key       | Config Path              | Notes                        |
|-----------------|-----------|--------------------------|------------------------------|
| Claude Code     | `claude`  | `.mcp.json`              | Standard MCP config          |
| Cursor          | `cursor`  | `.cursor/mcp.json`       | Standard MCP config          |
| VS Code         | `vscode`  | `.vscode/settings.json`  | Merged into existing config  |
| Zed             | `zed`     | `.zed/settings.json`     | Uses `context_servers` key   |
| Gemini CLI      | `gemini`  | `.gemini/settings.json`  | Standard MCP config          |
| NeoVim/LunarVim | `neovim`  | `.nvim-mcp.json`         | For mcp.nvim / nvim-mcp      |
| OpenCode        | `opencode`| `.opencode.json`         | Standard MCP config          |

## How It Works

`mix ragex.setup`:

1. Detects which editors have config files in the project directory
2. Generates the correct MCP config pointing to `bin/ragex-mcp`
3. Merges into existing config files (never overwrites)
4. Optionally runs initial project analysis
5. Optionally downloads the embedding model

## NeoVim / LunarVim

For NeoVim with MCP support (via `mcp.nvim` or similar plugins), the setup
generates `.nvim-mcp.json` in the project root:

```json
{
  "mcpServers": {
    "ragex": {
      "command": "/path/to/project/bin/ragex-mcp",
      "args": ["--project", "/path/to/project"],
      "env": {}
    }
  }
}
```

Configure your NeoVim MCP plugin to read from this file. For `mcp.nvim`:

```lua
require("mcp").setup({
  config_files = { ".nvim-mcp.json" }
})
```

## Health Check

```bash
mix ragex.status
```

Shows:
- Knowledge Graph: node/edge counts
- Embedding Model: loaded status
- Git Integration: backend, repo root, branch
- Editor Configs: which editors have ragex configured
- SCIP Bridge: available indexers and detected languages

## Config Merging

When an editor config file already exists, `mix ragex.setup` merges the
ragex entry without overwriting other servers. For example, if `.mcp.json`
already contains a `cicada` server:

```json
{
  "mcpServers": {
    "cicada": { "command": "cicada-mcp" },
    "ragex": { "command": "/path/to/bin/ragex-mcp", "args": ["--project", "/path/to/project"] }
  }
}
```

Use `--force` to overwrite instead of merge.

## Programmatic API

```elixir
# Detect editors
Ragex.CLI.EditorConfig.detect_editors("/opt/project")
#=> [claude: %{name: "Claude Code", ...}]

# Generate for specific editor
Ragex.CLI.EditorConfig.generate(:neovim, "/opt/project")
#=> {:ok, "/opt/project/.nvim-mcp.json"}

# Generate for all detected
Ragex.CLI.EditorConfig.generate_all("/opt/project")
#=> %{claude: {:ok, "..."}, zed: {:ok, "..."}}
```
