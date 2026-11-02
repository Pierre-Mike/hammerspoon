-- Pronunciation practice, the part that decides — no hs.* dependency.
--
-- apps/pronunciation sends each English dictation take to a phoneme scorer
-- (apps/pronunciation/scorer.py), which says word by word where the sounds
-- made differ from how the word is pronounced. This module keeps the tally:
--
--   • a word is tracked from its first slip, and put in practice on its second,
--     so one misheard take does not earn a lesson
--   • a word in practice climbs boxes (Leitner) as it is said right in a
--     lesson, each box coming back later than the last, and is mastered after
--     the last one; a miss sends it back to the start
--   • a mastered word that slips twice again comes back into practice
--
-- The state is one plain table the plugin saves as JSON. Times are epoch
-- seconds and are always passed in, so a spec can run a month in a line.

local M = {}

local DAY = 86400

M.VERSION        = 1
M.MIN_FLAGS      = 2            -- slips before a word is put in practice
M.INTERVALS      = { 1, 3, 7, 14, 30 }   -- days until a passed word comes back, by box
M.CLIPS_PER_WORD = 3            -- recordings of the slip kept per word
M.PASS_AT        = 0.8          -- same bar as align.PASS_AT in the scorer
M.LESSON_SIZE    = 8
M.REMIND_AT      = 5            -- due words before the weekly reminder
M.REMIND_EVERY   = 7 * DAY
M.MIN_WORDS      = 3            -- shorter takes are not worth a pass of the model

M.CLAUDE = (os.getenv("HOME") or "") .. "/.local/bin/claude"
M.MODEL  = "claude-haiku-5-5"
M.BUDGET = 0.05

function M.new()
  return { version = M.VERSION, takes = 0, words = {}, lastLesson = nil, lastReminder = nil }
end

-- Is this take worth scoring as English? Dictation pinned to another language
-- says no outright. Otherwise a take with more than one accented letter reads
-- as French: espeak would score it as English and flag every word in it.
function M.english(text, language)
  if language and language ~= "" and language ~= "en" then return false end
  text = text or ""
  local n = 0
  for _ in text:gmatch("%a+") do n = n + 1 end
  if n < M.MIN_WORDS then return false end
  local accents = 0
  for _ in text:gmatch("\195[\128-\191]") do accents = accents + 1 end   -- À…ÿ
  for _ in text:gmatch("\197[\146\147]") do accents = accents + 1 end    -- Œ œ
  return accents < 2
end

-- "θ→t" for a swap, "h→∅" for a dropped sound, "+ə" for an added one.
function M.patternOf(err)
  if not err.exp or err.exp == "" then return "+" .. tostring(err.got) end
  if not err.got or err.got == "" then return err.exp .. "→∅" end
  return err.exp .. "→" .. err.got
end

local function entry(s, word)
  local e = s.words[word]
  if not e then
    e = { word = word, seen = 0, flags = 0, patterns = {}, clips = {} }
    s.words[word] = e
  end
  return e
end

