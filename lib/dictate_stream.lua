-- Live dictation, the part that decides what to type — no hs.* dependency.
--
-- The server (dictate/, through parakeet_server.py) says which
-- prefix of the transcript has settled. This module turns that into keystrokes:
-- what is new since the last poll, and what to do at the end when the final
-- transcript and the text already on screen disagree.
--
-- Rolling back is the dangerous half. Backspaces land in a document we cannot
-- read, wherever focus happens to be. In a terminal that is fine; in vim normal
-- mode it is destructive, and in a field with autocomplete it can delete
-- something the application inserted. So the bound is small and the fallback is
-- to stop rather than to guess.

local M = {}

-- A divergence longer than this is not repaired. 40 blind deletions can land
-- anywhere; the user gets the full transcript on the clipboard and is told.
M.MAX_BACKSPACES = 40

-- ── What is new ─────────────────────────────────────────────────────────────

-- The text to type now, given what has already been handed to the typer and
-- what the server says is settled. nil means the server contradicted itself —
-- `stable` is no longer an extension of what is on screen — which is the one
-- case there is nothing safe to type.
function M.delta(typed, stable)
  typed, stable = typed or "", stable or ""
  if stable:sub(1, #typed) ~= typed then return nil end
  return stable:sub(#typed + 1)
end

-- ── Words ───────────────────────────────────────────────────────────────────
-- Everything below compares WORDS, not characters, and that is the whole point.
-- The model emits punctuation and casing as tokens, so a sentence boundary that
-- moves re-cases and re-punctuates everything behind it: two passes in the
-- research corpus rewrote 16 and 33 words of rendering without changing a
-- single word, and on one ten-take run the final pass dropped one period from a
-- 190-character take that was otherwise word-perfect. Read as characters, that
-- period is a 100-character divergence and the whole take gets abandoned. Read
-- as words, it is nothing: those characters are already in the document and the
-- design accepts that they drift.

local function normalize(w)
  return (w:lower():gsub("[^a-z0-9\']", ""))
end

-- Each word with where it ends, so a prefix of the list can be sliced back out
-- of the string it came from.
local function wordize(s)
  local out = {}
  for word, hi in s:gmatch("(%S+)()") do
    out[#out + 1] = { key = normalize(word), word = word, stop = hi - 1 }
  end
  return out
end

local function agreeing(a, b)
  local n, i = math.min(#a, #b), 0
  while i < n and a[i + 1].key == b[i + 1].key do i = i + 1 end
  return i
end

-- ── Where the committed text ends in the live hypothesis ────────────────────

-- Byte index of the last UTF-8 lead byte at or before `i`, so a style span
-- never cuts a character in half.
local function boundary(s, i)
  while i > 0 do
    local b = s:byte(i + 1)
    if not b or b < 0x80 or b >= 0xC0 then return i end
    i = i - 1
  end
  return 0
end

-- How many bytes of `text` (the live hypothesis) the user already has at the
-- cursor, for the preview to show dim. Word-level, so the highlight does not
-- jump backwards every time a comma moves.
function M.committedLen(text, stable)
  text, stable = text or "", stable or ""
  if stable == "" or text == "" then return 0 end
  local a, b = wordize(text), wordize(stable)
  local i = agreeing(a, b)
  if i == 0 then return 0 end
  return boundary(text, a[i].stop)
end

-- ── Putting it right at the end ─────────────────────────────────────────────

local function split(text, clusters)
  if clusters then return clusters(text) end
  local out = {}
  for i = 1, #text do out[i] = text:sub(i, i) end
  return out
end

-- What to do once the take is over: `typed` is what went to the keyboard,
-- `final` is the whole transcript.
--
--   none       every word typed is in the transcript, in order, and there is
--              nothing left to add
--   append     the usual case, and the only one the measurements expected: the
--              words typed are the transcript's first words, so the rest is
--              simply typed after them
--   fix        a word that was typed is not in the transcript — backspace to
--              the last word they agree on and type the rest
--   clipboard  too much is wrong to delete blind; the caller shows the text and
--              leaves it on the clipboard
--
-- opts.clusters is apps/keystroke_typer's splitter, so a backspace count is
-- counted in keypresses rather than bytes: deleting "é" is one press, not two.
function M.reconcile(typed, final, opts)
  opts = opts or {}
  typed, final = typed or "", final or ""
  if typed == "" then
    return { action = (final == "") and "none" or "append", backspaces = 0, text = final }
  end
  local a, b = wordize(typed), wordize(final)
  local i = agreeing(a, b)

  if i == #a then
    -- Every word typed is still there. The tail is all that is missing, plus
    -- any punctuation the transcript hangs off the last word typed — a closing
    -- period is worth having and costs no deletion.
    local extra = ""
    if i > 0 and #b[i].word > #a[i].word and b[i].word:sub(1, #a[i].word) == a[i].word then
      extra = b[i].word:sub(#a[i].word + 1)
    end
    local rest = extra .. final:sub(((i > 0) and b[i].stop or 0) + 1)
    if rest == "" then return { action = "none", backspaces = 0, text = "" } end
    return { action = "append", backspaces = 0, text = rest }
  end

  local wrong = typed:sub(((i > 0) and a[i].stop or 0) + 1)
  local back = #split(wrong, opts.clusters)
  local rest = final:sub(((i > 0) and b[i].stop or 0) + 1)
  local limit = opts.maxBackspaces or M.MAX_BACKSPACES
  if back > limit then
    return { action = "clipboard", backspaces = back, text = final }
  end
  return { action = "fix", backspaces = back, text = rest }
end

-- ── Whether to stream at all ────────────────────────────────────────────────

-- `st` is what the caller knows at the moment a take starts:
--   on          the user's setting
--   engine      the selected model's engine; only parakeet carries timestamps
--   dictate     what /health reported for this server
--   llmCleanup  LM Studio rewrites the finished transcript wholesale, and a
--               rewrite has no prefix to have committed against
-- Returns ok, reason — the reason is for the log, and is nil when ok.
function M.available(st)
  st = st or {}
  if not st.on then return false, "off" end
  if st.engine ~= "parakeet" then return false, "engine " .. tostring(st.engine) end
  if not st.dictate then return false, "server has no live dictation" end
  if st.llmCleanup then return false, "LM Studio clean-up rewrites the transcript" end
  return true, nil
end

return M
