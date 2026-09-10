--- `:Ragex` command surface.
---
--- A single dispatcher command plus a handful of convenience commands. The
--- generic form `:Ragex <tool> [key=value ...]` can invoke *any* catalog tool
--- without dedicated plumbing, which keeps the command set small while still
--- exposing the full ~50-tool surface.
local M = {}

local catalog = require("ragex.tools.catalog")
local client = require("ragex.client")
local display = require("ragex.display")
local response = require("ragex.response")
local ui = require("ragex.ui")

--- Coerce a "key=value" string into a typed Lua value.
---@param value string
---@return any
local function coerce(value)
  if value == "true" then
    return true
  elseif value == "false" then
    return false
  elseif tonumber(value) then
    return tonumber(value)
  elseif value:sub(1, 1) == "{" or value:sub(1, 1) == "[" then
    local ok, decoded = pcall(vim.json.decode, value)
    if ok then
      return decoded
    end
  end
  return value
end

--- Parse trailing "key=value" tokens into an arguments table.
---@param tokens string[]
---@return table
local function parse_kv(tokens)
  local args = {}
  for _, token in ipairs(tokens) do
    local key, value = token:match("^([%w_]+)=(.*)$")
    if key then
      args[key] = coerce(value)
    end
  end
  return args
end

--- Interactive menu: pick a category, then a tool.
function M.tool_menu()
  local categories = catalog.by_category()
  local names = vim.tbl_keys(categories)
  table.sort(names)

  vim.ui.select(names, { prompt = "Ragex category: " }, function(category)
    if not category then
      return
    end

    local tools = categories[category]
    local labels = {}
    for _, tool in ipairs(tools) do
      table.insert(labels, string.format("%s -- %s", tool.name, tool.desc))
    end

    vim.ui.select(labels, { prompt = "Ragex tool (" .. category .. "): " }, function(_, idx)
      if idx then
        require("ragex.tools.run").run_catalog(tools[idx].name)
      end
    end)
  end)
end

--- Show a summary of the connection + graph.
function M.status()
  local result, err = client.call_tool_sync("graph_stats", {}, 8000)
  if err then
    ui.notify("not connected: " .. response.error_message(err), vim.log.levels.WARN)
    return
  end

  local data = response.unwrap(result)
  local lines = {
    "Ragex status",
    string.rep("=", 40),
    "transport : " .. tostring(client.transport_kind()),
    "socket    : " .. tostring(client.config().socket_path),
    "binary    : " .. tostring(client.config().ragex_bin),
    "",
    "graph nodes : " .. tostring(data and data.node_count or "?"),
    "graph edges : " .. tostring(data and data.edge_count or "?"),
  }
  ui.float(lines, { title = "Ragex status" })
end

--- List every catalog tool in a buffer.
function M.list_tools()
  local lines = { "Ragex tool catalog", string.rep("=", 40), "" }
  local categories = catalog.by_category()
  local names = vim.tbl_keys(categories)
  table.sort(names)

  for _, category in ipairs(names) do
    table.insert(lines, "## " .. category)
    for _, tool in ipairs(categories[category]) do
      table.insert(lines, string.format("  %-28s %s", tool.name, tool.desc))
    end
    table.insert(lines, "")
  end

  ui.open_buffer(lines, { title = "ragex://tools", filetype = "markdown" })
end

--- Entry point for `:Ragex ...`.
---@param fargs string[]
function M.dispatch(fargs)
  local sub = fargs[1]
  local rest = vim.list_slice(fargs, 2)

  if sub == nil or sub == "" then
    M.tool_menu()
    return
  end

  local run = require("ragex.tools.run")

  if sub == "menu" then
    M.tool_menu()
  elseif sub == "status" then
    M.status()
  elseif sub == "tools" then
    M.list_tools()
  elseif sub == "search" then
    run.run_search("hybrid_search", { title = "Ragex: hybrid search" })
  elseif sub == "semantic" then
    run.run_search("semantic_search", { title = "Ragex: semantic search" })
  elseif sub == "word" then
    require("ragex").search_word()
  elseif sub == "analyze" then
    require("ragex").analyze_file()
  elseif sub == "analyze_dir" then
    require("ragex").analyze_directory()
  elseif sub == "query" then
    require("ragex").rag_query(table.concat(rest, " "))
  elseif sub == "explain" then
    require("ragex").rag_explain()
  elseif sub == "suggest" then
    require("ragex").rag_suggest()
  elseif sub == "rename_function" then
    require("ragex").rename_function()
  elseif sub == "rename_module" then
    require("ragex").rename_module()
  elseif sub == "auto" then
    require("ragex").toggle_auto_analyze()
  elseif catalog.get(sub) then
    -- Generic: `:Ragex <tool> key=value ...`
    local args = parse_kv(rest)
    if next(args) == nil then
      run.run_catalog(sub)
    else
      run.run(sub, args)
    end
  else
    ui.notify("unknown subcommand or tool: " .. sub .. " (try :Ragex tools)", vim.log.levels.ERROR)
  end
end

--- Register the user commands.
function M.setup()
  vim.api.nvim_create_user_command("Ragex", function(cmd_opts)
    M.dispatch(cmd_opts.fargs)
  end, {
    nargs = "*",
    complete = function(arg_lead, cmd_line, _)
      local candidates = {
        "menu",
        "status",
        "tools",
        "search",
        "semantic",
        "word",
        "analyze",
        "analyze_dir",
        "query",
        "explain",
        "suggest",
        "rename_function",
        "rename_module",
        "auto",
      }
      for _, tool in ipairs(catalog.tools) do
        table.insert(candidates, tool.name)
      end

      -- Only complete the first argument.
      if #vim.split(cmd_line, "%s+") <= 2 then
        return vim.tbl_filter(function(item)
          return item:sub(1, #arg_lead) == arg_lead
        end, candidates)
      end
      return {}
    end,
    desc = "Ragex: MCP client (run :Ragex for a menu)",
  })

  vim.api.nvim_create_user_command("RagexSearch", function()
    require("ragex").search_hybrid()
  end, { desc = "Ragex: hybrid search" })

  vim.api.nvim_create_user_command("RagexQuery", function(cmd_opts)
    require("ragex").rag_query(cmd_opts.args)
  end, { nargs = "+", desc = "Ragex: streaming RAG query" })

  vim.api.nvim_create_user_command("RagexStatus", function()
    M.status()
  end, { desc = "Ragex: connection status" })

  vim.api.nvim_create_user_command("RagexClose", function()
    client.close()
    ui.notify("connection closed")
  end, { desc = "Ragex: close the transport" })
end

return M
