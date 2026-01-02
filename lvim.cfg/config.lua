-- Read the docs: https://www.lunarvim.org/docs/configuration
-- Example configs: https://github.com/LunarVim/starter.lvim
-- Video Tutorials: https://www.youtube.com/watch?v=sFA9kX-Ud_c&list=PLhoH5vyxr6QqGu0i7tt_XoVK9v-KvZ3m6
-- Forum: https://www.reddit.com/r/lunarvim/
-- Discord: https://discord.com/invite/Xb9B4Ny

lvim.lsp.installer.setup.automatic_installation = false
lvim.format_on_save.enabled = true
lvim.colorscheme = "nord"

-- keymappings [view all the defaults by pressing <leader>Lk]
lvim.leader = "space"

lvim.keys.normal_mode["<C-s>"] = ":w<cr>"
lvim.keys.normal_mode["<C-ы>"] = ":w<cr>"
lvim.keys.normal_mode["<C-f>"] = ":Telescope live_grep<CR>"
lvim.keys.normal_mode["<C-a>"] = ":Telescope live_grep<CR>"
lvim.keys.normal_mode["<C-o>"] = ":Telescope find_files<CR>"
lvim.keys.normal_mode["<C-b>"] = ":Telescope buffers<CR>"
lvim.keys.normal_mode["<C-k>"] = ":NvimTreeToggle<CR>"
lvim.keys.normal_mode["<C-t>"] = ":ToggleTerm<CR>"
-- lvim.keys.normal_mode["<C-p>"] = ":TranslateW<CR>"
lvim.keys.normal_mode["<C-p>"] = ":FuzzyOpen<CR>"
lvim.keys.normal_mode["<C-j>"] = ":BufferLineCycleNext<CR>"
lvim.keys.normal_mode["<C-h>"] = ":BufferLineCyclePrev<CR>"
lvim.keys.normal_mode["<C-l>"] = ":BufferKill<CR>"
lvim.keys.normal_mode["<C-ф>"] = ":startinsert<CR>"

vim.keymap.set({ "n", "x" }, "p", "<Plug>(YankyPutAfter)")
vim.keymap.set({ "n", "x" }, "P", "<Plug>(YankyPutBefore)")
vim.keymap.set({ "n", "x" }, "gp", "<Plug>(YankyGPutAfter)")
vim.keymap.set({ "n", "x" }, "gP", "<Plug>(YankyGPutBefore)")
lvim.keys.normal_mode["<C-e>"] = "<Plug>(YankyPreviousEntry)"
lvim.keys.normal_mode["<C-E>"] = "<Plug>(YankyNextEntry)"
lvim.keys.normal_mode["]p"] = "<Plug>(YankyPutIndentAfterLinewise)"
lvim.keys.normal_mode["[p"] = "<Plug>(YankyPutIndentBeforeLinewise)"
lvim.keys.normal_mode["]P"] = "<Plug>(YankyPutIndentAfterLinewise)"
lvim.keys.normal_mode["[P"] = "<Plug>(YankyPutIndentBeforeLinewise)"
lvim.keys.normal_mode[">p"] = "<Plug>(YankyPutIndentAfterShiftRight)"
lvim.keys.normal_mode["<p"] = "<Plug>(YankyPutIndentAfterShiftLeft)"
lvim.keys.normal_mode[">P"] = "<Plug>(YankyPutIndentBeforeShiftRight)"
lvim.keys.normal_mode["<P"] = "<Plug>(YankyPutIndentBeforeShiftLeft)"
lvim.keys.normal_mode["=p"] = "<Plug>(YankyPutAfterFilter)"
lvim.keys.normal_mode["=P"] = "<Plug>(YankyPutBeforeFilter)"

vim.keymap.set('n', '@q', ':bdelete<CR>', { desc = "Delete current buffer" })
vim.keymap.set('n', '@fr', ':FlutterRun<CR>', { desc = "Run flutter" })
vim.keymap.set('n', '@fq', ':FlutterQuit<CR>', { desc = "Quit flutter" })
vim.keymap.set('n', '@fe', ':FlutterEmulators<CR>', { desc = "List flutter emulators" })
vim.keymap.set('n', '@fd', ':FlutterDevices<CR>', { desc = "List flutter devices" })
vim.keymap.set('n', '@fl', ':FlutterLogToggle<CR>', { desc = "Toggle flutter log" })
vim.keymap.set('n', '@d', ':lua vim.diagnostic.open_float()<CR>', { desc = "Toggle Floating Diagnostics Window" })
vim.keymap.set('n', '@D', ':DiagWindowShow<CR>', { desc = "Toggle Diagnostics Window" })
vim.keymap.set('n', '@S', '<cmd>lua require("spectre").toggle()<CR>', { desc = "Toggle Spectre" })
vim.keymap.set({ 'n', 'v' }, '@ss', '<cmd>lua require("spectre").open_visual({select_word=true})<CR>',
  { desc = "Search current word" })
vim.keymap.set('n', '@sf', '<cmd>lua require("spectre").open_file_search({select_word=true})<CR>',
  { desc = "Search on current file" })
vim.keymap.set({ 'n', 'x' }, '@R', function() require('telescope').extensions.refactoring.refactors() end)

vim.keymap.set('i', '<C-`>', '<cmd>lua vim.lsp.scroll(4)<CR>', { desc = 'Scroll a pop-up down' })

