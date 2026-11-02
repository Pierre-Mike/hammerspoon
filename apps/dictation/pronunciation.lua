-- Pronunciation: learns which English words you mispronounce from your own
-- dictation, then drills them in short lessons you start from the Dictation
-- tile. Part of apps/dictation, built on its context:
--
--   local pr = require("apps.dictation.pronunciation")({
--     ctx = ctx, isRecording = fn, micName = fn })
--   pr.onTake({ text, wav })   a finished take; dictation calls it
--   pr.menuRows()              the Pronunciation group of the tile
--
-- This file does these things and nothing else:
--   • queues each English take dictation hands it (its WAV and transcript)
--     in an inbox
--   • runs the phoneme scorer (scorer/scorer.py, a warm local HTTP server) over the
--     inbox when dictation is idle, and stops it after a few idle minutes
--   • keeps the tally in lib/pronunciation and saves it as JSON
--   • runs a lesson: a panel in the middle of the screen, the word said by
--     macOS `say`, your own slip played back, and Space held to answer, which
--     records the mic and scores the attempt with the same model
--   • reminds you once a week when enough words are due
--
-- What counts as a slip, when a word comes back and what Claude is asked are
-- all in lib/pronunciation; how a word is scored is apps/dictation/scorer/align.py.
--
-- Nothing is sent anywhere except the optional coaching: the practice words,
-- their IPA and the sound swaps go to Claude for a respelling, a tip and an
-- example sentence. Never the audio, never the sentence a word came from.

local pron    = require("lib.pronunciation")
local rewrite = require("lib.text_actions")
local utils   = require("lib.utils")
local UI      = require("lib.ui")
local menu    = UI.menu
local theme   = UI.theme

local unpack = table.unpack or unpack

local HOME   = os.getenv("HOME")
local DIR    = HOME .. "/.cache/hs-pronunciation"
local LOG    = "/tmp/hs-pronunciation.log"
local UV     = "/opt/homebrew/bin/uv"
local FFMPEG = "/opt/homebrew/bin/ffmpeg"
local SAY    = "/usr/bin/say"
local STT    = "http://127.0.0.1:8765"
local PORT   = 8796
local BASE   = "http://127.0.0.1:" .. PORT
local IDLE_S = 300      -- the scorer is stopped after this long unused
local BOOT_S = 900      -- its first start installs torch and downloads the model
local MIN_ATTEMPT = 0.4 -- seconds; a shorter Space press is a slip of the finger
local MAX_TRIES   = 3   -- misses on one word before the panel suggests moving on

-- The settings, kept beside dictation's own as dictate.pronunciation.<key>.
local SETTINGS = {
  collect    = true,        -- learn from every English take
  coaching   = true,        -- ask Claude for a respelling, a tip and a sentence
  voice      = "Samantha",  -- the macOS voice that says the word
  lessonSize = 8,
}
local function settingKey(key) return "dictate.pronunciation." .. key end

