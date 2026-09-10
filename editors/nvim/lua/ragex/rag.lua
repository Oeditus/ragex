--- RAG workflows with live streaming.
---
--- Ragex exposes streaming variants (`rag_query_stream`, `rag_explain_stream`,
--- `rag_suggest_stream`) that emit `notifications/progress` chunks before the
--- final `tools/call` response. We subscribe to those chunks and append them
--- to a scratch buffer so the answer materializes token-by-token.
local M = {}

local client = require("ragex.client")
local display = require("ragex.display")
local response = require("ragex.response")
local ui = require("ragex.ui")

--- Map a non-streaming RAG tool to its streaming counterpart.
local STREAMING = {
  rag_query = "rag_query_stream",
  rag_explain = "rag_explain_stream",
  rag_suggest = "rag_suggest_stream",
}

--- Run a streaming RAG tool, appending chunks to a buffer.
---@param tool string            one of rag_query/rag_explain/rag_suggest
---@param args table
---@param opts table|nil         { title }
function M.stream(tool, args, opts)
  opts = opts or {}
  local stream_tool = STREAMING[tool] or (tool .. "_stream")

  local title = opts.title or ("Ragex: " .. tool)

  -- Collect the final content field name so we can render the completed answer
  -- even if streaming notifications never arrive (e.g. socket transport that
  -- does not forward progress).
  local _, append, finish = ui.stream_buffer({
    title = "ragex://" .. stream_tool,
    filetype = "markdown",
    height = 22,
  })

  local received_chunks = false

  client.call_tool(stream_tool, args, {
    timeout = 300000,
    on_chunk = function(text, done, _value)
      if text and text ~= "" then
        received_chunks = true
        append(text)
      end
      if done then
        finish()
      end
    end,
    callback = function(result, err)
      if err then
        ui.notify(tool .. " failed: " .. response.error_message(err), vim.log.levels.ERROR)
        return
      end

      local data, uerr = response.unwrap(result)
      if uerr then
        ui.notify(tool .. " failed: " .. uerr, vim.log.levels.ERROR)
        return
      end

      -- If no progress notifications arrived, render the final payload.
      if not received_chunks then
        local text = data.response or data.explanation or data.suggestions
        if type(text) == "string" and text ~= "" then
          append(text)
        else
          display.show(title, data)
        end
      end

      finish()
      ui.notify(title .. " complete")
    end,
  })
end

return M