-- Fold one analysed take into the state. Returns the words that entered
-- practice with this take, and the clip files that fell off the end and can
-- be deleted.
function M.ingest(s, result, now)
  s.takes = (s.takes or 0) + 1
  local entered, drop = {}, {}
  for _, w in ipairs((result and result.words) or {}) do
    local e = s.words[w.word]
    if w.flagged then
      e = e or entry(s, w.word)
      if e.mastered then
        -- Back from mastered: it has to slip MIN_FLAGS times again.
        e.mastered, e.flags = nil, 0
      end
      e.seen = e.seen + 1
      e.flags = e.flags + 1
      e.lastFlagged = now
      e.expected, e.heard = w.expected, w.heard
      for _, err in ipairs(w.errors or {}) do
        local p = M.patternOf(err)
        e.patterns[p] = (e.patterns[p] or 0) + 1
      end
      if w.clip then
        table.insert(e.clips, 1, w.clip)
        while #e.clips > M.CLIPS_PER_WORD do drop[#drop + 1] = table.remove(e.clips) end
      end
      if e.box == nil and not e.mastered and e.flags >= M.MIN_FLAGS then
        e.box, e.due = 0, now
        entered[#entered + 1] = w.word
      end
    elseif e then
      e.seen = e.seen + 1
    end
  end
  return entered, drop
end

local function practising(s)
  local out = {}
  for _, e in pairs(s.words) do
    if e.box ~= nil then out[#out + 1] = e end
  end
  return out
end

local function byNeed(a, b)
  if a.box ~= b.box then return a.box < b.box end
  if a.flags ~= b.flags then return a.flags > b.flags end
  return a.word < b.word
end

-- Words whose time has come, least learned first, then the most slipped.
function M.due(s, now, limit)
  local out = {}
  for _, e in ipairs(practising(s)) do
    if (e.due or 0) <= now then out[#out + 1] = e end
  end
  table.sort(out, byNeed)
  while #out > (limit or M.LESSON_SIZE) do table.remove(out) end
  return out
end

-- What a lesson started now drills: the due words, or when none are due, the
-- weakest words in practice. A lesson asked for is never empty while anything
-- is being practised.
function M.lessonItems(s, now, limit)
  local items = M.due(s, now, limit)
  if #items > 0 then return items end
  items = practising(s)
  table.sort(items, byNeed)
  while #items > (limit or M.LESSON_SIZE) do table.remove(items) end
  return items
end

-- The first attempt at a word in a lesson decides where it goes.
function M.grade(s, word, passed, now)
  local e = s.words[word]
  if not e then return end
  e.tries = (e.tries or 0) + 1
  e.passes = (e.passes or 0) + (passed and 1 or 0)
  if not passed then
    e.box, e.due = 0, now + DAY
    return
  end
  local box = (e.box or 0) + 1
  if box > #M.INTERVALS then
    e.box, e.due, e.mastered = nil, nil, now
  else
    e.box, e.due = box, now + M.INTERVALS[box] * DAY
  end
end

-- Did an attempt say the word right? `result` is /score's answer for the word
-- alone; returns the verdict and the word's own result, when there is one.
function M.attempt(result, word)
  for _, w in ipairs((result and result.words) or {}) do
    if w.word == word then return (w.score or 0) >= M.PASS_AT, w end
  end
  return false, nil
end

-- The sound swaps behind the words in practice, commonest first: what the
-- menu lists as "sounds to work on".
function M.patterns(s, limit)
  local by = {}
  for _, e in ipairs(practising(s)) do
    for p, n in pairs(e.patterns or {}) do
      local row = by[p] or { pattern = p, count = 0, words = {} }
      row.count = row.count + n
      row.words[#row.words + 1] = e.word
      by[p] = row
    end
  end
  local out = {}
  for _, row in pairs(by) do table.sort(row.words); out[#out + 1] = row end
  table.sort(out, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.pattern < b.pattern
  end)
  while #out > (limit or 5) do table.remove(out) end
  return out
end

-- Counts for the tile.
function M.stats(s, now)
  local st = { practising = 0, due = 0, mastered = 0, tracked = 0 }
  for _, e in pairs(s.words) do
    st.tracked = st.tracked + 1
    if e.box ~= nil then
      st.practising = st.practising + 1
      if (e.due or 0) <= now then st.due = st.due + 1 end
    elseif e.mastered then
      st.mastered = st.mastered + 1
    end
  end
  return st
end

function M.shouldRemind(s, now)
  if M.stats(s, now).due < M.REMIND_AT then return false end
  if s.lastLesson and now - s.lastLesson < M.REMIND_EVERY then return false end
  if s.lastReminder and now - s.lastReminder < DAY then return false end
  return true
end

-- ── Tips ──────────────────────────────────────────────────────────────────
-- Built in for the swaps a French speaker makes most, so a lesson has
-- something to say with Claude switched off or unreachable.
M.TIPS = {
  ["θ→t"] = "TH as in three: tongue tip lightly between your teeth, then blow air out. No tap.",
  ["θ→s"] = "TH as in three: tongue between your teeth, not behind them. Blow air past it.",
  ["θ→f"] = "TH as in three: tongue between your teeth, lips relaxed. Your lip should not touch your teeth.",
  ["ð→d"] = "TH as in this: tongue between your teeth and add your voice, a buzzing th.",
  ["ð→z"] = "TH as in this: tongue between your teeth, not behind them, with voice.",
  ["h→∅"] = "Start with a breath: push a little air out before the vowel, as if fogging a mirror.",
  ["+h"]  = "No h here: start the vowel straight from your throat, with no breath in front of it.",
  ["ɪ→i"] = "Short i as in ship: relax your mouth, shorter and looser than the ee in sheep.",
  ["i→ɪ"] = "Long ee as in sheep: smile a little and hold the sound longer than the i in ship.",
  ["ɹ→∅"] = "Say the American r: curl your tongue back without touching the roof of your mouth.",
  ["ŋ→n"] = "NG as in sing: the back of your tongue touches the soft palate. No g at the end.",
  ["w→v"] = "W as in wine: round your lips, no teeth on your lip.",
  ["v→w"] = "V as in vine: top teeth on your lower lip and buzz.",
  ["z→s"] = "Final z as in days: keep your voice on, a buzz instead of a hiss.",
  ["æ→ɛ"] = "A as in cat: open your mouth wider and drop your jaw, between e and a.",
  ["æ→ɑ"] = "A as in cat: spread your lips and keep the sound at the front of your mouth.",
  ["æ→aɪ"] = "A as in cat: one flat sound, mouth open wide. Don't glide into an i.",
  ["aɪ→æ"] = "I as in kind: start open, like ah, then glide to ee. Two sounds in one.",
  -- Heard in the first takes this plugin checked, 2026-10-30.
  ["ʃ→s"] = "SH as in should: round your lips and pull your tongue back a little. A hush, not a hiss.",
  ["tʃ→ʃ"] = "CH as in achieve: start with a t, tongue on the ridge behind your teeth, then release into sh.",
  ["ʊ→u"] = "Short oo as in should: relaxed lips, short and loose. Not the long oo in food.",
  ["ʊ→y"] = "Short oo as in should: lips loosely rounded, tongue back. Not the French u.",
  ["u→y"] = "OO as in food: tongue pulled back, lips rounded. Not the French u in tu.",
  ["d→∅"] = "Finish the word: touch the ridge behind your teeth for the final d, even if it's quick.",
  ["z→∅"] = "Finish the word: end on a buzzing z. English plurals are heard.",
  ["ɹ→ʁ"] = "American r: tongue curled back in the middle of the mouth. Not the French r from the throat.",
  ["l→d"] = "L: tongue tip on the ridge behind your teeth and let air flow around the sides.",
}

-- The tip a lesson shows for a word: Claude's when there is one, else the
-- built-in one for its commonest swap, else nothing.
function M.tip(e)
  if e.coach and type(e.coach.tip) == "string" and e.coach.tip ~= "" then return e.coach.tip end
  local best, n = nil, 0
  for p, c in pairs(e.patterns or {}) do
    if M.TIPS[p] and (c > n or (c == n and p < best)) then best, n = p, c end
  end
  return best and M.TIPS[best] or nil
end

-- ── Coaching from Claude ──────────────────────────────────────────────────
-- Only the words, how they should sound and what was heard go out. The
-- sentence a word came from stays on this Mac: dictation is work email and
-- chat, and the lesson does not need it.
M.COACH_SYSTEM = table.concat({
  "You coach a French speaker on English pronunciation.",
  "The input is a JSON list of words. Each has the IPA it should have (expected),",
  "the IPA a phoneme recognizer heard (heard) and the sound swaps (patterns).",
  "For each word reply with: respell, a simple English respelling with the stressed",
  "syllable in capitals (\"pro-NUN-see-AY-shun\"); tip, at most 25 words on how to",
  "place the mouth for the sound that went wrong; sentence, a short everyday",
  "sentence that uses the word.",
  "Reply with a JSON array of {\"word\",\"respell\",\"tip\",\"sentence\"} and nothing else.",
}, " ")

M.COACH_ASK = "Coach the words from stdin as your instructions say."

function M.coachInput(entries)
  local parts = {}
  for _, e in ipairs(entries) do
    local pats = {}
    for p in pairs(e.patterns or {}) do pats[#pats + 1] = string.format("%q", p) end
    table.sort(pats)
    parts[#parts + 1] = string.format('{"word":%q,"expected":%q,"heard":%q,"patterns":[%s]}',
      e.word, e.expected or "", e.heard or "", table.concat(pats, ","))
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

-- Same lockdown as lib/text_actions: no tools, no settings, no MCP, so the
-- run can only produce text.
function M.coachArgv(model)
  return {
    "-p", M.COACH_ASK,
    "--system-prompt", M.COACH_SYSTEM,
    "--model", model or M.MODEL,
    "--tools", "",
    "--setting-sources", "",
    "--safe-mode",
    "--strict-mcp-config",
    "--no-session-persistence",
    "--output-format", "json",
    "--max-budget-usd", tostring(M.BUDGET),
  }
end

-- `decoded` is claude's --output-format json; `decode` turns the reply text
-- into a table (hs.json.decode in the plugin). Returns word -> coach, or nil.
function M.parseCoach(decoded, decode)
  if type(decoded) ~= "table" or decoded.is_error or type(decoded.result) ~= "string" then return nil end
  local text = decoded.result:gsub("<think>.-</think>", "")
  text = text:match("%[.*%]")
  if not text then return nil end
  local ok, list = pcall(decode, text)
  if not ok or type(list) ~= "table" then return nil end
  local by = {}
  for _, c in ipairs(list) do
    if type(c) == "table" and type(c.word) == "string" then
      by[c.word:lower()] = { respell = c.respell, tip = c.tip, sentence = c.sentence }
    end
  end
  return by
end

-- "/θɹiː/" from the scorer's space-separated phones.
function M.ipa(phones)
  if not phones or phones == "" then return "" end
  return "/" .. phones:gsub(" ", "") .. "/"
end

return M
