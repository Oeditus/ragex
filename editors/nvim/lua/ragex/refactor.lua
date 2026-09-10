--- High-level refactoring flows.
---
--- These wrap the raw MCP tools (`refactor_code`, `advanced_refactor`,
--- `preview_refactor`) with editor-friendly behaviour:
---   * derive the module/function from the buffer when possible
---   * preview + confirm before mutating files
---   * reload any buffers the server changed on disk
local M = {}

local client = require("ragex.client")
local display = require("ragex.display")
local response = require("ragex.response")
local ui = require("ragex.ui")

--- Detect the enclosing `defmodule` name in the current buffer.
---@return string|nil
function M.current_module()
  local lines = vim.api.nvim_buf_get_lines(0, 0, 200, false)
  for _, line in ipairs(lines) do
    local name = line:match("^%s*defmodule%s+([%w%.]+)%s+do")
    if name then
      return name
    end
  end
  return nil
end

--- Detect the function name under the cursor.
---@return string|nil
function M.function_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local def = line:match("^%s*defp?%s+([%w_!?]+)")
  if def then
    return def
  end
  local word = ""
  pcall(function()
    word = vim.fn.expand("<cword>")
  end)
  return word
end

--- Reload buffers whose files changed on disk.
---@param files string[]|nil
local function reload(files)
  vim.schedule(function()
    if type(files) == "table" and #files > 0 then
      for _, file in ipairs(files) do
        local bufnr = vim.fn.bufnr(file)
        if bufnr ~= -1 then
          pcall(vim.api.nvim_buf_call, bufnr, function()
            vim.cmd("edit!")
          end)
        end
      end
    else
      -- Fall back to reloading the current buffer.
      pcall(vim.cmd, "edit!")
    end
  end)
end

--- Confirm a destructive refactoring.
---@param prompt string
---@param on_yes fun()
local function confirm(prompt, on_yes)
  vim.ui.select({ "Yes", "No" }, { prompt = prompt }, function(choice)
    if choice == "Yes" then
      on_yes()
    end
  end)
end

--- Rename a function project-wide.
---@param opts table|nil  { module, old_name, new_name, arity }
function M.rename_function(opts)
  opts = opts or {}

  local function ask(cb)
    local module = opts.module or M.current_module()
    if not module then
      module = ui.input("Module: ", nil, function(v)
        cb(v, opts.old_name or M.function_under_cursor(), opts.new_name, opts.arity)
      end)
      return
    end
    cb(module, opts.old_name or M.function_under_cursor(), opts.new_name, opts.arity)
  end

  ask(function(module, old_name, new_name, arity)
    if not module or not old_name then
      ui.notify("module and function name are required", vim.log.levels.WARN)
      return
    end

    local function with_new_name(nn)
      if not nn or nn == "" then
        return
      end

      local function with_arity(a)
        local params = { module = module, old_name = old_name, new_name = nn }
        if a then
          params.arity = tonumber(a)
        end

        confirm(string.format("Rename %s.%s -> %s project-wide?", module, old_name, nn), function()
          client.call_tool("refactor_code", {
            operation = "rename_function",
            params = params,
            scope = "project",
            validate = true,
            format = true,
          }, {
            timeout = 120000,
            callback = function(result, err)
              if err then
                ui.notify("rename failed: " .. response.error_message(err), vim.log.levels.ERROR)
                return
              end
              local data, uerr = response.unwrap(result)
              if uerr then
                ui.notify("rename failed: " .. uerr, vim.log.levels.ERROR)
                return
              end
              ui.notify(string.format("renamed %s.%s -> %s", module, old_name, nn))
              reload(data and data.files_modified)
            end,
          })
        end)
      end

      if arity then
        with_arity(arity)
      else
        ui.input("Arity (blank = any): ", nil, with_arity)
      end
    end

    if new_name then
      with_new_name(new_name)
    else
      ui.input("New name: ", nil, with_new_name)
    end
  end)
end

