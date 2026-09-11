--- JSON-RPC 2.0 client for the Ragex MCP server.
---
--- Supports two transports behind one API:
---
---   * **socket** -- connects to the per-project Unix domain socket exposed by
---     a running Ragex server (`Ragex.MCP.SocketServer`). Preferred because it
---     reuses the already-warm VM (graph, embeddings, dllb pool).
---   * **stdio** -- spawns `bin/ragex-mcp` as a child process and speaks
---     newline-delimited JSON-RPC over its stdin/stdout, exactly like Zed,
---     Cursor and Claude Desktop do.
---
--- The default mode is `"auto"`: reuse a live socket when one is present,
--- otherwise launch a stdio child. Connections are health-checked and
--- re-established lazily on the next request after a failure.
---
--- Responses are dispatched by JSON-RPC `id`, so many requests may be in
--- flight at once. `notifications/*` messages (progress, ai/progress) are
--- routed to subscribers keyed by the originating request id.
local M = {}

local socket_path = require("ragex.socket_path")

---@class RagexClientConfig
---@field mode "auto"|"socket"|"stdio"
---@field socket_path string|nil
---@field ragex_bin string|nil            Path to bin/ragex-mcp
---@field project string|nil              Project root passed as --project
---@field log_level string|nil
---@field request_timeout integer          Default per-request timeout (ms)
---@field debug boolean

---@type RagexClientConfig
local config = {
  mode = "auto",
  socket_path = nil,
  ragex_bin = nil,
  project = nil,
  log_level = "info",
  request_timeout = 60000,
  debug = false,
}

--- Active connection state.
---@type table
local state = {
  kind = nil,          -- "socket" | "stdio" | nil
  job_id = nil,        -- vim job id (both transports use jobstart)
  generation = 0,      -- bumped on every (re)connect; guards stale callbacks
  close_epoch = 0,     -- bumped only by M.close(); guards in-flight connects
  next_id = 1,
  pending = {},        -- id -> { cb, timer, started_at, tool }
  subscribers = {},    -- id -> { on_chunk }
  buffer = "",         -- partial line accumulator
  ready = false,
  starting = false,
}

local function log(msg, level)
  if config.debug then
    vim.schedule(function()
      vim.notify("[ragex] " .. msg, level or vim.log.levels.DEBUG)
    end)
  end
end

--- Configure the client. Merges into existing config.
---
--- Defined here as a thin forwarder; the real implementation lives below the
--- connection-teardown helpers (which must exist before it can call them).
---@param opts RagexClientConfig|nil
function M.setup(opts)
  M._setup(opts)
end

---@return RagexClientConfig
function M.config()
  return config
end

-- ── Connection lifecycle ─────────────────────────────────────────────────

local function reset_connection()
  state.kind = nil
  state.job_id = nil
  state.buffer = ""
  state.ready = false
  state.starting = false
  if state.starting_timer then
    pcall(vim.fn.timer_stop, state.starting_timer)
    state.starting_timer = nil
  end
  -- Bump the generation so callbacks belonging to the previous connection
  -- (on_exit/on_stdout) become no-ops once a new connection is established.
  state.generation = state.generation + 1
end

--- Fail every in-flight request (used when the transport dies).
---@param reason string
local function fail_all_pending(reason)
  local pending = state.pending
  state.pending = {}
  state.subscribers = {}

  local is_exiting = (vim.v.exiting ~= 0 or state.exiting)

  for id, entry in pairs(pending) do
    if entry.timer then
      pcall(vim.fn.timer_stop, entry.timer)
      entry.timer = nil
    end
    if entry.cb and not is_exiting then
      vim.schedule(function()
        entry.cb(nil, { kind = "transport", message = reason, id = id })
      end)
    end
  end
end