lvim.builtin.which_key.mappings["M"] = {
  name = "McpHub",
  m = { "<cmd>MCPHub<cr>", "Open McpHub" },
}

-- Add visual mode mappings using @M prefix
vim.keymap.set('v', '@M', '<cmd>MCPHub<cr>', { desc = "McpHub with Selection" })

-- Ragex integration
local ragex = require("user.ragex")
local ragex_telescope = require("user.ragex_telescope")

-- Setup Ragex with configuration
ragex.setup({
  ragex_path = vim.fn.expand("~/Proyectos/Ammotion/ragex"),
  enabled = true,
  debug = false,
})

-- Ragex keybindings (using "r" prefix for Ragex)
lvim.builtin.which_key.mappings["r"] = {
  name = "Ragex",
  s = { function() ragex_telescope.ragex_search() end, "Semantic Search" },
  w = { function() ragex_telescope.ragex_search_word() end, "Search Word" },
  f = { function() ragex_telescope.ragex_functions() end, "Find Functions" },
  m = { function() ragex_telescope.ragex_modules() end, "Find Modules" },
  a = { function() ragex.analyze_current_file() end, "Analyze File" },
  d = { function() ragex.analyze_directory(vim.fn.getcwd()) end, "Analyze Directory" },
  c = { function() ragex.show_callers() end, "Find Callers" },
  r = {
    function()
      vim.ui.input({ prompt = "New name: " }, function(name)
        if name then
          ragex.rename_function(name)
        end
      end)
    end,
    "Rename Function",
  },
  R = {
    function()
      vim.ui.input({ prompt = "Old module: " }, function(old_name)
        if old_name then
          vim.ui.input({ prompt = "New module: " }, function(new_name)
            if new_name then
              ragex.rename_module(old_name, new_name)
            end
          end)
        end
      end)
    end,
    "Rename Module",
  },
  g = { 
    function()
      local result = ragex.graph_stats()
      if result and result.result then
        -- Unwrap MCP response
        local stats = result.result
        if stats.content and stats.content[1] and stats.content[1].text then
          local ok, parsed = pcall(vim.fn.json_decode, stats.content[1].text)
          if ok then
            stats = parsed
          end
        end
        
        -- Format stats for display
        local lines = {
          "# Graph Statistics",
          "",
          string.format("**Nodes**: %d", stats.node_count or 0),
          string.format("**Edges**: %d", stats.edge_count or 0),
          string.format("**Average Degree**: %.2f", stats.average_degree or 0),
          string.format("**Density**: %.4f", stats.density or 0),
          "",
          "## Node Types",
        }
        
        if stats.node_counts_by_type then
          for node_type, count in pairs(stats.node_counts_by_type) do
            table.insert(lines, string.format("- %s: %d", node_type, count))
          end
        end
        
        if stats.top_by_degree and #stats.top_by_degree > 0 then
          table.insert(lines, "")
          table.insert(lines, "## Top by Degree")
          for i, node in ipairs(stats.top_by_degree) do
            if i > 10 then break end
            table.insert(lines, string.format("- %s (in:%d, out:%d, total:%d)",
              node.node_id or "unknown",
              node.in_degree or 0,
              node.out_degree or 0,
              node.total_degree or 0))
          end
        end
        
        ragex.show_in_float("Ragex Graph Statistics", lines)
      else
        vim.notify("No graph statistics available", vim.log.levels.WARN)
      end
    end,
    "Graph Stats"
  },
  W = { function() ragex.watch_directory(vim.fn.getcwd()) end, "Watch Directory" },
  t = { function() ragex.toggle_auto_analyze() end, "Toggle Auto-Analysis" },
  -- Phase 8: Advanced Graph Algorithms
  b = { function() ragex.show_betweenness_centrality() end, "Betweenness Centrality" },
  o = { function() ragex.show_closeness_centrality() end, "Closeness Centrality" },
  n = { function() ragex.show_communities("louvain") end, "Detect Communities (Louvain)" },
  l = { function() ragex.show_communities("label_propagation") end, "Detect Communities (Label Prop)" },
  e = { 
    function()
      vim.ui.select({ "graphviz", "d3" }, {
        prompt = "Export format:",
      }, function(format)
        if format then
          local ext = format == "graphviz" and "dot" or "json"
          vim.ui.input({
            prompt = "Save as: ",
            default = vim.fn.getcwd() .. "/graph." .. ext,
          }, function(filepath)
            if filepath then
              ragex.export_graph_to_file(format, filepath)
            end
          end)
        end
      end)
    end,
    "Export Graph"
  },
}

-- Register Telescope commands for Ragex
vim.api.nvim_create_user_command("RagexSearch", ragex_telescope.ragex_search, {})
vim.api.nvim_create_user_command("RagexFunctions", ragex_telescope.ragex_functions, {})
vim.api.nvim_create_user_command("RagexModules", ragex_telescope.ragex_modules, {})
vim.api.nvim_create_user_command("RagexSearchWord", ragex_telescope.ragex_search_word, {})
vim.api.nvim_create_user_command("RagexToggleAuto", function() ragex.toggle_auto_analyze() end, {})

-- Add Ragex status to lualine
local function ragex_status()
  if ragex.config.enabled then
    return "  Ragex"
  end
  return ""
