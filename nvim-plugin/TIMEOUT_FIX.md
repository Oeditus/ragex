# Timeout Fix for Analyzer Commands

## Problem
Analyzer commands (`:Ragex find_dead_code`, `:Ragex quality_report`, etc.) were hanging indefinitely with "[Ragex] Analyzing..." message, while search commands worked fine.

## Root Cause
Two timeout issues:

1. **Socat timeout conflict**: The socat command used `-t30` (30 seconds) which caused the socket connection to close prematurely, even though the Lua timer was set correctly. This prevented long-running operations from completing.

2. **Wrong timeout configuration**: Analysis operations were using the default timeout (60s) instead of the analyze timeout (120s).

## Solution

### 1. Remove socat timeout (`lua/ragex/core.lua`)
Changed from:
```lua
local cmd = string.format(
  "(printf '%%s\\n' %s; sleep 0.1) | socat -t30 - UNIX-CONNECT:%s 2>&1",
  vim.fn.shellescape(request),
  M.config.socket_path
)
```

To:
```lua
-- No timeout flag on socat - timeout is managed by Lua timer
-- This allows long-running operations to complete without premature connection close
local cmd = string.format(
  "printf '%%s\\n' %s | socat - UNIX-CONNECT:%s",
  vim.fn.shellescape(request),
  M.config.socket_path
)
```

**Key insight**: The Lua timer (via `vim.fn.timer_start`) already manages timeouts correctly. Adding a socat timeout causes premature connection closure. By removing the socat timeout, the connection stays open until either:
- The server responds (success)
- The Lua timer triggers (timeout)
- The job exits with an error (failure)

### 2. Analyze timeout for analysis operations (`lua/ragex/analysis.lua`)
Changed from:
```lua
core.execute(method, params or {}, function(result, error_type)
  -- ... callback
end)
```

To:
```lua
-- Use analyze timeout for all analysis operations (they can be slow)
core.execute(method, params or {}, function(result, error_type)
  -- ... callback
end, core.config.timeout.analyze)
```

## Timeout Configuration
From `lua/ragex/init.lua`:
```lua
timeout = {
  default = 60000,   -- 60s for most operations
  analyze = 120000,  -- 120s for analysis operations
  search = 30000,    -- 30s for search operations
}
```

## Testing
After installing the fix:

1. Reinstall plugin:
   ```bash
   cd /opt/Proyectos/Oeditus/ragex/nvim-plugin
   ./install_lvim.sh
   ```

2. Restart LunarVim:
   ```vim
   :LvimReload
   ```

3. Test analyzer commands:
   ```vim
   :Ragex find_dead_code
   :Ragex quality_report
   :Ragex analyze_dependencies
   :Ragex semantic_operations
   ```

All should now complete successfully (may take 30-120 seconds for large codebases).

## Related Files
- `nvim-plugin/lua/ragex/core.lua` - MCP client with socat communication
- `nvim-plugin/lua/ragex/analysis.lua` - Analysis operations wrapper
- `nvim-plugin/lua/ragex/init.lua` - Configuration with timeout values

## Legacy Plugin Reference
The working solution was found in the legacy plugin at `lvim.cfg/lua/user/ragex.lua` which never used a socat timeout flag, relying solely on the Lua timer for timeout management.

## Commit
```bash
git add nvim-plugin/lua/ragex/{core,analysis}.lua nvim-plugin/TIMEOUT_FIX.md
git commit -m "fix(nvim): remove socat timeout flag, rely on Lua timer

- Remove socat -t30 timeout flag that caused premature connection close
- Use analyze timeout (120s) for all analysis operations in analysis.lua
- Let Lua timer manage timeouts (avoids conflict with socat timeout)
- Fixes analyzer commands hanging/timing out

The issue was that socat -t30 closed connections after 30 seconds,
even though Lua timer was set correctly to 120s for analysis ops.
By removing socat timeout, connections stay open until Lua timer
triggers or server responds.

Resolves issue where search worked but analyzers (dead_code,
quality_report, etc.) timed out due to socat closing connection.

Co-Authored-By: Warp <agent@warp.dev>"
```
