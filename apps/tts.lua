-- TTS service: a spoken-text queue any app can post to.
--
-- Other apps hand text to Hammerspoon three ways; all funnel into one FIFO queue
-- that plays serially so nothing talks over itself:
--   • HTTP    curl -sX POST localhost:8790/speak -d 'hello there'
--   • CLI     hs -c 'speak("hello there")'
--   • URL     open 'hammerspoon://speak?text=hello%20there'
--
-- Pipeline per chunk:  text → pocket-tts warm server (:8791) → WAV path → afplay.
-- Long text is split into sentences up front (lib/tts_core) and enqueued as
-- separate chunks, so playback starts after the first sentence instead of after
-- the whole blob synthesises. Voice/quality come from Kyutai pocket-tts running
-- on CPU; this module is just the queue, the intake, and the playback plumbing.
--
-- The server's default is to stream the audio as it is generated, which is how
-- apps/voice_agent hears its first syllable about a second sooner. Notifications
-- stay on files: afplay wants a path, and a notification nobody is waiting on
-- does not need the second back.
--
-- This module also owns the lifecycle of a *second* pocket-tts server, on 8793,
-- running the French model for apps/voice_agent. Nothing spoken here goes to it:
-- notifications are English and stay on 8791. See the bottom of the file.

local core  = require("lib.tts_core")
local utils = require("lib.utils")
local cfg   = require("lib.config")

local LOG = "/tmp/hs-tts.log"
local function logf(fmt, ...) utils.logf(LOG, fmt, ...) end

local M = {
  queue    = {},
  speaking = false,
  enabled  = true,
  gen      = 0,            -- bumped on stop; in-flight callbacks compare against it
  voice    = cfg.TTS_VOICE,
  playTask = nil,
  server   = nil,
  menu     = nil,
}

