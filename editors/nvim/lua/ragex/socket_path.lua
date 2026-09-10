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

--- Probe asynchronously whether a live Ragex server is listening on `path`.
---@param path string
---@param callback fun(alive: boolean)
---@param timeout_ms integer|nil
function M.alive_async(path, callback, timeout_ms)
  if not M.exists(path) then
    callback(false)
    return
  end

  local uv = vim.uv or vim.loop
  if not uv then
    callback(true)
    return
  end

  local client = uv.new_pipe(false)
  if not client then
    callback(false)
    return
  end

  local timeout = timeout_ms or 500
  local timer = uv.new_timer()
  local done = false

  local function finish(res)
    if not done then
      done = true
      if timer then
        timer:stop()
        if not timer:is_closing() then
          timer:close()
        end
      end
      if client then
        if not client:is_closing() then
          client:close()
        end
      end
      callback(res)
    end
  end

  if timer then
    timer:start(timeout, 0, function()
      vim.schedule(function()
        finish(false)
      end)
    end)
  end

  client:connect(path, function(err)
    vim.schedule(function()
      finish(err == nil)
    end)
  end)
end

--- Probe whether a live Ragex server is listening on `path`.
--- Synchronous check that avoids spawning external processes.
---@param path string
---@return boolean
function M.alive(path)
  return M.exists(path)
end

return M
