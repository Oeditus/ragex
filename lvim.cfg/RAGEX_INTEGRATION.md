# Ragex Integration for LunarVim

Complete integration of Ragex (Hybrid RAG system for Elixir code analysis) with LunarVim.

## Overview

This integration provides:
- **Semantic code search** using natural language
- **Hybrid search** (symbolic + semantic)
- **Safe refactoring** (rename functions/modules project-wide)
- **Call graph analysis** (find callers, call chains)
- **Advanced graph algorithms** (centrality metrics, community detection)
- **Graph visualization** (Graphviz, D3.js export)
- **Auto-analysis** on save for Elixir files
- **Beautiful Telescope UI** for search results
- **Status line indicator**

## Files

- `~/.config/lvim/lua/user/ragex.lua` - Core Ragex integration module
- `~/.config/lvim/lua/user/ragex_telescope.lua` - Telescope pickers for Ragex
- `~/.config/lvim/config.lua` - Updated with Ragex keybindings and setup

## Prerequisites

1. **Ragex must be running** in the background:
   ```bash
   cd ~/Proyectos/Ammotion/ragex
   mix run --no-halt &
   ```

2. **Initial analysis** of your Elixir project:
   - Open LunarVim in your Elixir project
   - Press `<leader>rd` to analyze the directory
   - Or use `:RagexSearch` to start searching immediately

## Keybindings

All Ragex commands are under the `<leader>r` prefix (space + r by default):

### Search
- `<leader>rs` - **Semantic Search**: Natural language code search with Telescope
- `<leader>rw` - **Search Word**: Search for word under cursor
- `<leader>rf` - **Find Functions**: Search for functions by description
- `<leader>rm` - **Find Modules**: Search for modules by description

### Analysis
- `<leader>ra` - **Analyze File**: Analyze current file (auto-runs on save)
- `<leader>rd` - **Analyze Directory**: Analyze entire project directory
- `<leader>rc` - **Find Callers**: Show all callers of function under cursor
- `<leader>rg` - **Graph Stats**: Show knowledge graph statistics
- `<leader>rW` - **Watch Directory**: Enable auto-reindex on file changes

### Refactoring
- `<leader>rr` - **Rename Function**: Rename function under cursor (project-wide)
- `<leader>rR` - **Rename Module**: Rename module (project-wide)

### Graph Algorithms (Phase 8)
- `<leader>rb` - **Betweenness Centrality**: Find bridge/bottleneck functions
- `<leader>ro` - **Closeness Centrality**: Find central functions in call graph
- `<leader>rn` - **Detect Communities (Louvain)**: Discover architectural modules
- `<leader>rl` - **Detect Communities (Label Propagation)**: Fast community detection
- `<leader>re` - **Export Graph**: Save visualization (Graphviz or D3.js)

## Commands

Alternative to keybindings, you can use these commands:

- `:RagexSearch` - Open semantic search prompt
- `:RagexFunctions` - Search for functions
- `:RagexModules` - Search for modules
- `:RagexSearchWord` - Search for word under cursor

## Usage Examples

### 1. Semantic Code Search

**Scenario**: Find authentication-related code

1. Press `<leader>rs`
2. Type: "user authentication and login"
3. Browse results in Telescope
4. Press Enter to jump to selected result

**Alternative**: Use word under cursor
- Place cursor on a word (e.g., "authenticate")
- Press `<leader>rw`

### 2. Find Callers

**Scenario**: Find all places that call a function

1. Place cursor on function name (e.g., `process_payment`)
2. Press `<leader>rc`
3. View callers in floating window
4. Press `q` or `Esc` to close

### 3. Safe Refactoring

**Scenario**: Rename `get_user/1` to `fetch_user/1` everywhere

1. Place cursor on `get_user` function definition
2. Press `<leader>rr`
3. Type new name: `fetch_user`
4. Ragex will:
   - Find all call sites
   - Update all files atomically
   - Validate syntax in all files
   - Format code automatically
   - Create backups
   - Rollback if any error occurs

### 4. Project Setup

**Initial setup for a new Elixir project:**

