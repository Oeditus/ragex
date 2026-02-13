-- Vim command definitions for ragex.nvim

local M = {}

function M.setup()
  -- Main Ragex command with subcommands
  vim.api.nvim_create_user_command("Ragex", function(opts)
    local ragex = require("ragex")
    local args = opts.fargs
    local subcmd = args[1]
    
    if not subcmd then
      vim.notify("[Ragex] Usage: :Ragex <subcommand>", vim.log.levels.INFO)
      vim.notify("Try :Ragex search, :Ragex analyze_file, etc.", vim.log.levels.INFO)
      return
    end
    
    -- Search commands
    if subcmd == "search" then
      ragex.telescope.search()
    elseif subcmd == "search_word" then
      ragex.telescope.search_word()
    elseif subcmd == "functions" then
      ragex.telescope.functions()
    elseif subcmd == "modules" then
      ragex.telescope.modules()
    
    -- Analysis commands
    elseif subcmd == "analyze_file" then
      ragex.analyze_file()
    elseif subcmd == "analyze_directory" then
      ragex.analyze_directory()
    elseif subcmd == "watch_directory" then
      ragex.watch_directory()
    elseif subcmd == "graph_stats" then
      ragex.graph_stats()
    elseif subcmd == "toggle_auto" then
      ragex.toggle_auto_analyze()
    
    -- Navigation commands
    elseif subcmd == "find_callers" then
      ragex.telescope.callers()
    elseif subcmd == "find_paths" then
      vim.notify("[Ragex] find_paths requires parameters", vim.log.levels.WARN)
    
    -- Refactoring commands
    elseif subcmd == "rename_function" then
      ragex.refactor.rename_function()
    elseif subcmd == "rename_module" then
      ragex.refactor.rename_module()
    elseif subcmd == "extract_function" then
      ragex.refactor.extract_function()
    elseif subcmd == "inline_function" then
      ragex.refactor.inline_function()
    elseif subcmd == "convert_visibility" then
      ragex.refactor.convert_visibility()
    
    -- Code quality commands
    elseif subcmd == "find_duplicates" then
      ragex.telescope.duplicates()
    elseif subcmd == "find_similar" then
      ragex.analysis.find_similar_code()
    elseif subcmd == "find_dead_code" then
      ragex.telescope.dead_code()
    elseif subcmd == "analyze_dependencies" then
      ragex.analysis.analyze_dependencies()
    elseif subcmd == "coupling_report" then
      ragex.analysis.coupling_report()
    elseif subcmd == "quality_report" then
      ragex.analysis.quality_report()
    
    -- Impact analysis commands
    elseif subcmd == "analyze_impact" then
      ragex.analysis.analyze_impact()
    elseif subcmd == "estimate_effort" then
      ragex.analysis.estimate_effort()
    elseif subcmd == "risk_assessment" then
      ragex.analysis.risk_assessment()
    
    -- Graph algorithm commands
    elseif subcmd == "betweenness_centrality" then
      ragex.graph.betweenness_centrality()
    elseif subcmd == "closeness_centrality" then
      ragex.graph.closeness_centrality()
    elseif subcmd == "detect_communities" then
      ragex.graph.detect_communities()
    elseif subcmd == "export_graph" then
      ragex.graph.export_graph()
    
    -- Semantic and security analysis (Phase D)
    elseif subcmd == "semantic_operations" then
      ragex.semantic_operations()
    elseif subcmd == "analyze_security_issues" then
      ragex.analyze_security_issues()
    elseif subcmd == "semantic_analysis" then
      ragex.semantic_analysis()
    elseif subcmd == "analyze_business_logic" then
      ragex.analyze_business_logic()
    
    -- Refactoring suggestions
    elseif subcmd == "suggest_refactorings" then
      ragex.suggest_refactorings()
    elseif subcmd == "explain_suggestion" then
      local suggestion_id = args[2]
      if suggestion_id then
        ragex.explain_suggestion(suggestion_id)
      else
        vim.notify("[Ragex] Usage: :Ragex explain_suggestion <id>", vim.log.levels.WARN)
      end
    
    -- Preview and AI features
    elseif subcmd == "preview_refactor" then
      vim.notify("[Ragex] preview_refactor requires parameters", vim.log.levels.WARN)
    elseif subcmd == "validate_with_ai" then
      ragex.validate_with_ai()
    
    -- RAG commands
    elseif subcmd == "rag_query" then
      ragex.rag.rag_query()
    elseif subcmd == "rag_explain" then
      ragex.rag.rag_explain()
    elseif subcmd == "rag_suggest" then
      ragex.rag.rag_suggest()
    elseif subcmd == "expand_query" then
      ragex.rag.expand_query()
    elseif subcmd == "metaast_search" then
      ragex.rag.metaast_search()
    
    -- AI cache management
    elseif subcmd == "ai_cache_stats" then
      ragex.analysis.get_ai_cache_stats()
    elseif subcmd == "ai_usage" then
      ragex.analysis.get_ai_usage()
    elseif subcmd == "clear_ai_cache" then
      ragex.analysis.clear_ai_cache()
    
    else
      vim.notify("[Ragex] Unknown subcommand: " .. subcmd, vim.log.levels.ERROR)
    end
  end, {
    nargs = "+",
    complete = function(arg_lead, cmdline, cursor_pos)
      local subcommands = {
        -- Search
        "search",
        "search_word",
        "functions",
        "modules",
        
        -- Analysis
        "analyze_file",
        "analyze_directory",
        "watch_directory",
        "graph_stats",
        "toggle_auto",
        
        -- Navigation
        "find_callers",
        "find_paths",
        
        -- Refactoring
        "rename_function",
        "rename_module",
        "extract_function",
        "inline_function",
        "convert_visibility",
        
        -- Code quality
        "find_duplicates",
        "find_similar",
        "find_dead_code",
        "analyze_dependencies",
        "coupling_report",
        "quality_report",
        
        -- Impact analysis
        "analyze_impact",
        "estimate_effort",
        "risk_assessment",
        
        -- Graph algorithms
        "betweenness_centrality",
        "closeness_centrality",
        "detect_communities",
        "export_graph",
        
        -- Semantic & security analysis
        "semantic_operations",
        "analyze_security_issues",
        "semantic_analysis",
        "analyze_business_logic",
        
        -- Refactoring suggestions
        "suggest_refactorings",
        "explain_suggestion",
        
        -- Preview & AI features
        "preview_refactor",
        "validate_with_ai",
        
        -- RAG features
        "rag_query",
        "rag_explain",
        "rag_suggest",
        "expand_query",
        "metaast_search",
        
        -- AI cache
        "ai_cache_stats",
        "ai_usage",
        "clear_ai_cache",
      }
      
      -- Filter subcommands based on what user has typed
      local matches = {}
      for _, cmd in ipairs(subcommands) do
        if cmd:find("^" .. vim.pesc(arg_lead)) then
          table.insert(matches, cmd)
        end
      end
      
      return matches
    end,
  })
end

return M
