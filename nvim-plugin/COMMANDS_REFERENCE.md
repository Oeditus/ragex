# Ragex NeoVim/LunarVim Plugin - Command Reference

Quick reference for all 60+ available commands.

## Search & Navigation

```vim
:Ragex search                  " Open semantic search prompt
:Ragex search_word             " Search word under cursor
:Ragex functions               " Browse all functions
:Ragex modules                 " Browse all modules
:Ragex find_callers            " Find functions calling current function
:Ragex find_paths              " Find call paths between functions
```

## File Analysis

```vim
:Ragex analyze_file            " Analyze current file
:Ragex analyze_directory       " Analyze directory recursively
:Ragex watch_directory         " Watch directory for changes
:Ragex graph_stats             " Show knowledge graph statistics
:Ragex toggle_auto             " Toggle auto-analyze on save
```

## Refactoring

```vim
:Ragex rename_function         " Rename function (project-wide)
:Ragex rename_module           " Rename module (project-wide)
:Ragex extract_function        " Extract selection to new function
:Ragex inline_function         " Inline function at call sites
:Ragex convert_visibility      " Toggle def/defp (public/private)
```

## Code Quality & Analysis

```vim
:Ragex find_duplicates         " Find duplicate code (AST-based)
:Ragex find_similar            " Find similar code to selection
:Ragex find_dead_code          " Find unused functions
:Ragex analyze_dependencies    " Analyze module dependencies
:Ragex coupling_report         " Generate coupling metrics report
:Ragex quality_report          " Generate overall quality report
```

## Impact Analysis

```vim
:Ragex analyze_impact          " Analyze change impact
:Ragex estimate_effort         " Estimate refactoring effort
:Ragex risk_assessment         " Assess refactoring risk
```

## Graph Algorithms (Phase 8)

```vim
:Ragex betweenness_centrality  " Find bridge/bottleneck functions
:Ragex closeness_centrality    " Find central functions
:Ragex detect_communities      " Detect architectural modules
:Ragex export_graph            " Export graph (Graphviz/D3)
```

## Semantic & Security Analysis (Phase D)

```vim
:Ragex semantic_operations     " Extract semantic operations (OpKind)
:Ragex analyze_security_issues " Run CWE-based security analyzers
:Ragex semantic_analysis       " Combined semantic + security
:Ragex analyze_business_logic  " Run all business logic analyzers
```

## Refactoring Suggestions (Phase 11G)

```vim
:Ragex suggest_refactorings    " Get AI-powered refactoring suggestions
:Ragex explain_suggestion <id> " Explain a specific suggestion
```

## Preview & AI Features (Phases A-D)

```vim
:Ragex preview_refactor        " Preview refactoring with AI commentary
:Ragex validate_with_ai        " AI-enhanced validation explanations
```

## RAG Features

```vim
:Ragex rag_query               " Natural language query about codebase
:Ragex rag_explain             " Explain code at cursor position
:Ragex rag_suggest             " Get suggestions for selected code
:Ragex expand_query            " Expand query with synonyms
:Ragex metaast_search          " Search by MetaAST patterns
```

## AI Cache Management

```vim
:Ragex ai_cache_stats          " Show AI feature cache statistics
:Ragex ai_usage                " Show AI feature usage metrics
:Ragex clear_ai_cache          " Clear AI feature cache
```

## Additional Analysis Tools

```vim
:Ragex find_complex_code       " Find high-complexity functions
:Ragex analyze_quality         " Analyze code quality metrics
:Ragex analyze_dead_code_patterns " Analyze patterns in dead code
:Ragex find_circular_dependencies " Find circular dependency cycles
```

## Programmatic API

All commands are also available as Lua functions:

```lua
local ragex = require("ragex")

-- Search
ragex.semantic_search("parse JSON", {limit = 10})
ragex.hybrid_search("database connection")

-- Analysis
ragex.analyze_file("/path/to/file.ex")
ragex.analyze_directory("/path/to/project")
ragex.find_duplicates({min_similarity = 0.8})

-- Refactoring
ragex.rename_function("old_name", "new_name", 2)
ragex.extract_function("new_func_name")
ragex.inline_function("MyModule", "helper", 1)

-- Impact Analysis
ragex.analyze_impact("MyModule", "process", 2)
ragex.estimate_effort("MyModule", "process", 2)
ragex.risk_assessment("MyModule", "process", 2)

-- Graph Algorithms
ragex.betweenness_centrality({max_nodes = 100})
ragex.detect_communities({algorithm = "louvain"})
ragex.export_graph({format = "dot", output = "graph.dot"})

-- Semantic & Security (Phase D)
ragex.semantic_operations({path = "lib/mymodule.ex"})
ragex.analyze_security_issues({path = "lib/"})
ragex.semantic_analysis({path = "lib/"})

-- RAG Features
ragex.rag.rag_query("How does authentication work?")
ragex.rag.rag_explain("MyModule.authenticate/2")
ragex.rag.rag_suggest()  -- Uses visual selection

-- AI Features
ragex.suggest_refactorings({path = "lib/"})
ragex.preview_refactor("rename_function", {module = "MyModule", old_name = "foo", new_name = "bar"})
ragex.validate_with_ai("lib/mymodule.ex")

-- Quality Analysis
ragex.find_dead_code({confidence = "high"})
ragex.coupling_report()
ragex.quality_report()
```

## Configuration