end

-- Safely add to lualine
if lvim.builtin.lualine and lvim.builtin.lualine.sections and lvim.builtin.lualine.sections.lualine_x then
  table.insert(lvim.builtin.lualine.sections.lualine_x, 1, ragex_status)
else
  -- Initialize if not present
  lvim.builtin.lualine = lvim.builtin.lualine or {}
  lvim.builtin.lualine.sections = lvim.builtin.lualine.sections or {}
  lvim.builtin.lualine.sections.lualine_x = lvim.builtin.lualine.sections.lualine_x or {}
  table.insert(lvim.builtin.lualine.sections.lualine_x, ragex_status)
end

lvim.builtin.which_key.mappings["t"] = {
  name = "+Terminal",
  f = { "<cmd>ToggleTerm<cr>", "Floating terminal" },
  v = { "<cmd>2ToggleTerm size=30 direction=vertical<cr>", "Split vertical" },
  h = { "<cmd>2ToggleTerm size=30 direction=horizontal<cr>", "Split horizontal" },
}
vim.api.nvim_set_keymap("n", "gD", "<cmd>lua vim.lsp.buf.declaration()<CR>", { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "gd", "<cmd>lua vim.lsp.buf.definition()<CR>", { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "@h", "<cmd>lua vim.lsp.buf.hover()<CR>", { noremap = true, silent = true })

vim.cmd("nnoremap gpd <cmd>lua require('goto-preview').goto_preview_definition()<CR>")
vim.cmd("nnoremap gpi <cmd>lua require('goto-preview').goto_preview_implementation()<CR>")
vim.cmd("nnoremap gP <cmd>lua require('goto-preview').close_all_win()<CR>")

vim.g['gist_use_password_in_gitconfig'] = 1

lvim.lsp.installer.setup.ensure_installed = {}

local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

lspconfig.erlangls.setup({
  filetypes = { "erlang" },
  root_dir = require("lspconfig").util.root_pattern("rebar.config", "mix.exs", ".git"),
  cmd = { "erlang_ls" },
})

-- C# / OmniSharp LSP setup
lspconfig.omnisharp.setup({
  cmd = { vim.fn.expand("$HOME/.local/bin/omnisharp") },
  enable_editorconfig_support = true,
  enable_ms_build_load_projects_on_demand = false,
  enable_roslyn_analyzers = true,
  organize_imports_on_format = true,
  enable_import_completion = true,
  sdk_include_prereleases = true,
  analyze_open_documents_only = false,
  filetypes = { "cs", "vb" },
  root_dir = function(fname)
    return lspconfig.util.root_pattern("*.sln")(fname) or lspconfig.util.root_pattern("*.csproj")(fname)
  end,
  on_attach = function(client, bufnr)
    local opts = { buffer = bufnr, noremap = true, silent = true }
    
    -- Navigation
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
    vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, opts)
    vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
    vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
    
    -- C# specific keybindings
    vim.keymap.set('n', '@cs', '<cmd>lua require("omnisharp_extended").lsp_definitions()<CR>', opts)
    vim.keymap.set('n', '@ct', '<cmd>lua require("omnisharp_extended").lsp_type_definition()<CR>', opts)
    vim.keymap.set('n', '@ci', '<cmd>lua require("omnisharp_extended").lsp_implementation()<CR>', opts)
    vim.keymap.set('n', '@cr', '<cmd>lua require("omnisharp_extended").lsp_references()<CR>', opts)
    
    print("✓ OmniSharp LSP attached to buffer " .. bufnr)
  end,
  capabilities = require('cmp_nvim_lsp').default_capabilities(),
})

-- vim.lsp.config('expert', {
--   cmd = { 'expert_linux_amd64' },
--   root_markers = { 'mix.exs', '.git' },
--   filetypes = { 'elixir', 'eelixir', 'heex' },
-- })

-- vim.lsp.enable 'expert'

-- Recognize .cure files FIRST (before LSP setup)
vim.filetype.add({
  extension = {
    cure = 'cure',
  },
})

-- Add Cure syntax plugin from local directory
vim.opt.runtimepath:append('/opt/Proyectos/Ammotion/cure/vicure')

-- Configure diagnostics appearance
vim.diagnostic.config({
  virtual_text = {
    prefix = '●',
    source = 'always',
  },
  signs = true,
  underline = true,
  update_in_insert = false,
  severity_sort = true,
})
-- Define diagnostic signs
local signs = { Error = " ", Warn = " ", Hint = " ", Info = " " }
for type, icon in pairs(signs) do
  local hl = "DiagnosticSign" .. type
  vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = hl })
end
-- Cure LSP configuration
if not configs.cure_lsp then
  configs.cure_lsp = {
    default_config = {
      cmd = { '/opt/Proyectos/Ammotion/cure/cure-lsp', 'start' },
      filetypes = { 'cure' },
      root_dir = function(fname)
        return lspconfig.util.find_git_ancestor(fname) or vim.fn.getcwd()
      end,
      settings = {},
      single_file_support = true,
    },
  }