--- Real implementation of `M.setup/1` (see the forwarder above).
---
--- Reconfiguring tears down any existing connection so the next request
--- reconnects using the new settings (transport, socket path, binary, …).
---@param opts RagexClientConfig|nil
function M._setup(opts)
  -- Drop any live connection so new settings take effect on the next request.
  if state.job_id then
    pcall(vim.fn.jobstop, state.job_id)
  end
  fail_all_pending("client reconfigured")
  reset_connection()

  config = vim.tbl_deep_extend("force", config, opts or {})
  if not config.socket_path then
    config.socket_path = socket_path.compute()
  end
end

---@param chunk string
local function handle_stdout(chunk)
  state.buffer = state.buffer .. chunk

  while true do
    local newline = state.buffer:find("\n", 1, true)
    if not newline then
      break
    end

    local line = state.buffer:sub(1, newline - 1)
    state.buffer = state.buffer:sub(newline + 1)

    if line ~= "" then
      M._dispatch(line)
    end
  end
end

--- Parse and route a single JSON-RPC message.
---@param line string
function M._dispatch(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    log("dropped unparsable message: " .. line:sub(1, 200), vim.log.levels.WARN)
    return
  end

  -- Notifications carry no id.
  if msg.id == nil then
    M._handle_notification(msg)
    return
  end

  -- The Ragex socket server replies with a numeric id; stdio replies with the
  -- id we sent. Normalize to a string key.
  local key = tostring(msg.id)
  local entry = state.pending[key]
  if not entry then
    -- Could be a notification addressed by progressToken instead.
    M._handle_notification(msg)
    return
  end

  state.pending[key] = nil
  if entry.timer then
    vim.fn.timer_stop(entry.timer)
  end

  if entry.on_chunk then
    state.subscribers[key] = nil
  end

  vim.schedule(function()
    if msg.error then
      entry.cb(nil, { kind = "rpc", message = msg.error.message or "unknown error", code = msg.error.code })
    else
      entry.cb(msg.result, nil)
    end
  end)
end

--- Helper to refresh timeout timer when progress is received.
local function reset_entry_timer(key, entry)
  if entry and entry.timer and entry.timeout and entry.timeout > 0 then
    pcall(vim.fn.timer_stop, entry.timer)
    local t_val = entry.timeout
    entry.timer = vim.fn.timer_start(t_val, function()
      if state.pending[key] then
        state.pending[key] = nil
        state.subscribers[key] = nil
        if entry.cb then
          entry.cb(nil, { kind = "timeout", message = "request timed out after " .. t_val .. "ms" })
        end
      end
    end)
  end
end

--- Route a server-initiated message (progress / ai notifications).
---@param msg table
function M._handle_notification(msg)
  local method = msg.method or ""
  local params = msg.params or {}

  -- Progress notifications reference the originating request id via
  -- `progressToken` (see Ragex.MCP.Server.send_progress/3).
  local token = params.progressToken
  if token ~= nil then
    local key = tostring(token)
    local entry = state.subscribers[key] or state.pending[key]
    if entry then
      if entry.on_chunk then
        local value = params.value or {}
        entry.on_chunk(value.text or "", value.done == true, value)
      end
      reset_entry_timer(key, entry)
    end
  end

  -- Legacy ai/progress or analyzer/progress notifications go to all subscribers.
  if method == "ai/progress" or method == "analyzer/progress" then
    local payload = params.params or params
    for key, entry in pairs(state.subscribers) do
      if entry.on_chunk then
        entry.on_chunk(params.text or "", false, payload)
      end
      reset_entry_timer(key, entry)
    end
    for key, entry in pairs(state.pending) do
      if entry.on_chunk then
        entry.on_chunk(params.text or "", false, payload)
      end
      reset_entry_timer(key, entry)
    end
  end
end

--- Start the stdio child process.
---@param on_ready fun(ok: boolean, err: table|nil)
local function start_stdio(on_ready)
  local bin = config.ragex_bin
  if not bin or vim.fn.filereadable(bin) ~= 1 then
    on_ready(false, { kind = "config", message = "ragex_bin not found: " .. tostring(bin) })
    return
  end

  local cmd = { bin }
  if config.project and config.project ~= "" then
    vim.list_extend(cmd, { "--project", config.project })
  end
  if config.log_level and config.log_level ~= "" then
    vim.list_extend(cmd, { "--log-level", config.log_level })
  end

  log("starting stdio child: " .. table.concat(cmd, " "))

  -- Capture the generation this connection belongs to. Any callback whose
  -- generation no longer matches `state.generation` is stale (the connection
  -- was torn down or replaced) and must be ignored.
  local my_gen = state.generation

  local job_id = vim.fn.jobstart(cmd, {
    -- Detach the daemon from Neovim's lifecycle: indexing a large project
    -- can legitimately take minutes, and without `detach` Neovim's own
    -- shutdown sequence tries to stop (and wait on) this job when the
    -- editor exits -- which is what makes `:wq` appear to hang while
    -- ragex-mcp is still starting up/indexing. A detached job survives
    -- `:q`/`:wq`/a crashed editor and keeps indexing in the background;
    -- the next session reconnects to it via its Unix socket instead of
    -- booting another (see `start_socket` / `ensure_connected`).
    detach = true,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if state.generation ~= my_gen or not data then
        return
      end
      -- jobstart delivers a list of lines without trailing newlines.
      for _, l in ipairs(data) do
        if l ~= "" then
          handle_stdout(l .. "\n")
        end
      end
    end,
    on_stderr = function(_, data)
      if state.generation ~= my_gen or not data or not config.debug then
        return
      end
      for _, l in ipairs(data) do
        if l ~= "" then
          log("stderr: " .. l)
        end
      end
    end,
    on_exit = function(_, code)
      if state.generation ~= my_gen then
        return
      end
      log("stdio child exited with code " .. code, vim.log.levels.WARN)
      reset_connection()
      fail_all_pending("ragex-mcp exited (code " .. code .. ")")
    end,
  })

  if job_id <= 0 then
    on_ready(false, { kind = "spawn", message = "jobstart failed for " .. bin })
    return
  end

  state.kind = "stdio"
  state.job_id = job_id
  state.ready = true
  on_ready(true, nil)
end

--- Start a socket connection and verify it with a ping.
---
--- `on_ready(true, nil)` is only called once a JSON-RPC reply has been seen,
--- so a stale socket (file present, no listener) or a socat that dies
--- immediately surfaces as `on_ready(false, ...)` and lets `ensure_connected`
--- fall back to stdio instead of failing later with "socket bridge closed".
---@param on_ready fun(ok: boolean, err: table|nil)
local function start_socket(on_ready)
  local path = config.socket_path
  if not socket_path.exists(path) then
    on_ready(false, { kind = "socket", message = "socket not present: " .. tostring(path) })
    return
  end

  log("connecting to socket: " .. path)

  local settled = false
  local verified = false
  -- Capture the generation this connection belongs to; stale callbacks from a
  -- previous connection must not tear down the current one.
  local my_gen = state.generation

  local function stale()
    return state.generation ~= my_gen
  end

  local function fail(err)
    if settled or stale() then
      return
    end
    settled = true
    if state.job_id then
      pcall(vim.fn.jobstop, state.job_id)
    end
    reset_connection()
    on_ready(false, err)
  end

  local function succeed()
    if settled or stale() then
      return
    end
    settled = true
    state.kind = "socket"
    state.ready = true
    on_ready(true, nil)
  end

  -- `socat` bridges our stdin/stdout to the Unix socket. We keep stdin open
  -- so the connection is not torn down between requests.
  local job_id = vim.fn.jobstart({ "socat", "-", "UNIX-CONNECT:" .. path }, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if stale() or not data then
        return
      end
      for _, l in ipairs(data) do
        if l ~= "" then
          -- The first reply proves the socket is live; mark it verified and
          -- promote the connection. Subsequent data is normal dispatch.
          if not verified then
            verified = true
            succeed()
          end
          handle_stdout(l .. "\n")
        end
      end
    end,
    on_stderr = function(_, data)
      if stale() or not data or not config.debug then
        return
      end
      for _, l in ipairs(data) do
        if l ~= "" then
          log("socket stderr: " .. l)
        end
      end
    end,
    on_exit = function(_, code)
      if stale() then
        return
      end

      if not settled then
        -- Died before we ever got a reply: treat as a failed connection.
        fail({ kind = "socket", message = "socat exited (code " .. code .. ")" })
        return
      end

      log("socket bridge exited with code " .. code, vim.log.levels.WARN)
      reset_connection()
      fail_all_pending("socket bridge closed (code " .. code .. ")")
    end,
  })

  if job_id <= 0 then
    fail({ kind = "socket", message = "jobstart failed for socat" })
    return
  end

  state.job_id = job_id

  -- Send a ping immediately; the on_stdout callback above promotes the
  -- connection on the first reply. If nothing arrives within the grace
  -- period, give up and let the caller fall back.
  pcall(vim.fn.chansend, job_id, '{"jsonrpc":"2.0","id":0,"method":"ping","params":{}}\n')

  vim.defer_fn(function()
    if not settled then
      fail({ kind = "socket", message = "no response from socket " .. path })
    end
  end, 1500)
