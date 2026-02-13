-- Core MCP client for ragex.nvim
-- Handles communication with Ragex MCP server via Unix socket

local M = {}
local utils = require("ragex.utils")
local ui = require("ragex.ui")

-- Module state
M.config = {}

-- Initialize with configuration
function M.init(config)
  M.config = config
end

-- Debug logging
local function debug_log(msg)
  if M.config.debug then
    ui.notify("Debug: " .. msg, "debug")
  end
end

-- Execute MCP command via Unix socket
function M.execute(method, params, callback, timeout_ms)
  if not M.config.enabled then
    debug_log("Ragex is disabled")
    return nil
  end

  -- Default timeout based on operation
  local default_timeout = M.config.timeout.default
  if method == "analyze_directory" then
    default_timeout = M.config.timeout.analyze
  elseif method == "semantic_search" or method == "hybrid_search" then
    default_timeout = M.config.timeout.search
  end
  timeout_ms = timeout_ms or default_timeout

  -- Build MCP request
  local request = vim.fn.json_encode({
    jsonrpc = "2.0",
    method = "tools/call",
    params = {
      name = method,
      arguments = params or {},
    },
    id = vim.fn.rand(),
  })

  debug_log("Request: " .. method)
  if M.config.debug then
    debug_log("Params: " .. vim.inspect(params))
  end

  -- Command to send request via socat
  local cmd = string.format(
    "printf '%%s\\n' %s | socat - UNIX-CONNECT:%s 2>&1",
    vim.fn.shellescape(request),
    M.config.socket_path
  )

  if callback then
    -- Async execution with timeout
    local timer = nil
    local job_id = nil
    local completed = false
    local response_received = false

    job_id = vim.fn.jobstart(cmd, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        if completed then return end

        if data and #data > 0 then
          local result_str = table.concat(data, "\n"):gsub("^%s+", ""):gsub("%s+$", "")

          if result_str ~= "" then
            response_received = true
            completed = true
            if timer then
              vim.fn.timer_stop(timer)
            end

            debug_log("Response received")
            local ok, result = pcall(vim.fn.json_decode, result_str)
            if ok and result then
              callback(result, nil)
            else
              debug_log("JSON parse error")
              callback(nil, "parse_error")
            end
          end
        end
      end,
      on_stderr = function(_, data)
        if data and #data > 0 then
          local err = table.concat(data, "\n")
          if err ~= "" and not err:match("^%s*$") then
            debug_log("Stderr: " .. err)
          end
        end
      end,
      on_exit = function(_, exit_code)
        if completed then return end

        completed = true
        if timer then
          vim.fn.timer_stop(timer)
        end

        if exit_code ~= 0 and not response_received then
          debug_log("Command exited with code: " .. exit_code)
          callback(nil, "error")
        end
      end,
    })

    -- Timeout timer
    timer = vim.fn.timer_start(timeout_ms, function()
      if not completed then
        completed = true
        debug_log("Timeout for " .. method)
        if job_id then
          vim.fn.jobstop(job_id)
        end
        callback(nil, "timeout")
      end
    end)
  else
    -- Synchronous execution
    debug_log("Sync command: " .. cmd)

    local handle = io.popen(cmd)
    local result_str = ""

    if handle then
      result_str = handle:read("*a")
      handle:close()
    end

    if result_str and result_str ~= "" then
      result_str = result_str:gsub("^%s+", ""):gsub("%s+$", "")
      debug_log("Sync response received")
      local ok, result = pcall(vim.fn.json_decode, result_str)
      if ok and result then
        return result
      end
    end

    return nil
  end
end

-- Semantic search
function M.semantic_search(query, opts)
  opts = opts or {}
  local params = {
    query = query,
    limit = opts.limit or M.config.search.limit,
    threshold = opts.threshold or M.config.search.threshold,
    node_type = opts.node_type,
  }

  return M.execute("semantic_search", params)
end

-- Hybrid search
function M.hybrid_search(query, opts)
  opts = opts or {}
  local params = {
    query = query,
    limit = opts.limit or M.config.search.limit,
    threshold = opts.threshold or M.config.search.threshold,
    strategy = opts.strategy or M.config.search.strategy,
  }

  return M.execute("hybrid_search", params)
end

-- Analyze file
function M.analyze_file(filepath)
  if not filepath or filepath == "" then
    ui.notify("No file to analyze", "warn")
    return
  end

  M.execute("analyze_file", { path = filepath }, function(result, error_type)
    if error_type then
      ui.notify("Failed to analyze file: " .. error_type, "error")
      return
    end

    if result and result.result then
      ui.notify("File analyzed successfully", "info")
    else
      ui.notify("Analysis failed", "error")
    end
  end)
end

