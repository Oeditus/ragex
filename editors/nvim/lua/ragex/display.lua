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

--- Pretty-print any Lua value as JSON lines.
---@param data any
---@return string[]
function M.json(data)
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    return vim.split(vim.inspect(data), "\n", { plain = true })
  end

  -- Re-decode with a pretty printer if available (Neovim ships jq-less).
  local pretty = vim.fn.systemlist({ "jq", "." }, encoded)
  if vim.v.shell_error == 0 and #pretty > 0 then
    return pretty
  end

  return vim.split(encoded, "\n", { plain = true })
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