end
-- Setup with enhanced on_attach
lspconfig.cure_lsp.setup({
  on_attach = function(client, bufnr)
    vim.api.nvim_buf_set_option(bufnr, 'omnifunc', 'v:lua.vim.lsp.omnifunc')
    
    local opts = { noremap = true, silent = true, buffer = bufnr }
    
    -- Navigation
    vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
    vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, opts)
    vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
    vim.keymap.set('n', 'go', vim.lsp.buf.type_definition, opts)
    
    -- Information
    vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
    vim.keymap.set('n', 'gs', vim.lsp.buf.signature_help, opts)
    
    -- Diagnostics
    vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, opts)
    vim.keymap.set('n', ']d', vim.diagnostic.goto_next, opts)
    vim.keymap.set('n', '<space>e', vim.diagnostic.open_float, opts)
    vim.keymap.set('n', '<space>q', vim.diagnostic.setloclist, opts)
    
    -- Actions
    vim.keymap.set('n', '<space>rn', vim.lsp.buf.rename, opts)
    vim.keymap.set('n', '<space>ca', vim.lsp.buf.code_action, opts)
    
    -- Formatting
    vim.keymap.set('n', '<space>f', function()
      vim.lsp.buf.format({ async = true })
    end, opts)
    
    -- Document symbols
    vim.keymap.set('n', '<space>ds', vim.lsp.buf.document_symbol, opts)
    
    print("✓ Cure LSP attached to buffer " .. bufnr)
  end,
  capabilities = require('cmp_nvim_lsp').default_capabilities(),
})

-- Auto-commands for Cure files
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'cure',
  callback = function()
    vim.opt_local.commentstring = '# %s'
    vim.opt_local.shiftwidth = 2
    vim.opt_local.tabstop = 2
    vim.opt_local.expandtab = true
    -- The LSP should auto-start based on filetype
  end,
})

