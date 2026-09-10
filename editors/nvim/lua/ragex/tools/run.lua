--- Tool execution: build context, call the tool, display the result.
---
--- Centralizes the "prompt -> call -> render" flow so every catalog tool and
--- the generic `:Ragex call` command share identical behaviour (timeouts,
--- error handling, result rendering).
local M = {}

local client = require("ragex.client")
local catalog = require("ragex.tools.catalog")
local display = require("ragex.display")
local response = require("ragex.response")
local ui = require("ragex.ui")

--- Build catalog arguments asynchronously without blocking Neovim's event loop.
---@param spec RagexToolSpec
---@param callback fun(args: table|nil)
function M.build_args_async(spec, callback)
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    path = vim.fn.expand("%:p")
  end

  local cwd = vim.fn.getcwd()
  local relpath = path
  if path ~= "" and path:sub(1, #cwd) == cwd then
    relpath = path:sub(#cwd + 2)
  end

  -- `<cword>` raises E348 on an empty buffer / blank line; guard it.
  local word = ""
  pcall(function()
    word = vim.fn.expand("<cword>")
  end)

  local thread = coroutine.create(function()
    local co = coroutine.running()
    local ctx = {
      path = path,
      relpath = relpath,
      cwd = cwd,
      word = word,
      input = function(prompt, default)
        vim.schedule(function()
          vim.ui.input({ prompt = prompt, default = default }, function(value)
            coroutine.resume(co, value)
          end)
        end)
        return coroutine.yield()
      end,
      select = function(prompt, items)
        vim.schedule(function()
          vim.ui.select(items, { prompt = prompt }, function(choice)
            coroutine.resume(co, choice)
          end)
        end)
        return coroutine.yield()
      end,
    }

    local ok, args = pcall(spec.args, ctx)
    if ok and type(args) == "table" then
      callback(args)
    else
      callback(nil)
    end
  end)

  coroutine.resume(thread)
end

--- Resolve the timeout for a tool spec.
---@param spec RagexToolSpec|nil
---@return integer
local function timeout_for(spec)
  local key = (spec and spec.timeout) or "default"
  return catalog.timeouts[key] or catalog.timeouts.default
end

--- Run a tool by name with explicit arguments.
---@param name string
---@param args table
---@param opts table|nil  { on_result, silent, on_chunk, timeout }
function M.run(name, args, opts)
  opts = opts or {}
  local spec = catalog.get(name)
  local timeout = opts.timeout or timeout_for(spec)

  client.call_tool(name, args, {
    timeout = timeout,
    on_chunk = opts.on_chunk,
    callback = function(result, err)
      if err then
        ui.notify(name .. " failed: " .. response.error_message(err), vim.log.levels.ERROR)
        if opts.on_result then
          opts.on_result(nil, err)
        end
        return
      end

      local data, uerr = response.unwrap(result)
      if uerr then
        ui.notify(name .. " failed: " .. uerr, vim.log.levels.ERROR)
        if opts.on_result then
          opts.on_result(nil, { kind = "unwrap", message = uerr })
        end
        return
      end

      if opts.on_result then
        opts.on_result(data, nil)
      elseif not opts.silent then
        display.show(name, data)
      end
    end,
  })
end

--- Run a catalog tool: build args asynchronously, then execute.
---@param name string
---@param opts table|nil
function M.run_catalog(name, opts)
  local spec = catalog.get(name)
  if not spec then
    ui.notify("unknown tool: " .. name, vim.log.levels.ERROR)
    return
  end

  M.build_args_async(spec, function(args)
    if args == nil then
      return
    end
    M.run(name, args, opts)
  end)
end

--- Run a catalog tool asynchronously and route search results through Telescope picker.
---@param name string
---@param opts table|nil
function M.run_search(name, opts)
  local spec = catalog.get(name)
  if not spec then
    ui.notify("unknown tool: " .. name, vim.log.levels.ERROR)
    return
  end

  M.build_args_async(spec, function(args)
    if args == nil then
      return
    end
    local picker = require("ragex.picker")
    picker.search(name, args.query, vim.tbl_extend("force", args, { query = nil }), {
      title = opts and opts.title or nil,
    })
  end)
end

return M
