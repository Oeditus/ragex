--- Helpers for interpreting Ragex MCP responses.
---
--- Every `tools/call` response is wrapped by the server as:
---
---   { content = { { type = "text", text = "<json>" } } }
---
--- where `<json>` is the JSON-encoded tool payload. These helpers unwrap that
--- envelope and decode the inner payload so callers can work with plain Lua
--- tables.
local M = {}

--- Unwrap an MCP `tools/call` result.
---@param result table|nil
---@return table|nil data, string|nil err
function M.unwrap(result)
  if result == nil then
    return nil, "empty result"
  end

  -- Error shape: { error = {...} } (rare; usually surfaced via JSON-RPC error).
  if result.error then
    return nil, result.error.message or "unknown error"
  end

  local content = result.content
  if type(content) ~= "table" or content[1] == nil then
    -- Some servers return the payload directly.
    return result, nil
  end

  local text = content[1].text
  if type(text) ~= "string" then
    return result, nil
  end

  local ok, decoded = pcall(vim.json.decode, text)
  if ok and decoded ~= nil then
    return decoded, nil
  end

  -- Not JSON (plain text tool output) -- return it verbatim.
  return { text = text }, nil
end

--- Normalize a tool error into a human-readable string.
---@param err table|nil
---@return string
function M.error_message(err)
  if not err then
    return "unknown error"
  end
  if type(err) == "string" then
    return err
  end
  if err.message then
    return err.message
  end
  return vim.inspect(err)
end

--- Best-effort extraction of a list of results from a search payload.
---
--- `semantic_search` / `hybrid_search` return `{ results = [...] }` where each
--- element has `node_id`, `score`, `description`, and optional `context`.
---@param data table|nil
---@return table[] results
function M.search_results(data)
  if type(data) ~= "table" then
    return {}
  end
  return data.results or {}
end

--- Render a search result row as a single display line.
---@param item table
---@return string
function M.format_search_item(item)
  local id = item.node_id or "?"
  local score = item.score and string.format("%.3f", item.score) or "?"
  local desc = item.description or ""

  -- Context (when include_context = true) carries file/line.
  local location = ""
  local ctx = item.context
  if type(ctx) == "table" and ctx.file then
    location = ctx.file
    if ctx.line then
      location = location .. ":" .. tostring(ctx.line)
    end
  end

  local parts = { string.format("[%s] %s", score, id) }
  if location ~= "" then
    table.insert(parts, location)
  end
  if desc ~= "" then
    table.insert(parts, desc)
  end

  return table.concat(parts, "  ")
end

--- Split a `node_id` like "Elixir.My.Module.func/2" into module/function/arity.
---@param node_id string|nil
---@return string|nil module, string|nil func, integer|nil arity
function M.parse_node_id(node_id)
  if type(node_id) ~= "string" then
    return nil, nil, nil
  end

  local module, func, arity = node_id:match("^(.-)%.([%w_!?]+)/(%d+)$")
  if module then
    return module, func, tonumber(arity)
  end

  return node_id, nil, nil
end

--- Extract a file path and line from a search/context payload, if present.
---@param item table
---@return string|nil file, integer|nil line
function M.location(item)
  local ctx = item and item.context
  if type(ctx) == "table" and ctx.file then
    return ctx.file, ctx.line
  end
  return nil, nil
end

return M