--- Rename a module project-wide.
---@param opts table|nil  { old_name, new_name }
function M.rename_module(opts)
  opts = opts or {}

  local function with_new_name(nn)
    if not nn or nn == "" then
      return
    end
    local old = opts.old_name
    confirm(string.format("Rename module %s -> %s project-wide?", old, nn), function()
      client.call_tool("refactor_code", {
        operation = "rename_module",
        params = { old_name = old, new_name = nn },
        validate = true,
      }, {
        timeout = 120000,
        callback = function(result, err)
          if err then
            ui.notify("rename failed: " .. response.error_message(err), vim.log.levels.ERROR)
            return
          end
          local data, uerr = response.unwrap(result)
          if uerr then
            ui.notify("rename failed: " .. uerr, vim.log.levels.ERROR)
            return
          end
          ui.notify(string.format("renamed module %s -> %s", old, nn))
          reload(data and data.files_modified)
        end,
      })
    end)
  end

  local old = opts.old_name
  if not old then
    ui.input("Current module name: ", M.current_module(), function(value)
      if value and value ~= "" then
        opts.old_name = value
        ui.input("New module name: ", nil, with_new_name)
      end
    end)
  else
    ui.input("New module name: ", nil, with_new_name)
  end
end

--- Run an advanced refactoring operation (fully-supported subset).
---@param operation string
function M.advanced(operation)
  local module = M.current_module()
  local func = M.function_under_cursor()

  local function run(params)
    client.call_tool("advanced_refactor", {
      operation = operation,
      params = params,
      validate = true,
      format = true,
    }, {
      timeout = 120000,
      callback = function(result, err)
        if err then
          ui.notify(operation .. " failed: " .. response.error_message(err), vim.log.levels.ERROR)
          return
        end
        local data, uerr = response.unwrap(result)
        if uerr then
          ui.notify(operation .. " failed: " .. uerr, vim.log.levels.ERROR)
          return
        end
        ui.notify(operation .. " applied")
        reload(data and data.files_modified)
      end,
    })
  end

  if operation == "convert_visibility" then
    ui.input("Module: ", module, function(mod)
      if not mod then
        return
      end
      ui.input("Function: ", func, function(fn)
        if not fn then
          return
        end
        ui.input("Arity: ", nil, function(arity)
          if not arity then
            return
          end
          ui.select({ "public", "private" }, { prompt = "Visibility: " }, function(vis)
            if not vis then
              return
            end
            run({ module = mod, ["function"] = fn, arity = tonumber(arity), visibility = vis })
          end)
        end)
      end)
    end)
  elseif operation == "rename_parameter" then
    ui.input("Module: ", module, function(mod)
      if not mod then
        return
      end
      ui.input("Function: ", func, function(fn)
        if not fn then
          return
        end
        ui.input("Arity: ", nil, function(arity)
          if not arity then
            return
          end
          ui.input("Old parameter: ", nil, function(old_param)
            if not old_param then
              return
            end
            ui.input("New parameter: ", nil, function(new_param)
              if not new_param then
                return
              end
              run({
                module = mod,
                ["function"] = fn,
                arity = tonumber(arity),
                old_param = old_param,
                new_param = new_param,
              })
            end)
          end)
        end)
      end)
    end)
  else
    ui.notify("unsupported advanced operation: " .. operation, vim.log.levels.WARN)
  end
end

--- Preview a refactoring without applying it.
---@param operation string
function M.preview(operation)
  local module = M.current_module()
  local old_name = M.function_under_cursor()

  ui.input("New name: ", nil, function(new_name)
    if not new_name then
      return
    end
    client.call_tool("preview_refactor", {
      operation = operation,
      params = { module = module, old_name = old_name, new_name = new_name },
      format = "unified",
    }, {
      timeout = 60000,
      callback = function(result, err)
        if err then
          ui.notify("preview failed: " .. response.error_message(err), vim.log.levels.ERROR)
          return
        end
        local data, uerr = response.unwrap(result)
        if uerr then
          ui.notify("preview failed: " .. uerr, vim.log.levels.ERROR)
          return
        end
        display.show("preview: " .. operation, data)
      end,
    })
  end)
end

return M
