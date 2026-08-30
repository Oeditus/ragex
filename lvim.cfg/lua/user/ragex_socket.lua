-- Direct Unix socket connection to Ragex MCP server
-- This bypasses shell commands entirely

local M = {}

-- Resolve the MCP socket path the same way Ragex.MCP.SocketPath.compute_string/0
-- (Elixir) and bin/ragex-mcp (Bash) do, so we always talk to the correct
-- per-project/per-port server instead of a stale/foreign one:
--   1. RAGEX_MCP_SOCK (explicit override, used verbatim)
--   2. DLLB_PORT      (namespace by dllb server port)
--   3. otherwise       namespace by the current working directory (sanitized)
local function default_socket_path()
  local override = vim.fn.getenv("RAGEX_MCP_SOCK")
  if override ~= vim.NIL and override ~= "" then
    return override
  end

  local dllb_port = vim.fn.getenv("DLLB_PORT")
  if dllb_port ~= vim.NIL and dllb_port ~= "" then
    return "/tmp/ragex_mcp_" .. dllb_port .. ".sock"
  end

  local sanitized = vim.fn.getcwd():gsub("^/", ""):gsub("[^%w]+", "_"):gsub("_+$", "")
  return "/tmp/ragex_mcp_" .. sanitized .. ".sock"
end

local socket_path = default_socket_path()

function M.send_request(request_json)
  -- Use luasocket if available, otherwise fall back to command
  local has_socket, socket = pcall(require, "socket.unix")
  
  if has_socket then
    local client = socket()
    local ok, err = client:connect(socket_path)
    
    if not ok then
      return nil, "Failed to connect: " .. tostring(err)
    end
    
    -- Set timeout for receive (30 seconds for long operations)
    client:settimeout(30)
    
    -- Send request
    local sent, err = client:send(request_json .. "\n")
    if not sent then
      client:close()
      return nil, "Failed to send: " .. tostring(err)
    end
    
    -- Read response (wait for complete line)
    local response, err, partial = client:receive("*l")
    
    -- Always close the connection after receiving response
    client:close()
    
    if not response then
      if partial and partial ~= "" then
        return nil, "Incomplete response: " .. tostring(err) .. " (got: " .. partial:sub(1, 100) .. ")"
      end
      return nil, "Failed to receive: " .. tostring(err)
    end
    
    return response, nil
  else
    -- Fallback: use socat if available
    local handle = io.popen(string.format(
      "echo %s | socat - UNIX-CONNECT:%s",
      vim.fn.shellescape(request_json),
      socket_path
    ))
    
    if not handle then
      return nil, "Failed to execute socat"
    end
    
    local response = handle:read("*a")
    handle:close()
    
    return response, nil
  end
end

function M.test()
  local request = vim.fn.json_encode({
    jsonrpc = "2.0",
    method = "tools/call",
    params = {
      name = "graph_stats",
      arguments = vim.empty_dict() -- Force empty object
    },
    id = 1
  })
  
  vim.notify("Sending: " .. request, vim.log.levels.INFO)
  
  local response, err = M.send_request(request)
  
  if err then
    vim.notify("Error: " .. err, vim.log.levels.ERROR)
    return nil
  end
  
  vim.notify("Response: " .. (response or "nil"), vim.log.levels.INFO)
  
  if response then
    local ok, result = pcall(vim.fn.json_decode, response)
    if ok then
      return result
    else
      vim.notify("JSON decode failed: " .. tostring(result), vim.log.levels.ERROR)
    end
  end
  
  return nil
end

return M