lvim.plugins = {
  { 'shaunsingh/nord.nvim' },
  { 'MunifTanjim/nui.nvim' },
  { 'nvim-mini/mini.nvim', version = false },
  -- Cure language syntax highlighting
  {
    dir = '/opt/Proyectos/Ammotion/cure/vicure',
    lazy = false,
    priority = 50,
  },
  {
    "julienvincent/hunk.nvim",
    cmd = { "DiffEditor" },
    config = function()
      require("hunk").setup()
    end,
  },
  {
    'akinsho/flutter-tools.nvim',
    lazy = false,
    dependencies = {
      'nvim-lua/plenary.nvim',
      'stevearc/dressing.nvim', -- optional for vim.ui.select
    },
    config = function()
      require("flutter-tools").setup({
        ui = {
          -- the border type to use for all floating windows, the same options/formats
          -- used for ":h nvim_open_win" e.g. "single" | "shadow" | {<table-of-eight-chars>}
          border = "rounded",
          -- This determines whether notifications are show with `vim.notify` or with the plugin's custom UI
          -- please note that this option is eventually going to be deprecated and users will need to
          -- depend on plugins like `nvim-notify` instead.
          notification_style = 'native'
        },
        decorations = {
          statusline = {
            -- set to true to be able use the 'flutter_tools_decorations.app_version' in your statusline
            -- this will show the current version of the flutter app from the pubspec.yaml file
            app_version = false,
            -- set to true to be able use the 'flutter_tools_decorations.device' in your statusline
            -- this will show the currently running device if an application was started with a specific
            -- device
            device = true,
            -- set to true to be able use the 'flutter_tools_decorations.project_config' in your statusline
            -- this will show the currently selected project configuration
            project_config = false,
          }
        },
        debugger = { -- integrate with nvim dap + install dart code debugger
          enabled = false,
          -- if empty dap will not stop on any exceptions, otherwise it will stop on those specified
          -- see |:help dap.set_exception_breakpoints()| for more info
          exception_breakpoints = {},
          -- Whether to call toString() on objects in debug views like hovers and the
          -- variables list.
          -- Invoking toString() has a performance cost and may introduce side-effects,
          -- although users may expected this functionality. null is treated like false.
          evaluate_to_string_in_debug_views = true,
          -- You can use the `debugger.register_configurations` to register custom runner configuration (for example for different targets or flavor). Plugin automatically registers the default configuration, but you can override it or add new ones.
          -- register_configurations = function(paths)
          --   require("dap").configurations.dart = {
          --     -- your custom configuration
          --   }
          -- end,
        },
        -- flutter_path = "<full/path/if/needed>", -- <-- this takes priority over the lookup
        flutter_lookup_cmd = nil, -- example "dirname $(which flutter)" or "asdf where flutter"
        root_patterns = { ".git", "pubspec.yaml" }, -- patterns to find the root of your flutter project
        fvm = false, -- takes priority over path, uses <workspace>/.fvm/flutter_sdk if enabled
        default_run_args = nil, -- Default options for run command (i.e `{ flutter = "--no-version-check" }`). Configured separately for `dart run` and `flutter run`.
        widget_guides = {
          enabled = false,
        },
        closing_tags = {
          highlight = "ErrorMsg", -- highlight for the closing tag
          prefix = ">", -- character to use for close tag e.g. > Widget
          priority = 10, -- priority of virtual text in current line
          -- consider to configure this when there is a possibility of multiple virtual text items in one line
          -- see `priority` option in |:help nvim_buf_set_extmark| for more info
          enabled = true -- set to false to disable
        },
        dev_log = {
          enabled = true,
          filter = nil, -- optional callback to filter the log
          -- takes a log_line as string argument; returns a boolean or nil;
          -- the log_line is only added to the output if the function returns true
          notify_errors = false, -- if there is an error whilst running then notify the user
          open_cmd = "15split", -- command to use to open the log buffer
          focus_on_open = true, -- focus on the newly opened log window
        },
        dev_tools = {
          autostart = true, -- autostart devtools server if not detected
          auto_open_browser = true, -- Automatically opens devtools in the browser
        },
        outline = {
          open_cmd = "30vnew", -- command to use to open the outline buffer
          auto_open = false -- if true this will open the outline automatically when it is first populated
        },
        lsp = {
          color = { -- show the derived colours for dart variables
            enabled = true, -- whether or not to highlight color variables at all, only supported on flutter >= 2.10
            background = false, -- highlight the background
            background_color = nil, -- required, when background is transparent (i.e. background_color = { r = 19, g = 17, b = 24},)
            foreground = false, -- highlight the foreground
            virtual_text = true, -- show the highlight using virtual text
            virtual_text_str = "■", -- the virtual text character to highlight
          },
          on_attach = my_custom_on_attach,
          capabilities = my_custom_capabilities, -- e.g. lsp_status capabilities
          --- OR you can specify a function to deactivate or change or control how the config is created
          capabilities = function(config)
            config.specificThingIDontWant = false
            return config
          end,
          -- see the link below for details on each option:
          -- https://github.com/dart-lang/sdk/blob/master/pkg/analysis_server/tool/lsp_spec/README.md#client-workspace-configuration
          settings = {
            showTodos = true,
            completeFunctionCalls = true,
            -- analysisExcludedFolders = {"<path-to-flutter-sdk-packages>"},
            renameFilesWithClasses = "prompt", -- "always"
            enableSnippets = true,
            updateImportsOnRename = true, -- Whether to update imports and other directives when files are renamed. Required for `FlutterRename` command.
          }
        }
      })
    end,
  },
  {
    "ravitemer/mcphub.nvim",
    lazy = false,
    priority = 1001,
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
    build = "npm install -g mcp-hub@latest",
    config = function()
      require("mcphub").setup({
        create_commands = true,
        servers = {
          -- warp = {
          --   url = "http://127.0.0.1:7392/ai",  -- Warp's base AI endpoint
          --   headers = {
          --     ["Content-Type"] = "application/json",
          --     ["X-Integration-Type"] = "lunarvim"
          --   }
          -- },
          cure = {
            command = "/opt/Proyectos/Ammotion/cure/cure-mcp",
            args = { "start" },
            stdio = true,  -- Use stdio for JSON-RPC communication
            description = "Cure language MCP server - compilation, type-checking, FSM analysis",
          }
        },
        extensions = {
          avante = {
            show_result_in_chat = true,
            make_vars = true,
            make_slash_commands = true,
          }
        }
      })
    end,
  }, 
  {
    'wfxr/minimap.vim',
    build = "cargo install --locked code-minimap",
    -- cmd = {"Minimap", "MinimapClose", "MinimapToggle", "MinimapRefresh", "MinimapUpdateHighlight"},
    config = function()
      vim.cmd("let g:minimap_width = 10")
      vim.cmd("let g:minimap_auto_start = 1")
      vim.cmd("let g:minimap_auto_start_win_enter = 1")
    end,
  },
  {
    "elixir-tools/elixir-tools.nvim",
    -- version = "*",
    event = { "BufReadPre", "BufNewFile" },
    config = function()
      local elixir = require("elixir")
      local elixirls = require("elixir.elixirls")

      elixir.setup {
        elixirls = {
          enable = true,
          -- repo = "mhanberg/elixir-ls",
          cmd = "/home/am/Proyectos/Other/elixir-ls/releases/language_server.sh",
          settings = elixirls.settings {
            enableTestLenses = true,
            dialyzerEnabled = true,
            fetchDeps = false,
            suggestSpecs = false,
            autoInsertRequiredAlias = false,
            languageServerOverridePath = "/home/am/Proyectos/Other/elixir-ls/releases",
          },
          open_output_panel = { window = "float" },
          on_attach = function(client, bufnr)
            vim.keymap.set("n", "<space>fp", ":ElixirFromPipe<cr>", { buffer = true, noremap = true })
            vim.keymap.set("n", "<space>tp", ":ElixirToPipe<cr>", { buffer = true, noremap = true })
            vim.keymap.set("v", "<space>em", ":ElixirExpandMacro<cr>", { buffer = true, noremap = true })
            vim.keymap.set("n", "@t", "<cmd>lua vim.lsp.codelens.run()<CR>", { buffer = true, noremap = true })
          end,
        },
        nextls = { enable = false },
        credo = { enable = true },
        projectionist = { enable = true }
      }
    end,
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
  },
  {
    'mrcjkb/rustaceanvim',
    version = '^6', -- Recommended
    lazy = false, -- This plugin is already lazy
    ft = { 'rust' },
    config = function()
      vim.g.rustaceanvim = {
        -- Plugin configuration
        tools = {},
        -- LSP configuration
        server = {
          on_attach = function(client, bufnr)
            -- Custom keybindings for Rust
            local opts = { buffer = bufnr, noremap = true, silent = true }
            vim.keymap.set('n', '@r', '<cmd>RustLsp runnables<CR>', opts)
            vim.keymap.set('n', '@rd', '<cmd>RustLsp debuggables<CR>', opts)
            vim.keymap.set('n', '@re', '<cmd>RustLsp explainError<CR>', opts)
            vim.keymap.set('n', '@ro', '<cmd>RustLsp openCargo<CR>', opts)
            vim.keymap.set('n', '@rp', '<cmd>RustLsp parentModule<CR>', opts)
            vim.keymap.set('n', 'K', '<cmd>RustLsp hover actions<CR>', opts)
            vim.keymap.set('n', '@ca', '<cmd>RustLsp codeAction<CR>', opts)
            vim.keymap.set('n', '@em', '<cmd>RustLsp expandMacro<CR>', opts)
            vim.keymap.set('n', '@rrd', '<cmd>RustLsp renderDiagnostic<CR>', opts)
          end,
          default_settings = {
            -- rust-analyzer language server configuration
            ['rust-analyzer'] = {
              cargo = {
                allFeatures = true,
                loadOutDirsFromCheck = true,
                buildScripts = {
                  enable = true,
                },
              },
              -- Add clippy lints for Rust
              checkOnSave = {
                allFeatures = true,
                command = 'clippy',
                extraArgs = { '--no-deps' },
              },
              procMacro = {
                enable = true,
                ignored = {
                  ['async-trait'] = { 'async_trait' },
                  ['napi-derive'] = { 'napi' },
                  ['async-recursion'] = { 'async_recursion' },
                },
              },
            },
          },
        },
        -- DAP configuration
        dap = {},
      }
    end,
  },
  {
    'rust-lang/rust.vim',
    ft = 'rust',
    init = function()
      vim.g.rustfmt_autosave = 1
      vim.g.rustfmt_emit_files = 1
      vim.g.rustfmt_fail_silently = 0
      vim.g.rust_clip_command = 'xclip -selection clipboard'
    end,
  },
  {
    'saecki/crates.nvim',
    ft = { 'rust', 'toml' },
    config = function()
      require('crates').setup({
        null_ls = {
          enabled = true,
          name = "crates.nvim",
        },
        popup = {
          border = "rounded",
        },
      })
    end,
  },
  {
    "ThePrimeagen/refactoring.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
    },
    lazy = false,
    config = function()
      require("refactoring").setup({})
    end,
  },
  {
    "nvim-pack/nvim-spectre",
    dependencies = {
      "nvim-lua/plenary.nvim",
    },
  },
  { 'mg979/vim-visual-multi' },
  { 'chrisbra/unicode.vim' },
  { 'hkupty/iron.nvim' },
  { 'kdheepak/lazygit.nvim' },
  { 'wakatime/vim-wakatime' },
  { 'tpope/vim-unimpaired' },
  { 'tpope/vim-projectionist' },
  { 'hrsh7th/nvim-cmp' },
  { 'MattesGroeger/vim-bookmarks' },
  { 'wsdjeg/vim-fetch' },
  { 'jeffkreeftmeijer/vim-numbertoggle' },
  {
    "tpope/vim-fugitive",
    cmd = {
      "G",
      "Git",
      "Gdiffsplit",
      "Gread",
      "Gwrite",
      "Ggrep",
      "GMove",
      "GDelete",
      "GBrowse",
      "GRemove",
      "GRename",
      "Glgrep",
      "Gedit"
    },
    ft = { "fugitive" }
  },
  {
    "mattn/vim-gist",
    event = "BufRead",
    dependencies = "mattn/webapi-vim",
  },
  { "mrjones2014/nvim-ts-rainbow", },
  {
    "nvim-telescope/telescope-project.nvim",
    event = "BufWinEnter",
    init = function()
      -- vim.cmd [[packadd telescope.nvim]]
    end,
  },
  {
    "rmagatti/goto-preview",
    config = function()
      require('goto-preview').setup {
        width = 120,              -- Width of the floating window
        height = 25,              -- Height of the floating window
        default_mappings = false, -- Bind default mappings
        debug = false,            -- Print debug information
        opacity = nil,            -- 0-100 opacity level of the floating window where 100 is fully transparent.
        post_open_hook = nil      -- A function taking two arguments, a buffer and a window to be ran as a hook.
        -- You can use "default_mappings = true" setup option
      }
    end,
  },
  {
    "3rd/diagram.nvim",
    dependencies = {
      "3rd/image.nvim",
    },
    opts = { -- you can just pass {}, defaults below
      renderer_options = {
        mermaid = {
          background = nil, -- nil | "transparent" | "white" | "#hex"
          theme = nil,      -- nil | "default" | "dark" | "forest" | "neutral"
          scale = 1,        -- nil | 1 (default) | 2  | 3 | ...
        },
        plantuml = {
          charset = nil,
        },
        d2 = {
          theme_id = nil,
          dark_theme_id = nil,
          scale = nil,
          layout = nil,
          sketch = nil,
        },
      }
    },
  },
  {
    "folke/trouble.nvim",
    opts = {}, -- for default options, refer to the configuration section for custom setup.
    cmd = "TroubleToggle",
    keys = {
      {
        "<leader>xx",
        "<cmd>Trouble diagnostics toggle<cr>",
        desc = "Diagnostics (Trouble)",
      },
      {
        "<leader>xX",
        "<cmd>Trouble diagnostics toggle filter.buf=0<cr>",
        desc = "Buffer Diagnostics (Trouble)",
      },
      {
        "<leader>cs",
        "<cmd>Trouble symbols toggle focus=false<cr>",
        desc = "Symbols (Trouble)",
      },
      {
        "<leader>cl",
        "<cmd>Trouble lsp toggle focus=false win.position=right<cr>",
        desc = "LSP Definitions / references / ... (Trouble)",
      },
      {
        "<leader>xL",
        "<cmd>Trouble loclist toggle<cr>",
        desc = "Location List (Trouble)",
      },
      {
        "<leader>xQ",
        "<cmd>Trouble qflist toggle<cr>",
        desc = "Quickfix List (Trouble)",
      },
    },
  },
  { "cloudhead/neovim-fuzzy" },
  {
    "gbprod/yanky.nvim",
    config = function()
      require("yanky").setup({
        {
          ring = {
            history_length = 1000,
            storage = "shada",
            storage_path = vim.fn.stdpath("data") .. "/databases/yanky.db", -- Only for sqlite storage
            sync_with_numbered_registers = true,
            cancel_event = "update",
            ignore_registers = { "_" },
            update_register_on_cycle = false,
          },
          picker = {
            select = {
              action = nil, -- nil to use default put action
            },
            telescope = {
              use_default_mappings = true, -- if default mappings should be used
              mappings = nil,              -- nil to use default mappings or no mappings (see `use_default_mappings`)
            },
          },
          system_clipboard = {
            sync_with_ring = true,
          },
          preserve_cursor_position = {
            enabled = true,
          },
          textobj = {
            enabled = true,
          },
        },
        highlight = {
          on_put = true,
          on_yank = true,
          timer = 1500,
        },
      })
    end,
  },
  { "farmergreg/vim-lastplace" },
  -- C# / .NET development
  {
    "Hoffs/omnisharp-extended-lsp.nvim",
    ft = { "cs" },
    dependencies = { "nvim-lua/plenary.nvim" },
  },
  -- {
  --   "folke/noice.nvim",
  --   event = "VeryLazy",
  --   config = function()
  --     require("noice").setup({
  --       lsp = {
  --         -- override markdown rendering so that **cmp** and other plugins use **Treesitter**
  --         override = {
  --           ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
  --           ["vim.lsp.util.stylize_markdown"] = true,
  --           ["cmp.entry.get_documentation"] = true,
  --         },
  --       },
  --       -- you can enable a preset for easier configuration
  --       presets = {
  --         bottom_search = true,         -- use a classic bottom cmdline for search
  --         command_palette = true,       -- position the cmdline and popupmenu together
  --         long_message_to_split = true, -- long messages will be sent to a split
  --         inc_rename = false,           -- enables an input dialog for inc-rename.nvim
  --         lsp_doc_border = false,       -- add a border to hover docs and signature help
  --       },
  --     })
  --   end,
  --   opts = {
  --     -- add any options here
  --   },
  --   dependencies = {
  --     -- if you lazy-load any plugin below, make sure to add proper `module="..."` entries
  --     "MunifTanjim/nui.nvim",
  --     -- OPTIONAL:
  --     --   `nvim-notify` is only needed, if you want to use the notification view.
  --     --   If not available, we use `mini` as the fallback
  --     {
  --       "rcarriga/nvim-notify",
  --       config = function()
  --         require("notify").setup {
  --           stages = 'fade_in_slide_out',
  --           background_colour = 'FloatShadow',
  --           timeout = 500,
  --         }
  --         vim.notify = require('notify')
  --       end
  --     }
  --   }
  -- },
  {
    "cseickel/diagnostic-window.nvim",
    dependencies = { "MunifTanjim/nui.nvim" }
  },
  {
    "romgrk/nvim-treesitter-context",
    config = function()
      require("treesitter-context").setup {
        enable = true,   -- Enable this plugin (Can be enabled/disabled later via commands)
        throttle = true, -- Throttles plugin updates (may improve performance)
        max_lines = 0,   -- How many lines the window should span. Values <= 0 mean no limit.
        patterns = {     -- Match patterns for TS nodes. These get wrapped to match at word boundaries.
          -- For all filetypes
          -- Note that setting an entry here replaces all other patterns for this entry.
          -- By setting the 'default' entry below, you can control which nodes you want to
          -- appear in the context window.
          default = {
            'class',
            'function',
            'method',
          },
        },
      }
    end
  },
  {
    "RRethy/vim-illuminate",
    config = function()
      -- default configuration
      require('illuminate').configure({
        -- providers: provider used to get references in the buffer, ordered by priority
        providers = {
            'lsp',
            'treesitter',
            'regex',
        },
        -- delay: delay in milliseconds
        delay = 100,
        -- filetype_overrides: filetype specific overrides.
        -- The keys are strings to represent the filetype while the values are tables that
        -- supports the same keys passed to .configure except for filetypes_denylist and filetypes_allowlist
        filetype_overrides = {},
        -- filetypes_denylist: filetypes to not illuminate, this overrides filetypes_allowlist
        filetypes_denylist = {
            'dirbuf',
            'dirvish',
            'fugitive',
        },
        -- filetypes_allowlist: filetypes to illuminate, this is overridden by filetypes_denylist
        -- You must set filetypes_denylist = {} to override the defaults to allow filetypes_allowlist to take effect
        filetypes_allowlist = {},
        -- modes_denylist: modes to not illuminate, this overrides modes_allowlist
        -- See `:help mode()` for possible values
        modes_denylist = {},
        -- modes_allowlist: modes to illuminate, this is overridden by modes_denylist
        -- See `:help mode()` for possible values
        modes_allowlist = {},
        -- providers_regex_syntax_denylist: syntax to not illuminate, this overrides providers_regex_syntax_allowlist
        -- Only applies to the 'regex' provider
        -- Use :echom synIDattr(synIDtrans(synID(line('.'), col('.'), 1)), 'name')
        providers_regex_syntax_denylist = {},
        -- providers_regex_syntax_allowlist: syntax to illuminate, this is overridden by providers_regex_syntax_denylist
        -- Only applies to the 'regex' provider
        -- Use :echom synIDattr(synIDtrans(synID(line('.'), col('.'), 1)), 'name')
        providers_regex_syntax_allowlist = {},
        -- under_cursor: whether or not to illuminate under the cursor
        under_cursor = true,
        -- large_file_cutoff: number of lines at which to use large_file_config
        -- The `under_cursor` option is disabled when this cutoff is hit
        large_file_cutoff = 10000,
        -- large_file_config: config to use for large files (based on large_file_cutoff).
        -- Supports the same keys passed to .configure
        -- If nil, vim-illuminate will be disabled for large files.
        large_file_overrides = nil,
        -- min_count_to_highlight: minimum number of matches required to perform highlighting
        min_count_to_highlight = 1,
        -- should_enable: a callback that overrides all other settings to
        -- enable/disable illumination. This will be called a lot so don't do
        -- anything expensive in it.
        should_enable = function(bufnr) return true end,
        -- case_insensitive_regex: sets regex case sensitivity
        case_insensitive_regex = false,
        -- disable_keymaps: disable default keymaps
        disable_keymaps = false,
      })
    end
  },
}