end

--- Ensure a connection is up, starting one if needed.
---@param cb fun(ok: boolean, err: table|nil)
local function ensure_connected(cb)
  if state.ready and state.job_id then
    cb(true, nil)
    return
  end

  if state.starting then
    -- Someone else is connecting; poll briefly.
    local ticks = 0
    if state.starting_timer then
      pcall(vim.fn.timer_stop, state.starting_timer)
    end
    state.starting_timer = vim.fn.timer_start(50, function()
      ticks = ticks + 1
      if state.ready then
        if state.starting_timer then
          pcall(vim.fn.timer_stop, state.starting_timer)
          state.starting_timer = nil
        end
        cb(true, nil)
      elseif ticks > 200 then
        if state.starting_timer then
          pcall(vim.fn.timer_stop, state.starting_timer)
          state.starting_timer = nil
        end
        cb(false, { kind = "timeout", message = "timed out waiting for connection" })
      end
    end)
    return
  end

  state.starting = true
  -- Snapshot the close epoch this attempt belongs to. `start_socket` and
  -- `start_stdio` mutate `state.job_id`/`state.ready` as soon as a job
  -- spawns successfully -- *before* the connection is confirmed usable.
  -- If `M.close()` runs while this attempt is still in flight (e.g.
  -- Neovim starts exiting while we're still probing a socket or booting
  -- a fresh stdio server), nothing would otherwise stop the attempt from
  -- completing *after* close() already returned, silently leaving a
  -- brand-new job (potentially a whole `mix run` BEAM VM) running with no
  -- autocmd left to ever stop it -- exactly the scenario that makes `:q`
  -- hang until the user resorts to `:noa q`.
  local my_close_epoch = state.close_epoch

  local function done(ok, err)
    state.starting = false

    if state.close_epoch ~= my_close_epoch then
      -- Superseded by a close() that happened mid-connect. For a socket
      -- bridge (cheap `socat`) just kill it -- nothing is lost. For a
      -- freshly booted `stdio` daemon, leave it running detached instead:
      -- it may be in the middle of indexing a huge project, and killing it
      -- here is exactly what used to make quitting mid-startup hang (or
      -- silently throw away all that indexing work). It keeps going in the
      -- background and exposes its socket for the next session to use.
      if ok and state.job_id then
        if state.kind == "stdio" then
          pcall(vim.fn.chanclose, state.job_id)
        else
          pcall(vim.fn.jobstop, state.job_id)
        end
        reset_connection()
      end
      cb(false, err or { kind = "stale", message = "connection attempt superseded by close()" })
      return
    end

    if ok then
      -- A fresh, non-stale connection just succeeded, so we're clearly not
      -- mid editor-shutdown. Safe to let future failures notify again.
      state.exiting = false
    end

    cb(ok, err)
  end

  if config.mode == "socket" then
    start_socket(function(ok, err)
      done(ok, err)
    end)
  elseif config.mode == "auto" then
    socket_path.alive_async(config.socket_path, function(is_alive)
      if is_alive then
        start_socket(function(ok, err)
          if ok then
            done(true, nil)
          else
            log("socket unavailable, falling back to stdio")
            start_stdio(done)
          end
        end)
      else
        start_stdio(done)
      end
    end)
  else
    start_stdio(done)
  end
