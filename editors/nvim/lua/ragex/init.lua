--- ragex.nvim -- Neovim / LunarVim client for the Ragex MCP server.
---
--- Public entry point. `require("ragex").setup(opts)` wires up the client,
--- commands and (optional) autocmds. Everything else is reachable through the
--- `:Ragex` command or the module functions re-exported here.
local M = {}

local socket_path = require("ragex.socket_path")

---@class RagexConfig
---@field ragex_bin string            Path to bin/ragex-mcp
---@field project string|nil          Project root passed to the server
---@field transport "auto"|"socket"|"stdio" Transport selection
---@field mode "auto"|"socket"|"stdio"|nil Deprecated alias for `transport`
---@field socket_path string|nil      Override the computed socket path
---@field enabled boolean
---@field debug boolean
---@field log_level string
---@field auto_analyze boolean        Re-index the current file on save
---@field auto_analyze_on_start boolean
---@field auto_analyze_dirs string[]
---@field timeout integer             Default request timeout (ms)
---@field statusline boolean
---@field keymaps boolean             Install default <leader>r* keymaps
---@field search table                { limit, threshold, strategy }

---@type RagexConfig
local defaults = {
  ragex_bin = vim.fn.expand("~/Proyectos/Oeditus/ragex/bin/ragex-mcp"),
  project = nil,
  transport = "auto",
  socket_path = nil,
  enabled = true,
  debug = false,
  log_level = "info",
  auto_analyze = false,
  auto_analyze_on_start = true,
  auto_analyze_dirs = {},
  timeout = 60000,
  statusline = true,
  keymaps = true,
  search = {
    limit = 30,
    threshold = 0.2,
    strategy = "fusion",
  },
}

M.config = vim.deepcopy(defaults)

---@type string|nil
M._status_text = nil

--- Update statusline text dynamically and force statusline redraw.
---@param text string|nil
function M.update_statusline(text)
  M._status_text = text
  vim.schedule(function()
    pcall(vim.cmd, "redrawstatus")
  end)
end

--- Resolve the ragex-mcp binary, honouring an explicit path first, then
--- walking up from the cwd looking for a sibling `bin/ragex-mcp`.
---@param explicit string|nil
---@return string
local function resolve_bin(explicit)
  if explicit and explicit ~= "" and vim.fn.filereadable(explicit) == 1 then
    return explicit
  end

  local found = vim.fn.findfile("bin/ragex-mcp", vim.fn.getcwd() .. ";")
  if found ~= "" then
    return vim.fn.fnamemodify(found, ":p")
  end

  return defaults.ragex_bin
end

--- Install default keymaps under <leader>r (Ragex).
local function setup_keymaps()
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { desc = "Ragex: " .. desc, silent = true })
  end

  map("<leader>rs", function()
    M.search_semantic()
  end, "Semantic search")
  map("<leader>rh", function()
    M.search_hybrid()
  end, "Hybrid search")
  map("<leader>rw", function()
    M.search_word()
  end, "Search word under cursor")
  map("<leader>rf", function()
    M.call("find_callers")
  end, "Find callers")
  map("<leader>rp", function()
    M.call("find_paths")
  end, "Find call paths")
  map("<leader>ra", function()
    M.analyze_file()
  end, "Analyze current file")
  map("<leader>rA", function()
    M.analyze_directory()
  end, "Analyze project")
  map("<leader>rg", function()
    M.call("graph_stats")
  end, "Graph statistics")
  map("<leader>rq", function()
    M.rag_query()
  end, "RAG query (streaming)")
  map("<leader>re", function()
    M.rag_explain()
  end, "RAG explain (streaming)")
  map("<leader>rS", function()
    M.rag_suggest()
  end, "RAG suggest (streaming)")
  map("<leader>rr", function()
    M.rename_function()
  end, "Rename function")
  map("<leader>rR", function()
    M.rename_module()
  end, "Rename module")
  map("<leader>rc", function()
    M.call("scan_security")
  end, "Security scan (file)")
  map("<leader>rd", function()
    M.call("find_dead_code")
  end, "Find dead code")
  map("<leader>rm", function()
    M.call("mcp_stats")
  end, "MCP telemetry")
end

--- Install the auto-analyze autocmd.
local function setup_auto_analyze()
  if auto_analyze_group then
    pcall(vim.api.nvim_del_augroup_by_id, auto_analyze_group)
  end

  auto_analyze_group = vim.api.nvim_create_augroup("RagexAutoAnalyze", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = auto_analyze_group,
    pattern = { "*.ex", "*.exs", "*.erl", "*.hrl", "*.py", "*.js", "*.jsx", "*.ts", "*.tsx" },
    callback = function()
      local file = vim.fn.expand("<afile>:p")
      require("ragex.tools.run").run("analyze_file", { path = file }, { silent = true })
    end,
  })
