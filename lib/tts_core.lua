-- Pure TTS-queue logic — no hs.* dependency, fully unit-testable.
--
-- The impure app (apps/tts.lua) owns the hs.httpserver intake, the pocket-tts
-- client, and afplay playback. Everything here is deterministic string/table
-- work: sanitising incoming text, chopping it into speakable chunks (so long
-- input starts talking after the first sentence instead of the whole blob), and
-- the FIFO queue primitives that serialise playback.

local M = {}

-- Collapse all runs of whitespace (incl. newlines/tabs) to single spaces and
-- trim the ends. Returns "" for nil/blank so callers can treat empty as "skip".
function M.sanitize(text)
  if not text then return "" end
  local s = text:gsub("%s+", " ")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Split one already-sanitised string into <= maxLen pieces at word boundaries.
-- A single word longer than maxLen is emitted whole (never mid-word) — better a
-- slightly long chunk than a mangled token.
local function wrapWords(s, maxLen, out)
  while #s > maxLen do
    local cut = s:sub(1, maxLen):match("^.*()%s") -- last space within the window
    cut = cut and (cut - 1) or nil
    if not cut or cut < 1 then
      local nextSpace = s:find("%s", maxLen + 1)   -- overlong word: break after it
      if not nextSpace then break end
      cut = nextSpace - 1
    end
    out[#out + 1] = (s:sub(1, cut):gsub("%s+$", ""))
    s = (s:sub(cut + 1):gsub("^%s+", ""))
  end
  if #s > 0 then out[#out + 1] = s end
end

-- Split text into speakable chunks, each <= maxLen (default 220) chars.
-- Breaks on sentence terminators (. ! ? …) first, greedily merges short
-- sentences up to maxLen to avoid many tiny synthesis calls, and hard-wraps any
-- sentence that is still too long. Returns {} for empty input.
function M.splitSentences(text, maxLen)
  maxLen = maxLen or 220
  local s = M.sanitize(text)
  if s == "" then return {} end

  -- 1) coarse split into sentences, keeping their trailing punctuation.
  local sentences, buf = {}, ""
  for i = 1, #s do
    local c = s:sub(i, i)
    buf = buf .. c
    if c:match("[%.%!%?]") then
      -- absorb any run of terminators/quotes/brackets, then require a space/end
      local nxt = s:sub(i + 1, i + 1)
      if nxt == "" or nxt == " " then
        sentences[#sentences + 1] = (buf:gsub("^%s+", ""):gsub("%s+$", ""))
        buf = ""
      end
    end
  end
  if buf:gsub("%s+", "") ~= "" then
    sentences[#sentences + 1] = (buf:gsub("^%s+", ""):gsub("%s+$", ""))
  end

  -- 2) merge short adjacent sentences, hard-wrap long ones.
  local chunks, cur = {}, ""
  for _, sent in ipairs(sentences) do
    if #sent > maxLen then
      if cur ~= "" then chunks[#chunks + 1] = cur; cur = "" end
      wrapWords(sent, maxLen, chunks)
    elseif cur == "" then
      cur = sent
    elseif #cur + 1 + #sent <= maxLen then
      cur = cur .. " " .. sent
    else
      chunks[#chunks + 1] = cur
      cur = sent
    end
  end
  if cur ~= "" then chunks[#chunks + 1] = cur end
  return chunks
end

-- FIFO queue primitives. The queue is a plain array; index 1 is the head.
-- enqueue appends one or many chunks and returns the new length.
function M.enqueue(queue, chunks)
  if type(chunks) == "string" then chunks = { chunks } end
  for _, c in ipairs(chunks or {}) do
    if c ~= nil and c ~= "" then queue[#queue + 1] = c end
  end
  return #queue
end

-- dequeue removes and returns the head chunk, or nil when empty.
function M.dequeue(queue)
  if #queue == 0 then return nil end
  return table.remove(queue, 1)
end

-- clear empties the queue in place and returns how many chunks were dropped.
function M.clear(queue)
  local n = #queue
  for i = n, 1, -1 do queue[i] = nil end
  return n
end

return M
