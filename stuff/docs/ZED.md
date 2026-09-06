# Zed Editor Integration (Deprecated / Invalidated)

> [!CAUTION]
> **DEPRECATED & INVALIDATED**: Zed Editor integration via `.zed/settings.json` is deprecated and no longer supported as a primary workflow in Ragex v0.30.0+.
> 
> Please use the native **MCP Socket Server** (`/tmp/ragex_mcp.sock`), **LunarVim/Neovim**, or the CLI (`mix ragex.serve`) instead.

---

## Historical Reference

The instructions below are preserved for historical reference only.

Ragex previously provided integration with the [Zed](https://zed.dev/) editor through three mechanisms:

1. **MCP Context Server** -- Ragex's tools were available in Zed's Agent Panel
2. **Task Runner** -- Ragex mix tasks were accessible via `task: spawn`
3. **Keybindings** -- Common operations bound to keyboard shortcuts

---

## Deprecated Setup

### Prerequisites

- Zed editor (`https://zed.dev/`)
- Elixir 1.19+ and Erlang/OTP 27+
- Ragex compiled (`mix deps.get && mix compile`)

### MCP Socket Server Alternative (Recommended)

Start the persistent socket server instead:

```bash
./start_server.sh
```

Or connect via standard Model Context Protocol over socket `/tmp/ragex_mcp.sock`.