end

--- Configure the plugin.
---@param opts RagexConfig|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  M.config.ragex_bin = resolve_bin(M.config.ragex_bin)
  M.config.socket_path = M.config.socket_path or socket_path.compute()
  if not M.config.project then
    M.config.project = vim.fn.getcwd()
  end

  require("ragex.client").setup({
    -- The public config key is `transport`; the client's internal key is `mode`.
    mode = M.config.transport or M.config.mode,
    socket_path = M.config.socket_path,
    ragex_bin = M.config.ragex_bin,
    project = M.config.project,
    log_level = M.config.log_level,
    request_timeout = M.config.timeout,
    debug = M.config.debug,
  })

  require("ragex.commands").setup()

  if M.config.keymaps then
    setup_keymaps()
  end

  if M.config.auto_analyze then
    setup_auto_analyze()
  end

  local function stop_timer(timer)
    if type(timer) == "number" then
      pcall(vim.fn.timer_stop, timer)
    elseif timer and type(timer) == "userdata" or type(timer) == "table" then
      pcall(function()
        if timer.stop then timer:stop() end
        if timer.close and not (timer.is_closing and timer:is_closing()) then timer:close() end
      end)
    end
  end

  M._startup_timers = M._startup_timers or {}
  for _, timer in ipairs(M._startup_timers) do
    stop_timer(timer)
  end
  M._startup_timers = {}

  if M.config.auto_analyze_on_start then
    local timer = vim.defer_fn(function()
      M.analyze_directory()
    end, 1000)
    table.insert(M._startup_timers, timer)
  end

  for _, dir in ipairs(M.config.auto_analyze_dirs or {}) do
    local timer = vim.defer_fn(function()
      require("ragex.tools.run").run("analyze_directory", { path = dir }, { silent = true })
    end, 2000)
    table.insert(M._startup_timers, timer)
  end

  -- Cleanly close connections & jobs on editor exit without blocking
  vim.api.nvim_create_autocmd({ "VimLeavePre", "VimLeave" }, {
    group = vim.api.nvim_create_augroup("RagexTeardown", { clear = true }),
    callback = function()
      M.close()
    end,
  })

  return M
end

-- ── Public API ───────────────────────────────────────────────────────────

--- Call any catalog tool by name.
---@param name string
function M.call(name)
  require("ragex.tools.run").run_catalog(name)
end

--- Open an interactive menu of every catalog tool grouped by category.
function M.menu()
  require("ragex.commands").tool_menu()
end

--- Semantic search (Telescope picker).
---@param query string|nil
function M.search_semantic(query)
  if query then
    require("ragex.picker").search("semantic_search", query, { limit = M.config.search.limit })
  else
    require("ragex.tools.run").run_search("semantic_search", { title = "Ragex: semantic search" })
  end
end

--- Hybrid search (Telescope picker).
---@param query string|nil
function M.search_hybrid(query)
  if query then
    require("ragex.picker").search("hybrid_search", query, {
      limit = M.config.search.limit,
      strategy = M.config.search.strategy,
    })
  else
    require("ragex.tools.run").run_search("hybrid_search", { title = "Ragex: hybrid search" })
  end
end

--- Search for the word under the cursor.
function M.search_word()
  local word = ""
  pcall(function()
    word = vim.fn.expand("<cword>")
  end)
  if word == "" then
    require("ragex.ui").notify("no word under cursor", vim.log.levels.WARN)
    return
  end
  M.search_hybrid(word)
end

--- Analyze the current file.
---@param path string|nil
function M.analyze_file(path)
  path = path or vim.fn.expand("%:p")
  if path == "" then
    require("ragex.ui").notify("no file to analyze", vim.log.levels.WARN)
    return
  end
  require("ragex.tools.run").run("analyze_file", { path = path })
end

