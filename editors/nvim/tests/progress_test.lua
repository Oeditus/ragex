-- Test statusline progress parsing and updating in ragex.nvim
local failures = 0
local function check(name, cond, extra)
  if cond then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name .. (extra and (" :: " .. tostring(extra)) or ""))
  end
end

local ragex = require("ragex")
ragex.setup({ keymaps = false, auto_analyze_on_start = false })

-- 1. Initial statusline before connection
check("initial statusline text before connection", ragex.statusline() == "")

-- 2. The yoke symbol is glued to "Ragex" -- no separating space.
check("symbol is glued to the label", ragex.SYMBOL .. "Ragex" == ragex.LABEL_READY)
check("no space between symbol and label", not ragex.LABEL_READY:find(" ", 1, true))
check("idle label", ragex.LABEL_IDLE == ragex.SYMBOL .. "Ragex: idle")

-- 3. The status() helper formats bracketed details consistently.
check("status() with detail", ragex.status("Indexing...") == ragex.SYMBOL .. "Ragex [Indexing...]")
check("status() without detail", ragex.status(nil) == ragex.LABEL_READY)

-- 4. Verify update_statusline
ragex.update_statusline(ragex.status("Starting server..."))
check("update_statusline sets _status_text", ragex.statusline() == ragex.SYMBOL .. "Ragex [Starting server...]")

-- 5. Simulate progress events via mock chunk handling logic
local on_chunk_test = function(payload)
  local params = payload.params or payload
  local event = payload.event or params.event
  local file = params.file
  local current = params.current
  local total = params.total
  local to_analyze = params.to_analyze
  local stage = params.stage or event

  if event == "analysis_scanning" or stage == "scanning_directory" then
    ragex.update_statusline(ragex.status("Scanning directory..."))
  elseif event == "analysis_scip" or stage == "scip_indexing" then
    ragex.update_statusline(ragex.status("SCIP indexing..."))
  elseif event == "analysis_start" or (to_analyze and not current) then
    if to_analyze and to_analyze == 0 then
      ragex.update_statusline(ragex.status("Up to date"))
    elseif to_analyze then
      ragex.update_statusline(ragex.status(string.format("0/%d (0%%): starting...", to_analyze)))
    else
      ragex.update_statusline(ragex.status("Indexing..."))
    end
  elseif current and total and total > 0 then
    local pct = math.floor((current / total) * 100)
    local short = file and vim.fn.fnamemodify(file, ":t") or ""
    if short ~= "" then
      ragex.update_statusline(ragex.status(string.format("%d/%d (%d%%): %s", current, total, pct, short)))
    else
      ragex.update_statusline(ragex.status(string.format("%d/%d (%d%%)", current, total, pct)))
    end
  elseif file then
    local short = vim.fn.fnamemodify(file, ":t")
    ragex.update_statusline(ragex.status(string.format("%s/%s: %s", current or "?", total or "?", short)))
  elseif event == "analysis_complete" then
    local count = params.analyzed or params.total or 0
    ragex.update_statusline(ragex.status(string.format("Indexed %d files", count)))
  end
end

local S = ragex.SYMBOL

-- Test event: scanning
on_chunk_test({ event = "analysis_scanning" })
check("analysis_scanning updates statusline", ragex.statusline() == S .. "Ragex [Scanning directory...]")

-- Test event: analysis_start
on_chunk_test({ event = "analysis_start", params = { total = 100, to_analyze = 50 } })
check("analysis_start updates statusline", ragex.statusline() == S .. "Ragex [0/50 (0%): starting...]", ragex.statusline())

-- Test event: analysis_file (progress)
on_chunk_test({ event = "analysis_file", params = { current = 25, total = 50, file = "/path/to/my_module.ex" } })
check(
  "analysis_file updates statusline with percentage and filename",
  ragex.statusline() == S .. "Ragex [25/50 (50%): my_module.ex]",
  ragex.statusline()
)

-- Test event: analysis_complete
on_chunk_test({ event = "analysis_complete", params = { analyzed = 50, total = 50 } })
check("analysis_complete updates statusline", ragex.statusline() == S .. "Ragex [Indexed 50 files]", ragex.statusline())

-- 6. Readiness transition (③): idle -> ready once indexing completes.
ragex.update_statusline(nil)
ragex.set_ready(false)
check("idle state renders idle label", ragex.statusline() == S .. "Ragex: idle", ragex.statusline())

ragex.set_ready(true)
check("ready state renders bare ready label", ragex.statusline() == S .. "Ragex", ragex.statusline())

-- 7. Completion resets statusline
ragex.update_statusline(nil)
ragex.set_ready(false)
ragex._status_text = nil
check("completion resets statusline", ragex.statusline() == "", ragex.statusline())

if failures == 0 then
  print("ALL PROGRESS TESTS PASS")
  vim.cmd("qa!")
else
  print(failures .. " FAILURE(S)")
  vim.cmd("cq")
end