1. Open LunarVim in project root
2. Press `<leader>rd` to analyze directory
3. Wait for analysis to complete
4. Press `<leader>rW` to enable watching (auto-reindex on save)
5. Start coding! Files are analyzed automatically on save

### 5. Find Bridge Functions (Betweenness Centrality)

**Scenario**: Identify critical functions that connect different parts of your codebase

1. Press `<leader>rb`
2. View top 20 functions with highest betweenness scores
3. Higher scores = more important "bridge" functions
4. These are often good refactoring targets or critical paths

**Use case**: Find bottlenecks, identify functions to optimize, understand data flow

### 6. Find Central Functions (Closeness Centrality)

**Scenario**: Find functions that are "close" to all other functions in the call graph

1. Press `<leader>ro`
2. View top 20 functions with highest closeness scores
3. These are well-connected, often core utility functions

**Use case**: Find core APIs, identify reusable utilities, understand architecture

### 7. Discover Architectural Modules (Community Detection)

**Scenario**: Automatically discover cohesive groups of functions (potential modules)

1. Press `<leader>rn` for Louvain algorithm (more accurate)
2. Or press `<leader>rl` for Label Propagation (faster)
3. View detected communities with member counts
4. Each community represents a potential architectural module

**Use case**: Refactor large modules, discover hidden structure, plan microservices

### 8. Export Graph Visualization

**Scenario**: Create a visual representation of your call graph

1. Press `<leader>re`
2. Choose format: Graphviz (DOT) or D3.js (JSON)
3. Specify output path (default: current directory)
4. Open exported file or process with visualization tool

**Graphviz example**:
```bash
# After exporting to graph.dot
dot -Tpng graph.dot -o graph.png
open graph.png
```

**D3.js example**:
```javascript
// Load graph.json into a D3 force-directed graph visualization
// Nodes include centrality scores and community assignments
```

## Auto-Analysis

Files are automatically analyzed when you save them (`.ex` and `.exs` files only).

To disable auto-analysis, edit `~/.config/lvim/lua/user/ragex.lua`:
```lua
ragex.setup({
  enabled = false,  -- Disable auto-analysis
})
```

## Status Line

A " Ragex" indicator appears in your status line when Ragex is enabled.

## Advanced Usage

### Custom Search Threshold

Search with custom similarity threshold:
```lua
:lua require("user.ragex").semantic_search("query", { threshold = 0.8, limit = 20 })
```

### Graph Statistics

View knowledge graph stats:
```lua
:lua vim.print(require("user.ragex").graph_stats())
```

### Module-Scoped Refactoring

Rename function only within current module:
```lua
:lua require("user.ragex").rename_function("new_name", "module")
```

## Troubleshooting

### "No results found"

**Cause**: Project not analyzed yet

**Solution**:
1. Press `<leader>rd` to analyze directory
2. Wait for "Analyzed X files" notification
3. Try search again

### "Could not determine current module"

**Cause**: Cursor not in a valid Elixir module

**Solution**:
1. Ensure you're in a `.ex` or `.exs` file
2. Ensure file has `defmodule` declaration
3. Place cursor inside module definition

### "Failed to analyze file"

**Cause**: Ragex server not running or syntax errors

**Solution**:
1. Check Ragex is running: `ps aux | grep "mix run"`
2. Start Ragex: `cd ~/Proyectos/Ammotion/ragex && mix run --no-halt &`
3. Check file for syntax errors: `mix compile`

### Slow searches

**Cause**: Large codebase without cache

**Solution**:
1. Enable caching in Ragex config (see Ragex CONFIGURATION.md)
2. First search is slower (builds cache)
3. Subsequent searches are fast (<100ms)

## Configuration

### Change Ragex Path

Edit `~/.config/lvim/config.lua`:
```lua
ragex.setup({
  ragex_path = vim.fn.expand("~/custom/path/to/ragex"),
})
```

### Enable Debug Logging

```lua
ragex.setup({
  debug = true,  -- Enable debug logs
})
```

### Customize Keybindings

Edit the `lvim.builtin.which_key.mappings["r"]` section in `config.lua`:

```lua
lvim.builtin.which_key.mappings["r"] = {
  name = "Ragex",
  s = { function() ragex_telescope.ragex_search() end, "Semantic Search" },
  -- Add your custom keybindings here
}
```

## Integration with Other Tools

### Works with ElixirLS

Ragex complements ElixirLS:
- **ElixirLS**: Diagnostics, autocomplete, go-to-definition (syntax-based)
- **Ragex**: Semantic search, project-wide refactoring, call graph analysis

### Works with vim-test

Find test files for current module:
```lua
:lua require("user.ragex").semantic_search("test for " .. require("user.ragex").get_current_module())
```

## Performance

- **Cold start**: ~2-3 seconds (first Ragex call)
- **Search**: <100ms typical
- **Analysis**: ~100 files/second
- **Refactoring**: Depends on number of affected files
- **Betweenness Centrality**: <200ms for 1000 nodes
- **Closeness Centrality**: <300ms for 1000 nodes
- **Community Detection**: <1s for 10000 nodes

## API Reference

### Core Functions

```lua
local ragex = require("user.ragex")

-- Search
ragex.semantic_search(query, opts)  -- opts: { limit, threshold, node_type }
ragex.hybrid_search(query, opts)    -- opts: { limit, strategy }

-- Analysis
ragex.analyze_current_file()
ragex.analyze_directory(path, opts)  -- opts: { recursive, parallel, extensions }
ragex.watch_directory(path, extensions)

-- Callers
ragex.find_callers()                 -- Returns query result
ragex.show_callers()                 -- Shows in floating window

-- Refactoring
ragex.rename_function(new_name, scope)  -- scope: "project" or "module"
ragex.rename_module(old_name, new_name)

-- Graph Algorithms (Phase 8)
ragex.betweenness_centrality(opts)      -- opts: { max_nodes, normalize }
ragex.closeness_centrality(opts)        -- opts: { normalize }
ragex.detect_communities(opts)          -- opts: { algorithm, max_iterations, resolution, hierarchical, seed }
ragex.export_graph(opts)                -- opts: { format, include_communities, color_by, max_nodes }

-- Phase 8 UI Functions
ragex.show_betweenness_centrality()     -- Show in floating window
ragex.show_closeness_centrality()       -- Show in floating window
ragex.show_communities(algorithm)       -- algorithm: "louvain" or "label_propagation"
ragex.export_graph_to_file(format, filepath)  -- format: "graphviz" or "d3"

-- Utilities
ragex.graph_stats()
ragex.get_current_module()
ragex.get_function_arity()
```

### Telescope Functions

```lua
local ragex_telescope = require("user.ragex_telescope")

ragex_telescope.ragex_search()       -- Prompted semantic search
ragex_telescope.ragex_search_word()  -- Search word under cursor
ragex_telescope.ragex_functions()    -- Search functions
ragex_telescope.ragex_modules()      -- Search modules
```

## Tips and Best Practices

1. **Enable watching** for active projects: `<leader>rW`
2. **Use semantic search** for exploratory work: `<leader>rs`
3. **Use word search** for quick lookups: `<leader>rw`
4. **Test refactoring** with module scope first: `:lua require("user.ragex").rename_function("new_name", "module")`
5. **Check graph stats** periodically: `<leader>rg`
6. **Analyze after large changes**: `<leader>rd`
7. **Find bottlenecks** with betweenness centrality: `<leader>rb`
8. **Discover architecture** with community detection: `<leader>rn`
9. **Export visualizations** for documentation: `<leader>re`

## Future Enhancements

Planned features:
- Completion integration (semantic suggestions)
- Inline code actions (LSP integration)
- Call graph visualization
- Embedding model selection
- Multi-language support (Erlang, Python, JavaScript)

## Support

- **Ragex Documentation**: `~/Proyectos/Ammotion/ragex/stuff/docs/USAGE.md`
- **Issues**: Report in Ragex repository
- **LunarVim Docs**: https://www.lunarvim.org/docs/configuration

---

**Last Updated**: January 1, 2026  
**Ragex Version**: 0.2.0 (with Phase 8: Advanced Graph Algorithms)  
**LunarVim Compatibility**: Latest