```lua
require("ragex").setup({
  -- Path to ragex installation
  ragex_path = vim.fn.expand("/opt/ragex"),
  
  -- Enable/disable plugin
  enabled = true,
  
  -- Debug mode
  debug = false,
  
  -- Auto-analyze on file save
  auto_analyze = false,
  
  -- Auto-analyze on startup
  auto_analyze_on_start = false,
  
  -- Additional directories to analyze on startup
  auto_analyze_dirs = {},
  
  -- Search defaults
  search = {
    limit = 50,
    threshold = 0.2,
    strategy = "fusion",  -- "fusion", "semantic_first", "graph_first"
  },
  
  -- Socket path
  socket_path = "/tmp/ragex_mcp.sock",
  
  -- Timeouts (milliseconds)
  timeout = {
    default = 60000,
    analyze = 120000,
    search = 30000,
  },
  
  -- Telescope UI
  telescope = {
    theme = "dropdown",
    previewer = true,
    show_score = true,
    layout_config = {
      width = 0.8,
      height = 0.9,
    },
  },
  
  -- Statusline integration
  statusline = {
    enabled = true,
    symbol = " Ragex",
  },
  
  -- Notifications
  notifications = {
    enabled = true,
    verbose = false,
  },
})
```

## Keybinding Examples

```lua
-- In your NeoVim/LunarVim config
local ragex = require("ragex")

-- Search
vim.keymap.set("n", "<leader>rs", ":Ragex search<CR>", {desc = "Ragex: Search"})
vim.keymap.set("n", "<leader>rw", ":Ragex search_word<CR>", {desc = "Ragex: Search word"})
vim.keymap.set("n", "<leader>rf", ":Ragex functions<CR>", {desc = "Ragex: Functions"})
vim.keymap.set("n", "<leader>rm", ":Ragex modules<CR>", {desc = "Ragex: Modules"})

-- Analysis
vim.keymap.set("n", "<leader>ra", ":Ragex analyze_file<CR>", {desc = "Ragex: Analyze file"})
vim.keymap.set("n", "<leader>rA", ":Ragex analyze_directory<CR>", {desc = "Ragex: Analyze directory"})
vim.keymap.set("n", "<leader>rg", ":Ragex graph_stats<CR>", {desc = "Ragex: Graph stats"})

-- Refactoring
vim.keymap.set("n", "<leader>rr", ":Ragex rename_function<CR>", {desc = "Ragex: Rename function"})
vim.keymap.set("n", "<leader>rR", ":Ragex rename_module<CR>", {desc = "Ragex: Rename module"})
vim.keymap.set("v", "<leader>re", ":Ragex extract_function<CR>", {desc = "Ragex: Extract function"})
vim.keymap.set("n", "<leader>ri", ":Ragex inline_function<CR>", {desc = "Ragex: Inline function"})

-- Quality
vim.keymap.set("n", "<leader>rd", ":Ragex find_duplicates<CR>", {desc = "Ragex: Find duplicates"})
vim.keymap.set("n", "<leader>rD", ":Ragex find_dead_code<CR>", {desc = "Ragex: Find dead code"})
vim.keymap.set("n", "<leader>rc", ":Ragex coupling_report<CR>", {desc = "Ragex: Coupling report"})
vim.keymap.set("n", "<leader>rq", ":Ragex quality_report<CR>", {desc = "Ragex: Quality report"})

-- Impact
vim.keymap.set("n", "<leader>rI", ":Ragex analyze_impact<CR>", {desc = "Ragex: Analyze impact"})
vim.keymap.set("n", "<leader>rE", ":Ragex estimate_effort<CR>", {desc = "Ragex: Estimate effort"})
vim.keymap.set("n", "<leader>rk", ":Ragex risk_assessment<CR>", {desc = "Ragex: Risk assessment"})

-- RAG
vim.keymap.set("n", "<leader>rq", ":Ragex rag_query<CR>", {desc = "Ragex: RAG query"})
vim.keymap.set("n", "<leader>rx", ":Ragex rag_explain<CR>", {desc = "Ragex: RAG explain"})
vim.keymap.set("v", "<leader>rS", ":Ragex rag_suggest<CR>", {desc = "Ragex: RAG suggest"})

-- Suggestions
vim.keymap.set("n", "<leader>rsu", ":Ragex suggest_refactorings<CR>", {desc = "Ragex: Suggest refactorings"})
vim.keymap.set("n", "<leader>rp", ":Ragex preview_refactor<CR>", {desc = "Ragex: Preview refactor"})
```

## Health Check

```vim
:checkhealth ragex
```

Checks:
- Ragex installation
- Socket availability
- Dependencies (plenary.nvim, telescope.nvim)
- Server connection

## Requirements

- **NeoVim:** 0.9.0+
- **Ragex:** 0.2.0+ with MCP server running
- **plenary.nvim:** Required
- **telescope.nvim:** Optional (for UI pickers)
- **socat:** Required for socket communication

## Troubleshooting

1. **Commands not working:** Ensure MCP server is running and socket exists at `/tmp/ragex_mcp.sock`
2. **Slow responses:** First analysis generates embeddings (cached afterward)
3. **Enable debug mode:** Set `debug = true` in configuration
4. **Check health:** Run `:checkhealth ragex`

## See Also

- `README.md` - Full documentation
- `PHASE12A_STATUS.md` - Implementation status
- `UPDATED.md` - Recent changes
- `INSTALL.md` - Installation guide

---

**Plugin Version:** 0.2.0  
**Last Updated:** February 13, 2026  
**Total Commands:** 60+  
**MCP Tools:** 65 (100% coverage)