-- Resolve a caller's selector to a concrete pocket-tts voice.
--   nil/""      -> the current default (M.voice)
--   profile key -> its mapped voice (cfg.TTS_PROFILES)
--   anything else -> used verbatim (a raw voice name or a path/hf:// URL to clone)
function M.resolveVoice(sel)
  if not sel or sel == "" then return M.voice end
  return (cfg.TTS_PROFILES and cfg.TTS_PROFILES[sel]) or sel
end

-- forward declarations (drain/play reference each other and the menu)
local drain, play, updateMenu

function updateMenu()
  if not M.menu then return end
  local q = #M.queue
  local icon = (not M.enabled) and "🔇" or (M.speaking and "🗣️" or "🔊")
  M.menu:setTitle(q > 0 and (icon .. tostring(q)) or icon)
end

function play(path, myGen)
  M.playTask = hs.task.new(cfg.AFPLAY, function(_code)
    M.playTask = nil
    M.speaking = false
    if myGen == M.gen then drain() end
    updateMenu()
  end, { path })
  M.playTask:start()
  updateMenu()
end

function drain()
  if M.speaking or not M.enabled or #M.queue == 0 then return end
  M.speaking = true
  local item  = core.dequeue(M.queue)      -- { text = <chunk>, voice = <resolved voice> }
  local myGen = M.gen
  updateMenu()
  -- X-Format: path asks the server for a finished WAV on disk instead of its
  -- default audio stream. afplay cannot read a growing file, and hs.http hands
  -- back a whole response rather than chunks, so there is nothing here that
  -- could consume the stream. The voice agent takes the streaming path.
  hs.http.asyncPost(cfg.POCKET_TTS_BASE .. "/speak", item.text,
    { ["X-Voice"] = item.voice or M.voice, ["X-Format"] = "path",
      ["Content-Type"] = "text/plain; charset=utf-8" },
    function(status, body, _headers)
      if myGen ~= M.gen then M.speaking = false; return end   -- stopped mid-synth
      body = utils.trim(body)
      if status ~= 200 or not body or body == "" or body:match("^__ERROR__") then
        logf("[tts] synth miss status=%s body=%s", tostring(status), tostring(body))
        M.speaking = false
        drain()                                               -- skip this chunk, keep going
        return
      end
      play(body, myGen)
    end)
end

-- Public: queue text for speech in a chosen voice. `sel` is a profile key, a raw
-- voice name, a clone path/URL, or nil (default voice). Returns the new queue
-- length (0 if nothing to say).
function M.speak(text, sel)
  if not M.enabled then logf("[tts] disabled, dropping"); return 0 end
  local chunks = core.splitSentences(text)
  if #chunks == 0 then return 0 end
  local voice = M.resolveVoice(sel)
  local items = {}
  for _, c in ipairs(chunks) do items[#items + 1] = { text = c, voice = voice } end
  local n = core.enqueue(M.queue, items)
  logf("[tts] +%d chunk(s) voice=%s, queue=%d", #chunks, voice, n)
  updateMenu()
  drain()
  return n
end

-- Public: stop now — cancel playback, drop everything queued, ignore in-flight synth.
function M.stop()
  M.gen = M.gen + 1
  local dropped = core.clear(M.queue)
  if M.playTask then M.playTask:terminate(); M.playTask = nil end
  M.speaking = false
  logf("[tts] stop (dropped %d)", dropped)
  updateMenu()
end

-- ---- speak the current selection (Fn+S) -----------------------------------
-- macOS exposes no "give me the selected text" API, so we borrow the clipboard:
-- press ⌘C, read what landed, put the user's clipboard back. The pasteboard's
-- changeCount is what tells us a copy actually happened — polling for it is why
-- an empty selection stays silent instead of re-speaking a stale clipboard.
local SEL = cfg.TTS_SELECTION or {}

-- Grab everything currently on the pasteboard and return a closure that puts it
-- back. readAllData keeps non-text flavours (images, rich text) intact; the
-- getContents path is the fallback for Hammerspoon builds without it.
local function snapshotPasteboard()
  local ok, data = pcall(hs.pasteboard.readAllData)
  if ok and type(data) == "table" and next(data) ~= nil then
    return function() pcall(hs.pasteboard.writeAllData, data) end
  end
  local text = hs.pasteboard.getContents()
  return function()
    if text ~= nil then pcall(hs.pasteboard.setContents, text) end
  end
end

-- Public: copy the selection and queue it for speech. `sel` overrides the voice
-- (defaults to the read-aloud profile in cfg.TTS_SELECTION.PROFILE).
function M.speakSelection(sel)
  -- One grab at a time: a held Fn+S auto-repeats, and overlapping grabs race on
  -- the pasteboard, so the restore could put back another grab's copy instead of
  -- what the user had.
  if M.selecting then return end
  M.selecting = true
  local poll    = SEL.POLL or 0.03
  local timeout = SEL.TIMEOUT or 0.45
  local before  = hs.pasteboard.changeCount()
  local restore = snapshotPasteboard()

  -- One tick of delay: we are normally called from inside a keyDown eventtap,
  -- and a synthetic ⌘C posted from within that callback can be swallowed.
  -- Timers live on M: an unreferenced hs.timer can be collected mid-poll.
  M.selStart = hs.timer.doAfter(poll, function()
    M.selStart = nil
    hs.eventtap.keyStroke({ "cmd" }, "c", 0)
    local waited = 0
    M.selPoll = hs.timer.doEvery(poll, function()
      waited = waited + poll
      local landed = hs.pasteboard.changeCount() ~= before
      if not landed and waited < timeout then return end
      M.selPoll:stop(); M.selPoll = nil
      M.selecting = false

      local text = core.selectionText(landed and hs.pasteboard.getContents() or nil, landed)
      restore()
      if not text then
        logf("[tts] selection: nothing to speak (copy landed=%s)", tostring(landed))
        hs.alert.show("nothing selected")
        return
      end
      logf("[tts] selection: %d chars", #text)
      hs.alert.show("🔊 " .. utils.truncate(core.sanitize(text), 60))
      M.speak(text, sel or SEL.PROFILE)
    end)
  end)
end

-- ---- HTTP intake (the service other apps post to) -------------------------
-- Kept on M (not a bare local): an unreferenced hs.httpserver gets garbage-
-- collected after load and silently stops listening on the port.
M.intake = hs.httpserver.new()
M.intake:setPort(cfg.TTS_PORT)
M.intake:setCallback(function(method, headers, path, body)
  -- hs.httpserver passes (method, path, headers, body) in some versions and
  -- (method, headers, path, body) in others; detect which arg is the path.
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" then
    path, headers = headers, path
  end
  local route = path:match("^[^?]*")                 -- strip ?query for routing
  local query = path:match("%?(.*)$") or ""
  headers = headers or {}

  -- Voice selector: header X-Profile / X-Voice wins, else ?profile= / ?voice=.
  local function param(name)
    local v = query:match("[?&]?" .. name .. "=([^&]*)") or query:match("^" .. name .. "=([^&]*)")
    return v and utils.urldecode(v) or nil
  end
  local sel = headers["X-Profile"] or headers["X-Voice"] or param("profile") or param("voice")

  if method == "POST" and route == "/speak" then
    local n = M.speak(body or "", sel)
    return (n > 0 and "queued\n" or "empty\n"), 200, {}
  elseif route == "/stop" then
    -- Method-agnostic: stop carries no body, and hs.httpserver rejects a
    -- bodyless POST with 400 before the callback runs — so `curl .../stop`
    -- (a GET) must work too.
    M.stop()
    return "stopped\n", 200, {}
  elseif route == "/voices" then
    local keys = {}
    for k, v in pairs(cfg.TTS_PROFILES or {}) do keys[#keys + 1] = string.format('"%s":"%s"', k, v) end
    table.sort(keys)
    return "{" .. table.concat(keys, ",") .. "}\n", 200, { ["Content-Type"] = "application/json" }
  elseif route == "/status" then
    local s = string.format('{"speaking":%s,"queued":%d,"enabled":%s,"voice":"%s"}\n',
      tostring(M.speaking), #M.queue, tostring(M.enabled), M.voice)
    return s, 200, { ["Content-Type"] = "application/json" }
  end
  return "ok\n", 200, {}
end)
M.intake:start()
logf("[tts] intake listening on http://127.0.0.1:%s", tostring(cfg.TTS_PORT))

-- ---- CLI + URL entry points ----------------------------------------------
-- Global so `hs -c 'speak("hi there")'` works from any shell/app.
-- Second arg picks a voice: profile key, raw voice name, or clone path.
--   hs -c 'speak("build passed", "code")'   hs -c 'speak("hi", "marius")'
_G.speak = function(text, sel) return M.speak(text, sel) end
_G.speakStop = function() return M.stop() end
-- Same thing Fn+S does, without the chord — handy for testing from a shell.
_G.speakSelection = function(sel) return M.speakSelection(sel) end

-- open 'hammerspoon://speak?text=hi%20there&profile=alerts'  (or &voice=marius)
hs.urlevent.bind("speak", function(_evt, params)
  M.speak(params.text or "", params.profile or params.voice)
end)
hs.urlevent.bind("speakStop", function() M.stop() end)
hs.urlevent.bind("speakSelection", function(_evt, params)
  M.speakSelection((params or {}).profile or (params or {}).voice)
end)

-- ---- menu bar -------------------------------------------------------------
M.menu = require("lib.menuhub").item("Speech queue")
if M.menu then
  M.menu:setMenu(function()
    -- Submenu: pick the default voice by profile (sorted, tick the current one).
    local keys = {}
    for k in pairs(cfg.TTS_PROFILES or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    local voiceItems = {}
    for _, k in ipairs(keys) do
      local v = cfg.TTS_PROFILES[k]
      voiceItems[#voiceItems + 1] = {
        title = string.format("%s (%s)", k, v),
        checked = (M.voice == v),
        fn = function() M.voice = v; updateMenu() end,
      }
    end
    return {
      { title = M.speaking and "Speaking…" or "Idle", disabled = true },
      { title = "Queued: " .. #M.queue, disabled = true },
      { title = "-" },
      { title = "Stop", fn = function() M.stop() end },
      { title = M.enabled and "Disable" or "Enable",
        fn = function() M.enabled = not M.enabled; if not M.enabled then M.stop() end; updateMenu() end },
      { title = "Speak selection  (Fn+S)",
        fn = function() M.speakSelection() end },
      { title = "Speak clipboard",
        fn = function() M.speak(hs.pasteboard.getContents() or "") end },
      { title = "-" },
      { title = "Default voice: " .. M.voice, menu = voiceItems },
      { title = "Restart voice servers", fn = function() M.restartServer() end },
    }
  end)
  updateMenu()
end

-- ---- warm pocket-tts server lifecycle -------------------------------------
-- Two instances of one script, because a pocket-tts process holds exactly one
-- model and the model — not the voice name — decides the phonetics. French read
-- by the English model gets every word right and every sound wrong, whichever of
-- the 26 voices you pick. So the French model runs beside the English one rather
-- than replacing it, and notifications keep the voice they have always had.
--
-- The French instance exists for apps/voice_agent, which posts French replies to
-- it directly. It is optional by design: if it never comes up, the agent
-- synthesises on the English server instead and logs that once.
local INSTANCES = {
  {
    key      = "server",
    name     = "english",
    port     = cfg.POCKET_TTS_PORT,
    language = cfg.TTS_LANGUAGE,
    out      = cfg.POCKET_TTS_OUT,
    log      = "/tmp/hs-pocket-tts.log",
    voice    = function() return M.voice end,          -- follows the menu bar picker
  },
  {
    key      = "frServer",
    name     = "french",
    port     = cfg.POCKET_TTS_FR_PORT,
    language = cfg.TTS_LANGUAGE_FR,
    out      = cfg.POCKET_TTS_FR_OUT,
    log      = "/tmp/hs-pocket-tts-fr.log",
    voice    = function() return cfg.TTS_VOICE_FR end,
  },
}

-- Held on M: an unreferenced hs.task can be collected before its callback runs.
M.killTasks = {}

local function launchServer(inst)
  local voice = inst.voice()
  -- Routed through sh so model-load progress lands in a file. The first run of a
  -- new language downloads several hundred megabytes, and without a log
  -- "still downloading" is indistinguishable from "broken". `exec` matters:
  -- without it terminate() kills the shell and leaves Python holding the port.
  local cmd = string.format("mkdir -p %q && exec %q %q >> %q 2>&1",
    inst.out, cfg.POCKET_TTS_PY, cfg.POCKET_TTS_SERVER, inst.log)
  -- Only clear the handle if it is still ours: a restart terminates the old
  -- server, whose callback lands after the new one is stored here.
  local task
  task = hs.task.new("/bin/sh", function(code, _out, err)
    logf("[tts] %s server exited code=%s err=%s", inst.name, tostring(code), tostring(err))
    if M[inst.key] == task then M[inst.key] = nil end
  end, { "-c", cmd })
  M[inst.key] = task
  M[inst.key]:setEnvironment({
    HOME = os.getenv("HOME"),
    PATH = "/opt/homebrew/bin:/usr/bin:/bin",
    PYTHONUNBUFFERED    = "1",
    POCKET_TTS_PORT     = tostring(inst.port),
    POCKET_TTS_VOICE    = voice,
    POCKET_TTS_LANGUAGE = inst.language,
    POCKET_TTS_OUT      = inst.out,
  })
  M[inst.key]:start()
  logf("[tts] launching pocket-tts %s server (port=%d, voice=%s, lang=%s, log=%s)",
    inst.name, inst.port, voice, inst.language, inst.log)
end

-- Free the port first so a reload doesn't stack a second worker on it.
--
-- Kill the listener, never ourselves. A bare `lsof -ti :PORT` also matches
-- sockets whose *remote* port is PORT, and Hammerspoon holds one of those every
-- time it posts a chunk of text to be spoken — the same pattern took Hammerspoon
-- down from apps/voice_agent before it was fixed there.
local function restartOne(inst)
  local pending = M.killTasks[inst.key]
  if pending and pending:isRunning() then return end   -- a restart is already underway
  if M[inst.key] then M[inst.key]:terminate(); M[inst.key] = nil end
  local killCmd = string.format(
    "lsof -tiTCP:%d -sTCP:LISTEN | grep -vx %d | xargs kill -9 2>/dev/null; true",
    inst.port, hs.processInfo.processID)
  M.killTasks[inst.key] = hs.task.new("/bin/sh", function() launchServer(inst) end,
    { "-c", killCmd })
  M.killTasks[inst.key]:start()
end

function M.restartServer()
  for _, inst in ipairs(INSTANCES) do restartOne(inst) end
end

M.restartServer()

return M
