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
  auto_analyze_on_start = false,
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

---@type integer|nil
local auto_analyze_group = nil

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

  if M.config.auto_analyze_on_start then
    vim.defer_fn(function()
      M.analyze_directory()
    end, 1000)
  end

  for _, dir in ipairs(M.config.auto_analyze_dirs or {}) do
    vim.defer_fn(function()
      require("ragex.tools.run").run("analyze_directory", { path = dir }, { silent = true })
    end, 2000)
  end

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
function M.analyze_directory(path)
  require("ragex.tools.run").run("analyze_directory", { path = path or vim.fn.getcwd() })
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

--- Statusline component (returns a short string when connected).
---@return string
function M.statusline()
  if not M.config.enabled or not M.config.statusline then
    return ""
  end
  local client = require("ragex.client")
  if client.is_connected() then
    return "  Ragex"
  end
  return ""
end

--- Close the transport (call from a VimLeave autocmd if desired).
function M.close()
  require("ragex.client").close()
end

return M