--- Analyze a directory (defaults to the project root).
---@param path string|nil
---@param opts table|nil
function M.analyze_directory(path, opts)
  path = path or vim.fn.getcwd()
  opts = opts or {}
  local exclude = opts.exclude_patterns or { ".ragex", "dllb*", ".git", "_build", "deps", "node_modules", "target" }

  -- The very first request of a session may have to boot a whole fresh
  -- ragex-mcp server first (compile, load the embedding model, start
  -- dllb) before it can process anything at all -- that can legitimately
  -- take anywhere from a few seconds to a couple of minutes and is easily
  -- mistaken for a hang if the statusline just says "Indexing..." the
  -- whole time. Say so explicitly while we're not connected yet.
  if require("ragex.client").is_connected() then
    M.update_statusline("Ȝ ragex [Scanning directory...]")
  else
    M.update_statusline("Ȝ ragex [Starting server...]")
  end

  require("ragex.tools.run").run("analyze_directory", {
    path = path,
    exclude_patterns = exclude,
  }, {
    silent = true,
    on_chunk = function(_, _, payload)
      if payload and type(payload) == "table" then
        local params = payload.params or payload
        local event = payload.event or params.event
        local file = params.file
        local current = params.current
        local total = params.total
        local to_analyze = params.to_analyze
        local stage = params.stage or event

        if event == "analysis_scanning" or stage == "scanning_directory" then
          M.update_statusline("Ȝ ragex [Scanning directory...]")
        elseif event == "analysis_scip" or stage == "scip_indexing" then
          M.update_statusline("Ȝ ragex [SCIP indexing...]")
        elseif event == "analysis_start" or (to_analyze and not current) then
          if to_analyze and to_analyze == 0 then
            M.update_statusline("Ȝ ragex [Up to date]")
          elseif to_analyze then
            M.update_statusline(string.format("Ȝ ragex [0/%d (0%%): starting...]", to_analyze))
          else
            M.update_statusline("Ȝ ragex [Indexing...]")
          end
        elseif current and total and total > 0 then
          local pct = math.floor((current / total) * 100)
          local short = file and vim.fn.fnamemodify(file, ":t") or ""
          if short ~= "" then
            M.update_statusline(string.format("Ȝ ragex [%d/%d (%d%%): %s]", current, total, pct, short))
          else
            M.update_statusline(string.format("Ȝ ragex [%d/%d (%d%%)]", current, total, pct))
          end
        elseif file then
          local short = vim.fn.fnamemodify(file, ":t")
          M.update_statusline(string.format("Ȝ ragex [%s/%s: %s]", current or "?", total or "?", short))
        elseif event == "analysis_complete" then
          local count = params.analyzed or params.total or 0
          M.update_statusline(string.format("Ȝ ragex [Indexed %d files]", count))
        end
      end
    end,
    on_result = function(data, err)
      if err then
        -- `ragex.tools.run` already notifies with the raw error message; add
        -- context here since a timeout during startup usually means a
        -- stale/orphaned ragex-mcp or dllb-server process from a previous
        -- crash is wedged and holding the port/db lock, not that this
        -- request is simply slow.
        local label = (err.kind == "timeout") and "Timed out" or "Error"
        M.update_statusline(string.format("Ȝ ragex [%s]", label))
        if err.kind == "timeout" then
          vim.schedule(function()
            require("ragex.ui").notify(
              "analyze_directory timed out -- if this keeps happening, a stale/orphaned "
                .. "ragex-mcp or dllb-server process from a previous crash may be wedged; "
                .. "check `ps aux | grep -E 'ragex-mcp|dllb-server'`",
              vim.log.levels.WARN
            )
          end)
        end
      else
        M.update_statusline("Ȝ ragex")
        local count = data and (data.success or data.analyzed or data.total) or 0
        vim.schedule(function()
          require("ragex.ui").notify(string.format("Indexed %d files for %s", count, vim.fn.fnamemodify(path, ":t")))
        end)
      end
    end,
  })
end

--- Watch a directory for changes (defaults to project root).
---@param path string|nil
function M.watch_directory(path)
  path = path or vim.fn.getcwd()
  require("ragex.tools.run").run("watch_directory", { path = path }, {
    on_result = function()
      require("ragex.ui").notify(string.format("Watching %s for file changes", vim.fn.fnamemodify(path, ":t")))
    end,
  })
end

--- Auto-detect base branch (main or master) asynchronously.
---@param user_branch string|nil
---@param callback fun(base: string)
local function detect_base_branch_async(user_branch, callback)
  if user_branch and user_branch ~= "" then
    callback(user_branch)
    return
  end

  local branches = { "main", "master", "origin/main", "origin/master" }
  local idx = 1

  local function try_next()
    if idx > #branches then
      callback("main")
      return
    end
    local b = branches[idx]
    idx = idx + 1
    vim.fn.jobstart({ "git", "rev-parse", "--verify", b }, {
      on_exit = function(_, code)
        if code == 0 then
          callback(b)
        else
          try_next()
        end
      end,
    })
  end

  try_next()
end

--- Get list of changed file paths between HEAD and base branch asynchronously.
---@param base_branch string
---@param callback fun(files: string[])
local function get_changed_files_async(base_branch, callback)
  local stdout_lines = {}
  vim.fn.jobstart({ "git", "diff", "--name-only", base_branch .. "...HEAD" }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        stdout_lines = data
      end
    end,
    on_exit = function(_, code)
      local files = {}
      if code == 0 and #stdout_lines > 0 then
        for _, line in ipairs(stdout_lines) do
          line = vim.trim(line)
          if line ~= "" then
            table.insert(files, line)
          end
        end
      end
      if #files > 0 then
        callback(files)
      else
        local fallback_lines = {}
        vim.fn.jobstart({ "git", "diff", "--name-only", base_branch }, {
          stdout_buffered = true,
          on_stdout = function(_, data)
            if data then
              fallback_lines = data
            end
          end,
          on_exit = function()
            local fb_files = {}
            for _, line in ipairs(fallback_lines) do
              line = vim.trim(line)
              if line ~= "" then
                table.insert(fb_files, line)
              end
            end
            callback(fb_files)
          end,
        })
      end
    end,
  })
