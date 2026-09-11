-- Headless smoke test for ragex.nvim.
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua -l tests/smoke.lua
--
-- Verifies that the plugin loads, setup() wires up commands, and (when a
-- Ragex server is reachable) a real tool call round-trips.

local failures = 0
local function check(name, cond, extra)
  if cond then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name .. (extra and (" :: " .. tostring(extra)) or ""))
  end
end

-- 1. Module loads.
local ok, ragex = pcall(require, "ragex")
check("require('ragex')", ok, not ok and ragex or nil)
if not ok then
  print("ABORT: plugin failed to load")
  vim.cmd("cq")
end

-- 2. setup() with an explicit binary.
local config = {
  ragex_bin = vim.fn.getcwd() .. "/bin/ragex-mcp",
  project = vim.fn.getcwd(),
  mode = "auto",
  debug = false,
  keymaps = false,
}
local setup_ok, setup_err = pcall(ragex.setup, config)
check("ragex.setup()", setup_ok, setup_err)

-- 3. Commands registered.
check(":Ragex exists", vim.fn.exists(":Ragex") == 2)
check(":RagexSearch exists", vim.fn.exists(":RagexSearch") == 2)
check(":RagexQuery exists", vim.fn.exists(":RagexQuery") == 2)
check(":RagexCR exists", vim.fn.exists(":RagexCR") == 2)
check(":RagexStatus exists", vim.fn.exists(":RagexStatus") == 2)

-- 4. Catalog is well-formed.
local catalog = require("ragex.tools.catalog")
check("catalog has tools", #catalog.tools > 40, #catalog.tools)

local seen = {}
local dup = nil
for _, tool in ipairs(catalog.tools) do
  if seen[tool.name] then
    dup = tool.name
  end
  seen[tool.name] = true
end
check("catalog has no duplicate tool names", dup == nil, dup)

-- 5. Live round-trip (best effort).
local client = require("ragex.client")
local result, err = client.call_tool_sync("graph_stats", {}, 25000)
if err then
  print("warn - live call skipped: " .. require("ragex.response").error_message(err))
else
  local data, uerr = require("ragex.response").unwrap(result)
  check("graph_stats round-trip", uerr == nil and type(data) == "table", uerr)
end

-- client.close() intentionally leaves a stdio-mode daemon running in the
-- background (see client.lua's `M.close` docs) so real editor sessions
-- never hang on exit while indexing. The test harness isn't a real
-- session though, so explicitly tear down anything it may have booted.
local stopped, stop_msg = false, nil
client.stop_daemon(function(ok, message)
  stopped, stop_msg = ok, message
end)
vim.wait(5000, function()
  return stopped ~= false or stop_msg ~= nil
end, 20)
if stop_msg then
  print((stopped and "ok   - " or "warn - ") .. "stop_daemon: " .. stop_msg)
end

client.close()

if failures == 0 then
  print("ALL PASS")
  vim.cmd("qa!")
else
  print(failures .. " FAILURE(S)")
  vim.cmd("cq")
end
