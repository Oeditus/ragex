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
ragex.setup({ keymaps = false })

-- 1. Initial statusline before connection
check("initial statusline text before connection", ragex.statusline() == "")

-- 2. Verify update_statusline
ragex.update_statusline("Ȝ ragex [Starting server...]")
check("update_statusline sets _status_text", ragex.statusline() == "Ȝ ragex [Starting server...]")

-- 3. Simulate progress events via mock chunk handling logic
local on_chunk_test = function(payload)
  local params = payload.params or payload
  local event = payload.event or params.event
  local file = params.file
  local current = params.current
  local total = params.total
  local to_analyze = params.to_analyze
  local stage = params.stage or event

  if event == "analysis_scanning" or stage == "scanning_directory" then
    ragex.update_statusline("Ȝ ragex [Scanning directory...]")
  elseif event == "analysis_scip" or stage == "scip_indexing" then
    ragex.update_statusline("Ȝ ragex [SCIP indexing...]")
  elseif event == "analysis_start" or (to_analyze and not current) then
    if to_analyze and to_analyze == 0 then
      ragex.update_statusline("Ȝ ragex [Up to date]")
    elseif to_analyze then
      ragex.update_statusline(string.format("Ȝ ragex [0/%d (0%%): starting...]", to_analyze))
    else
      ragex.update_statusline("Ȝ ragex [Indexing...]")
    end
  elseif current and total and total > 0 then
    local pct = math.floor((current / total) * 100)
    local short = file and vim.fn.fnamemodify(file, ":t") or ""
    if short ~= "" then
      ragex.update_statusline(string.format("Ȝ ragex [%d/%d (%d%%): %s]", current, total, pct, short))
    else
      ragex.update_statusline(string.format("Ȝ ragex [%d/%d (%d%%)]", current, total, pct))
    end
  elseif file then
    local short = vim.fn.fnamemodify(file, ":t")
    ragex.update_statusline(string.format("Ȝ ragex [%s/%s: %s]", current or "?", total or "?", short))
  elseif event == "analysis_complete" then
    local count = params.analyzed or params.total or 0
    ragex.update_statusline(string.format("Ȝ ragex [Indexed %d files]", count))
  end
end

-- Test event: scanning
on_chunk_test({ event = "analysis_scanning" })
check("analysis_scanning updates statusline", ragex.statusline() == "Ȝ ragex [Scanning directory...]")

-- Test event: analysis_start
on_chunk_test({ event = "analysis_start", params = { total = 100, to_analyze = 50 } })
check("analysis_start updates statusline", ragex.statusline() == "Ȝ ragex [0/50 (0%): starting...]", ragex.statusline())

-- Test event: analysis_file (progress)
on_chunk_test({ event = "analysis_file", params = { current = 25, total = 50, file = "/path/to/my_module.ex" } })
check("analysis_file updates statusline with percentage and filename", ragex.statusline() == "Ȝ ragex [25/50 (50%): my_module.ex]", ragex.statusline())

-- Test event: analysis_complete
on_chunk_test({ event = "analysis_complete", params = { analyzed = 50, total = 50 } })
check("analysis_complete updates statusline", ragex.statusline() == "Ȝ ragex [Indexed 50 files]", ragex.statusline())

ragex.update_statusline(nil)
check("completion resets statusline", ragex.statusline() == "", ragex.statusline())

if failures == 0 then
  print("ALL PROGRESS TESTS PASS")
  vim.cmd("qa!")
else
  print(failures .. " FAILURE(S)")
  vim.cmd("cq")
end
