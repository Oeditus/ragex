--- `:checkhealth ragex` support.
local M = {}

local socket_path = require("ragex.socket_path")

function M.check()
  local health = vim.health or require("health")
  local client = require("ragex.client")
  local config = client.config()

  health.start("ragex.nvim")

  -- Neovim version
  if vim.fn.has("nvim-0.9") == 1 then
    health.ok("Neovim >= 0.9")
  else
    health.error("Neovim >= 0.9 required")
  end

  -- ragex binary
  if config.ragex_bin and vim.fn.filereadable(config.ragex_bin) == 1 then
    health.ok("ragex-mcp binary: " .. config.ragex_bin)
  else
    health.error("ragex-mcp binary not found (set `ragex_bin` in setup())")
  end

  -- socat (needed for the socket transport)
  if vim.fn.executable("socat") == 1 then
    health.ok("socat available (socket transport enabled)")
  else
    health.warn("socat not found -- socket transport disabled, will use stdio")
  end

  -- socket presence
  local path = config.socket_path or socket_path.compute()
  if socket_path.exists(path) then
    health.ok("Unix socket present: " .. path)
  else
    health.info("No Unix socket at " .. path .. " (stdio transport will be used)")
  end

  -- optional UI deps
  if (pcall(require, "telescope")) then
    health.ok("telescope.nvim available")
  else
    health.warn("telescope.nvim not installed (falling back to vim.ui.select)")
  end

  -- live connectivity probe
  local result, err = client.call_tool_sync("graph_stats", {}, 15000)
  if err then
    health.warn("Could not reach Ragex server: " .. require("ragex.response").error_message(err))
  else
    local data = require("ragex.response").unwrap(result)
    local nodes = data and (data.node_count or (data.graph and data.graph.nodes)) or "?"
    health.ok("Connected to Ragex server (graph nodes: " .. tostring(nodes) .. ")")
  end
end

return M
