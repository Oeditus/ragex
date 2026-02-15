-- Code analysis and quality features for ragex.nvim

local M = {}
local core = require("ragex.core")
local utils = require("ragex.utils")
local ui = require("ragex.ui")

-- Helper to execute analysis and show results
local function execute_analysis(method, params, title, formatter)
  local loading = ui.notify_loading("Analyzing...")
  
  -- Use analyze timeout for all analysis operations (they can be slow)
  core.execute(method, params or {}, function(result, error_type)
    ui.dismiss_notification(loading)
    
    if error_type then
      ui.notify("Analysis failed: " .. error_type, "error")
      return
    end
    
    local data, err = utils.parse_mcp_response(result)
    if err then
      ui.notify("Analysis failed: " .. err, "error")
      return
    end
    
    if formatter then
      ui.show_results(data, { title = title, formatter = formatter })
    else
      -- vim.inspect returns a string with newlines, need to split into array of lines
      local inspected = vim.inspect(data)
      local lines = vim.split(inspected, "\n", { plain = true })
      ui.show_float(lines, { title = title })
    end
  end, core.config.timeout.analyze)
end

-- Find duplicates
function M.find_duplicates(opts)
  opts = opts or {}
  execute_analysis("find_duplicates", opts, "Code Duplicates")
end

-- Find similar code
function M.find_similar_code(code_snippet, opts)
  opts = opts or {}
  opts.code = code_snippet or utils.get_visual_selection()
  
  if not opts.code then
    ui.notify("No code provided", "warn")
    return
  end
  
  execute_analysis("find_similar_code", opts, "Similar Code")
end

-- Find dead code
function M.find_dead_code(opts)
  opts = opts or {}
  execute_analysis("find_dead_code", opts, "Dead Code")
end

-- Analyze dependencies
function M.analyze_dependencies(opts)
  opts = opts or {}
  execute_analysis("analyze_dependencies", opts, "Dependencies")
end

-- Coupling report
function M.coupling_report()
  execute_analysis("coupling_report", {}, "Coupling Report")
end

-- Quality report
function M.quality_report()
  execute_analysis("quality_report", {}, "Quality Report")
end

-- Analyze impact
function M.analyze_impact(module, func_name, arity)
  module = module or utils.get_current_module()
  if not module then
    ui.notify("Could not determine current module", "warn")
    return
  end
  
  if not func_name then
    func_name, arity = utils.get_function_under_cursor()
  end
  
  if not func_name then
    ui.notify("Could not determine function name", "warn")
    return
  end
  
  -- Server expects target in format: "Module.function/arity" or "Module"
  local target
  if arity then
    target = string.format("%s.%s/%d", module, func_name, arity)
  else
    target = string.format("%s.%s", module, func_name)
  end
  
  local params = { target = target }
  
  execute_analysis("analyze_impact", params, string.format("Impact: %s", target))
end

-- Estimate refactoring effort
function M.estimate_effort(module, func_name, arity, operation)
  module = module or utils.get_current_module()
  if not module then
    ui.notify("Could not determine current module", "warn")
    return
  end
  
  if not func_name then
    func_name, arity = utils.get_function_under_cursor()
  end
  
  if not func_name then
    ui.notify("Could not determine function name", "warn")
    return
  end
  
  if not operation then
    -- Default operation for effort estimation
    operation = "rename_function"
  end
  
  -- Server expects target in format: "Module.function/arity" or "Module"
  local target
  if arity then
    target = string.format("%s.%s/%d", module, func_name, arity)
  else
    target = string.format("%s.%s", module, func_name)
  end
  
  local params = {
    operation = operation,
    target = target
  }
  
  execute_analysis("estimate_refactoring_effort", params, "Refactoring Effort")
end

-- Risk assessment
function M.risk_assessment(module, func_name, arity)
  module = module or utils.get_current_module()
  if not module then
    ui.notify("Could not determine current module", "warn")
    return
  end
  
  if not func_name then
    func_name, arity = utils.get_function_under_cursor()
  end
  
  if not func_name then
    ui.notify("Could not determine function name", "warn")
    return
  end
  
  -- Server expects target in format: "Module.function/arity" or "Module"
  local target
  if arity then
    target = string.format("%s.%s/%d", module, func_name, arity)
  else
    target = string.format("%s.%s", module, func_name)
  end
  
  local params = { target = target }
  
  execute_analysis("risk_assessment", params, "Risk Assessment")
end

-- Semantic analysis (Phase D)
function M.semantic_operations(opts)
  opts = opts or {}
  opts.path = opts.path or vim.fn.expand("%:p")
  execute_analysis("semantic_operations", opts, "Semantic Operations")
end

function M.analyze_security_issues(opts)
  opts = opts or {}
  opts.path = opts.path or vim.fn.getcwd()
  execute_analysis("analyze_security_issues", opts, "Security Issues (CWE)")
