-- ragex.nvim plugin guard.
--
-- Prevents double-loading. Users must call `require("ragex").setup({...})` to
-- activate the plugin (or use a plugin manager's `config`/`opts` mechanism).

if vim.g.loaded_ragex then
  return
end
vim.g.loaded_ragex = 1

-- Expose a health check for `:checkhealth ragex`.
if vim.fn.exists(":CheckHealth") == 2 or vim.fn.has("nvim-0.9") == 1 then
  vim.api.nvim_create_autocmd("User", {
    pattern = "RagexHealth",
    callback = function()
      require("ragex.health").check()
    end,
  })
end
