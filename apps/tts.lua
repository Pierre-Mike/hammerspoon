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
  local text  = core.dequeue(M.queue)
  local myGen = M.gen
  updateMenu()
  hs.http.asyncPost(cfg.POCKET_TTS_BASE .. "/speak", text,
    { ["X-Voice"] = M.voice, ["Content-Type"] = "text/plain; charset=utf-8" },
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

-- Public: queue text for speech. Returns the new queue length (0 if nothing to say).
function M.speak(text)
  if not M.enabled then logf("[tts] disabled, dropping"); return 0 end
  local chunks = core.splitSentences(text)
  if #chunks == 0 then return 0 end
  local n = core.enqueue(M.queue, chunks)
  logf("[tts] +%d chunk(s), queue=%d", #chunks, n)
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

-- ---- HTTP intake (the service other apps post to) -------------------------
local intake = hs.httpserver.new()
intake:setPort(cfg.TTS_PORT)
intake:setCallback(function(method, path, _headers, body)
  if method == "POST" and path == "/speak" then
    local n = M.speak(body or "")
    return (n > 0 and "queued\n" or "empty\n"), 200, {}
  elseif method == "POST" and path == "/stop" then
    M.stop()
    return "stopped\n", 200, {}
  elseif path == "/status" then
    local s = string.format('{"speaking":%s,"queued":%d,"enabled":%s,"voice":"%s"}\n',
      tostring(M.speaking), #M.queue, tostring(M.enabled), M.voice)
    return s, 200, { ["Content-Type"] = "application/json" }
  end
  return "ok\n", 200, {}
end)
intake:start()
logf("[tts] intake listening on http://127.0.0.1:%s", tostring(cfg.TTS_PORT))

-- ---- CLI + URL entry points ----------------------------------------------
-- Global so `hs -c 'speak("hi there")'` works from any shell/app.
_G.speak = function(text) return M.speak(text) end
_G.speakStop = function() return M.stop() end

-- open 'hammerspoon://speak?text=hi%20there&voice=marius'
hs.urlevent.bind("speak", function(_evt, params)
  if params.voice and params.voice ~= "" then M.voice = params.voice end
  M.speak(params.text or "")
end)
hs.urlevent.bind("speakStop", function() M.stop() end)

-- ---- menu bar -------------------------------------------------------------
M.menu = hs.menubar.new()
if M.menu then
  M.menu:setMenu(function()
    return {
      { title = M.speaking and "Speaking…" or "Idle",
        disabled = true },
      { title = "Queued: " .. #M.queue, disabled = true },
      { title = "-" },
      { title = "Stop", fn = function() M.stop() end },
      { title = M.enabled and "Disable" or "Enable",
        fn = function() M.enabled = not M.enabled; if not M.enabled then M.stop() end; updateMenu() end },
      { title = "Speak clipboard",
        fn = function() M.speak(hs.pasteboard.getContents() or "") end },
      { title = "-" },
      { title = "Voice: " .. M.voice, disabled = true },
      { title = "Restart voice server", fn = function() M.restartServer() end },
    }
  end)
  updateMenu()
end

-- ---- warm pocket-tts server lifecycle -------------------------------------
local function launchServer()
  M.server = hs.task.new(cfg.POCKET_TTS_PY, function(code, _out, err)
    logf("[tts] server exited code=%s err=%s", tostring(code), tostring(err))
    M.server = nil
  end, { cfg.POCKET_TTS_SERVER })
  M.server:setEnvironment({
    HOME = os.getenv("HOME"),
    PATH = "/opt/homebrew/bin:/usr/bin:/bin",
    POCKET_TTS_PORT     = tostring(cfg.POCKET_TTS_PORT),
    POCKET_TTS_VOICE    = M.voice,
    POCKET_TTS_LANGUAGE = cfg.TTS_LANGUAGE,
  })
  M.server:start()
  logf("[tts] launching warm pocket-tts server (voice=%s, lang=%s)", M.voice, cfg.TTS_LANGUAGE)
end

-- Free the port first so a reload doesn't stack a second worker on it.
function M.restartServer()
  if M.server then M.server:terminate(); M.server = nil end
  local k = hs.task.new("/bin/sh", function() launchServer() end,
    { "-c", string.format("lsof -ti :%d | xargs kill -9 2>/dev/null; true", cfg.POCKET_TTS_PORT) })
  k:start()
end

M.restartServer()

return M
