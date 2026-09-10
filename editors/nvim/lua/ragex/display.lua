--- Rendering helpers that turn arbitrary Ragex tool payloads into readable
--- buffers / floats.
---
--- The MCP surface is large (~50 tools) and heterogeneous, so rather than
--- hand-formatting every tool we provide:
---   * `display.json` -- pretty-printed JSON (always correct, verbose)
---   * `display.auto` -- prefers a `summary`/`content`/`text` field when the
---     payload provides one, else falls back to pretty JSON.
local M = {}

local ui = require("ragex.ui")

local function format_json(val, indent)
  indent = indent or 0
  local spaces = string.rep("  ", indent)
  local t = type(val)
  if t == "nil" then
    return "null"
  elseif t == "boolean" or t == "number" then
    return tostring(val)
  elseif t == "string" then
    return vim.json.encode(val)
  elseif t == "table" then
    local is_array = vim.islist and vim.islist(val) or (vim.tbl_islist and vim.tbl_islist(val)) or (#val > 0)
    if is_array then
      if #val == 0 then return "[]" end
      local items = {}
      for _, item in ipairs(val) do
        table.insert(items, spaces .. "  " .. format_json(item, indent + 1))
      end
      return "[\n" .. table.concat(items, ",\n") .. "\n" .. spaces .. "]"
    else
      local keys = vim.tbl_keys(val)
      if #keys == 0 then return "{}" end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      local items = {}
      for _, k in ipairs(keys) do
        table.insert(items, spaces .. "  " .. vim.json.encode(tostring(k)) .. ": " .. format_json(val[k], indent + 1))
      end
      return "{\n" .. table.concat(items, ",\n") .. "\n" .. spaces .. "}"
    end
  else
    return vim.json.encode(tostring(val))
  end
end

--- Pretty-print any Lua value as JSON lines.
---@param data any
---@return string[]
function M.json(data)
  local ok, formatted = pcall(format_json, data, 0)
  if ok and formatted then
    return vim.split(formatted, "\n", { plain = true })
  end

  local ok_enc, encoded = pcall(vim.json.encode, data)
  if ok_enc then
    return vim.split(encoded, "\n", { plain = true })
  end

  return vim.split(vim.inspect(data), "\n", { plain = true })
end

--- Choose the most human-friendly representation available in `data`.
---@param data any
---@return string[]
function M.auto(data)
  if type(data) ~= "table" then
    return { tostring(data) }
  end

  -- Prefer explicit prose fields the server provides.
  for _, key in ipairs({ "summary", "content", "report", "text", "message" }) do
    local value = data[key]
    if type(value) == "string" and value ~= "" then
      return vim.split(value, "\n", { plain = true })
    end
  end

  return M.json(data)
end

--- Show a payload in a split buffer.
---@param title string
---@param data any
---@param opts table|nil  { mode = "auto"|"json" }
function M.show(title, data, opts)
  opts = opts or {}
  local lines = (opts.mode == "json") and M.json(data) or M.auto(data)

  -- Prepend a header separator for readability.
  local header = { "── " .. title .. " " .. string.rep("─", math.max(0, 60 - #title)) }
  vim.list_extend(header, lines)

  ui.open_buffer(header, { title = "ragex://" .. title, filetype = "json" })
end

--- Show a payload in a floating window.
---@param title string
---@param data any
---@param opts table|nil
function M.float(title, data, opts)
  opts = opts or {}
  local lines = (opts.mode == "json") and M.json(data) or M.auto(data)
  ui.float(lines, { title = title })
end

return M
