-- ragex.nvim - Hybrid RAG system for NeoVim
-- Main plugin entry point

local M = {}

-- Configuration with defaults
M.config = {
  project_root = vim.fn.getcwd(),
  ragex_path = vim.fn.expand("/opt/ragex"),
  enabled = true,
  debug = false,
  auto_analyze = false,
  auto_analyze_on_start = false,
  auto_analyze_dirs = {},
  
  search = {
    limit = 50,
    threshold = 0.2,
    strategy = "fusion",
  },
  
  socket_path = "/tmp/ragex_mcp.sock",
  
  timeout = {
    default = 60000,
    analyze = 120000,
    search = 30000,
  },
  
  telescope = {
    theme = "dropdown",
    previewer = true,
    show_score = true,
    layout_config = {
      width = 0.8,
      height = 0.9,
    },
  },
  
  statusline = {
    enabled = true,
    symbol = " Ragex",
  },
  
  notifications = {
    enabled = true,
    verbose = false,
  },
}

-- Setup function
function M.setup(opts)
  -- Merge user config with defaults
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  
  -- Load submodules
  M.core = require("ragex.core")
  M.commands = require("ragex.commands")
  M.telescope = require("ragex.telescope")
  M.ui = require("ragex.ui")
  M.refactor = require("ragex.refactor")
  M.analysis = require("ragex.analysis")
  M.graph = require("ragex.graph")
  M.rag = require("ragex.rag")
  M.utils = require("ragex.utils")
  
  -- Initialize core with config
  M.core.init(M.config)
  
  -- Setup commands
  M.commands.setup()
  
  -- Setup autocommands
  if M.config.auto_analyze then
    M._setup_auto_analyze()
  end
  
  -- Analyze on startup
  if M.config.auto_analyze_on_start then
    vim.defer_fn(function()
      M.analyze_directory(vim.fn.getcwd())
    end, 1000)
  end
  
  -- Analyze additional directories
  if #M.config.auto_analyze_dirs > 0 then
    vim.defer_fn(function()
      for _, dir in ipairs(M.config.auto_analyze_dirs) do
        M.analyze_directory(dir)
      end
    end, 2000)
  end
  
  -- Setup statusline
  if M.config.statusline.enabled then
    M._setup_statusline()
  end
end

-- Setup auto-analyze on file save
function M._setup_auto_analyze()
  local group = vim.api.nvim_create_augroup("RagexAutoAnalyze", { clear = true })
  
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.ex", "*.exs", "*.erl", "*.hrl", "*.py", "*.js", "*.jsx", "*.ts", "*.tsx" },
    callback = function()
      local filepath = vim.fn.expand("<afile>:p")
      M.analyze_file(filepath)
    end,
  })
end

-- Setup statusline component
function M._setup_statusline()
  -- This will be integrated with lualine or other statusline plugins
  -- For now, just set a global variable that can be used
  _G.ragex_statusline = function()
    if M.config.enabled then
      return M.config.statusline.symbol
    end
    return ""
  end
end

-- Public API - delegates to submodules

-- Search functions
function M.semantic_search(query, opts)
  return M.core.semantic_search(query, opts)
end

function M.hybrid_search(query, opts)
  return M.core.hybrid_search(query, opts)
end

-- Analysis functions
function M.analyze_file(filepath)
  return M.core.analyze_file(filepath or vim.fn.expand("%:p"))
end

function M.analyze_directory(path, opts)
  return M.core.analyze_directory(path or vim.fn.getcwd(), opts)
end

function M.watch_directory(path, extensions)
  return M.core.watch_directory(path, extensions)
end

function M.graph_stats()
  return M.core.graph_stats()
end

-- Caller/callee functions
function M.find_callers(module, function_name, arity)
  return M.core.find_callers(module, function_name, arity)
end

function M.find_paths(from_module, from_func, to_module, to_func, opts)
  return M.core.find_paths(from_module, from_func, to_module, to_func, opts)
end

-- Refactoring functions
function M.rename_function(old_name, new_name, arity, opts)
  return M.refactor.rename_function(old_name, new_name, arity, opts)
end

function M.rename_module(old_name, new_name)
  return M.refactor.rename_module(old_name, new_name)
end

function M.extract_function(params)
  return M.refactor.extract_function(params)
end

function M.inline_function(module, func_name, arity)
  return M.refactor.inline_function(module, func_name, arity)
end

function M.change_signature(module, func_name, arity, changes)
  return M.refactor.change_signature(module, func_name, arity, changes)
end

