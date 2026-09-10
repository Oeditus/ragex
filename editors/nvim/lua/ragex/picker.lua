--- Telescope-backed pickers for Ragex search results.
---
--- Falls back to `vim.ui.select` when Telescope is unavailable, so the plugin
--- never hard-depends on it.
local M = {}

local client = require("ragex.client")
local response = require("ragex.response")
local ui = require("ragex.ui")

---@return boolean
local function has_telescope()
  local ok, _ = pcall(require, "telescope")
  return ok
end

--- Open a search result at its file:line (or show a float when no location).
---@param item table
local function open_item(item)
  local file, line = response.location(item)
  if file and file ~= "" then
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    if line and line > 0 then
      pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
      vim.cmd("normal! zz")
    end
  else
    ui.float({ response.format_search_item(item) }, { title = "Ragex result" })
  end
end

--- Run a search tool and present results.
---@param tool string        "semantic_search" | "hybrid_search"
---@param query string
---@param args table|nil     extra tool arguments
---@param opts table|nil     { title }
function M.search(tool, query, args, opts)
  opts = opts or {}
  local title = opts.title or ("Ragex: " .. tool)

  local arguments = vim.tbl_extend("force", { query = query }, args or {})

  client.call_tool(tool, arguments, {
    callback = function(result, err)
      if err then
        ui.notify("search failed: " .. response.error_message(err), vim.log.levels.ERROR)
        return
      end

      local data, uerr = response.unwrap(result)
      if uerr then
        ui.notify("search failed: " .. uerr, vim.log.levels.ERROR)
        return
      end

      local results = response.search_results(data)
      if #results == 0 then
        ui.notify("no results", vim.log.levels.WARN)
        return
      end

      if has_telescope() then
        local pickers = require("telescope.pickers")
        local finders = require("telescope.finders")
        local conf = require("telescope.config").values
        local actions = require("telescope.actions")
        local action_state = require("telescope.actions.state")

        pickers
          .new({}, {
            prompt_title = title,
            finder = finders.new_table({
              results = results,
              entry_maker = function(entry)
                return {
                  value = entry,
                  display = response.format_search_item(entry),
                  ordinal = response.format_search_item(entry),
                }
              end,
            }),
            sorter = conf.generic_sorter({}),
            attach_mappings = function(prompt_bufnr)
              actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                if selection then
                  open_item(selection.value)
                end
              end)
              return true
            end,
          })
          :find()
      else
        local labels = {}
        for _, item in ipairs(results) do
          table.insert(labels, response.format_search_item(item))
        end

        vim.ui.select(labels, { prompt = title }, function(_, idx)
          if idx then
            open_item(results[idx])
          end
        end)
      end
    end,
  })
end

--- Generic picker over an arbitrary list of already-fetched rows.
---@param title string
---@param rows table[]            raw items
---@param render fun(item: table): string
---@param on_select fun(item: table)|nil
function M.pick(title, rows, render, on_select)
  if #rows == 0 then
    ui.notify("no results", vim.log.levels.WARN)
    return
  end

  if has_telescope() then
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    pickers
      .new({}, {
        prompt_title = title,
        finder = finders.new_table({
          results = rows,
          entry_maker = function(entry)
            local display = render(entry)
            return { value = entry, display = display, ordinal = display }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local selection = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if selection and on_select then
              on_select(selection.value)
            end
          end)
          return true
        end,
      })
      :find()
  else
    local labels = {}
    for _, item in ipairs(rows) do
      table.insert(labels, render(item))
    end
    vim.ui.select(labels, { prompt = title }, function(_, idx)
      if idx and on_select then
        on_select(rows[idx])
      end
    end)
  end
end

return M