local hunk = require("hunk")
hunk.setup({
  keys = {
    global = {
      quit = { "q" },
      accept = { "<leader><Cr>" },
      focus_tree = { "<leader>e" },
    },

    tree = {
      expand_node = { "l", "<Right>" },
      collapse_node = { "h", "<Left>" },

      open_file = { "<Cr>" },

      toggle_file = { "a" },
    },

    diff = {
      toggle_hunk = { "A" },
      toggle_line = { "a" },
      -- This is like toggle_line but it will also toggle the line on the other
      -- 'side' of the diff.
      toggle_line_pair = { "s" },

      prev_hunk = { "[h" },
      next_hunk = { "]h" },

      -- Jump between the left and right diff view
      toggle_focus = { "<Tab>" },
    },
  },

  ui = {
    tree = {
      -- Mode can either be `nested` or `flat`
      mode = "nested",
      width = 35,
    },
    --- Can be either `vertical` or `horizontal`
    layout = "vertical",
  },

  icons = {
    selected = "󰡖",
    deselected = "",
    partially_selected = "󰛲",

    folder_open = "",
    folder_closed = "",
  },

  -- Called right after each window and buffer are created.
  hooks = {
    ---@param _context { buf: number, tree: NuiTree, opts: table }
    on_tree_mount = function(_context) end,
    ---@param _context { buf: number, win: number }
    on_diff_mount = function(_context) end,
  },
})

