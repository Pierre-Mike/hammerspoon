-- A Claude Code session that stays running, for small questions from the hub
-- panel. The rules live here and are pure; apps/claude_chat runs the process.
--
-- One `claude -p` process is kept open with stream-json on both sides: each
-- question is one JSON line on its stdin, and the answer comes back on stdout
-- as events, word by word with --include-partial-messages. The process stays
-- warm between questions, so a question does not pay Claude Code's start-up,
-- and the conversation carries on until "New chat".
--
-- The session is read-only and can look things up: Read, Glob, Grep,
-- WebSearch and WebFetch. Nothing that edits a file or runs a command, because
-- nobody is watching the panel to approve it.

local M = {}

M.TOOLS     = "Read,Glob,Grep,WebSearch,WebFetch"
M.MAX_LINES = 200   -- the transcript kept, oldest dropped first

-- Short answers suit a box a third of a screen wide.
M.SYSTEM = "You are answering quick questions typed into a small panel on the user's Mac. "
        .. "Answer in a few short lines of plain text. No Markdown headings or tables."

-- The arguments after the binary. `model` is an alias or an id, nil for the
-- user's default; `resume` is a session id to carry on from.
function M.args(model, resume)
  local a = { "-p", "--input-format", "stream-json", "--output-format", "stream-json",
              "--verbose", "--include-partial-messages",
              "--tools", M.TOOLS, "--permission-mode", "bypassPermissions",
              "--append-system-prompt", M.SYSTEM }
  if model and model ~= "" and model ~= "default" then
    a[#a + 1] = "--model"; a[#a + 1] = model
  end
  if resume and resume ~= "" then
    a[#a + 1] = "--resume"; a[#a + 1] = resume
  end
  return a
end

-- ── JSON out ───────────────────────────────────────────────────────────────
-- Only strings need encoding, so this is a string escaper rather than a JSON
-- library; it keeps the module free of hs.json and testable as is.
local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

function M.quote(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    return ESC[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

-- One question as the line stream-json input wants on stdin.
function M.message(text)
  return '{"type":"user","message":{"role":"user","content":[{"type":"text","text":'
      .. M.quote(text) .. '}]}}\n'
end

-- ── Events in ──────────────────────────────────────────────────────────────
function M.new()
  return { lines = {}, buffer = "", busy = false, session = nil, model = nil, cost = 0, open = nil }
end

-- Complete lines from a chunk of stdout; a partial line waits in the buffer.
function M.split(state, chunk)
  state.buffer = state.buffer .. (chunk or "")
  local out = {}
  while true do
    local nl = state.buffer:find("\n", 1, true)
    if not nl then break end
    local line = state.buffer:sub(1, nl - 1)
    state.buffer = state.buffer:sub(nl + 1)
    if line:find("%S") then out[#out + 1] = line end
  end
  return out
end

local function push(state, who, text)
  state.lines[#state.lines + 1] = { who = who, text = text }
  while #state.lines > M.MAX_LINES do table.remove(state.lines, 1) end
  return state.lines[#state.lines]
end

-- What the user asked, into the transcript.
function M.ask(state, text)
  push(state, "you", text)
  state.busy, state.open = true, nil
end

function M.note(state, text) push(state, "note", text) end

-- One decoded event. Returns true when the transcript changed.
function M.apply(state, ev)
  if type(ev) ~= "table" then return false end
  if ev.type == "system" and ev.subtype == "init" then
    state.session, state.model = ev.session_id or state.session, ev.model or state.model
    return false
  end
  if ev.type == "stream_event" and type(ev.event) == "table" then
    local e = ev.event
    if e.type == "content_block_start" and type(e.content_block) == "table" then
      local b = e.content_block
      if b.type == "text" then
        state.open = push(state, "reply", "")
      elseif b.type == "tool_use" then
        state.open = nil
        push(state, "note", "Using " .. tostring(b.name) .. "…")
        return true
      end
    elseif e.type == "content_block_delta" and type(e.delta) == "table"
           and e.delta.type == "text_delta" and state.open then
      state.open.text = state.open.text .. (e.delta.text or "")
      return true
    elseif e.type == "content_block_stop" then
      -- A reply that started with a newline or ended with one reads as a gap.
      if state.open then state.open.text = state.open.text:gsub("^%s+", ""):gsub("%s+$", "") end
      state.open = nil
    end
    return false
  end
  if ev.type == "result" then
    state.busy, state.open = false, nil
    state.session = ev.session_id or state.session
    if type(ev.total_cost_usd) == "number" then state.cost = state.cost + ev.total_cost_usd end
    if ev.is_error then
      push(state, "note", "Couldn't answer: " .. tostring(ev.result or ev.subtype or "error"))
    end
    -- Empty reply lines are the ones a tool call interrupted before any text.
    for i = #state.lines, 1, -1 do
      if state.lines[i].who == "reply" and state.lines[i].text == "" then table.remove(state.lines, i) end
    end
    return true
  end
  return false
end

-- The status the widget shows beside its title.
function M.status(state, running)
  if not running then return "Starting…" end
  if state.busy then return "Thinking…" end
  return "Ready"
end

return M
