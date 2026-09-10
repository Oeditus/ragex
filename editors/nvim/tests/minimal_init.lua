-- Minimal init for headless tests: put the plugin on the runtimepath.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/editors/nvim")
