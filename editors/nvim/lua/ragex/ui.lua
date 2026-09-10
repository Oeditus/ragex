--- UI primitives for ragex.nvim.
---
--- Deliberately dependency-free: notifications use `vim.notify`, selections
--- use `vim.ui.select`, and rich output uses scratch buffers + floating
--- windows. Telescope (when installed) provides the fancy pickers in
--- `ragex.ui.picker`, but nothing here requires it.
local M = {}

local ns = vim.api.nvim_create_namespace("ragex")

--- Notify with a consistent prefix.
---@param msg string
---@param level integer|nil  vim.log.levels.*
function M.notify(msg, level)
  vim.notify("[ragex] " .. msg, level or vim.log.levels.INFO)
end

--- Open a scratch buffer in a split showing a list of lines.
---@param lines string[]
---@param opts table|nil  { title, filetype, modifiable, split }
---@return integer bufnr
function M.open_buffer(lines, opts)
  opts = opts or {}
  local split = opts.split or "botright split"

  vim.cmd(split)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, bufnr)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = opts.modifiable ~= false
  if opts.filetype then
    vim.bo[bufnr].filetype = opts.filetype
  end

  if opts.title then
    vim.api.nvim_buf_set_name(bufnr, opts.title)
  end

  return bufnr
end

--- Show a list of lines in a floating window.
---@param lines string[]
---@param opts table|nil  { title, width, height, border }
function M.float(lines, opts)
  opts = opts or {}
  lines = lines or {}

  local max_width = 0
  for _, l in ipairs(lines) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(l))
  end

  local total = vim.o.columns
  local total_h = vim.o.lines

  local width = opts.width or math.min(math.max(max_width + 4, 40), math.floor(total * 0.9))
  local height = opts.height or math.min(math.max(#lines, 1), math.floor(total_h * 0.8))

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].bufhidden = "wipe"

  local row = math.floor((total_h - height) / 2)
  local col = math.floor((total - width) / 2)

  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = opts.border or "rounded",
    title = opts.title,
    title_pos = "center",
  })

  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = bufnr, nowait = true, silent = true })

  vim.keymap.set("n", "<Esc>", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = bufnr, nowait = true, silent = true })

  return bufnr, win
end

--- Create (or reuse) a buffer that streams text, e.g. for RAG responses.
---@param opts table|nil  { title, filetype, split }
---@return integer bufnr
---@return fun(chunk: string) append
---@return fun() finish
function M.stream_buffer(opts)
  opts = opts or {}
  local split = opts.split or "botright split"
  local height = opts.height or 20

  vim.cmd(split .. " " .. height)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, bufnr)

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = opts.filetype or "markdown"

  if opts.title then
    vim.api.nvim_buf_set_name(bufnr, opts.title)
  end

  -- Start with an empty line so appends have somewhere to grow.
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })

  local append = function(chunk)
    if chunk == nil or chunk == "" then
      return
    end
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      vim.bo[bufnr].modifiable = true
      local lines = vim.split(chunk, "\n", { plain = true })

      local last = vim.api.nvim_buf_line_count(bufnr)
      local current = vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ""

      -- Append the first segment to the current line, then add the rest.
      local new_lines = { current .. lines[1] }
      for i = 2, #lines do
        table.insert(new_lines, lines[i])
      end

      vim.api.nvim_buf_set_lines(bufnr, last - 1, last, false, new_lines)
      vim.bo[bufnr].modifiable = false

      -- Keep the cursor at the bottom while streaming, if the window shows it.
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) == bufnr then
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(bufnr), 0 })
      end
    end)
  end

  local finish = function()
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.bo[bufnr].modifiable = true
      end
    end)
  end

  return bufnr, append, finish
end

--- Present a list of choices and invoke `on_choice`.
---@param items string[]
---@param prompt string
---@param on_choice fun(choice: string|nil, idx: integer|nil)
function M.select(items, prompt, on_choice)
  vim.ui.select(items, { prompt = prompt }, on_choice)
end

--- Prompt for a single line of input.
---@param prompt string
---@param default string|nil
---@param on_submit fun(value: string|nil)
function M.input(prompt, default, on_submit)
  vim.ui.input({ prompt = prompt, default = default }, on_submit)
end

---@return integer
function M.namespace()
  return ns
end

return M