end

-- ── Request API ──────────────────────────────────────────────────────────

--- Send a JSON-RPC request.
---
--- @param method string          e.g. "tools/call", "tools/list"
--- @param params table|nil
--- @param opts table|nil         { callback, on_chunk, timeout }
--- @return integer|nil           request id (for cancellation), or nil on immediate failure
function M.request(method, params, opts)
  opts = opts or {}
  local callback = opts.callback
  local on_chunk = opts.on_chunk
  local timeout = opts.timeout or config.request_timeout

  local id = state.next_id
  state.next_id = id + 1
  local key = tostring(id)

  local message = {
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or {},
  }

  ensure_connected(function(ok, err)
    if not ok then
      if callback then
        callback(nil, err or { kind = "connection", message = "could not connect" })
      end
      return
    end

    local encoded = vim.json.encode(message)

    local entry = {
      cb = callback,
      on_chunk = on_chunk,
      started_at = vim.loop.now(),
      tool = params and params.name or method,
      timeout = timeout,
    }

    if timeout and timeout > 0 then
      entry.timer = vim.fn.timer_start(timeout, function()
        if state.pending[key] then
          state.pending[key] = nil
          state.subscribers[key] = nil
          if callback then
            callback(nil, { kind = "timeout", message = "request timed out after " .. timeout .. "ms" })
          end
        end
      end)
    end

    state.pending[key] = entry
    if on_chunk then
      state.subscribers[key] = entry
    end

    local ok_send, send_err = pcall(function()
      vim.fn.chansend(state.job_id, encoded .. "\n")
    end)

    if not ok_send then
      state.pending[key] = nil
      state.subscribers[key] = nil
      if entry.timer then
        vim.fn.timer_stop(entry.timer)
      end
      if callback then
        callback(nil, { kind = "send", message = tostring(send_err) })
      end
    end
  end)

  return id
