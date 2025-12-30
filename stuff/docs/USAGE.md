# Ragex Usage Guide

**Version**: 0.2.0  
**Date**: December 30, 2025

Complete guide to using Ragex, the Hybrid RAG system for intelligent codebase analysis and manipulation.

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [MCP Integration](#mcp-integration)
3. [How Do I Benefit From Ragex When Editing Elixir Project in VIM](#how-do-i-benefit-from-ragex-when-editing-elixir-project-in-vim)
4. [How Do I Benefit From Ragex When Editing Elixir Project in LunarVim (NeoVim)](#how-do-i-benefit-from-ragex-when-editing-elixir-project-in-lunarvim-neovim)
5. [Core Workflows](#core-workflows)
6. [Code Analysis](#code-analysis)
7. [Semantic Search](#semantic-search)
8. [Code Editing](#code-editing)
9. [Refactoring](#refactoring)
10. [Configuration](#configuration)
11. [Best Practices](#best-practices)
12. [Troubleshooting](#troubleshooting)

---

## Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/your-org/ragex.git
cd ragex

# Install dependencies
mix deps.get

# Compile the project
mix compile
```

### First Run

```bash
# Start the Ragex MCP server
mix run --no-halt

# The server will:
# - Initialize the knowledge graph
# - Load the embedding model (first run downloads ~90MB)
# - Start listening on stdin/stdout for MCP commands
```

### Quick Test

```elixir
# In another terminal, use the MCP protocol:
echo '{"jsonrpc":"2.0","method":"tools/list","id":1}' | mix run --no-halt
```

---

## MCP Integration

Ragex implements the Model Context Protocol (MCP) for seamless integration with AI assistants.

### Connecting to Claude Desktop

Add to your Claude Desktop configuration (`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS):

```json
{
  "mcpServers": {
    "ragex": {
      "command": "mix",
      "args": ["run", "--no-halt"],
      "cwd": "/path/to/ragex"
    }
  }
}
```

### Available Tools

Ragex exposes 17 MCP tools across 4 categories:

#### Analysis Tools (5)
- `analyze_file` - Parse and index source files
- `analyze_directory` - Batch analyze entire projects
- `query_graph` - Search for code entities
- `list_nodes` - Browse indexed entities
- `watch_directory` - Auto-reindex on file changes

#### Search Tools (4)
- `semantic_search` - Natural language code search
- `hybrid_search` - Combined symbolic + semantic search
- `get_embeddings_stats` - ML model statistics
- `find_paths` - Call chain discovery

#### Graph Tools (2)
- `graph_stats` - Comprehensive analysis
- `list_watched` - View watched directories

#### Editing Tools (6)
- `edit_file` - Safe single-file editing
- `validate_edit` - Preview validation
- `rollback_edit` - Undo edits
- `edit_history` - Query backups
- `edit_files` - Multi-file transactions
- `refactor_code` - Semantic refactoring

---

## How Do I Benefit From Ragex When Editing Elixir Project in VIM

Ragex can significantly enhance your VIM workflow for Elixir development through several integration approaches.

### 1. Language Server Integration

**Via ElixirLS + MCP Bridge:**

Ragex complements ElixirLS by providing semantic code understanding that goes beyond traditional LSP capabilities.

```vim
" In your .vimrc or init.vim
" Configure ElixirLS first, then add Ragex integration

" Example function to query Ragex from VIM
function! RagexSemanticSearch(query)
  let l:cmd = 'echo ' . shellescape(json_encode({
        \ 'jsonrpc': '2.0',
        \ 'method': 'tools/call',
        \ 'params': {'name': 'semantic_search', 'arguments': {'query': a:query, 'limit': 10}},
        \ 'id': 1
        \ })) . ' | mix run --no-halt'
  let l:result = system(l:cmd)
  return json_decode(l:result)
endfunction
```

### 2. Code Navigation

**Find definitions and usages semantically:**

```vim
" Add to your VIM config
nnoremap <leader>rf :call RagexFindFunction()<CR>
nnoremap <leader>rc :call RagexFindCallers()<CR>
nnoremap <leader>rs :call RagexSearch(expand('<cword>'))<CR>

function! RagexFindFunction()
  " Get function under cursor and find its definition
  let l:word = expand('<cword>')
  " Query Ragex graph for function definition
  " Open result in quickfix window
endfunction
```

**Benefits:**
- Semantic search beyond grep/ctags
- Find functions by behavior description
- Discover call chains between functions
- Navigate complex codebases faster

### 3. Refactoring Support

**Safe rename operations:**

```vim
" Rename function across entire project
command! -nargs=1 RagexRename call RagexRenameFunction(<f-args>)

function! RagexRenameFunction(new_name)
  let l:module = RagexGetCurrentModule()
  let l:func = expand('<cword>')
  let l:arity = RagexGetFunctionArity()
  
  " Call Ragex refactor_code tool
  let l:request = {
        \ 'operation': 'rename_function',
        \ 'module': l:module,
        \ 'old_name': l:func,
        \ 'new_name': a:new_name,
        \ 'arity': l:arity,
        \ 'scope': 'project',
        \ 'validate': v:true,
        \ 'format': v:true
        \ }
  
  " Execute and reload affected buffers
endfunction
```

**What you get:**
- Project-wide refactoring from VIM
- Automatic validation and formatting
- Rollback capability if issues occur
- No partial updates (atomic transactions)

### 4. Intelligent Code Completion

**Enhance completion with semantic context:**

```vim
" Use with VIM's omnifunc or completion plugins
setlocal omnifunc=RagexComplete

function! RagexComplete(findstart, base)
  if a:findstart
    " Find start of completion
    return col('.') - 1
  else
    " Query Ragex for semantically relevant functions
    let l:context = getline('.')
    let l:results = RagexSemanticSearch('functions related to ' . a:base)
    return l:results
  endif
endfunction
```

### 5. Quick Documentation Lookup

```vim
" Show function details from knowledge graph
nnoremap K :call RagexShowDoc()<CR>

function! RagexShowDoc()
  let l:word = expand('<cword>')
  " Query Ragex for function details
  " Display in preview window with:
  " - Function signature
  " - File location
  " - Callers and callees
  " - Semantically similar functions
endfunction
```

### 6. Automated Workflows

**Watch and auto-analyze on save:**

```vim
" Auto-analyze file on save
autocmd BufWritePost *.ex,*.exs call RagexAnalyzeFile(expand('%:p'))

function! RagexAnalyzeFile(filepath)
  " Trigger Ragex analysis
  " Update knowledge graph
  " Regenerate embeddings for changed code
endfunction
```

### 7. Project Setup

**Initial Ragex setup for VIM workflow:**

```bash
# 1. Start Ragex in background (in project root)
cd /path/to/elixir/project
mix run --no-halt > /tmp/ragex.log 2>&1 &
echo $! > /tmp/ragex.pid

# 2. Initial analysis
echo '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"analyze_directory","arguments":{"path":".","recursive":true,"extensions":[".ex",".exs"]}},"id":1}' | nc localhost 5555

# 3. Enable watching
echo '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"watch_directory","arguments":{"path":".","extensions":[".ex",".exs"]}},"id":2}' | nc localhost 5555
```

**Add to your project's .vimrc.local:**

```vim
" Project-specific Ragex configuration
let g:ragex_project_root = getcwd()
let g:ragex_enabled = 1

" Load Ragex VIM integration
source ~/.vim/ragex.vim
```

### 8. Integration with Existing Plugins

**Works alongside:**
- **ElixirLS**: Traditional LSP features (diagnostics, basic completion)
- **vim-test**: Run tests, Ragex finds related test files
- **fzf.vim**: Combine fuzzy finding with semantic search
- **ALE/Syntastic**: Linting + Ragex validation
- **vim-projectionist**: Navigation + Ragex call graph

**Example fzf integration:**

```vim
" Semantic code search with fzf
command! -nargs=1 RagexFzf call fzf#run(fzf#wrap({
      \ 'source': RagexSearchSource(<q-args>),
      \ 'sink': function('RagexOpenResult'),
      \ 'options': '--preview "bat --color=always {1}"'
      \ }))

function! RagexSearchSource(query)
  " Query Ragex semantic search
  " Return list of file:line:content
endfunction
```

### 9. Performance Tips

**Optimize for VIM workflow:**

1. **Cache embeddings** - Enable persistent cache for instant results
2. **Use async** - Make Ragex calls asynchronous to avoid blocking VIM
3. **Limit results** - Keep limit=10 for interactive use
4. **Filter by file scope** - Search only relevant directories

```vim
" Async Ragex call example (with vim-dispatch or ALE)
function! RagexSearchAsync(query)
  call job_start(['mix', 'run', '--no-halt'], {
        \ 'in_io': 'pipe',
        \ 'out_cb': function('RagexHandleResults')
        \ })
endfunction
```

### 10. Sample VIM Plugin Structure

Create `~/.vim/ragex.vim`:

```vim
" Ragex VIM Integration
" Author: Your Name
" Version: 0.1.0

if exists('g:loaded_ragex')
  finish
endif
let g:loaded_ragex = 1

" Configuration
let g:ragex_project_root = get(g:, 'ragex_project_root', getcwd())
let g:ragex_cmd = get(g:, 'ragex_cmd', 'mix run --no-halt')

" Core functions
function! ragex#search(query) abort
  " Implementation
endfunction

function! ragex#analyze_file(filepath) abort
  " Implementation
endfunction

function! ragex#find_callers() abort
  " Implementation
endfunction

" Commands
command! -nargs=1 RagexSearch call ragex#search(<f-args>)
command! RagexAnalyze call ragex#analyze_file(expand('%:p'))
command! RagexCallers call ragex#find_callers()

" Mappings
nnoremap <silent> <Plug>(ragex-search) :call ragex#search(expand('<cword>'))<CR>
nnoremap <silent> <Plug>(ragex-callers) :call ragex#find_callers()<CR>
```

### Benefits Summary

**Without Ragex:**
- Limited to grep, ctags, ElixirLS
- No semantic understanding
- Manual refactoring across files
- Difficult to discover related code

**With Ragex:**
- Natural language code search from VIM
- Semantic navigation beyond syntax
- Safe project-wide refactoring
- Discover functions by behavior
- Understand call chains instantly
- Auto-updated knowledge graph
- Rollback capability for edits

---

## How Do I Benefit From Ragex When Editing Elixir Project in LunarVim (NeoVim)

LunarVim provides a modern NeoVim configuration with LSP, Telescope, and Lua integration, making Ragex integration even more powerful than traditional VIM.

### 1. Lua-Based Integration

**Create `~/.config/lvim/lua/user/ragex.lua`:**

```lua
local M = {}

-- Configuration
M.config = {
  project_root = vim.fn.getcwd(),
  ragex_path = "/path/to/ragex",
  enabled = true,
}

-- Execute Ragex MCP command
function M.execute(method, params)
  local request = vim.fn.json_encode({
    jsonrpc = "2.0",
    method = "tools/call",
    params = {
      name = method,
      arguments = params,
    },
    id = vim.fn.rand(),
  })

  local cmd = string.format(
    "cd %s && echo '%s' | mix run --no-halt",
    M.config.ragex_path,
    request
  )

  local handle = io.popen(cmd)
  local result = handle:read("*a")
  handle:close()

  return vim.fn.json_decode(result)
end

-- Semantic search
function M.semantic_search(query, opts)
  opts = opts or {}
  local params = {
    query = query,
    limit = opts.limit or 10,
    threshold = opts.threshold or 0.7,
    node_type = opts.node_type,
  }

  return M.execute("semantic_search", params)
end

-- Hybrid search
function M.hybrid_search(query, opts)
  opts = opts or {}
  local params = {
    query = query,
    limit = opts.limit or 10,
    strategy = opts.strategy or "fusion",
  }

  return M.execute("hybrid_search", params)
end

-- Analyze current file
function M.analyze_current_file()
  local filepath = vim.fn.expand("%:p")
  return M.execute("analyze_file", { path = filepath })
end

-- Find callers of function under cursor
function M.find_callers()
  local module = M.get_current_module()
  local func = vim.fn.expand("<cword>")
  local arity = M.get_function_arity()

  return M.execute("query_graph", {
    query = string.format("calls %s.%s/%d", module, func, arity),
  })
end

-- Refactor: rename function
function M.rename_function(new_name)
  local module = M.get_current_module()
  local old_name = vim.fn.expand("<cword>")
  local arity = M.get_function_arity()

  local params = {
    operation = "rename_function",
    module = module,
    old_name = old_name,
    new_name = new_name,
    arity = arity,
    scope = "project",
    validate = true,
    format = true,
  }

  local result = M.execute("refactor_code", params)

  -- Reload all affected buffers
  if result.result and result.result.success then
    vim.cmd("checktime")
    vim.notify("Function renamed successfully", vim.log.levels.INFO)
  else
    vim.notify("Refactoring failed: " .. (result.error or "unknown"), vim.log.levels.ERROR)
  end

  return result
end

-- Helper: Get current module name
function M.get_current_module()
  local lines = vim.api.nvim_buf_get_lines(0, 0, 50, false)
  for _, line in ipairs(lines) do
    local module = line:match("defmodule%s+([%w%.]+)")
    if module then
      return module
    end
  end
  return nil
end

-- Helper: Get function arity (simplified)
function M.get_function_arity()
  local line = vim.fn.getline(".")
  local args = line:match("def%s+%w+%((.-)%)")
  if not args or args == "" then
    return 0
  end
  local _, count = args:gsub(",", "")
  return count + 1
end

return M
```

### 2. Telescope Integration

**Semantic code search with Telescope:**

Add to `~/.config/lvim/config.lua`:

```lua
local ragex = require("user.ragex")

-- Telescope picker for Ragex semantic search
local function ragex_search()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.action_state")

  vim.ui.input({ prompt = "Ragex Search: " }, function(query)
    if not query then return end

    local results = ragex.hybrid_search(query)

    if not results.result or not results.result.results then
      vim.notify("No results found", vim.log.levels.WARN)
      return
    end

    local entries = {}
    for _, item in ipairs(results.result.results) do
      table.insert(entries, {
        value = item,
        display = string.format(
          "%s:%d [%.2f] %s",
          item.file or "unknown",
          item.line or 0,
          item.score or 0,
          item.text or ""
        ),
        ordinal = item.text or "",
        filename = item.file,
        lnum = item.line,
      })
    end

    pickers.new({}, {
      prompt_title = "Ragex Search Results",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return entry
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection.filename then
            vim.cmd(string.format("edit +%d %s", selection.lnum, selection.filename))
          end
        end)
        return true
      end,
    }):find()
  end)
end

-- Register command
vim.api.nvim_create_user_command("RagexSearch", ragex_search, {})
```

### 3. Which-Key Integration

**Add keybindings to LunarVim's which-key:**

```lua
lvim.builtin.which_key.mappings["r"] = {
  name = "Ragex",
  s = { "<cmd>RagexSearch<cr>", "Semantic Search" },
  a = { function() require("user.ragex").analyze_current_file() end, "Analyze File" },
  c = { function() require("user.ragex").find_callers() end, "Find Callers" },
  r = {
    function()
      vim.ui.input({ prompt = "New name: " }, function(name)
        if name then
          require("user.ragex").rename_function(name)
        end
      end)
    end,
    "Rename Function",
  },
  f = { "<cmd>Telescope ragex_functions<cr>", "Find Functions" },
  m = { "<cmd>Telescope ragex_modules<cr>", "Find Modules" },
}
```

### 4. Custom Telescope Pickers

**Create specialized Telescope pickers:**

```lua
local ragex = require("user.ragex")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values

-- Find functions by semantic similarity
local function ragex_functions()
  vim.ui.input({ prompt = "Find functions: " }, function(query)
    if not query then return end

    local results = ragex.semantic_search(query, { node_type = "function" })

    if not results.result or not results.result.results then
      return
    end

    local entries = vim.tbl_map(function(item)
      return {
        value = item,
        display = string.format(
          "%s.%s/%d [%.2f]",
          item.node_id[1] or "?",
          item.node_id[2] or "?",
          item.node_id[3] or 0,
          item.score or 0
        ),
        ordinal = table.concat(item.node_id or {}, "."),
        filename = item.file,
        lnum = item.line,
      }
    end, results.result.results)

    pickers.new({}, {
      prompt_title = "Ragex Functions",
      finder = finders.new_table({ results = entries, entry_maker = function(e) return e end }),
      sorter = conf.generic_sorter({}),
      previewer = conf.qflist_previewer({}),
    }):find()
  end)
end

vim.api.nvim_create_user_command("RagexFunctions", ragex_functions, {})
```

### 5. LSP Integration

**Enhance ElixirLS with Ragex:**

```lua
-- Override LSP rename with Ragex refactoring
local function setup_lsp_overrides()
  lvim.lsp.on_attach_callback = function(client, bufnr)
    if client.name == "elixirls" then
      -- Use Ragex for rename instead of LSP
      vim.keymap.set("n", "<leader>lr", function()
        vim.ui.input({ prompt = "New name: " }, function(new_name)
          if new_name then
            require("user.ragex").rename_function(new_name)
          end
        end)
      end, { buffer = bufnr, desc = "Rename (Ragex)" })

      -- Add semantic search to LSP menu
      vim.keymap.set("n", "<leader>ls", function()
        require("user.ragex").semantic_search(vim.fn.expand("<cword>"))
      end, { buffer = bufnr, desc = "Semantic Search" })
    end
  end
end

setup_lsp_overrides()
```

### 6. Auto-Analysis on Save

**Automatically analyze files when saving:**

```lua
local ragex_group = vim.api.nvim_create_augroup("RagexAnalysis", { clear = true })

vim.api.nvim_create_autocmd({ "BufWritePost" }, {
  group = ragex_group,
  pattern = { "*.ex", "*.exs" },
  callback = function()
    -- Async analysis to avoid blocking
    vim.fn.jobstart(
      string.format(
        "cd %s && echo '%s' | mix run --no-halt",
        require("user.ragex").config.ragex_path,
        vim.fn.json_encode({
          jsonrpc = "2.0",
          method = "tools/call",
          params = {
            name = "analyze_file",
            arguments = { path = vim.fn.expand("%:p") },
          },
          id = vim.fn.rand(),
        })
      ),
      {
        on_exit = function(_, code)
          if code == 0 then
            vim.notify("File analyzed", vim.log.levels.DEBUG)
          end
        end,
      }
    )
  end,
})
```

### 7. Completion Integration

**Add Ragex as a completion source:**

```lua
local cmp = require("cmp")

local ragex_source = {}

function ragex_source:new()
  return setmetatable({}, { __index = self })
end

function ragex_source:get_trigger_characters()
  return { ".", ":" }
end

function ragex_source:complete(params, callback)
  local input = string.sub(params.context.cursor_before_line, params.offset)
  
  -- Query Ragex for semantic completions
  local results = require("user.ragex").semantic_search(
    "functions related to " .. input,
    { limit = 20, node_type = "function" }
  )

  if not results.result or not results.result.results then
    callback({})
    return
  end

  local items = vim.tbl_map(function(item)
    return {
      label = string.format("%s/%d", item.node_id[2], item.node_id[3]),
      kind = cmp.lsp.CompletionItemKind.Function,
      detail = item.text,
      documentation = string.format(
        "Module: %s\nFile: %s:%d\nScore: %.2f",
        item.node_id[1],
        item.file,
        item.line,
        item.score
      ),
    }
  end, results.result.results)

  callback(items)
end

-- Register the source
cmp.register_source("ragex", ragex_source:new())

-- Add to sources
table.insert(lvim.builtin.cmp.sources, { name = "ragex", priority = 750 })
```

### 8. Status Line Integration

**Show Ragex status in LunarVim status line:**

```lua
local function ragex_status()
  if not require("user.ragex").config.enabled then
    return ""
  end
  return "  Ragex"
end

-- Add to lualine
lvim.builtin.lualine.sections.lualine_x = {
  ragex_status,
  "encoding",
  "fileformat",
  "filetype",
}
```

### 9. Float Window for Results

**Display search results in floating window:**

```lua
local function show_in_float(title, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(30, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  vim.api.nvim_buf_set_keymap(buf, "n", "q", "<cmd>close<cr>", { noremap = true })
  vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", "<cmd>close<cr>", { noremap = true })
end

-- Show callers in float
function M.show_callers()
  local results = require("user.ragex").find_callers()
  
  if not results.result then
    vim.notify("No callers found", vim.log.levels.WARN)
    return
  end

  local lines = { "Callers:", "" }
  for _, caller in ipairs(results.result) do
    table.insert(lines, string.format("  %s:%d", caller.file, caller.line))
  end

  show_in_float("Ragex Callers", lines)
end
```

### 10. Full Configuration Example

**Complete `~/.config/lvim/config.lua` setup:**

```lua
-- Ragex integration
local ragex = require("user.ragex")

-- Configure Ragex
ragex.config.ragex_path = vim.fn.expand("~/Proyectos/Ammotion/ragex")
ragex.config.enabled = true

-- Keybindings
lvim.builtin.which_key.mappings["r"] = {
  name = "Ragex",
  s = { "<cmd>RagexSearch<cr>", "Semantic Search" },
  f = { "<cmd>RagexFunctions<cr>", "Find Functions" },
  a = { function() ragex.analyze_current_file() end, "Analyze File" },
  c = { function() ragex.find_callers() end, "Find Callers" },
  r = {
    function()
      vim.ui.input({ prompt = "New name: " }, function(name)
        if name then ragex.rename_function(name) end
      end)
    end,
    "Rename Function",
  },
}

-- Auto-analysis
vim.api.nvim_create_autocmd({ "BufWritePost" }, {
  pattern = { "*.ex", "*.exs" },
  callback = function()
    ragex.analyze_current_file()
  end,
})

-- Status line
table.insert(lvim.builtin.lualine.sections.lualine_x, 1, {
  function()
    return ragex.config.enabled and "  Ragex" or ""
  end,
})
```

### 11. Project-Specific Configuration

**Create `.lvimrc` or `.exrc` in your Elixir project:**

```lua
-- .lvimrc (requires exrc option)
local ragex = require("user.ragex")

-- Project-specific Ragex path
ragex.config.ragex_path = vim.fn.getcwd() .. "/../ragex"

-- Auto-analyze entire project on startup
vim.defer_fn(function()
  local result = ragex.execute("analyze_directory", {
    path = vim.fn.getcwd(),
    recursive = true,
    extensions = { ".ex", ".exs" },
  })
  
  if result.result then
    vim.notify(
      string.format("Analyzed %d files", result.result.files_analyzed or 0),
      vim.log.levels.INFO
    )
  end
end, 1000)

-- Enable watching
ragex.execute("watch_directory", {
  path = vim.fn.getcwd(),
  extensions = { ".ex", ".exs" },
})
```

### Benefits Over Standard VIM

**LunarVim/NeoVim advantages:**
- **Lua API**: Faster, more maintainable than VimScript
- **Async/Jobs**: Non-blocking Ragex calls
- **Telescope**: Beautiful search UI with previews
- **LSP Integration**: Seamless with ElixirLS
- **Which-Key**: Discoverable keybindings
- **Modern UI**: Floating windows, notifications
- **Tree-sitter**: Better syntax understanding
- **Built-in completion**: Easy to extend with Ragex

**Performance:**
- Async operations don't block editor
- Telescope caching improves repeated searches
- Lua is faster than VimScript
- Job control for background analysis

---

## Core Workflows

### Workflow 1: Analyze a New Project

```bash
# Step 1: Start Ragex
mix run --no-halt

# Step 2: Analyze the project (via MCP)
{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "params": {
    "name": "analyze_directory",
    "arguments": {
      "path": "/path/to/project",
      "recursive": true,
      "extensions": [".ex", ".exs", ".erl", ".py", ".js", ".ts"]
    }
  },
  "id": 1
}
```

**Result:**
- All source files parsed
- Functions, modules, calls indexed
- Knowledge graph populated
- Embeddings generated
- Ready for search and analysis

### Workflow 2: Find Related Code

```bash
# Natural language search
{
  "name": "semantic_search",
  "arguments": {
    "query": "function that validates user authentication",
    "limit": 10,
    "threshold": 0.7
  }
}

# Hybrid search (best results)
{
  "name": "hybrid_search",
  "arguments": {
    "query": "authentication validation",
    "limit": 10,
    "strategy": "fusion"
  }
}
```

**Result:**
- Ranked list of relevant functions
- Similarity scores
- File locations
- Function signatures

### Workflow 3: Safe Code Refactoring

```bash
# Step 1: Rename a function across entire codebase
{
  "name": "refactor_code",
  "arguments": {
    "operation": "rename_function",
    "module": "MyApp.Auth",
    "old_name": "check_user",
    "new_name": "validate_user",
    "arity": 2,
    "scope": "project",
    "validate": true,
    "format": true
  }
}
```

**What happens:**
1. Ragex finds function definition via graph
2. Discovers all call sites
3. Creates atomic transaction
4. Updates all files
5. Validates syntax in all files
6. Formats code automatically
7. Creates backups
8. Commits changes atomically

**If anything fails:**
- Automatic rollback
- All files restored
- No partial changes

### Workflow 4: Multi-File Editing

```bash
{
  "name": "edit_files",
  "arguments": {
    "edits": [
      {
        "file": "lib/app/user.ex",
        "changes": [
          {
            "type": "replace",
            "start_line": 10,
            "end_line": 15,
            "new_content": "def new_implementation do\n  :ok\nend"
          }
        ],
        "validate": true,
        "format": true
      },
      {
        "file": "lib/app/admin.ex",
        "changes": [
          {
            "type": "insert",
            "line": 20,
            "content": "# New admin feature\n"
          }
        ]
      }
    ],
    "create_backup": true
  }
}
```

**Safety guarantees:**
- All-or-nothing atomicity
- Pre-validation of all files
- Automatic rollback on any error
- Backups created before changes
- Format integration

---

## Code Analysis

### Analyzing Individual Files

**Elixir:**
```elixir
# Via Elixir API
{:ok, analysis} = Ragex.Analyzers.Elixir.analyze(source_code, "lib/my_module.ex")

# Returns:
%{
  modules: [%{name: :MyModule, file: "lib/my_module.ex", line: 1}],
  functions: [
    %{module: :MyModule, name: :func, arity: 2, line: 10, file: "lib/my_module.ex"}
  ],
  calls: [
    %{from_module: :MyModule, from_function: :func, from_arity: 2,
      to_module: :OtherModule, to_function: :helper, to_arity: 1}
  ]
}
```

**Python:**
```python
# Python analysis
content = """
def calculate_sum(a, b):
    return a + b

def main():
    result = calculate_sum(1, 2)
"""

{:ok, analysis} = Ragex.Analyzers.Python.analyze(content, "script.py")
```

**Supported Languages:**
- Elixir (.ex, .exs) - Full AST parsing
- Erlang (.erl, .hrl) - Full AST parsing
- Python (.py) - AST via subprocess
- JavaScript/TypeScript (.js, .jsx, .ts, .tsx, .mjs) - Regex-based

### Batch Analysis

```bash
# Analyze entire directory
{
  "name": "analyze_directory",
  "arguments": {
    "path": "/path/to/project",
    "recursive": true,
    "parallel": true,
    "extensions": [".ex", ".exs"]
  }
}
```

**Performance:**
- Parallel processing
- ~100 files/second (depends on file size)
- Progress reporting
- Error handling per file

### Watching for Changes

```bash
# Enable auto-reindex
{
  "name": "watch_directory",
  "arguments": {
    "path": "/path/to/project",
    "extensions": [".ex", ".exs"]
  }
}
```

**Features:**
- Automatic reanalysis on file changes
- Incremental updates (only changed files)
- Embedding regeneration for modified entities
- Real-time graph updates

---

## Semantic Search

### Natural Language Queries

```bash
# Find authentication-related code
{
  "name": "semantic_search",
  "arguments": {
    "query": "user login and session management",
    "limit": 10,
    "threshold": 0.7,
    "node_type": "function"
  }
}
```

**Response:**
```json
{
  "results": [
    {
      "node_type": "function",
      "node_id": ["MyApp.Auth", "authenticate_user", 2],
      "score": 0.92,
      "text": "Authenticates user credentials and creates session",
      "file": "lib/myapp/auth.ex",
      "line": 45
    }
  ]
}
```

### Hybrid Search (Best Results)

```bash
{
  "name": "hybrid_search",
  "arguments": {
    "query": "validate email format",
    "limit": 10,
    "strategy": "fusion"  # or "semantic_first", "graph_first"
  }
}
```

**Strategies:**
- `fusion` - Combines semantic + graph (RRF algorithm) - **Recommended**
- `semantic_first` - Prioritizes ML similarity
- `graph_first` - Prioritizes graph structure

**Performance:**
- < 100ms typical query time
- < 50ms for vector search
- Scales to 10,000+ entities

### Finding Call Chains

```bash
# Discover how functions are connected
{
  "name": "find_paths",
  "arguments": {
    "from": ["MyApp.Web", "handle_request", 2],
    "to": ["MyApp.DB", "save_record", 1],
    "max_depth": 5,
    "max_paths": 10
  }
}
```

**Result:**
- All paths from function A to function B
- Call chain depth
- Intermediate functions
- Useful for understanding data flow

---

## Code Editing

### Single File Editing

```bash
{
  "name": "edit_file",
  "arguments": {
    "file": "lib/my_module.ex",
    "changes": [
      {
        "type": "replace",
        "start_line": 10,
        "end_line": 12,
        "new_content": "def new_function do\n  :ok\nend"
      }
    ],
    "validate": true,
    "format": true,
    "create_backup": true
  }
}
```

**Change Types:**

1. **Replace:**
```json
{
  "type": "replace",
  "start_line": 10,
  "end_line": 15,
  "new_content": "new code here"
}
```

2. **Insert:**
```json
{
  "type": "insert",
  "line": 20,
  "content": "new line\n"
}
```

3. **Delete:**
```json
{
  "type": "delete",
  "start_line": 10,
  "end_line": 12
}
```

### Validation

```bash
# Preview validation without editing
{
  "name": "validate_edit",
  "arguments": {
    "file": "lib/my_module.ex",
    "changes": [/* ... */],
    "language": "elixir"  # optional, auto-detected
  }
}
```

**Validators:**
- **Elixir**: `Code.string_to_quoted/2`
- **Erlang**: `:erl_scan` + `:erl_parse`
- **Python**: `ast.parse()`
- **JavaScript**: `vm.Script` (Node.js)

### Rollback

```bash
# Undo recent changes
{
  "name": "rollback_edit",
  "arguments": {
    "file": "lib/my_module.ex",
    "version": 2  # optional, defaults to previous
  }
}

# View backup history
{
  "name": "edit_history",
  "arguments": {
    "file": "lib/my_module.ex"
  }
}
```

**Backup System:**
- Location: `~/.ragex/backups/<project_hash>/`
- Retention: 10 backups per file (configurable)
- Compression: Automatic for older backups
- Metadata: Timestamps, checksums

### Formatting

**Automatic formatting** after edits:

- **Elixir**: `mix format`
- **Erlang**: `rebar3 fmt`
- **Python**: `black` or `autopep8`
- **JavaScript**: `prettier` or `eslint --fix`

**Configuration:**
```elixir
# In edit request
"format": true,
"formatter": "mix format"  # optional, auto-detected
```

---

## Refactoring

### Rename Function

```bash
{
  "name": "refactor_code",
  "arguments": {
    "operation": "rename_function",
    "module": "MyApp.User",
    "old_name": "get_user",
    "new_name": "fetch_user",
    "arity": 1,
    "scope": "project",  # or "module"
    "validate": true,
    "format": true
  }
}
```

**What gets updated:**
- Function definition
- All direct calls
- Module-qualified calls (`MyApp.User.get_user(id)`)
- Function references (`&get_user/1`)
- Calls in other modules (if scope: "project")

**Scope Options:**
- `module` - Only within the same file
- `project` - Across entire codebase

### Rename Module

```bash
{
  "name": "refactor_code",
  "arguments": {
    "operation": "rename_module",
    "old_name": "MyApp.OldModule",
    "new_name": "MyApp.NewModule",
    "validate": true,
    "format": true
  }
}
```

**What gets updated:**
- Module definition
- All aliases
- All imports
- All qualified calls
- All references

### Refactoring Workflow

1. **Discovery**: Graph finds all affected files
2. **Planning**: Builds transaction with all changes
3. **Validation**: Pre-validates all files
4. **Backup**: Creates backups
5. **Execution**: Applies changes atomically
6. **Format**: Runs formatters
7. **Verification**: Post-validates all files
8. **Commit**: Finalizes transaction

**If any step fails:**
- Automatic rollback
- All files restored
- Error reported
- No partial state

### Current Limitations

- **Elixir only** for AST-based refactoring
- Erlang/Python/JavaScript support planned
- No cross-language refactoring yet

---

## Configuration

### Embedding Models

**Default**: `all-MiniLM-L6-v2` (384 dimensions)

**Available Models:**
```elixir
# config/config.exs
config :ragex,
  embedding_model: :all_minilm_l6_v2  # Default, fast
  # embedding_model: :all_mpnet_base_v2  # Higher quality, 768 dims
  # embedding_model: :codebert_base  # Code-specific, 768 dims
  # embedding_model: :paraphrase_multilingual  # Multilingual, 384 dims
```

**Or via environment variable:**
```bash
export RAGEX_EMBEDDING_MODEL=all_mpnet_base_v2
mix run --no-halt
```

### Cache Configuration

**Enable persistent cache:**
```elixir
# config/config.exs
config :ragex,
  cache_embeddings: true,  # Default: false
  cache_dir: "~/.ragex/cache"
```

**Benefits:**
- 10x faster cold start
- ~15MB storage per 1,000 entities
- Automatic invalidation on model change

### Backup Configuration

```elixir
config :ragex, :editor,
  backup_dir: "~/.ragex/backups",
  max_backups_per_file: 10,
  compress_old_backups: true
```

### Performance Tuning

```elixir
config :ragex,
  # Graph query limits
  max_paths: 100,
  max_path_depth: 10,
  
  # Search limits
  max_search_results: 100,
  
  # Parallel processing
  max_parallel_analyzers: System.schedulers_online() * 2
```

---

## Best Practices

### 1. Project Setup

```bash
# Initial setup for a new project
1. Start Ragex
2. Analyze entire codebase
3. Enable directory watching
4. Let embeddings cache build
```

### 2. Incremental Development

```bash
# As you develop:
1. Keep directory watching enabled
2. Ragex auto-updates on file changes
3. Embeddings regenerate only for changed code
4. No manual reindexing needed
```

### 3. Search Strategies

**For exploratory search:**
- Use `hybrid_search` with `fusion` strategy
- Start with lower threshold (0.5)
- Increase limit to see more results

**For precise lookup:**
- Use `query_graph` for exact symbols
- Use `semantic_search` with high threshold (0.8+)
- Filter by `node_type`

### 4. Safe Refactoring

**Before refactoring:**
1. Ensure codebase is analyzed
2. Check graph stats
3. Verify function/module exists

**During refactoring:**
- Always use `validate: true`
- Always use `format: true`
- Use `scope: "module"` for testing
- Use `scope: "project"` for production

**After refactoring:**
- Verify files changed as expected
- Run your test suite
- Check edit history if needed
- Rollback if issues found

### 5. Performance

**For large codebases (>10,000 files):**
- Use `parallel: true` in analyze_directory
- Enable caching
- Consider incremental analysis only
- Use path depth limits

**For embedded systems:**
- Use smaller model (all-MiniLM-L6-v2)
- Reduce max_search_results
- Disable caching if storage limited

### 6. Error Handling

**If analysis fails:**
- Check file is valid source code
- Verify language is supported
- Check file permissions
- Look for syntax errors

**If search returns no results:**
- Lower threshold
- Try different query phrasing
- Check embeddings are generated
- Verify codebase is analyzed

**If refactoring fails:**
- Check function/module exists in graph
- Verify all files are accessible
- Check validation errors
- Use rollback if needed

---

## Troubleshooting

### Model Download Issues

**Problem**: Model fails to download

**Solution:**
```bash
# Manual download
cd ~/.cache/huggingface/
wget https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/model.safetensors

# Or use different model
export RAGEX_EMBEDDING_MODEL=all_mpnet_base_v2
```

### Memory Issues

**Problem**: High memory usage

**Solutions:**
```elixir
# Use smaller model
config :ragex, embedding_model: :all_minilm_l6_v2  # 384 dims vs 768

# Reduce batch size
config :ragex, embedding_batch_size: 16  # default: 32

# Limit search results
config :ragex, max_search_results: 50
```

### Slow Analysis

**Problem**: Directory analysis is slow

**Solutions:**
```bash
# Enable parallel processing
{"parallel": true}

# Analyze incrementally
{"recursive": false}  # Analyze one directory at a time

# Filter extensions
{"extensions": [".ex"]}  # Only Elixir files
```

### Graph State Issues

**Problem**: Entities not found in graph

**Solutions:**
```bash
# Clear and rebuild
1. Stop Ragex
2. rm -rf ~/.ragex/cache
3. Start Ragex
4. Re-analyze project
```

### Validation Errors

**Problem**: Edits fail validation

**Solutions:**
1. Check syntax of new content
2. Verify language is correct
3. Test validation separately
4. Check validator is installed (Python, Node.js)

### Backup/Rollback Issues

**Problem**: Cannot rollback

**Solutions:**
```bash
# Check backup directory
ls ~/.ragex/backups/<project_hash>/

# Verify backup exists
{
  "name": "edit_history",
  "arguments": {"file": "lib/my_module.ex"}
}

# Manual restore if needed
cp ~/.ragex/backups/<project_hash>/my_module.ex.<timestamp> lib/my_module.ex
```

---

## Advanced Usage

### Custom MCP Clients

```python
# Python MCP client example
import json
import subprocess

def call_ragex(method, params):
    request = {
        "jsonrpc": "2.0",
        "method": f"tools/call",
        "params": {
            "name": method,
            "arguments": params
        },
        "id": 1
    }
    
    proc = subprocess.Popen(
        ["mix", "run", "--no-halt"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        cwd="/path/to/ragex"
    )
    
    proc.stdin.write(json.dumps(request).encode())
    proc.stdin.close()
    
    response = json.loads(proc.stdout.readline())
    return response

# Usage
result = call_ragex("semantic_search", {
    "query": "authentication",
    "limit": 5
})
```

### Programmatic API

```elixir
# Direct Elixir API usage
alias Ragex.{Graph.Store, VectorStore, Editor}

# Analyze
{:ok, analysis} = Ragex.Analyzers.Elixir.analyze(code, file)
Ragex.store_analysis(analysis)

# Search
{:ok, embedding} = Ragex.Embeddings.Bumblebee.embed("find auth code")
results = VectorStore.search(embedding, limit: 10)

# Edit
transaction = Editor.Transaction.new(validate: true, format: true)
|> Editor.Transaction.add(file, changes)
{:ok, result} = Editor.Transaction.commit(transaction)
```

---

## Support

- **Issues**: https://github.com/your-org/ragex/issues
- **Discussions**: https://github.com/your-org/ragex/discussions
- **Documentation**: https://ragex.dev/docs

---

**Last Updated**: December 30, 2025  
**Version**: 0.2.0  
**License**: MIT