require("diagram").setup({
  integrations = {
    require("diagram.integrations.markdown"),
    require("diagram.integrations.neorg"),
  },
  renderer_options = {
    mermaid = {
      theme = "forest",
    },
    plantuml = {
      charset = "utf-8",
    },
    d2 = {
      theme_id = 1,
    },
  },
})


lvim.builtin.telescope.on_config_done = function(telescope)
  pcall(telescope.load_extension, "project")
  pcall(telescope.load_extension, "yank_history")
  -- load refactoring Telescope extension
  pcall(telescope.load_extension, "refactoring")

  -- pcall(telescope.load_extension, "frecency")
  -- pcall(telescope.load_extension, "neoclip")
  -- pcall(telescope.load_extension, "noice")
  -- any other extensions loading
end

-- require("telescope").load_extension("yank_history")

-- lvim.builtin.treesitter.rainbow.enable = false
lvim.builtin.illuminate.active = false

-- Rust-specific configuration
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'rust',
  callback = function()
    vim.opt_local.colorcolumn = '100'
    vim.opt_local.textwidth = 100
  end,
})

-- Add Rust and C# to treesitter
lvim.builtin.treesitter.ensure_installed = {
  "rust",
  "toml",
  "c_sharp",
}

-- Inlay hints for Rust (if using Neovim 0.10+)
if vim.fn.has("nvim-0.10") == 1 then
  vim.api.nvim_create_autocmd('LspAttach', {
    pattern = '*.rs',
    callback = function(args)
      local client = vim.lsp.get_client_by_id(args.data.client_id)
      if client and client.server_capabilities.inlayHintProvider then
        vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
      end
    end,
  })
end

-- C# specific configuration
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'cs',
  callback = function()
    vim.opt_local.colorcolumn = '120'
    vim.opt_local.textwidth = 120
    vim.opt_local.tabstop = 4
    vim.opt_local.shiftwidth = 4
    vim.opt_local.expandtab = true
  end,
})