end

--- Convenience: call an MCP tool (`tools/call`).
---@param name string
---@param args table|nil
--- Ensure a value encodes as a JSON object (not an array).
---
--- Neovim's `vim.json.encode` serializes an empty Lua table as `[]`, which the
--- Ragex server rejects for `arguments` (it requires a map). `vim.empty_dict()`
--- forces `{}`.
---@param value table|nil
---@return table
local function as_object(value)
  if value == nil or next(value) == nil then
    return vim.empty_dict()
  end
  return value
end

--- Convenience: call an MCP tool (`tools/call`).
---@param name string
---@param args table|nil
---@param opts table|nil
function M.call_tool(name, args, opts)
  return M.request("tools/call", { name = name, arguments = as_object(args) }, opts)
end

--- Convenience: list tools.
---@param opts table|nil
function M.list_tools(opts)
  return M.request("tools/list", {}, opts)
end

--- Convenience: list resources.
---@param opts table|nil
function M.list_resources(opts)
  return M.request("resources/list", {}, opts)
end

--- Convenience: read a resource by URI.
---@param uri string
---@param opts table|nil
function M.read_resource(uri, opts)
  return M.request("resources/read", { uri = uri }, opts)
end

--- Convenience: list prompts.
---@param opts table|nil
function M.list_prompts(opts)
  return M.request("prompts/list", {}, opts)
