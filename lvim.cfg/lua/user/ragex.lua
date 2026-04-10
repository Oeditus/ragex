-- Ragex Integration for LunarVim
-- Provides semantic code search, refactoring, and analysis for Elixir projects

local M = {}

-- Configuration
M.config = {
  project_root = vim.fn.getcwd(),
  ragex_path = vim.fn.expand("~/Proyectos/Oeditus/ragex"),
  enabled = true,
  debug = true,  -- Enable to see request/response logs
  auto_analyze = false,  -- Disabled by default, enable with :lua require('user.ragex').config.auto_analyze = true
  auto_analyze_on_start = true,  -- Analyze current directory on startup
  auto_analyze_dirs = {},  -- List of directories to analyze on startup, e.g. {"/path/to/project1", "/path/to/project2"}
}

-- Log debug messages
local function debug_log(msg)
  if M.config.debug then
    vim.notify("[Ragex] " .. msg, vim.log.levels.INFO)
  end
end

-- Execute Ragex MCP command
function M.execute(method, params, callback, timeout_ms)
  if not M.config.enabled then
    debug_log("Ragex is disabled")
    return
  end

  -- Default timeout: 60 seconds for most operations, 120 seconds for analyze_directory
  local default_timeout = method == "analyze_directory" and 120000 or 60000
  timeout_ms = timeout_ms or default_timeout

  local request = vim.fn.json_encode({
    jsonrpc = "2.0",
    method = "tools/call",
    params = {
      name = method,
      arguments = params,
    },
    id = vim.fn.rand(),
  })

  debug_log("Request JSON: " .. request)

  -- Connect to persistent socket server via Unix socket
  -- Use subshell with sleep to keep stdin open until server responds
  -- Without the sleep, socat closes the connection before the response arrives
  local cmd = string.format(
    "(printf '%%s\\n' %s; sleep 10) | socat -T5 STDIO UNIX-CONNECT:/tmp/ragex_mcp.sock",
    vim.fn.shellescape(request)
  )

  debug_log("Executing: " .. method .. " (timeout: " .. math.ceil(timeout_ms / 1000) .. "s)")
  debug_log("Command: " .. cmd)

  if callback then
    -- Async execution with timeout handling
    local timer = nil
    local job_id = nil
    local completed = false
    local response_received = false

    job_id = vim.fn.jobstart(cmd, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        if completed then return end
        
        if data and #data > 0 then
          local result_str = table.concat(data, "\n")
          -- Clean up any trailing newlines or empty strings
          result_str = result_str:gsub("^%s+", ""):gsub("%s+$", "")
          
          if result_str ~= "" then
            response_received = true
            completed = true
            if timer then
              vim.fn.timer_stop(timer)
            end
            
            debug_log("Response: " .. result_str:sub(1, 200))
            local ok, result = pcall(vim.fn.json_decode, result_str)
            if ok and result then
              callback(result, nil)  -- Success: result with no error
            else
              debug_log("JSON parse error for: " .. result_str:sub(1, 100))
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
    
    -- Fallback timer in case jobstart doesn't report timeout
    timer = vim.fn.timer_start(timeout_ms, function()
      if not completed then
        completed = true
        debug_log("Timer timeout triggered for " .. method)
        if job_id then
          vim.fn.jobstop(job_id)
        end
        callback(nil, "timeout")
      end
    end)
  else
    -- Synchronous execution  
    debug_log("Command: " .. cmd)
    
    -- Use io.popen with socat (works reliably)
    local handle = io.popen(cmd)
    local result_str = ""
    
    if handle then
      result_str = handle:read("*a")
      handle:close()
    end
    
    debug_log("Raw response: " .. (result_str or "nil"))
    
    if result_str and result_str ~= "" then
      result_str = result_str:gsub("^%s+", ""):gsub("%s+$", "")
      debug_log("Cleaned response: " .. result_str:sub(1, 200))
      local ok, result = pcall(vim.fn.json_decode, result_str)
      if ok and result then
        debug_log("Parsed successfully")
        return result
      else
        debug_log("JSON parse failed: " .. tostring(result))
      end
    else
      debug_log("Empty or nil response")
    end
    
    return nil
  end
end

-- Semantic search
function M.semantic_search(query, opts)
  opts = opts or {}
  local params = {
    query = query,
    limit = opts.limit or 10,
    threshold = opts.threshold or 0.2,  -- Default threshold (0.1-0.3 typical range)
    node_type = opts.node_type,
  }

  return M.execute("semantic_search", params)
end

-- Hybrid search (best results)
function M.hybrid_search(query, opts)
  opts = opts or {}
  local params = {
    query = query,
    limit = opts.limit or 10,
    threshold = opts.threshold or 0.15,  -- Lower threshold for better recall
    strategy = opts.strategy or "fusion",
  }

  return M.execute("hybrid_search", params)
end

-- Analyze current file
function M.analyze_current_file()
  local filepath = vim.fn.expand("%:p")
  if filepath == "" then
    vim.notify("No file to analyze", vim.log.levels.WARN)
    return
  end

  M.execute("analyze_file", { path = filepath }, function(result, error_type)
    if error_type then
      vim.notify("Failed to analyze file: " .. error_type, vim.log.levels.ERROR)
      return
    end
    
    if result and result.result then
      vim.notify("File analyzed successfully", vim.log.levels.INFO)
    else
      vim.notify("Failed to analyze file", vim.log.levels.ERROR)
    end
  end)
end

-- Analyze directory
function M.analyze_directory(path, opts)
  opts = opts or {}
  path = path or vim.fn.getcwd()
  
  local params = {
    path = path,
    recursive = opts.recursive ~= false,
    parallel = opts.parallel ~= false,
    extensions = opts.extensions or { ".ex", ".exs" },
  }

  -- Only show initial notification if not silent
  if not opts.silent then
    vim.notify("Analyzing directory: " .. path .. "...", vim.log.levels.INFO)
  end
  
  M.execute("analyze_directory", params, function(result, error_type)
    debug_log("analyze_directory result: " .. vim.inspect(result))
    
    -- Handle timeout error
    if error_type == "timeout" then
      if not opts.silent then
        vim.notify(string.format("✗ Ragex: Timed out analyzing %s (try again, embeddings will cache)", vim.fn.fnamemodify(path, ":~")), vim.log.levels.WARN)
      end
      return
    end
    
    -- Handle other errors
    if error_type == "error" or error_type == "parse_error" then
      if not opts.silent then
        vim.notify("✗ Ragex: Failed to analyze directory", vim.log.levels.ERROR)
      end
      return
    end
    
    if result and result.result then
      -- The MCP response wraps the actual result in result.content[1].text (JSON string)
      local actual_result = result.result
      
      -- If it's wrapped in content array, extract it
      if actual_result.content and actual_result.content[1] and actual_result.content[1].text then
        local ok, parsed = pcall(vim.fn.json_decode, actual_result.content[1].text)
        if ok then
          actual_result = parsed
        end
      end
      
      local count = actual_result.analyzed or actual_result.success or 0
      local total = actual_result.total or 0
      
      -- Show completion notification (replaces "Analyzing..." message)
      if not opts.silent then
        vim.notify(string.format("✓ Ragex: %d/%d files indexed in %s", count, total, vim.fn.fnamemodify(path, ":~")), vim.log.levels.INFO)
      end
    else
      if not opts.silent then
        vim.notify("✗ Ragex: Failed to analyze directory", vim.log.levels.ERROR)
      end
    end
  end)
end

-- Find callers of function under cursor
function M.find_callers()
  local module = M.get_current_module()
  if not module then
    vim.notify("Could not determine current module", vim.log.levels.WARN)
    return
  end

  local func = vim.fn.expand("<cword>")
  local arity = M.get_function_arity()

  return M.execute("query_graph", { 
    query_type = "get_callers",
    params = {
      module = module,
      ["function"] = func,
      arity = arity,
    },
  })
end

-- Refactor: rename function
function M.rename_function(new_name, scope)
  local module = M.get_current_module()
  if not module then
    vim.notify("Could not determine current module", vim.log.levels.WARN)
    return
  end

  local old_name = vim.fn.expand("<cword>")
  local arity = M.get_function_arity()

  local params = {
    operation = "rename_function",
    params = {
      module = module,
      old_name = old_name,
      new_name = new_name,
      arity = arity,
    },
    scope = scope or "project",
    validate = true,
    format = true,
  }

  vim.notify(
    string.format("Renaming %s.%s/%d -> %s", module, old_name, arity, new_name),
    vim.log.levels.INFO
  )

  M.execute("refactor_code", params, function(result)
    debug_log("refactor_code callback result: " .. vim.inspect(result))
    
    if not result then
      vim.notify("Refactoring failed: no response", vim.log.levels.ERROR)
      return
    end
    
    -- Handle error responses
    if result.error then
      vim.notify("Refactoring failed: " .. (result.error.message or vim.inspect(result.error)), vim.log.levels.ERROR)
      return
    end
    
    if not result.result then
      vim.notify("Refactoring failed: no result in response", vim.log.levels.ERROR)
      return
    end

    -- Unwrap MCP response
    local data = result.result
    debug_log("data before unwrap: " .. vim.inspect(data))
    
    if data.content and data.content[1] and data.content[1].text then
      local ok, parsed = pcall(vim.fn.json_decode, data.content[1].text)
      if ok then
        debug_log("parsed data: " .. vim.inspect(parsed))
        data = parsed
      else
        debug_log("Failed to parse JSON")
      end
    end

    debug_log("final data: " .. vim.inspect(data))
    
    if data.status == "success" then
      vim.cmd("checktime") -- Reload buffers
      vim.notify(string.format("Function renamed successfully (%d files)", data.files_modified or 0), vim.log.levels.INFO)
    else
      local err = data.error or "unknown error"
      vim.notify("Refactoring failed: " .. vim.inspect(err), vim.log.levels.ERROR)
    end
  end)
end

-- Refactor: rename module
function M.rename_module(old_name, new_name)
  local params = {
    operation = "rename_module",
    params = {
      old_name = old_name,
      new_name = new_name,
    },
    validate = true,
    format = true,
  }

  vim.notify(string.format("Renaming module %s -> %s", old_name, new_name), vim.log.levels.INFO)

  M.execute("refactor_code", params, function(result)
    if not result or not result.result then
      vim.notify("Refactoring failed: no response", vim.log.levels.ERROR)
      return
    end

    -- Unwrap MCP response
    local data = result.result
    if data.content and data.content[1] and data.content[1].text then
      local ok, parsed = pcall(vim.fn.json_decode, data.content[1].text)
      if ok then
        data = parsed
      end
    end

    if data.status == "success" then
      vim.cmd("checktime") -- Reload buffers
      vim.notify(string.format("Module renamed successfully (%d files)", data.files_modified or 0), vim.log.levels.INFO)
    else
      local err = data.error or result.error or "unknown error"
      vim.notify("Refactoring failed: " .. vim.inspect(err), vim.log.levels.ERROR)
    end
  end)
end

-- Watch current directory
function M.watch_directory(path, extensions)
  path = path or vim.fn.getcwd()
  extensions = extensions or { ".ex", ".exs" }

  local params = {
    path = path,
    extensions = extensions,
  }

  M.execute("watch_directory", params, function(result)
    if result and result.result then
      vim.notify("Watching directory: " .. path, vim.log.levels.INFO)
    else
      vim.notify("Failed to watch directory", vim.log.levels.ERROR)
    end
  end)
end

-- Get graph statistics
function M.graph_stats()
  return M.execute("graph_stats", {})
end

-- Phase 9: MCP Resources

-- Read a resource
function M.read_resource(uri, callback)
  if not M.config.enabled then
    debug_log("Ragex is disabled")
    return
  end

  local request = vim.fn.json_encode({
    jsonrpc = "2.0",
    method = "resources/read",
    params = { uri = uri },
    id = vim.fn.rand(),
  })

  debug_log("Resource request: " .. request)

  local cmd = string.format(
    "printf '%%s\\n' %s | socat - UNIX-CONNECT:/tmp/ragex_mcp.sock",
    vim.fn.shellescape(request)
  )

  if callback then
    vim.fn.jobstart(cmd, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        if data and #data > 0 then
          local result_str = table.concat(data, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          if result_str ~= "" then
            local ok, result = pcall(vim.fn.json_decode, result_str)
            if ok and result then
              callback(result, nil)
            else
              callback(nil, "parse_error")
            end
          end
        end
      end,
    })
  end
end

-- Phase 8: Advanced Graph Algorithms

-- Compute betweenness centrality
function M.betweenness_centrality(opts)
  opts = opts or {}
  local params = {
    max_nodes = opts.max_nodes or 1000,
    normalize = opts.normalize ~= false,
  }
  
  return M.execute("betweenness_centrality", params)
end

-- Compute closeness centrality
function M.closeness_centrality(opts)
  opts = opts or {}
  local params = {
    normalize = opts.normalize ~= false,
  }
  
  return M.execute("closeness_centrality", params)
end

-- Detect communities in the call graph
function M.detect_communities(opts)
  opts = opts or {}
  local params = {
    algorithm = opts.algorithm or "louvain",
    max_iterations = opts.max_iterations or 10,
    resolution = opts.resolution or 1.0,
    hierarchical = opts.hierarchical or false,
    seed = opts.seed,
  }
  
  return M.execute("detect_communities", params)
end

-- Export graph visualization
function M.export_graph(opts)
  opts = opts or {}
  local params = {
    format = opts.format or "graphviz",
    include_communities = opts.include_communities ~= false,
    color_by = opts.color_by or "pagerank",
    max_nodes = opts.max_nodes or 500,
  }
  
  return M.execute("export_graph", params)
end

-- Show betweenness centrality in floating window
function M.show_betweenness_centrality()
  vim.notify("Computing betweenness centrality...", vim.log.levels.INFO)
  
  M.execute("betweenness_centrality", { normalize = true }, function(result)
    if not result or not result.result then
      vim.notify("Failed to compute betweenness centrality", vim.log.levels.ERROR)
      return
    end
    
    -- Unwrap MCP response
    local data = result.result
    if data.content and data.content[1] and data.content[1].text then
      local ok, parsed = pcall(vim.fn.json_decode, data.content[1].text)
      if ok then
        data = parsed
      end
    end
    
    if not data.top_nodes or #data.top_nodes == 0 then
      vim.notify("No betweenness scores computed", vim.log.levels.WARN)
      return
    end
    
    local lines = { 
      "# Betweenness Centrality (Top Bridge Functions)", 
      "",
      "Higher scores indicate functions that connect different parts of the codebase.",
      ""
    }
    
    for i, node in ipairs(data.top_nodes) do
      if i <= 20 then  -- Show top 20
        table.insert(lines, string.format("%2d. %s  (%.6f)", i, node.node_id, node.betweenness_score))
      end
    end
    
    table.insert(lines, "")
    table.insert(lines, string.format("Total nodes analyzed: %d", data.total_nodes or 0))
    
    M.show_in_float("Betweenness Centrality", lines)
  end)
end

-- Show closeness centrality in floating window
function M.show_closeness_centrality()
  vim.notify("Computing closeness centrality...", vim.log.levels.INFO)
  
  M.execute("closeness_centrality", { normalize = true }, function(result)
    if not result or not result.result then
      vim.notify("Failed to compute closeness centrality", vim.log.levels.ERROR)
      return
    end
    
    -- Unwrap MCP response
    local data = result.result
    if data.content and data.content[1] and data.content[1].text then
      local ok, parsed = pcall(vim.fn.json_decode, data.content[1].text)
      if ok then
        data = parsed
      end
    end
    
    if not data.top_nodes or #data.top_nodes == 0 then
      vim.notify("No closeness scores computed", vim.log.levels.WARN)
      return
    end
    
    local lines = { 
      "# Closeness Centrality (Top Central Functions)", 
      "",
      "Higher scores indicate functions closer to all other functions in the call graph.",
      ""
    }
    
    for i, node in ipairs(data.top_nodes) do
      if i <= 20 then  -- Show top 20
        table.insert(lines, string.format("%2d. %s  (%.6f)", i, node.node_id, node.closeness_score))
      end
    end
    
    table.insert(lines, "")
    table.insert(lines, string.format("Total nodes analyzed: %d", data.total_nodes or 0))
    
    M.show_in_float("Closeness Centrality", lines)
  end)
end

-- Show communities in floating window
function M.show_communities(algorithm)
  algorithm = algorithm or "louvain"
  vim.notify(string.format("Detecting communities (%s)...", algorithm), vim.log.levels.INFO)
  
  local params = {
    algorithm = algorithm,
    max_iterations = 10,
    resolution = 1.0,
    hierarchical = false,
  }
  
  M.execute("detect_communities", params, function(result)
    if not result or not result.result then
      vim.notify("Failed to detect communities", vim.log.levels.ERROR)
      return
    end
    
    -- Unwrap MCP response
    local data = result.result
    if data.content and data.content[1] and data.content[1].text then
      local ok, parsed = pcall(vim.fn.json_decode, data.content[1].text)
      if ok then
        data = parsed
      end
    end
    
    if not data or #data == 0 then
      vim.notify("No communities detected", vim.log.levels.WARN)
      return
    end
    
    -- Sort communities by size (descending)
    table.sort(data, function(a, b) return a.size > b.size end)
    
    local lines = { 
      string.format("# Communities Detected (%s algorithm)", algorithm), 
      "",
      string.format("Found %d communities - potential architectural modules:", #data),
      ""
    }
    
    for i, community in ipairs(data) do
      if i <= 10 then  -- Show top 10 communities
        table.insert(lines, string.format("Community %d: %d members", i, community.size))
        
        -- Show first few members
        local member_count = math.min(5, #community.members)
        for j = 1, member_count do
          table.insert(lines, string.format("  - %s", community.members[j]))
        end
        
        if #community.members > member_count then
          table.insert(lines, string.format("  ... and %d more", #community.members - member_count))
        end
        
        table.insert(lines, "")
      end
    end
    
    if #data > 10 then
      table.insert(lines, string.format("... and %d more communities", #data - 10))
    end
    
    M.show_in_float("Community Detection", lines)
  end)
end

-- Export graph and save to file
function M.export_graph_to_file(format, filepath)
  format = format or "graphviz"
  filepath = filepath or vim.fn.expand("%:p:h") .. "/graph." .. (format == "graphviz" and "dot" or "json")
  
  vim.notify(string.format("Exporting graph to %s...", format), vim.log.levels.INFO)
  
  local params = {
    format = format,
    include_communities = true,
    color_by = "betweenness",
    max_nodes = 500,
  }
  
  M.execute("export_graph", params, function(result)
    if not result or not result.result then
      vim.notify("Failed to export graph", vim.log.levels.ERROR)
      return
    end
    
    -- Unwrap MCP response
    local data = result.result
    if data.content and data.content[1] and data.content[1].text then
      -- For export_graph, the response is the graph data itself
      local content = data.content[1].text
      
      -- Handle format-specific processing
      if format == "d3" then
        -- D3 format: content is JSON string, parse and re-encode for formatting
        local ok, parsed = pcall(vim.fn.json_decode, content)
        if ok then
          content = vim.fn.json_encode(parsed)
        end
      else
        -- Graphviz format: content might be JSON-encoded string, decode if needed
        -- Check if it starts with a quote (indicating it's JSON-encoded)
        if content:sub(1, 1) == '"' then
          local ok, decoded = pcall(vim.fn.json_decode, content)
          if ok and type(decoded) == "string" then
            content = decoded
          end
        end
      end
      
      -- Write to file
      local file = io.open(filepath, "w")
      if file then
        file:write(content)
        file:close()
        vim.notify(string.format("Graph exported to: %s", filepath), vim.log.levels.INFO)
        
        -- Offer to open the file
        vim.defer_fn(function()
          local choice = vim.fn.confirm("Open exported file?", "&Yes\n&No", 2)
          if choice == 1 then
            vim.cmd("edit " .. filepath)
          end
        end, 100)
      else
        vim.notify("Failed to write file: " .. filepath, vim.log.levels.ERROR)
      end
    end
  end)
end

-- Helper: Get current module name
function M.get_current_module()
  local lines = vim.api.nvim_buf_get_lines(0, 0, 100, false)
  for _, line in ipairs(lines) do
    local module = line:match("defmodule%s+([%w%.]+)")
    if module then
      return module
    end
  end
  return nil
end

-- Helper: Get function arity (improved)
function M.get_function_arity()
  -- Try current line first
  local line = vim.fn.getline(".")
  local args = line:match("def%s+%w+%((.-)%)") or line:match("defp%s+%w+%((.-)%)")
  
  -- If not found, search backwards for function definition
  if not args then
    local current_line = vim.fn.line(".")
    for i = current_line, math.max(1, current_line - 20), -1 do
      local search_line = vim.fn.getline(i)
      args = search_line:match("def%s+%w+%((.-)%)") or search_line:match("defp%s+%w+%((.-)%)")
      if args then
        break
      end
    end
  end
  
  if not args or args == "" then
    -- Prompt user for arity
    local arity_input = vim.fn.input("Function arity: ", "2")
    return tonumber(arity_input) or 0
  end
  
  -- Count commas + 1 for number of arguments
  -- Also handle default arguments (backslash backslash pattern)
  args = args:gsub("%s*\\\\.*", "")  -- Remove default arguments
  local _, count = args:gsub(",", "")
  return count + 1
end

-- Helper: Show results in floating window
function M.show_in_float(title, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")

  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(30, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })

  -- Keybindings to close
  local opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set("n", "q", "<cmd>close<cr>", opts)
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", opts)
  
  return buf, win
end

-- Show callers in floating window
-- Show callers in floating window with navigation
function M.show_callers()
  local module = M.get_current_module()
  if not module then
    vim.notify("Could not determine current module", vim.log.levels.WARN)
    return
  end

  local func = vim.fn.expand("<cword>")
  local arity = M.get_function_arity()

  M.execute("query_graph", { 
    query_type = "get_callers",
    params = {
      module = module,
      ["function"] = func,
      arity = arity
    }
  }, function(result)
    if not result or not result.result then
      vim.notify("No callers found", vim.log.levels.WARN)
      return
    end

    -- Unwrap MCP response
    local data = result.result
    if data.content and data.content[1] and data.content[1].text then
      local ok, parsed = pcall(vim.fn.json_decode, data.content[1].text)
      if ok then
        data = parsed
      end
    end

    if not data.callers or #data.callers == 0 then
      vim.notify("No callers found for " .. module .. "." .. func .. "/" .. arity, vim.log.levels.INFO)
      return
    end

    local lines = { string.format("# Callers of %s.%s/%d", module, func, arity), "", "Press <CR> to jump to caller, q to close", "" }
    local locations = {}  -- Store file:line for each entry
    
    for _, caller in ipairs(data.callers) do
      if caller.file and caller.line then
        local caller_name = string.format("%s.%s/%d", 
          caller.caller_module or "?", 
          caller.caller_function or "?", 
          caller.caller_arity or 0)
        table.insert(lines, string.format("%s:%d - %s", caller.file, caller.line, caller_name))
        table.insert(locations, {file = caller.file, line = caller.line})
      end
    end

    local buf, win = M.show_in_float("Ragex Callers", lines)
    
    -- Add keybinding to jump to location
    vim.keymap.set("n", "<CR>", function()
      local line_num = vim.fn.line(".")
      -- Line numbers 1-4 are header, locations start at line 5
      local loc_index = line_num - 4
      if loc_index > 0 and loc_index <= #locations then
        local loc = locations[loc_index]
        vim.cmd("close")  -- Close floating window
        vim.cmd(string.format("edit +%d %s", loc.line, loc.file))
      end
    end, { noremap = true, silent = true, buffer = buf })
  end)
end

-- Toggle auto-analysis
function M.toggle_auto_analyze()
  M.config.auto_analyze = not M.config.auto_analyze
  
  if M.config.auto_analyze then
    local ragex_group = vim.api.nvim_create_augroup("RagexAnalysis", { clear = true })
    vim.api.nvim_create_autocmd({ "BufWritePost" }, {
      group = ragex_group,
      pattern = { "*.ex", "*.exs" },
      callback = function()
        M.analyze_current_file()
      end,
    })
    vim.notify("Ragex auto-analysis enabled", vim.log.levels.INFO)
  else
    vim.api.nvim_del_augroup_by_name("RagexAnalysis")
    vim.notify("Ragex auto-analysis disabled", vim.log.levels.INFO)
  end
end

-- Show resource in floating window
function M.show_resource(uri, title)
  M.read_resource(uri, function(result, error_type)
    if error_type or not result or not result.result then
      vim.notify("Failed to read resource: " .. uri, vim.log.levels.ERROR)
      return
    end

    -- Unwrap MCP resource response
    local data = result.result
    if data.contents and data.contents[1] and data.contents[1].text then
      local ok, parsed = pcall(vim.fn.json_decode, data.contents[1].text)
      if ok then
        -- Pretty print JSON as YAML-like format
        local lines = { "# " .. title, "" }
        local function format_value(val, indent)
          indent = indent or 0
          local prefix = string.rep("  ", indent)
          
          if type(val) == "table" then
            if vim.tbl_islist(val) then
              for i, item in ipairs(val) do
                table.insert(lines, prefix .. "- " .. tostring(item))
              end
            else
              for k, v in pairs(val) do
                if type(v) == "table" then
                  table.insert(lines, prefix .. tostring(k) .. ":")
                  format_value(v, indent + 1)
                else
                  table.insert(lines, prefix .. tostring(k) .. ": " .. tostring(v))
                end
              end
            end
          else
            table.insert(lines, prefix .. tostring(val))
          end
        end
        
        format_value(parsed)
        M.show_in_float(title, lines)
      end
    end
  end)
end

-- Show all available resources
function M.show_resources_menu()
  local resources = {
    { name = "Graph Statistics", uri = "ragex://graph/stats" },
    { name = "Cache Status", uri = "ragex://cache/status" },
    { name = "Model Configuration", uri = "ragex://model/config" },
    { name = "Project Index", uri = "ragex://project/index" },
    { name = "Algorithm Catalog", uri = "ragex://algorithms/catalog" },
    { name = "Analysis Summary", uri = "ragex://analysis/summary" },
  }
  
  vim.ui.select(resources, {
    prompt = "Select Resource:",
    format_item = function(item)
      return item.name
    end,
  }, function(choice)
    if choice then
      M.show_resource(choice.uri, choice.name)
    end
  end)
end

-- Get a prompt (for interactive use)
function M.get_prompt(name, arguments, callback)
  if not M.config.enabled then
    debug_log("Ragex is disabled")
    return
  end

  local request = vim.fn.json_encode({
    jsonrpc = "2.0",
    method = "prompts/get",
    params = {
      name = name,
      arguments = arguments or {},
    },
    id = vim.fn.rand(),
  })

  local cmd = string.format(
    "printf '%%s\\n' %s | socat - UNIX-CONNECT:/tmp/ragex_mcp.sock",
    vim.fn.shellescape(request)
  )

  if callback then
    vim.fn.jobstart(cmd, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        if data and #data > 0 then
          local result_str = table.concat(data, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
          if result_str ~= "" then
            local ok, result = pcall(vim.fn.json_decode, result_str)
            if ok and result then
              callback(result, nil)
            else
              callback(nil, "parse_error")
            end
          end
        end
      end,
    })
  end
end

-- Execute analyze_architecture prompt
function M.prompt_analyze_architecture()
  vim.ui.input({ prompt = "Path to analyze: ", default = vim.fn.getcwd() }, function(path)
    if not path then return end
    
    vim.ui.select({ "shallow", "deep" }, {
      prompt = "Analysis depth:",
    }, function(depth)
      if not depth then return end
      
      M.get_prompt("analyze_architecture", { path = path, depth = depth }, function(result, err)
        if err or not result or not result.result then
          vim.notify("Failed to get prompt", vim.log.levels.ERROR)
          return
        end
        
        local prompt = result.result
        local message = prompt.messages and prompt.messages[1]
        if message and message.content and message.content.text then
          -- Show the prompt instructions
          local lines = vim.split(message.content.text, "\n")
          M.show_in_float("Analyze Architecture: " .. path, lines)
        end
      end)
    end)
  end)
end

-- Execute find_impact prompt
function M.prompt_find_impact()
  local module = M.get_current_module()
  if not module then
    vim.notify("Could not determine current module", vim.log.levels.WARN)
    return
  end
  
  local func = vim.fn.expand("<cword>")
  local arity = M.get_function_arity()
  
  M.get_prompt("find_impact", {
    module = module,
    ["function"] = func,
    arity = tostring(arity),
  }, function(result, err)
    if err or not result or not result.result then
      vim.notify("Failed to get prompt", vim.log.levels.ERROR)
      return
    end
    
    local prompt = result.result
    local message = prompt.messages and prompt.messages[1]
    if message and message.content and message.content.text then
      local lines = vim.split(message.content.text, "\n")
      M.show_in_float("Find Impact: " .. module .. "." .. func .. "/" .. arity, lines)
    end
  end)
end

-- Setup function
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  
  -- Auto-analyze on save for Elixir files (if enabled)
  if M.config.auto_analyze then
    local ragex_group = vim.api.nvim_create_augroup("RagexAnalysis", { clear = true })
    
    vim.api.nvim_create_autocmd({ "BufWritePost" }, {
      group = ragex_group,
      pattern = { "*.ex", "*.exs" },
      callback = function()
        M.analyze_current_file()
      end,
    })
    debug_log("Auto-analysis on save enabled")
  end
  
  -- Auto-analyze directories on startup (deferred to avoid blocking)
  if M.config.auto_analyze_on_start or (M.config.auto_analyze_dirs and #M.config.auto_analyze_dirs > 0) then
    vim.defer_fn(function()
      -- Check if current directory has Elixir files
      local has_elixir_files = vim.fn.glob("*.ex") ~= "" or vim.fn.glob("*.exs") ~= "" or 
                                vim.fn.glob("lib/**/*.ex") ~= "" or vim.fn.glob("test/**/*.exs") ~= ""
      
      -- Analyze current project directory if it has Elixir files
      if M.config.auto_analyze_on_start and has_elixir_files then
        local cwd = vim.fn.getcwd()
        debug_log("Auto-analyzing current directory on startup: " .. cwd)
        M.analyze_directory(cwd, { silent = false })
      end
      
      -- Analyze configured directories
      if M.config.auto_analyze_dirs and #M.config.auto_analyze_dirs > 0 then
        for _, dir in ipairs(M.config.auto_analyze_dirs) do
          local expanded_dir = vim.fn.expand(dir)
          if vim.fn.isdirectory(expanded_dir) == 1 then
            debug_log("Auto-analyzing configured directory: " .. expanded_dir)
            -- Use silent = true for background directories to avoid notification spam
            M.analyze_directory(expanded_dir, { silent = true })
          else
            debug_log("Skipping non-existent directory: " .. expanded_dir)
          end
        end
      end
    end, 1000)  -- Wait 1 second after startup to avoid blocking
  end
  
  debug_log("Ragex integration loaded")
end

return M
