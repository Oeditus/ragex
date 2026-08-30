# Ragex MCP Server Guide

## Socket naming

Ragex may run several independent instances at once (one per project, or one
per `dllb` server port), so the MCP Unix socket is namespaced instead of
using a single fixed path. The resolution order (identical across the
Elixir server, `bin/ragex-mcp`, `start_server.sh`/`test_socket.sh`, and the
nvim/lvim clients) is:

1. `RAGEX_MCP_SOCK` -- explicit override, used verbatim.
2. `DLLB_PORT` -- if set, the socket is `/tmp/ragex_mcp_<port>.sock`.
3. Otherwise, the socket is namespaced by the project directory being
   served: `/tmp/ragex_mcp_<sanitized_path>.sock`.

To find the socket for the server you started, run `ls /tmp/ragex_mcp_*.sock`
or check the `MCP Socket Server listening on ...` line the server logs on
startup. The examples below use `$SOCKET_PATH` as a stand-in for whichever
path applies to your instance.

## Quick Start

```bash
# 1. Clean up any old server for this project
pkill -f "mix run"
rm -f /tmp/ragex_mcp_*.sock

# 2. Start the server
cd ~/Proyectos/Oeditus/ragex
./start_server.sh

# 3. Test in another terminal (auto-detects the socket for this directory)
./test_socket.sh
```

## The Problem

If you see "Searching..." hanging forever in LunarVim, it means:
- The socket file exists at `$SOCKET_PATH`
- BUT no process is listening on it (dead socket)

This happens when:
1. Server crashes or is killed while socket file remains
2. Server gets stuck in Erlang BREAK mode
3. Server was redirected to background incorrectly

## The Solution

### Step 1: Clean Up

```bash
# Kill any existing Ragex processes
pkill -f "mix run"

# Remove the dead socket (use the exact path from `ls /tmp/ragex_mcp_*.sock`)
rm -f "$SOCKET_PATH"
```

### Step 2: Start Server Properly

**Option A: Interactive (Recommended for debugging)**
```bash
cd ~/Proyectos/Oeditus/ragex
mix run --no-halt
```

Watch for:
- `MCP Socket Server listening on /tmp/ragex_mcp_<...>.sock`
- `Socket file verified: /tmp/ragex_mcp_<...>.sock`
- `Accept loop started with PID: ...`

**Option B: Background with logging**
```bash
cd ~/Proyectos/Oeditus/ragex
./start_server.sh
```

### Step 3: Verify Server is Working

```bash
# Test socket communication
./test_socket.sh
```

You should see:
```
✓ Socket file exists
✓ Server responded
✓ Socket communication is working!
```

### Step 4: Test in LunarVim

```vim
" Enable debug mode temporarily to see what's happening
:lua require('ragex').config.debug = true

" Try a command
:Ragex search
```

## Troubleshooting

### "Connection refused" error

**Symptoms:**
- Socket file exists: `ls /tmp/ragex_mcp_*.sock` shows the file
- But `./test_socket.sh` fails with "Connection refused"

**Cause:** Dead socket - file exists but no process listening

**Fix:**
```bash
pkill -f "mix run"
rm -f /tmp/ragex_mcp_*.sock
./start_server.sh
```

### Server crashes immediately

**Check logs:**
```bash
# If using start_server.sh
tail -f /tmp/ragex_server.log

# If running interactively, look for errors in the terminal
```

**Common issues:**
- Model not downloaded: Run `mix ragex.models.download`
- Port conflict: Check if another process is using the socket
- Permission issues: Ensure `/tmp` is writable

### Stuck in BREAK mode

**Symptoms:**
- You see `BREAK: (a)bort (c)ontinue...` prompt
- Server appears hung

**Fix:**
```bash
# Kill the process
pkill -9 -f "mix run"

# Clean up
rm -f /tmp/ragex_mcp_*.sock

# Start fresh
./start_server.sh
```

### LunarVim still hangs

1. **Check server is running:**
   ```bash
   ./test_socket.sh
   ```

2. **Enable debug mode in LunarVim:**
   ```lua
   -- In ~/.config/lvim/config.lua
   require('ragex').setup({
     debug = true,  -- Enable debug logging
     -- ... rest of config
   })
   ```

3. **Check notifications:**
   After running `:Ragex search`, look for debug messages in notifications

4. **Check socket path matches:**
   ```lua
   -- In LunarVim
   :lua print(require('ragex').config.socket_path)
   ```
   Should print the socket for the project you're editing, e.g.
   `/tmp/ragex_mcp_home_user_myproject.sock` (or `/tmp/ragex_mcp_<port>.sock`
   if `DLLB_PORT` is set).

## Server Management

### Start Server
```bash
./start_server.sh
```

### Stop Server
```bash
pkill -f "mix run"
rm -f /tmp/ragex_mcp_*.sock
```

### Restart Server
```bash
pkill -f "mix run"
rm -f /tmp/ragex_mcp_*.sock
./start_server.sh
```

### Check Server Status
```bash
# Check if process is running
ps aux | grep "mix run" | grep -v grep

# Check if socket is responsive
./test_socket.sh
```

## What the Server Does

When started, the Ragex application:

1. **Starts the Supervision Tree:**
   - Graph Store (ETS tables for code graph)
   - Embeddings (Bumblebee ML models)
   - Vector Store (semantic search)
   - File Watcher (auto-reindex)
   - AI Provider Registry
   - AI Cache & Usage tracking

2. **Starts MCP Servers:**
   - Socket Server: Unix domain socket at `/tmp/ragex_mcp_<port_or_project>.sock`
     (see "Socket naming" above)
   - Stdio Server: For stdio-based clients

3. **Waits for Connections:**
   - Each client connection spawns a handler process
   - Handles MCP JSON-RPC 2.0 requests
   - Returns responses via the socket

## Performance Tips

1. **First startup is slow:** Models need to load (~1-2 minutes)
2. **First analysis is slow:** Embeddings are generated and cached
3. **Subsequent operations are fast:** Everything is cached

## Integration with LunarVim

Once the server is running and `./test_socket.sh` succeeds:

1. **Restart LunarVim or reload config:**
   ```vim
   :LvimReload
   ```

2. **Try commands:**
   ```vim
   :Ragex search
   :Ragex analyze_file
   :checkhealth ragex
   ```

3. **Use keybindings:**
   ```vim
   <leader>rs  " Search
   <leader>ra  " Analyze file
   <leader>rA  " Analyze directory
   ```

## Need Help?

1. Run `./test_socket.sh` first
2. Check `/tmp/ragex_server.log` for errors
3. Enable debug mode in LunarVim config
4. Look for error messages in LunarVim notifications

---

**Remember:** The server must be running in a terminal for the plugin to work!
