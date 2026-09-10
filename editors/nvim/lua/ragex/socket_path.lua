--- Resolve the Ragex MCP Unix socket path.
---
--- This mirrors the precedence implemented in three places that MUST agree:
---   * `Ragex.MCP.SocketPath.compute_string/0` (Elixir)
---   * `bin/ragex-mcp` (Bash launcher)
---   * this module (Lua client)
---
---   1. `RAGEX_MCP_SOCK` -- explicit override, used verbatim.
---   2. `DLLB_PORT`      -- namespace by the dllb server port.
---   3. otherwise        -- namespace by the project identity (sanitized).
---
--- Keeping the three implementations in lock-step is what lets the plugin
--- find the *correct* per-project server instead of a stale/foreign one.
local M = {}

--- Read an environment variable, treating empty strings as unset.
---@param name string
---@return string|nil
local function env(name)
  local value = vim.env[name]
  if value == nil or value == "" then
    return nil
  end
  return value
end

--- Sanitize an absolute path the same way the Elixir implementation does:
--- strip the leading slash, replace every run of non-alphanumerics with a
--- single underscore, and trim trailing underscores.
---@param path string
---@return string
local function sanitize(path)
  local expanded = vim.fn.fnamemodify(path, ":p")
  -- Trailing slash from :p is harmless but strip it for stability.
  expanded = expanded:gsub("/+$", "")
  local out = expanded:gsub("^/", ""):gsub("[^%w]+", "_"):gsub("_+$", "")
  return out
end

--- The project identity used for namespacing when no override is present.
---@return string
local function identity()
  return env("RAGEX_PROJECT")
    or env("RAGEX_AUTO_ANALYZE")
    or vim.fn.getcwd()
end

--- Compute the socket path as a string.
---@return string
function M.compute()
  local override = env("RAGEX_MCP_SOCK")
  if override then
    return override
  end

  local port = env("DLLB_PORT")
  if port then
    return "/tmp/ragex_mcp_" .. port .. ".sock"
  end

  return "/tmp/ragex_mcp_" .. sanitize(identity()) .. ".sock"
end

--- True when a socket file exists at `path` (best-effort liveness signal).
---
--- NOTE: a socket *file* existing does not mean a server is *listening* on it.
--- Ragex (like most Unix-socket servers) can leave a stale socket file behind
--- after a crash. Use `alive/1` to check for a live listener.
---@param path string
---@return boolean
function M.exists(path)
  return vim.fn.filereadable(path) == 1 or vim.fn.getftype(path) == "socket"
end

--- Probe whether a live Ragex server is listening on `path`.
---
--- A socket *file* existing does not mean a server is *listening* on it: Ragex
--- (like most Unix-socket servers) can leave a stale socket file behind after a
--- crash. Connecting to such a file yields "Connection refused", which is
--- exactly what makes the plugin pick the socket transport and then fail
--- instead of falling back to stdio.
---
--- This sends an MCP `ping` over the socket with a bounded timeout and checks
--- for a JSON-RPC response. It is deliberately synchronous and cheap (a few
--- hundred ms at worst) and only runs when a socket file is present.
---
--- @param path string
--- @param timeout_ms integer|nil  How long to wait for a response (default 800ms).
--- @return boolean
function M.alive(path, timeout_ms)
  if not M.exists(path) then
    return false
  end

  -- Without `timeout` (or `socat`) we cannot probe safely; assume alive and
  -- let the real connect surface any error.
  if vim.fn.executable("timeout") ~= 1 or vim.fn.executable("socat") ~= 1 then
    return true
  end

  local timeout = timeout_ms or 800
  local seconds = math.max(1, math.floor(timeout / 1000))
  local ping = '{"jsonrpc":"2.0","id":0,"method":"ping","params":{}}'

  local cmd = string.format(
    "printf '%%s\\n' %s | timeout %d socat -T%d - UNIX-CONNECT:%s 2>/dev/null",
    vim.fn.shellescape(ping),
    seconds,
    seconds,
    vim.fn.shellescape(path)
  )

  local output = vim.fn.system(cmd)
  return type(output) == "string" and output:find('"result"', 1, true) ~= nil
end

return M
