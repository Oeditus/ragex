--- The Ragex tool catalog.
---
--- A single declarative table describing every MCP tool the plugin knows
--- about: its category, how to build its arguments from the editing context,
--- and which timeout class it belongs to. Commands, the generic `:Ragex call`
--- runner, and the which-key menu are all generated from this catalog, so
--- adding a tool is a one-line change.
local M = {}

--- Timeout classes (milliseconds).
M.timeouts = {
  fast = 15000,
  default = 60000,
  slow = 180000,     -- directory analysis, quality scans
  very_slow = 300000 -- full audits / agent analysis
}

---@class RagexToolSpec
---@field name string
---@field category string
---@field desc string
---@field timeout string|nil         key into M.timeouts
---@field args fun(ctx: table): table  builds tool arguments from context
---@field needs string|nil           "path" | "target" | "query" | nil (hints for UI)

--- Context passed to `args`:
---   ctx.path       absolute path of the current buffer
---   ctx.relpath    path relative to cwd
---   ctx.cwd        project root (vim.fn.getcwd())
---   ctx.word       <cword> under the cursor
---   ctx.input(p)   prompt the user for a string (blocking, returns value|nil)
---   ctx.select(p, items) prompt for a choice (blocking, returns value|nil)

local function path_arg(ctx)
  return { path = ctx.path }
end

local function dir_arg(ctx)
  return { path = ctx.cwd }
end

local function target_input(ctx, prompt, default)
  local value = ctx.input(prompt or "Target (Module.function/arity or Module): ", default)
  if not value then
    return nil
  end
  return { target = value }
end