end

function M.semantic_analysis(opts)
  opts = opts or {}
  opts.path = opts.path or vim.fn.getcwd()
  execute_analysis("semantic_analysis", opts, "Semantic Analysis")
end

-- Business logic analysis
function M.analyze_business_logic(opts)
  opts = opts or {}
  opts.path = opts.path or vim.fn.getcwd()
  execute_analysis("analyze_business_logic", opts, "Business Logic Analysis")
end

-- Security scanning
function M.scan_security(opts)
  opts = opts or {}
  opts.path = opts.path or vim.fn.getcwd()
  execute_analysis("scan_security", opts, "Security Scan")
end

function M.security_audit(opts)
  opts = opts or {}
  opts.path = opts.path or vim.fn.getcwd()
  execute_analysis("security_audit", opts, "Security Audit")
end

function M.check_secrets(opts)
  opts = opts or {}
  opts.path = opts.path or vim.fn.getcwd()
  execute_analysis("check_secrets", opts, "Hardcoded Secrets")
end

-- Code smells
function M.detect_smells(opts)
  opts = opts or {}
  opts.path = opts.path or vim.fn.getcwd()
  execute_analysis("detect_smells", opts, "Code Smells")
end

function M.find_complex_code(opts)
  opts = opts or {}
  opts.path = opts.path or vim.fn.getcwd()
  execute_analysis("find_complex_code", opts, "Complex Code")
end

function M.analyze_quality(opts)
  opts = opts or {}
  opts.path = opts.path or vim.fn.getcwd()
  execute_analysis("analyze_quality", opts, "Quality Analysis")
end

-- Dead code patterns
function M.analyze_dead_code_patterns(opts)
  opts = opts or {}
  opts.path = opts.path or vim.fn.getcwd()
  execute_analysis("analyze_dead_code_patterns", opts, "Dead Code Patterns")
end

-- Circular dependencies
function M.find_circular_dependencies()
  execute_analysis("find_circular_dependencies", {}, "Circular Dependencies")
end

-- Refactoring suggestions
function M.suggest_refactorings(opts)
  opts = opts or {}
  opts.target = opts.target or vim.fn.getcwd()
  execute_analysis("suggest_refactorings", opts, "Refactoring Suggestions")
end

function M.explain_suggestion(suggestion_id)
  if not suggestion_id then
    ui.notify("Suggestion ID required", "warn")
    return
  end
  
  execute_analysis("explain_suggestion", {suggestion_id = suggestion_id}, "Suggestion Explanation")
end

-- Preview and validation
function M.preview_refactor(operation, params)
  if not operation or not params then
    ui.notify("Operation and params required", "warn")
    return
  end
  
  local opts = {
    operation = operation,
    params = params
  }
  execute_analysis("preview_refactor", opts, "Refactoring Preview")
end

function M.validate_with_ai(path, changes)
  local opts = {
    path = path or vim.fn.expand("%:p"),
    changes = changes
  }
  execute_analysis("validate_with_ai", opts, "AI Validation")
end

-- Refactoring history and conflicts
function M.refactor_conflicts(operation, params)
  if not operation or not params then
    ui.notify("Operation and params required", "warn")
    return
  end
  
  local opts = {
    operation = operation,
    params = params
  }
  execute_analysis("refactor_conflicts", opts, "Refactoring Conflicts")
end

function M.refactor_history()
  execute_analysis("refactor_history", {}, "Refactoring History")
end

function M.undo_refactor(operation_id)
  if not operation_id then
    ui.notify("Operation ID required", "warn")
    return
  end
  
  execute_analysis("undo_refactor", {operation_id = operation_id}, "Undo Refactoring")
end

function M.visualize_impact(module, func_name, arity, format)
  module = module or utils.get_current_module()
  if not module then
    ui.notify("Could not determine current module", "warn")
    return
  end
  
  if not func_name then
    func_name, arity = utils.get_function_under_cursor()
  end
  
  if not func_name then
    ui.notify("Could not determine function name", "warn")
    return
  end
  
  local params = {
    module = module,
    function_name = func_name,
    format = format or "ascii"
  }
  if arity then
    params.arity = arity
  end
  
  execute_analysis("visualize_impact", params, "Impact Visualization")
end

-- AI cache management
function M.get_ai_cache_stats()
  execute_analysis("get_ai_cache_stats", {}, "AI Cache Stats")
end

function M.get_ai_usage()
  execute_analysis("get_ai_usage", {}, "AI Usage Stats")
end

function M.clear_ai_cache(feature)
  local params = {}
  if feature then
    params.feature = feature
  end
  execute_analysis("clear_ai_cache", params, "Clear AI Cache")
end

return M
