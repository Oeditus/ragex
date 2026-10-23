-- Test dynamic tool discovery in ragex.nvim.
--
-- The plugin's static catalog is a convenience layer only; the server's
-- `tools/list` is the source of truth. These tests assert that a tool the
-- server advertises but the static catalog does not describe is still
-- reachable (②).
local failures = 0
local function check(name, cond, extra)
  if cond then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name .. (extra and (" :: " .. tostring(extra)) or ""))
  end
end

local catalog = require("ragex.tools.catalog")

-- 1. A tool present in the static catalog resolves without discovery.
check("static tool is known", catalog.get("analyze_file") ~= nil)

-- 2. A tool the static catalog does not describe is unknown before discovery.
check("undescribed tool unknown before discovery", catalog.get("advanced_refactor") == nil)

-- 3. Merge a server definition for it.
local added = catalog.merge_server_tools({
  {
    name = "advanced_refactor",
    description = "Refactor via advanced operations",
    inputSchema = {
      type = "object",
      properties = {
        max_nodes = { type = "integer", default = 1000 },
        normalize = { type = "boolean", default = true },
      },
    },
  },
  {
    name = "analyze_file",
    description = "Already known -- must not be overwritten",
    inputSchema = { type = "object", properties = {} },
  },
})

check("discovery reports exactly the new tool", #added == 1 and added[1] == "advanced_refactor", vim.inspect(added))

-- 4. It is now resolvable, and categorized as discovered.
local spec = catalog.get("advanced_refactor")
check("discovered tool resolves", spec ~= nil)
check("discovered tool keeps server description", spec and spec.desc == "Refactor via advanced operations")
check("discovered tool is flagged", spec and spec.discovered == true)
check("discovered tool has a timeout class", spec and catalog.timeouts[spec.timeout] ~= nil)

-- 5. Hand-written specs are never shadowed by server definitions.
local known = catalog.get("analyze_file")
check("static spec wins over server definition", known and known.discovered == nil)
check("static spec keeps its category", known and known.category == "Analysis")

-- 6. Discovered tools appear in the aggregate views used by the menu,
--    `:Ragex tools` and command completion.
local names = {}
for _, tool in ipairs(catalog.all()) do
  names[tool.name] = true
end
check("all() includes discovered tool", names["advanced_refactor"] == true)
check("all() includes static tools", names["analyze_file"] == true)

local categories = catalog.by_category()
check("by_category() exposes a Discovered bucket", categories["Discovered"] ~= nil)
check(
  "discovered tool is listed under Discovered",
  categories["Discovered"] and categories["Discovered"][1].name == "advanced_refactor"
)

-- 7. Merging is idempotent.
local again = catalog.merge_server_tools({
  { name = "advanced_refactor", description = "dup", inputSchema = { type = "object", properties = {} } },
})
check("re-merging reports nothing new", #again == 0, vim.inspect(again))

if failures == 0 then
  print("ALL CATALOG TESTS PASS")
  vim.cmd("qa!")
else
  print(failures .. " FAILURE(S)")
  vim.cmd("cq")
end