function M.convert_visibility(module, func_name, arity, to_visibility)
  return M.refactor.convert_visibility(module, func_name, arity, to_visibility)
end

function M.rename_parameter(module, func_name, arity, old_param, new_param)
  return M.refactor.rename_parameter(module, func_name, arity, old_param, new_param)
end

function M.modify_attributes(module, changes)
  return M.refactor.modify_attributes(module, changes)
end

-- Analysis functions
function M.find_duplicates(opts)
  return M.analysis.find_duplicates(opts)
end

function M.find_similar_code(code_snippet, opts)
  return M.analysis.find_similar_code(code_snippet, opts)
end

function M.find_dead_code(opts)
  return M.analysis.find_dead_code(opts)
end

function M.analyze_dependencies(opts)
  return M.analysis.analyze_dependencies(opts)
end

function M.coupling_report()
  return M.analysis.coupling_report()
end

function M.quality_report()
  return M.analysis.quality_report()
end

function M.analyze_impact(module, func_name, arity)
  return M.analysis.analyze_impact(module, func_name, arity)
end

function M.estimate_effort(module, func_name, arity)
  return M.analysis.estimate_effort(module, func_name, arity)
end

function M.risk_assessment(module, func_name, arity)
  return M.analysis.risk_assessment(module, func_name, arity)
end

-- Semantic analysis (Phase D)
function M.semantic_operations(opts)
  return M.analysis.semantic_operations(opts)
end

function M.analyze_security_issues(opts)
  return M.analysis.analyze_security_issues(opts)
end

function M.semantic_analysis(opts)
  return M.analysis.semantic_analysis(opts)
end

function M.analyze_business_logic(opts)
  return M.analysis.analyze_business_logic(opts)
end

-- Refactoring suggestions
function M.suggest_refactorings(opts)
  return M.analysis.suggest_refactorings(opts)
end

function M.explain_suggestion(suggestion_id)
  return M.analysis.explain_suggestion(suggestion_id)
end

-- Preview and validation
function M.preview_refactor(operation, params)
  return M.analysis.preview_refactor(operation, params)
end

function M.validate_with_ai(path, changes)
  return M.analysis.validate_with_ai(path, changes)
end

-- Graph algorithm functions
function M.betweenness_centrality(opts)
  return M.graph.betweenness_centrality(opts)
end

function M.closeness_centrality(opts)
  return M.graph.closeness_centrality(opts)
end

function M.detect_communities(opts)
  return M.graph.detect_communities(opts)
end

function M.export_graph(opts)
  return M.graph.export_graph(opts)
end

-- Telescope UI functions
function M.show_search_results()
  return M.telescope.search()
end

function M.show_functions()
  return M.telescope.functions()
end

function M.show_modules()
  return M.telescope.modules()
end

-- Toggle auto-analyze
function M.toggle_auto_analyze()
  M.config.auto_analyze = not M.config.auto_analyze
  if M.config.auto_analyze then
    M._setup_auto_analyze()
    M.ui.notify("Auto-analyze enabled", "info")
  else
    vim.api.nvim_del_augroup_by_name("RagexAutoAnalyze")
    M.ui.notify("Auto-analyze disabled", "info")
  end
end

-- Health check
function M.health()
  local health = vim.health or require("health")
  
  health.report_start("Ragex")
  
  -- Check if ragex is installed
  local ragex_path = M.config.ragex_path
  if vim.fn.isdirectory(ragex_path) == 1 then
    health.report_ok("Ragex found at: " .. ragex_path)
  else
    health.report_error("Ragex not found at: " .. ragex_path)
  end
  
  -- Check if socket exists
  local socket_path = M.config.socket_path
  if vim.fn.filereadable(socket_path) == 1 or vim.fn.isdirectory(socket_path) == 1 then
    health.report_ok("Socket found at: " .. socket_path)
  else
    health.report_warn("Socket not found at: " .. socket_path .. " (server may not be running)")
  end
  
  -- Check dependencies
  local has_telescope = pcall(require, "telescope")
  if has_telescope then
    health.report_ok("telescope.nvim installed")
  else
    health.report_warn("telescope.nvim not installed (UI features disabled)")
  end
  
  local has_plenary = pcall(require, "plenary")
  if has_plenary then
    health.report_ok("plenary.nvim installed")
  else
    health.report_error("plenary.nvim required")
  end
  
  -- Test connection
  local ok, result = pcall(M.core.execute, "graph_stats", {})
  if ok and result then
    health.report_ok("Connection to Ragex server successful")
  else
    health.report_warn("Cannot connect to Ragex server (make sure it's running)")
  end
end

return M