end

--- Convenience: get a prompt by name.
---@param name string
---@param args table|nil
---@param opts table|nil
function M.get_prompt(name, args, opts)
  return M.request("prompts/get", { name = name, arguments = args or {} }, opts)
end

--- Synchronous call: block until the response arrives (or timeout).
--- Intended for small, fast calls (health checks, graph stats). Never use it
--- for directory analysis or RAG queries.
---@param name string
---@param args table|nil
---@param timeout integer|nil
---@return table|nil result, table|nil err
function M.call_tool_sync(name, args, timeout)
  local result, err = nil, nil
  local done = false

  M.call_tool(name, args, {
    timeout = timeout or 10000,
    callback = function(res, e)
      result, err = res, e
      done = true
    end,
  })

  vim.wait(timeout and timeout + 500 or 10500, function()
    return done
  end, 20)

  if not done then
    return nil, { kind = "timeout", message = "sync call did not complete" }
  end

  return result, err
end

--- Close the active connection and fail outstanding requests.
---
--- Deliberately does NOT kill a `stdio`-mode job: that job is the Ragex
--- daemon itself (the whole BEAM VM), started with `detach = true`
--- precisely so it keeps indexing in the background after the editor
--- exits. Only the disposable `socket`-mode `socat` bridge is stopped
--- here. Use `M.stop_daemon()` to actually terminate the background
--- server.
function M.close()
  state.exiting = true
  state.close_epoch = (state.close_epoch or 0) + 1
  if state.starting_timer then
    pcall(vim.fn.timer_stop, state.starting_timer)
    state.starting_timer = nil
  end
  if state.job_id then
    pcall(vim.fn.chanclose, state.job_id)
    if state.kind ~= "stdio" then
      pcall(vim.fn.jobstop, state.job_id)
    end
  end
  fail_all_pending("client closed")
  reset_connection()
end

--- Deliberately terminate the background Ragex daemon.
---
--- Unlike `M.close()` (which only ever drops *this session's* connection
--- and intentionally leaves a `stdio`-mode daemon running), this always
--- signals the actual BEAM VM -- whether it was booted by this session or
--- a previous one. When this session only holds a `socket` bridge (or no
--- connection at all), the real server is found by asking who holds the
--- Unix socket open (`fuser`), since the bridge's own job id is useless
--- for that.
---@param callback fun(ok: boolean, message: string)|nil
function M.stop_daemon(callback)
  callback = callback or function() end

  -- Fast path: this session itself booted the daemon and still holds its
  -- job id -- no need to shell out.
  if state.kind == "stdio" and state.job_id then
    pcall(vim.fn.jobstop, state.job_id)
    reset_connection()
    callback(true, "stopped the ragex-mcp job owned by this session")
    return
  end

  local path = config.socket_path or socket_path.compute()
  if not socket_path.exists(path) then
    callback(false, "no socket found at " .. tostring(path))
    return
  end

  local output = {}
  local job_id = vim.fn.jobstart({ "fuser", "-k", "-TERM", path }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(output, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(output, data)
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        if state.job_id then
          pcall(vim.fn.jobstop, state.job_id)
        end
        reset_connection()
        callback(true, "sent SIGTERM to the ragex-mcp daemon behind " .. path)
      else
        local detail = vim.trim(table.concat(output, " "))
        callback(
          false,
          "could not signal " .. path .. " via fuser" .. (detail ~= "" and (": " .. detail) or "")
        )
      end
    end,
  })

  if job_id <= 0 then
    callback(false, "fuser not available -- kill the ragex-mcp/beam.smp process manually")
  end
end

---@return boolean
function M.is_connected()
  return state.ready and state.job_id ~= nil
end

---@return string|nil
function M.transport_kind()
  return state.kind
end

return M