---@type RagexToolSpec[]
M.tools = {
  -- ── Core analysis ────────────────────────────────────────────────────
  {
    name = "analyze_file",
    category = "Analysis",
    desc = "Index the current file into the knowledge graph",
    timeout = "default",
    needs = "path",
    args = path_arg,
  },
  {
    name = "analyze_directory",
    category = "Analysis",
    desc = "Index the whole project directory",
    timeout = "slow",
    needs = "path",
    args = dir_arg,
  },
  {
    name = "watch_directory",
    category = "Analysis",
    desc = "Watch the project and auto-reindex on change",
    timeout = "fast",
    needs = "path",
    args = dir_arg,
  },
  {
    name = "unwatch_directory",
    category = "Analysis",
    desc = "Stop watching the project",
    timeout = "fast",
    needs = "path",
    args = dir_arg,
  },
  {
    name = "list_watched",
    category = "Analysis",
    desc = "List watched directories",
    timeout = "fast",
    args = function()
      return {}
    end,
  },
  {
    name = "graph_stats",
    category = "Analysis",
    desc = "Knowledge graph statistics",
    timeout = "fast",
    args = function()
      return {}
    end,
  },
  {
    name = "list_nodes",
    category = "Analysis",
    desc = "List indexed modules / functions",
    timeout = "default",
    args = function(ctx)
      local kind = ctx.select("Node type: ", { "module", "function", "all" })
      if kind == nil then
        return nil
      end
      if kind == "all" then
        return { limit = 200 }
      end
      return { node_type = kind, limit = 200 }
    end,
  },

  -- ── Search ───────────────────────────────────────────────────────────
  {
    name = "semantic_search",
    category = "Search",
    desc = "Natural-language semantic code search",
    timeout = "default",
    needs = "query",
    args = function(ctx)
      local q = ctx.input("Semantic query: ", ctx.word)
      if not q then
        return nil
      end
      return { query = q, limit = 30, include_context = true }
    end,
  },
  {
    name = "hybrid_search",
    category = "Search",
    desc = "Hybrid (semantic + graph) code search",
    timeout = "default",
    needs = "query",
    args = function(ctx)
      local q = ctx.input("Hybrid query: ", ctx.word)
      if not q then
        return nil
      end
      return { query = q, limit = 30, include_context = true, strategy = "fusion" }
    end,
  },
  {
    name = "search_strings",
    category = "Search",
    desc = "Search indexed string literals",
    timeout = "default",
    needs = "query",
    args = function(ctx)
      local q = ctx.input("String to search: ", ctx.word)
      if not q then
        return nil
      end
      return { query = q, limit = 40 }
    end,
  },
  {
    name = "expand_query",
    category = "Search",
    desc = "Expand a query with synonyms / cross-language terms",
    timeout = "default",
    needs = "query",
    args = function(ctx)
      local q = ctx.input("Query to expand: ", ctx.word)
      if not q then
        return nil
      end
      return { query = q }
    end,
  },
  {
    name = "get_embeddings_stats",
    category = "Search",
    desc = "Embedding model / vector store statistics",
    timeout = "fast",
    args = function()
      return {}
    end,
  },

  -- ── Graph ────────────────────────────────────────────────────────────
  {
    name = "find_callers",
    category = "Graph",
    desc = "Find direct callers of a function",
    timeout = "default",
    args = function(ctx)
      local module = ctx.input("Module (e.g. MyApp.Foo): ")
      if not module then
        return nil
      end
      local func = ctx.input("Function name: ", ctx.word)
      if not func then
        return nil
      end
      return { module = module, function_name = func }
    end,
  },
  {
    name = "find_paths",
    category = "Graph",
    desc = "Find call chains between two functions",
    timeout = "default",
    args = function(ctx)
      local from = ctx.input("From (Module.function/arity): ")
      if not from then
        return nil
      end
      local to = ctx.input("To (Module.function/arity): ")
      if not to then
        return nil
      end
      return { from = from, to = to, max_depth = 10 }
    end,
  },
  {
    name = "betweenness_centrality",
    category = "Graph",
    desc = "Bridge / bottleneck functions",
    timeout = "default",
    args = function()
      return { normalize = true }
    end,
  },
  {
    name = "closeness_centrality",
    category = "Graph",
    desc = "Most central functions",
    timeout = "default",
    args = function()
      return { normalize = true }
    end,
  },
  {
    name = "detect_communities",
    category = "Graph",
    desc = "Detect architectural modules (communities)",
    timeout = "default",
    args = function(ctx)
      local algo = ctx.select("Algorithm: ", { "louvain", "label_propagation" })
      if algo == nil then
        return nil
      end
      return { algorithm = algo }
    end,
  },
  {
    name = "export_graph",
    category = "Graph",
    desc = "Export the call graph (Graphviz / D3)",
    timeout = "default",
    args = function(ctx)
      local format = ctx.select("Export format: ", { "graphviz", "d3" })
      if format == nil then
        return nil
      end
      return { format = format }
    end,
  },

  -- ── Quality ──────────────────────────────────────────────────────────
  {
    name = "analyze_quality",
    category = "Quality",
    desc = "Per-function quality metrics for the current file",
    timeout = "slow",
    needs = "path",
    args = path_arg,
  },
  {
    name = "quality_report",
    category = "Quality",
    desc = "Aggregated quality report",
    timeout = "default",
    args = function()
      return { report_type = "summary", format = "text" }
    end,
  },
  {
    name = "find_complex_code",
    category = "Quality",
    desc = "Functions exceeding a complexity threshold",
    timeout = "default",
    args = function()
      return { metric = "cyclomatic", threshold = 10, show_functions = true }
    end,
  },
  {
    name = "detect_smells",
    category = "Quality",
    desc = "Structural code smells for the current file",
    timeout = "slow",
    needs = "path",
    args = path_arg,
  },
  {
    name = "find_duplicates",
    category = "Quality",
    desc = "AST-based duplicate detection (project)",
    timeout = "slow",
    needs = "path",
    args = dir_arg,
  },
  {
    name = "find_similar_code",
    category = "Quality",
    desc = "Semantically similar functions",
    timeout = "slow",
    args = function()
      return { threshold = 0.9, limit = 50 }
    end,
  },
  {
    name = "find_dead_code",
    category = "Quality",
    desc = "Find unused functions",
    timeout = "slow",
    args = function()
      return { scope = "all", min_confidence = 0.5, format = "summary" }
    end,
  },
  {
    name = "analyze_dead_code_patterns",
    category = "Quality",
    desc = "Unreachable code inside live functions (current file)",
    timeout = "slow",
    needs = "path",
    args = path_arg,
  },

  -- ── Dependencies ─────────────────────────────────────────────────────
  {
    name = "analyze_dependencies",
    category = "Dependencies",
    desc = "Coupling metrics for all modules",
    timeout = "default",
    args = function()
      return { format = "summary" }
    end,
  },
  {
    name = "coupling_report",
    category = "Dependencies",
    desc = "Afferent/efferent coupling report",
    timeout = "default",
    args = function()
      return { format = "text", sort_by = "instability" }
    end,
  },
  {
    name = "find_circular_dependencies",
    category = "Dependencies",
    desc = "Circular dependencies",
    timeout = "default",
    args = function()
      return { scope = "module", limit = 100 }
    end,
  },

  -- ── Security ─────────────────────────────────────────────────────────
  {
    name = "scan_security",
    category = "Security",
    desc = "Fast security scan of the current file",
    timeout = "slow",
    needs = "path",
    args = path_arg,
  },
  {
    name = "analyze_security_issues",
    category = "Security",
    desc = "Full CWE-mapped security analysis (current file)",
    timeout = "slow",
    needs = "path",
    args = path_arg,
  },
  {
    name = "check_secrets",
    category = "Security",
    desc = "Hardcoded secrets in the current file",
    timeout = "slow",
    needs = "path",
    args = path_arg,
  },
  {
    name = "security_audit",
    category = "Security",
    desc = "Project-wide security audit report",
    timeout = "very_slow",
    needs = "path",
    args = function(ctx)
      return { path = ctx.cwd, format = "markdown", min_severity = "low" }
    end,
  },
  {
    name = "analyze_business_logic",
    category = "Security",
    desc = "Business-logic anti-patterns (current file)",
    timeout = "slow",
    needs = "path",
    args = path_arg,
  },

  -- ── Semantic ─────────────────────────────────────────────────────────
  {
    name = "semantic_operations",
    category = "Semantic",
    desc = "Side-effect profile (DB/HTTP/cache/queue) of the current file",
    timeout = "slow",
    needs = "path",
    args = path_arg,
  },
  {
    name = "semantic_analysis",
    category = "Semantic",
    desc = "Operations + security in one pass (current file)",
    timeout = "slow",
    needs = "path",
    args = path_arg,
  },
  {
    name = "metaast_search",
    category = "Semantic",
    desc = "Cross-language structural pattern search",
    timeout = "default",
    args = function(ctx)
      local lang = ctx.select("Source language: ", { "elixir", "erlang", "python", "javascript" })
      if lang == nil then
        return nil
      end
      local construct = ctx.input("Construct (e.g. Enum.map/2): ")
      if not construct then
        return nil
      end
      return { source_language = lang, source_construct = construct }
    end,
  },
  {
    name = "find_metaast_pattern",
    category = "Semantic",
    desc = "Find all nodes matching a MetaAST pattern",
    timeout = "default",
    args = function(ctx)
      local pattern = ctx.input("MetaAST pattern (e.g. loop:for): ")
      if not pattern then
        return nil
      end
      return { pattern = pattern }
    end,
  },

  -- ── Impact ───────────────────────────────────────────────────────────
  {
    name = "analyze_impact",
    category = "Impact",
    desc = "Blast radius of changing a target",
    timeout = "default",
    needs = "target",
    args = function(ctx)
      return target_input(ctx)
    end,
  },
  {
    name = "risk_assessment",
    category = "Impact",
    desc = "Risk score for modifying a target",
    timeout = "default",
    needs = "target",
    args = function(ctx)
      return target_input(ctx)
    end,
  },
  {
    name = "estimate_refactoring_effort",
    category = "Impact",
    desc = "Estimate effort for a refactoring operation",
    timeout = "default",
    needs = "target",
    args = function(ctx)
      local op = ctx.select("Operation: ", {
        "rename_function",
        "rename_module",
        "extract_function",
        "inline_function",
        "move_function",
        "change_signature",
      })
      if op == nil then
        return nil
      end
      local target = ctx.input("Target (Module.function/arity or Module): ")
      if not target then
        return nil
      end
      return { operation = op, target = target }
    end,
  },
  {
    name = "suggest_refactorings",
    category = "Impact",
    desc = "Refactoring opportunities in the current file",
    timeout = "slow",
    needs = "path",
    args = path_arg,
  },
  {
    name = "visualize_impact",
    category = "Impact",
    desc = "Visualize impact for the current file",
    timeout = "default",
    needs = "path",
    args = function(ctx)
      return { files = { ctx.path }, format = "ascii", depth = 2 }
    end,
  },

  -- ── Editing / refactoring ────────────────────────────────────────────
  {
    name = "preview_refactor",
    category = "Refactor",
    desc = "Preview a refactoring (no changes applied)",
    timeout = "default",
    args = function(ctx)
      local op = ctx.select("Operation: ", {
        "rename_function",
        "rename_module",
        "extract_function",
        "inline_function",
      })
      if op == nil then
        return nil
      end
      local module = ctx.input("Module: ")
      if not module then
        return nil
      end
      local old_name = ctx.input("Current name: ", ctx.word)
      if not old_name then
        return nil
      end
      local new_name = ctx.input("New name: ")
      if not new_name then
        return nil
      end
      return {
        operation = op,
        params = { module = module, old_name = old_name, new_name = new_name },
        format = "unified",
      }
    end,
  },
  {
    name = "refactor_conflicts",
    category = "Refactor",
    desc = "Check conflicts before a refactoring",
    timeout = "default",
    args = function(ctx)
      local op = ctx.select("Operation: ", {
        "rename_function",
        "rename_module",
        "move_function",
        "extract_module",
      })
      if op == nil then
        return nil
      end
      local module = ctx.input("Module: ")
      if not module then
        return nil
      end
      local old_name = ctx.input("Current name: ", ctx.word)
      if not old_name then
        return nil
      end
      local new_name = ctx.input("New name: ")
      if not new_name then
        return nil
      end
      return {
        operation = op,
        params = { module = module, old_name = old_name, new_name = new_name },
      }
    end,
  },
  {
    name = "undo_refactor",
    category = "Refactor",
    desc = "Undo the most recent refactoring",
    timeout = "default",
    args = function(ctx)
      return { project_path = ctx.cwd }
    end,
  },
  {
    name = "refactor_history",
    category = "Refactor",
    desc = "List refactoring history",
    timeout = "default",
    args = function(ctx)
      return { project_path = ctx.cwd, limit = 50 }
    end,
  },
  {
    name = "edit_history",
    category = "Refactor",
    desc = "Backup history for the current file",
    timeout = "fast",
    needs = "path",
    args = path_arg,
  },
  {
    name = "rollback_edit",
    category = "Refactor",
    desc = "Restore the current file from its latest backup",
    timeout = "default",
    needs = "path",
    args = path_arg,
  },

  -- ── RAG / AI ─────────────────────────────────────────────────────────
  {
    name = "rag_query",
    category = "RAG",
    desc = "Ask a question about the codebase (AI answer)",
    timeout = "slow",
    needs = "query",
    args = function(ctx)
      local q = ctx.input("Question: ", ctx.word)
      if not q then
        return nil
      end
      return { query = q, limit = 12, include_code = true }
    end,
  },
  {
    name = "rag_explain",
    category = "RAG",
    desc = "AI explanation of a target",
    timeout = "slow",
    needs = "target",
    args = function(ctx)
      local target = ctx.input("Target (file or Module.function/arity): ", ctx.relpath)
      if not target then
        return nil
      end
      return { target = target, aspect = "all" }
    end,
  },
  {
    name = "rag_suggest",
    category = "RAG",
    desc = "AI improvement suggestions for a target",
    timeout = "slow",
    needs = "target",
    args = function(ctx)
      local target = ctx.input("Target (file or Module.function/arity): ", ctx.relpath)
      if not target then
        return nil
      end
      return { target = target, focus = "all" }
    end,
  },
  {
    name = "validate_with_ai",
    category = "RAG",
    desc = "Validate the current buffer and explain errors with AI",
    timeout = "slow",
    needs = "path",
    args = function(ctx)
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      return { content = table.concat(lines, "\n"), path = ctx.path }
    end,
  },
  {
    name = "get_ai_usage",
    category = "RAG",
    desc = "AI provider usage / cost statistics",
    timeout = "fast",
    args = function()
      return {}
    end,
  },
  {
    name = "get_ai_cache_stats",
    category = "RAG",
    desc = "AI response cache statistics",
    timeout = "fast",
    args = function()
      return {}
    end,
  },
  {
    name = "clear_ai_cache",
    category = "RAG",
    desc = "Clear the AI response cache",
    timeout = "fast",
    args = function()
      return { operation = "all" }
    end,
  },

  -- ── Agent ────────────────────────────────────────────────────────────
  {
    name = "agent_analyze",
    category = "Agent",
    desc = "Full multi-pass AI project analysis",
    timeout = "very_slow",
    needs = "path",
    args = dir_arg,
  },
  {
    name = "agent_list_sessions",
    category = "Agent",
    desc = "List active agent sessions",
    timeout = "fast",
    args = function()
      return {}
    end,
  },
  {
    name = "mcp_stats",
    category = "Agent",
    desc = "MCP tool usage telemetry",
    timeout = "fast",
    args = function()
      return {}
    end,
  },

  -- ── Git ──────────────────────────────────────────────────────────────
  {
    name = "git_blame",
    category = "Git",
    desc = "Git blame for the current file",
    timeout = "default",
    needs = "path",
    args = path_arg,
  },
  {
    name = "git_history",
    category = "Git",
    desc = "Commit history for the current file",
    timeout = "default",
    needs = "path",
    args = path_arg,
  },
  {
    name = "co_change_analysis",
    category = "Git",
    desc = "Files that change together with the current file",
    timeout = "default",
    needs = "path",
    args = path_arg,
  },
  {
    name = "git_enrich",
    category = "Git",
    desc = "Enrich the graph with git metadata",
    timeout = "slow",
    needs = "path",
    args = dir_arg,
  },

  -- ── SCIP ─────────────────────────────────────────────────────────────
  {
    name = "scip_status",
    category = "SCIP",
    desc = "SCIP bridge status / available indexers",
    timeout = "fast",
    args = function(ctx)
      return { path = ctx.cwd }
    end,
  },
  {
    name = "scip_index",
    category = "SCIP",
    desc = "Run a SCIP indexer for the project",
    timeout = "very_slow",
    needs = "path",
    args = function(ctx)
      local lang = ctx.input("Language (blank = auto): ")
      if lang == nil then
        return nil
      end
      if lang == "" then
        return { path = ctx.cwd }
      end
      return { path = ctx.cwd, language = lang }
    end,
  },
}

--- Look up a tool spec by name.
---@param name string
---@return RagexToolSpec|nil
function M.get(name)
  for _, tool in ipairs(M.tools) do
    if tool.name == name then
      return tool
    end
  end
  return nil
end

--- Group tools by category, preserving declaration order.
---@return table<string, RagexToolSpec[]>
function M.by_category()
  local categories = {}
  for _, tool in ipairs(M.tools) do
    categories[tool.category] = categories[tool.category] or {}
    table.insert(categories[tool.category], tool)
  end
  return categories
end

return M