end

--- Perform a Ragex PR Code Review analysis against main/master (or explicit base branch).
---@param base_branch string|nil
function M.code_review(base_branch)
  detect_base_branch_async(base_branch, function(base)
    get_changed_files_async(base, function(files)
      if #files == 0 then
        require("ragex.ui").notify("No changed files found against branch '" .. base .. "'", vim.log.levels.WARN)
        return
      end

      require("ragex.ui").notify(string.format("Analyzing %d changed files against %s...", #files, base))
      M.update_statusline("Ȝ ragex [PR Review...]")

      -- Analyze changed files first to ensure graph and embeddings are fresh
      for _, file in ipairs(files) do
        if vim.fn.filereadable(file) == 1 then
          require("ragex.tools.run").run("analyze_file", { path = vim.fn.fnamemodify(file, ":p") }, { silent = true })
        end
      end

      -- Stream Code Review analysis
      local prompt = string.format(
        "Perform a comprehensive PR Code Review for changes against base branch '%s'. Changed files (%d):\n- %s\n\nAnalyze architectural impact, security risks, code smells, edge cases, potential bugs, breaking changes, and summarize key recommendations.",
        base,
        #files,
        table.concat(files, "\n- ")
      )

      require("ragex.rag").stream("rag_query", {
        query = prompt,
        limit = 20,
        threshold = M.config.search.threshold or 0.2,
        include_code = true,
      }, {
        title = string.format("Ragex: PR Code Review (vs %s)", base),
      })

      vim.defer_fn(function()
        M.update_statusline("Ȝ ragex")
      end, 2000)
    end)
  end)
end

--- Streaming RAG query.
---@param query string|nil
function M.rag_query(query)
  local function go(q)
    if not q or q == "" then
      return
    end
    require("ragex.rag").stream("rag_query", { query = q, limit = 12, include_code = true })
  end

  if query then
    go(query)
  else
    local word = ""
    pcall(function()
      word = vim.fn.expand("<cword>")
    end)
    vim.ui.input({ prompt = "Ragex query: ", default = word }, go)
  end
end

--- Streaming RAG explanation of the current file.
function M.rag_explain()
  local target = vim.fn.expand("%:p")
  require("ragex.rag").stream("rag_explain", { target = target, aspect = "all" })
end

--- Streaming RAG suggestions for the current file.
function M.rag_suggest()
  local target = vim.fn.expand("%:p")
  require("ragex.rag").stream("rag_suggest", { target = target, focus = "all" })
end

--- Rename a function (project-wide).
function M.rename_function()
  require("ragex.refactor").rename_function({})
end

--- Rename a module (project-wide).
function M.rename_module()
  require("ragex.refactor").rename_module({})
end

--- Graph statistics as a float.
function M.graph_stats()
  require("ragex.tools.run").run("graph_stats", {}, {
    on_result = function(data)
      require("ragex.display").float("Ragex graph stats", data)
    end,
  })
end

--- Toggle auto-analysis on save.
function M.toggle_auto_analyze()
  M.config.auto_analyze = not M.config.auto_analyze
  if M.config.auto_analyze then
    setup_auto_analyze()
    require("ragex.ui").notify("auto-analyze enabled")
  else
    if auto_analyze_group then
      pcall(vim.api.nvim_del_augroup_by_id, auto_analyze_group)
      auto_analyze_group = nil
    end
    require("ragex.ui").notify("auto-analyze disabled")
  end
end

--- Statusline component (returns dynamic progress log while indexing, or 'Ȝ ragex' when finished/connected).
---@return string
function M.statusline()
  if not M.config.enabled or not M.config.statusline then
    return ""
  end
  if M._status_text and M._status_text ~= "" then
    return M._status_text
  end
  local client = require("ragex.client")
  if client.is_connected() then
    return "Ȝ ragex"
  end
  return ""
end

--- Close the transport (call from a VimLeave autocmd if desired).
function M.close()
  if M._startup_timers then
    for _, timer in ipairs(M._startup_timers) do
      if type(timer) == "number" then
        pcall(vim.fn.timer_stop, timer)
      elseif timer and (type(timer) == "userdata" or type(timer) == "table") then
        pcall(function()
          if timer.stop then timer:stop() end
          if timer.close and not (timer.is_closing and timer:is_closing()) then timer:close() end
        end)
      end
    end
    M._startup_timers = {}
  end
  require("ragex.client").close()
end

return M