return function(host)
  local ctx = host.ctx
  local ui  = ctx:ui()
  local M = { lesson = nil, busy = false, server = nil, booting = false, waiting = {}, lastUse = 0 }

  -- On M so a spec can point them at a scratch directory.
  M.paths = {
    state   = DIR .. "/state.json",
    inbox   = DIR .. "/inbox",
    clips   = DIR .. "/clips",
    attempt = "/tmp/hs-pronunciation-attempt.wav",
    coach   = "/tmp/hs-pronunciation-coach.json",
    scorer  = HOME .. "/.hammerspoon/apps/dictation/scorer/scorer.py",
  }

  local function logf(fmt, ...) utils.logf(LOG, fmt, ...) end
  local function setting(key)
    local v = hs.settings.get(settingKey(key))
    if v == nil or type(v) ~= type(SETTINGS[key]) then return SETTINGS[key] end
    return v
  end
  local function setSetting(key, v) hs.settings.set(settingKey(key), v) end
  local function now() return os.time() end
  local function mkdirs()
    os.execute(string.format("mkdir -p %q %q", M.paths.inbox, M.paths.clips))
  end

  -- ── State ────────────────────────────────────────────────────────────────
  local function load()
    local ok, s = pcall(hs.json.read, M.paths.state)
    if ok and type(s) == "table" and type(s.words) == "table" then
      for _, e in pairs(s.words) do
        e.patterns, e.clips = e.patterns or {}, e.clips or {}
      end
      return s
    end
    return pron.new()
  end

  local function save()
    mkdirs()
    local ok, err = pcall(hs.json.write, M.state, M.paths.state, true, true)
    if not ok then logf("could not save %s: %s", M.paths.state, tostring(err)) end
  end

  M.state = load()

  -- ── Dictation ────────────────────────────────────────────────────────────
  -- The take in flight and the mic it records from, asked of dictation each
  -- time: both change under us.
  local function dictating()
    local ok, rec = pcall(host.isRecording)
    return ok and rec == true
  end

  local function mic()
    local ok, name = pcall(host.micName)
    if ok and type(name) == "string" and name ~= "" then return name end
    ok, name = pcall(function() return hs.audiodevice.defaultInputDevice():name() end)
    if ok and type(name) == "string" and name ~= "" then return name end
    return "0"
  end

  local function inboxNames()
    local out = {}
    pcall(function()
      for f in hs.fs.dir(M.paths.inbox) do
        if f:match("%.wav$") then out[#out + 1] = f end
      end
    end)
    table.sort(out)
    return out
  end

  -- ── The scorer ───────────────────────────────────────────────────────────
  local function touch() M.lastUse = hs.timer.secondsSinceEpoch() end

  local function stopServer()
    if M.serverRelease then M.serverRelease() end
    M.server, M.serverRelease = nil, nil
  end

  -- `uv run --script` reads the dependencies from scorer.py's own header, so
  -- the first start installs them. Its output goes to the log, through sh so
  -- the paths travel as arguments.
  local function launch()
    if not hs.fs.attributes(UV) then logf("no uv at %s; the scorer cannot start", UV); return end
    local task, done
    task, done = ctx:task("/bin/sh", function(code)
      done()
      if M.server == task then M.server, M.serverRelease = nil, nil end
      logf("scorer exited code=%d", code)
    end, { "-c", 'exec "$1" run --script "$2" --port "$3" >>"$4" 2>&1', "sh",
           UV, M.paths.scorer, tostring(PORT), LOG })
    task:setEnvironment({ HOME = HOME, PATH = "/opt/homebrew/bin:/usr/bin:/bin",
                          PHONEMIZER_ESPEAK_LIBRARY = "/opt/homebrew/lib/libespeak-ng.dylib" })
    M.server, M.serverRelease = task, done
    task:start()
    logf("starting the scorer on :%d", PORT)
  end

  local function health(cb)
    hs.http.asyncGet(BASE .. "/health", nil, function(code, body)
      local ok, h = pcall(hs.json.decode, body or "")
      cb(code == 200 and ok and type(h) == "table" and h or nil)
    end)
  end

  -- Calls cb(true) once the model answers, or cb(false, why). Callers that
  -- arrive while it boots wait on the same start.
  function M.ensureServer(cb)
    touch()
    M.waiting[#M.waiting + 1] = cb
    if M.booting then return end
    M.booting = true
    local started = hs.timer.secondsSinceEpoch()
    local stopPoll
    local function finish(ok, why)
      if not M.booting then return end
      M.booting = false
      if stopPoll then stopPoll() end
      local list = M.waiting
      M.waiting = {}
      for _, f in ipairs(list) do pcall(f, ok, why) end
    end
    local function check()
      health(function(h)
        if h and h.loaded then return finish(true) end
        if h and h.error then return finish(false, tostring(h.error)) end
        if not h and not M.server then launch() end
        if hs.timer.secondsSinceEpoch() - started > BOOT_S then finish(false, "the scorer did not start") end
      end)
    end
    stopPoll = select(2, ctx:timer(1, check))
    check()
  end

  local function post(path, body, cb)
    touch()
    hs.http.asyncPost(BASE .. path, hs.json.encode(body), { ["Content-Type"] = "application/json" },
      function(code, resp)
        touch()
        local ok, dec = pcall(hs.json.decode, resp or "")
        cb(code, ok and type(dec) == "table" and dec or nil)
      end)
  end

  -- ── Collecting takes ─────────────────────────────────────────────────────
  local drain

  local function readFile(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
  end
  local function writeFile(p, data)
    local f = io.open(p, "wb"); if not f then return false end
    f:write(data); f:close(); return true
  end

  -- Copied at once: dictation keeps only its last five takes.
  function M.onTake(take)
    if not setting("collect") then return end
    if not pron.english(take.text, hs.settings.get("dictate.language")) then
      logf("skipped a take that is not English, or too short: %q", utils.truncate(take.text or "", 60))
      return
    end
    local data = readFile(take.wav)
    if not data then logf("take %s is gone", tostring(take.wav)); return end
    mkdirs()
    local base = M.paths.inbox .. "/" .. (take.wav:match("([^/]+)%.wav$") or tostring(now()))
    if not (writeFile(base .. ".wav", data) and writeFile(base .. ".txt", take.text)) then
      logf("cannot write to %s", M.paths.inbox)
      return
    end
    ctx:after(3, function() drain() end)
  end

  -- One take at a time, never while dictation has the mic or a lesson is open:
  -- the scorer shares the CPU with both.
  M.failures = 0
  drain = function()
    if M.busy or M.lesson then return end
    if dictating() then ctx:after(5, function() drain() end); return end
    local name = inboxNames()[1]
    if not name then return end
    local wav = M.paths.inbox .. "/" .. name
    local txtPath = wav:gsub("%.wav$", ".txt")
    local text = readFile(txtPath) or ""
    local function done()
      os.remove(wav); os.remove(txtPath)
      M.failures = 0
    end
    M.busy = true
    M.ensureServer(function(ok, why)
      if not ok then
        M.busy = false
        logf("scorer unavailable (%s); %d takes wait", tostring(why), #inboxNames())
        ctx:after(600, function() drain() end)
        return
      end
      post("/analyze", { wav = wav, text = text, clips = M.paths.clips }, function(code, res)
        M.busy = false
        if code == 200 and res then
          local entered, drop = pron.ingest(M.state, res, now())
          for _, p in ipairs(drop) do os.remove(p) end
          save()
          local flagged = {}
          for _, w in ipairs(res.words or {}) do if w.flagged then flagged[#flagged + 1] = w.word end end
          logf("checked %s: %d words, flagged %s%s", name, #(res.words or {}),
               #flagged > 0 and table.concat(flagged, ", ") or "none",
               #entered > 0 and ("; now practising " .. table.concat(entered, ", ")) or "")
          done()
        elseif code == 400 then
          logf("dropped %s: %s", name, res and tostring(res.error) or "bad request")
          done()
        else
          M.failures = M.failures + 1
          logf("could not check %s (status %s): %s", name, tostring(code), res and tostring(res.error) or "")
          if M.failures >= 3 then logf("giving up on %s", name); done() end
        end
        ctx:after(1, function() drain() end)
      end)
    end)
  end
  M.drain = drain

  -- ── Coaching ─────────────────────────────────────────────────────────────
  local function coach(entries, onDone)
    if not setting("coaching") then return end
    local need = {}
    for _, e in ipairs(entries) do if not e.coach then need[#need + 1] = e end end
    if #need == 0 or not hs.fs.attributes(rewrite.CLAUDE) then return end
    if not writeFile(M.paths.coach, pron.coachInput(need)) then return end
    local task, release
    task, release = ctx:task("/bin/sh", function(code, out, err)
      release()
      local ok, decoded = pcall(hs.json.decode, out or "")
      local by = ok and pron.parseCoach(decoded, hs.json.decode) or nil
      if not by then
        logf("no coaching (exit %d): %s", code, utils.truncate(tostring(err ~= "" and err or out), 160))
        return
      end
      for _, e in ipairs(need) do
        if by[e.word] then e.coach = by[e.word] end
      end
      save()
      logf("coaching for %d words", #need)
      if onDone then onDone() end
    end, rewrite.shellArgv(rewrite.CLAUDE, M.paths.coach, pron.coachArgv(pron.MODEL)))
    task:setEnvironment({ HOME = HOME, PATH = "/opt/homebrew/bin:/usr/bin:/bin" })
    task:start()
    ctx:after(45, release)
  end

  -- ── The lesson panel ─────────────────────────────────────────────────────
  local W = 620
  local function lh(style) return math.ceil(theme.text[style] * theme.leading) end

  local function layout(L)
    local e = L.items[L.i]
    local pad, gap = theme.space.xl, theme.space.sm
    local inner = W - 2 * pad
    local els, y = {}, pad
    els[#els + 1] = UI.label(string.format("Lesson · %d of %d", L.i, #L.items),
      { x = pad, y = y, w = inner / 2, h = lh("footnote") }, { style = "footnote", color = "textSecondary" })
    els[#els + 1] = UI.label("esc to end",
      { x = pad + inner / 2, y = y, w = inner / 2, h = lh("caption") },
      { style = "caption", color = "textTertiary", align = "right" })
    y = y + lh("footnote") + gap

    els[#els + 1] = UI.label(e.word, { x = pad, y = y, w = inner, h = lh("hero") }, { style = "hero", bold = true })
    y = y + lh("hero") + gap

    local say = pron.ipa(e.expected)
    if e.coach and e.coach.respell then say = e.coach.respell .. " · " .. say end
    els[#els + 1] = UI.label(say, { x = pad, y = y, w = inner, h = lh("title") }, { style = "title", truncate = true })
    y = y + lh("title") + gap

    local heard = e.heard and e.heard ~= "" and ("You said " .. pron.ipa(e.heard)) or ""
    if heard ~= "" then
      els[#els + 1] = UI.label(heard, { x = pad, y = y, w = inner, h = lh("footnote") },
        { style = "footnote", color = "textSecondary", truncate = true })
      y = y + lh("footnote") + gap
    end

    local tip = pron.tip(e)
    if tip then
      -- As many lines as it wraps to, with a margin for word breaks, up to four.
      local lines = math.min(4, math.ceil(UI.measure(tip, theme.text.body) * 1.15 / inner))
      els[#els + 1] = UI.label(tip, { x = pad, y = y, w = inner, h = lines * lh("body") }, { style = "body" })
      y = y + lines * lh("body") + gap
    end

    if e.coach and e.coach.sentence then
      els[#els + 1] = UI.label("Then try: " .. e.coach.sentence, { x = pad, y = y, w = inner, h = lh("body") },
        { style = "body", color = "textSecondary", truncate = true })
      y = y + lh("body") + gap
    end

    y = y + theme.space.sm
    local r = theme.size.dot - 2
    local dotW = L.tone and (2 * r + theme.space.sm) or 0
    if L.tone then els[#els + 1] = UI.dot(pad + r, y + lh("body") / 2, L.tone, r) end
    els[#els + 1] = UI.label(L.status, { x = pad + dotW, y = y, w = inner - dotW, h = lh("body") },
      { style = "body", truncate = true })
    y = y + lh("body") + gap

    if L.stt then
      els[#els + 1] = UI.label("Speech to text heard: " .. L.stt, { x = pad, y = y, w = inner, h = lh("footnote") },
        { style = "footnote", color = "textSecondary", truncate = true })
      y = y + lh("footnote") + gap
    end

    y = y + theme.space.sm
    local hint = "hold space and speak · p hear it · m hear yourself · n next"
    if e.coach and e.coach.sentence then hint = hint .. " · s sentence" end
    els[#els + 1] = UI.label(hint, { x = pad, y = y, w = inner, h = lh("caption") },
      { style = "caption", color = "textTertiary" })
    y = y + lh("caption") + pad

    table.insert(els, 1, UI.backdrop(W, y, { radius = "lg" }))
    return els, y
  end

  local function draw()
    local L = M.lesson
    if not L then return end
    local els, h = layout(L)
    local frame = UI.place(hs.screen.mainScreen():frame(), W, h, "center")
    if not L.canvas then
      L.canvas, L.release = ui:surface("lesson", frame, { focusless = true, backdrop = false })
    else
      L.canvas:frame(frame)
    end
    L.canvas:replaceElements(unpack(els))
    L.canvas:show()
  end

  local function setStatus(text, tone)
    if not M.lesson then return end
    M.lesson.status, M.lesson.tone = text, tone
    draw()
  end

  -- ── Sound ────────────────────────────────────────────────────────────────
  local function stopSound()
    local L = M.lesson
    if L and L.soundStop then L.soundStop() end
    if L then L.soundStop = nil end
  end

  local function sayText(text, rate)
    stopSound()
    local task, release
    task, release = ctx:task(SAY, function() release() end,
      { "-v", setting("voice"), "-r", tostring(rate or 150), text })
    if M.lesson then M.lesson.soundStop = release end
    task:start()
  end

  local function playFile(path)
    stopSound()
    if not path or not hs.fs.attributes(path) then return false end
    local snd, release = ctx:sound(path)
    if not snd then return false end
    snd:play()
    if M.lesson then M.lesson.soundStop = release end
    return true
  end

  function M.playModel()
    local L = M.lesson
    if L then sayText(L.items[L.i].word, 140) end
  end

  function M.playSentence()
    local L = M.lesson
    local e = L and L.items[L.i]
    if e and e.coach and e.coach.sentence then sayText(e.coach.sentence, 160) end
  end

  -- Your last attempt at this word when there is one, else the slip itself.
  function M.playMine()
    local L = M.lesson
    if not L then return end
    if L.attempted and playFile(M.paths.attempt) then return end
    local clips = L.items[L.i].clips or {}
    if not playFile(clips[1]) then setStatus("No recording of this word yet", nil) end
  end

  -- ── Attempts ─────────────────────────────────────────────────────────────
  local nextItem

  local function score()
    local L = M.lesson
    local item = L.items[L.i]
    local at = L.i
    setStatus("Checking…", "working")
    M.ensureServer(function(ok, why)
      if not M.lesson or M.lesson.i ~= at then return end
      if not ok then return setStatus("Can't check yet · " .. tostring(why), "warning") end
      post("/score", { wav = M.paths.attempt, text = item.word }, function(code, res)
        if not M.lesson or M.lesson.i ~= at then return end
        if code ~= 200 or not res then
          return setStatus("Couldn't check that one · try again", "warning")
        end
        local passed, w = pron.attempt(res, item.word)
        if L.first == nil then
          L.first = passed
          pron.grade(M.state, item.word, passed, now())
          if passed then L.right = L.right + 1 end
          L.graded = L.graded + 1
          save()
        end
        local pct = w and math.floor((w.score or 0) * 100 + 0.5) or 0
        if passed then
          setStatus(string.format("Right · %d%%", pct), "success")
          ctx:after(1.6, function()
            if M.lesson and M.lesson.i == at then nextItem() end
          end)
        else
          L.tries = L.tries + 1
          local heard = w and w.heard and w.heard ~= "" and ("heard " .. pron.ipa(w.heard)) or "heard nothing"
          setStatus(string.format("Not quite · %s · %s", heard,
                                  L.tries >= MAX_TRIES and "n for the next word" or "try again"), "danger")
        end
      end)
    end)
    -- What the speech model makes of it, beside the score: the same check
    -- dictation would make. Optional, so a miss just leaves the line out.
    hs.http.asyncPost(STT .. "/transcribe", M.paths.attempt, { ["Content-Type"] = "text/plain" },
      function(code, body)
        if code == 200 and type(body) == "string" and not body:match("^__ERROR__")
           and M.lesson and M.lesson.i == at then
          M.lesson.stt = utils.truncate(utils.trim(body), 60)
          draw()
        end
      end)
  end

  function M.startAttempt()
    local L = M.lesson
    if not L or L.recording or L.status == "Checking…" then return end
    if dictating() then return setStatus("Dictation has the mic", "warning") end
    stopSound()
    os.remove(M.paths.attempt)
    L.stt = nil
    local task, release
    task, release = ctx:task(FFMPEG, function()
      release()
      if L.recording == task then L.recording = nil end
      if L.scoreOnExit and M.lesson == L then
        L.scoreOnExit, L.attempted = false, true
        score()
      end
    end, { "-y", "-f", "avfoundation", "-i", ":" .. mic(), "-ar", "16000", "-ac", "1", M.paths.attempt })
    L.recording, L.stopRecording, L.recStart = task, release, hs.timer.secondsSinceEpoch()
    task:start()
    setStatus("Listening… let go of space when you're done", "recording")
  end

  function M.stopAttempt()
    local L = M.lesson
    if not L or not L.recording then return end
    local long = hs.timer.secondsSinceEpoch() - L.recStart >= MIN_ATTEMPT
    L.scoreOnExit = long
    -- Through the task itself, not the release: the exit callback has to run
    -- to score the finished WAV.
    L.recording:terminate()
    if not long then setStatus("Hold space while you speak", nil) end
  end

  -- ── Lesson flow ──────────────────────────────────────────────────────────
  local function bindKeys(L)
    L.keys = {}
    local function bind(mods, key, pressed, released)
      L.keys[#L.keys + 1] = select(2, ctx:hotkey(mods, key, pressed, released))
    end
    bind({}, "space", M.startAttempt, M.stopAttempt)
    bind({}, "p", M.playModel)
    bind({}, "m", M.playMine)
    bind({}, "s", M.playSentence)
    bind({}, "n", function() nextItem() end)
    bind({}, "right", function() nextItem() end)
    bind({}, "escape", function() M.endLesson() end)
  end

  local function showItem()
    local L = M.lesson
    L.tries, L.first, L.attempted, L.stt = 0, nil, false, nil
    L.status, L.tone = "Listen, then hold space and say the word", nil
    draw()
    M.playModel()
  end

  nextItem = function()
    local L = M.lesson
    if not L then return end
    if L.recording then return end
    if L.i >= #L.items then return M.endLesson() end
    L.i = L.i + 1
    showItem()
  end

  function M.endLesson()
    local L = M.lesson
    if not L then return end
    M.lesson = nil
    stopSound()
    if L.stopRecording then L.stopRecording() end
    for _, release in ipairs(L.keys or {}) do release() end
    if L.release then L.release() end
    if L.graded > 0 then
      M.state.lastLesson = now()
      save()
      ui:toast(string.format("Lesson done · %d of %d right first time", L.right, L.graded),
               { tone = "success", seconds = 3 })
    end
    ctx:after(2, function() drain() end)
  end

  function M.startLesson()
    if M.lesson then return end
    if dictating() then return ui:toast("Finish dictating first", { tone = "warning" }) end
    local items = pron.lessonItems(M.state, now(), setting("lessonSize"))
    if #items == 0 then
      return ui:toast("Nothing to practise yet · keep dictating in English")
    end
    M.lesson = { items = items, i = 1, right = 0, graded = 0 }
    bindKeys(M.lesson)
    showItem()
    -- Warm the model while the first word plays.
    M.ensureServer(function(ok, why)
      if not ok and M.lesson then setStatus("The scorer isn't ready · " .. tostring(why), "warning") end
    end)
    coach(items, draw)
  end

  -- ── Reminder ─────────────────────────────────────────────────────────────
  local function remind()
    if M.lesson or not pron.shouldRemind(M.state, now()) then return end
    M.state.lastReminder = now()
    save()
    local st = pron.stats(M.state, now())
    ui:notify(string.format("%d words are ready to practise. Click to start a lesson.", st.due),
              { onClick = function() M.startLesson() end })
  end

  -- ── Menu ─────────────────────────────────────────────────────────────────
  local function patternRows()
    local rows = {}
    for _, p in ipairs(pron.patterns(M.state, 8)) do
      rows[#rows + 1] = menu.text(string.format("%s · %s", p.pattern,
        utils.truncate(table.concat(p.words, ", "), 50)))
    end
    if #rows == 0 then rows[1] = menu.text("Nothing yet") end
    return rows
  end

  local function wordRows()
    local rows, list = {}, pron.lessonItems(M.state, math.huge, 30)
    for _, e in ipairs(list) do
      local when = (e.due or 0) <= now() and "due" or os.date("%b %d", e.due)
      rows[#rows + 1] = menu.text(string.format("%s %s · box %d · %s", e.word, pron.ipa(e.expected), e.box, when))
    end
    if #rows == 0 then rows[1] = menu.text("Nothing yet") end
    return rows
  end

  -- The Pronunciation group of the Dictation tile.
  function M.menuRows()
    local st = pron.stats(M.state, now())
    local waiting = #inboxNames()
    local items = {
      menu.switch("Learn pronunciation from my dictation", setting("collect"), function()
        setSetting("collect", not setting("collect"))
      end),
      menu.text(string.format("%d words in practice · %d due · %d mastered", st.practising, st.due, st.mastered)),
    }
    if M.busy then
      items[#items + 1] = menu.text("Checking a take…")
    elseif waiting > 0 then
      items[#items + 1] = menu.text(string.format("%d takes waiting to be checked", waiting))
    end
    items[#items + 1] = menu.action(st.due > 0 and string.format("Start lesson · %d due", st.due) or "Practise now",
      function() M.startLesson() end, { disabled = st.practising == 0 })
    items[#items + 1] = menu.action("Check waiting takes now", function() drain() end,
      { disabled = waiting == 0 or M.busy })
    items[#items + 1] = menu.submenu("Sounds to work on", patternRows)
    items[#items + 1] = menu.submenu("Words in practice", wordRows)
    items[#items + 1] = menu.switch("Coaching tips from Claude", setting("coaching"), function()
      setSetting("coaching", not setting("coaching"))
    end)
    items[#items + 1] = menu.action("Open the pronunciation log", function() hs.execute("open -a Console " .. LOG) end)
    return items
  end

  -- ── Wiring ───────────────────────────────────────────────────────────────
  ctx:global("pronunciationLesson", function() M.startLesson() end)

  -- The scorer holds a gigabyte or so; it goes when nothing has used it for
  -- IDLE_S. Also the tick that checks for the weekly reminder.
  ctx:timer(60, function()
    if M.server and not M.lesson and not M.busy and not M.booting
       and hs.timer.secondsSinceEpoch() - M.lastUse > IDLE_S then
      logf("scorer idle for %ds; stopping it", IDLE_S)
      stopServer()
    end
    remind()
  end)
  ctx:atExit(stopServer)

  -- Takes that arrived before a reload are still in the inbox.
  ctx:after(20, function() drain() end)

  function M.stop()
    M.endLesson()
    stopServer()
  end

  return M
end