-- Analyze directory
function M.analyze_directory(path, opts)
  opts = opts or {}
  path = path or vim.fn.getcwd()

  local loading = ui.notify_loading("Analyzing directory: " .. path)

  local params = {
    path = path,
    recursive = opts.recursive ~= false,
    parallel = opts.parallel ~= false,
  }

  M.execute("analyze_directory", params, function(result, error_type)
    ui.dismiss_notification(loading)

    if error_type == "timeout" then
      ui.notify("Analysis timed out (try again, embeddings will cache)", "warn")
      return
    end

    if error_type then
      ui.notify("Analysis failed: " .. error_type, "error")
      return
    end

    local data, err = utils.parse_mcp_response(result)
    if err then
      ui.notify("Analysis failed: " .. err, "error")
      return
    end

    if data.files_analyzed then
      ui.notify(string.format("Analyzed %d files in %s", 
        data.files_analyzed, 
        utils.format_duration(data.duration_ms or 0)), "info")
    else
      ui.notify("Directory analyzed", "info")
    end
  end, M.config.timeout.analyze)
end

-- Watch directory
function M.watch_directory(path, extensions)
  path = path or vim.fn.getcwd()
  extensions = extensions or { ".ex", ".exs", ".erl", ".hrl", ".py", ".js", ".jsx", ".ts", ".tsx" }

  local params = {
    path = path,
    extensions = extensions,
  }

  M.execute("watch_directory", params, function(result, error_type)
    if error_type then
      ui.notify("Failed to watch directory: " .. error_type, "error")
      return
    end

    ui.notify("Watching directory: " .. path, "info")
  end)
end

-- Graph statistics
function M.graph_stats()
  local result = M.execute("graph_stats", {})
  if not result then
    ui.notify("Failed to get graph statistics", "error")
    return nil
  end

  local data, err = utils.parse_mcp_response(result)
  if err then
    ui.notify("Failed to parse stats: " .. err, "error")
    return nil
  end

  -- Show stats in floating window
  local lines = {
    "Knowledge Graph Statistics",
    string.rep("=", 40),
    "",
    string.format("Nodes: %d", data.node_count or 0),
    string.format("Edges: %d", data.edge_count or 0),
    string.format("Modules: %d", data.modules or 0),
    string.format("Functions: %d", data.functions or 0),
    "",
    "Top PageRank:",
  }

  if data.top_pagerank then
    for i, node in ipairs(data.top_pagerank) do
      if i > 10 then break end
      table.insert(lines, string.format("  %2d. %s (%.4f)", i, node.id, node.score))
    end
  end

  ui.show_float(lines, { title = "Graph Statistics" })

  return data
end

-- Find callers
function M.find_callers(module, func_name, arity)
  module = module or utils.get_current_module()
  if not module then
    ui.notify("Could not determine current module", "warn")
    return
  end

  if not func_name then
    func_name, arity = utils.get_function_under_cursor()
  end

  if not func_name then
    ui.notify("Could not determine function name", "warn")
    return
  end

  local params = {
    module = module,
    function_name = func_name,
  }

  if arity then
    params.arity = arity
  end

  local loading = ui.notify_loading("Finding callers...")

  M.execute("find_callers", params, function(result, error_type)
    ui.dismiss_notification(loading)

    if error_type then
      ui.notify("Failed to find callers: " .. error_type, "error")
      return
    end

    local data, err = utils.parse_mcp_response(result)
    if err then
      ui.notify("Failed to parse callers: " .. err, "error")
      return
    end

    if not data.callers or #data.callers == 0 then
      ui.notify("No callers found", "warn")
      return
    end

    -- Format and show callers
    local lines = {
      string.format("Callers of %s.%s/%s", module, func_name, arity or "?"),
      string.rep("=", 60),
      "",
    }

    for _, caller in ipairs(data.callers) do
      table.insert(lines, string.format("• %s", caller.caller_id or caller.id))
      if caller.file then
        table.insert(lines, string.format("  File: %s:%d", caller.file, caller.line or 0))
      end
      table.insert(lines, "")
    end

    ui.show_float(lines, { title = "Callers", height = math.min(#lines + 2, 30) })
  end)
end

-- Find paths between functions
function M.find_paths(from_module, from_func, to_module, to_func, opts)
  opts = opts or {}

  local params = {
    from_module = from_module,
    from_function = from_func,
    to_module = to_module,
    to_function = to_func,
    max_depth = opts.max_depth or 10,
    max_paths = opts.max_paths or 100,
  }

  local loading = ui.notify_loading("Finding paths...")

  M.execute("find_paths", params, function(result, error_type)
    ui.dismiss_notification(loading)

    if error_type then
      ui.notify("Failed to find paths: " .. error_type, "error")
      return
    end

    local data, err = utils.parse_mcp_response(result)
    if err then
      ui.notify("Failed to parse paths: " .. err, "error")
      return
    end

    if not data.paths or #data.paths == 0 then
      ui.notify("No paths found", "warn")
      return
    end

    -- Format and show paths
    local lines = {
      string.format("Paths from %s.%s to %s.%s", from_module, from_func, to_module, to_func),
      string.rep("=", 80),
      "",
      string.format("Found %d path(s):", #data.paths),
      "",
    }

    for i, path in ipairs(data.paths) do
      table.insert(lines, string.format("Path %d:", i))
      for j, node in ipairs(path) do
        local indent = string.rep("  ", j - 1)
        table.insert(lines, string.format("%s→ %s", indent, node))
      end
      table.insert(lines, "")
    end

    ui.show_float(lines, { title = "Call Paths", height = math.min(#lines + 2, 40) })
  end)
end

return M
