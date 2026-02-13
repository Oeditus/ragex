-- Ragex plugin configuration for LunarVim
-- Add this to your ~/.config/lvim/config.lua

lvim.plugins = vim.list_extend(lvim.plugins or {}, {
  {
    'ragex.nvim',
    dir = vim.fn.expand('~/.local/share/lunarvim/lazy/ragex.nvim'),
    dependencies = {
      'nvim-lua/plenary.nvim',
      'nvim-telescope/telescope.nvim',
    },
    config = function()
      require('ragex').setup({
        ragex_path = vim.fn.expand('~/Proyectos/Oeditus/ragex'),
        socket_path = '/tmp/ragex_mcp.sock',
        enabled = true,
        debug = false,
        auto_analyze = false,
      })
    end,
  },
})

-- Optional: Add keybindings
lvim.keys.normal_mode['<leader>rs'] = ':Ragex search<CR>'
lvim.keys.normal_mode['<leader>rw'] = ':Ragex search_word<CR>'
lvim.keys.normal_mode['<leader>rf'] = ':Ragex functions<CR>'
lvim.keys.normal_mode['<leader>rm'] = ':Ragex modules<CR>'
lvim.keys.normal_mode['<leader>ra'] = ':Ragex analyze_file<CR>'
lvim.keys.normal_mode['<leader>rA'] = ':Ragex analyze_directory<CR>'
lvim.keys.normal_mode['<leader>rg'] = ':Ragex graph_stats<CR>'
lvim.keys.normal_mode['<leader>rd'] = ':Ragex find_duplicates<CR>'
lvim.keys.normal_mode['<leader>rD'] = ':Ragex find_dead_code<CR>'
lvim.keys.normal_mode['<leader>rc'] = ':Ragex coupling_report<CR>'
lvim.keys.normal_mode['<leader>rq'] = ':Ragex quality_report<CR>'
lvim.keys.normal_mode['<leader>rI'] = ':Ragex analyze_impact<CR>'
lvim.keys.normal_mode['<leader>rsu'] = ':Ragex suggest_refactorings<CR>'
lvim.keys.normal_mode['<leader>rso'] = ':Ragex semantic_operations<CR>'
lvim.keys.normal_mode['<leader>rsi'] = ':Ragex analyze_security_issues<CR>'
lvim.keys.normal_mode['<leader>rsa'] = ':Ragex semantic_analysis<CR>'

-- Refactoring keybindings
lvim.keys.normal_mode['<leader>rr'] = ':Ragex rename_function<CR>'
lvim.keys.normal_mode['<leader>rR'] = ':Ragex rename_module<CR>'
lvim.keys.normal_mode['<leader>ri'] = ':Ragex inline_function<CR>'
lvim.keys.visual_mode['<leader>re'] = ':Ragex extract_function<CR>'

-- RAG features
lvim.keys.normal_mode['<leader>rQ'] = ':Ragex rag_query<CR>'
lvim.keys.normal_mode['<leader>rx'] = ':Ragex rag_explain<CR>'
lvim.keys.visual_mode['<leader>rS'] = ':Ragex rag_suggest<CR>'
