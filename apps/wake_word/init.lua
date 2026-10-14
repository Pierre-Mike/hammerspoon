-- Wake word: say "Codec" with no call open and the voice agent starts one.
--
-- This file does these things and nothing else:
--   • keeps a second ffmpeg tailing dictation's microphone into a raw file
--   • every 1.5 s, sends the last few seconds to dictation's Parakeet on :8765
--     when they are loud enough to be speech
--   • starts a call with POST /start on the voice agent's daemon when the
--     transcript has the word in it
--   • hands the agent whatever was said in front of the word, with POST /heard
--   • shows whether it is listening, and the switch, in the shared 🔨 hub
--
-- The rules — what counts as the word, which slice of audio to look at, when
-- to stay quiet — are all in lib/wake_word; this is the microphone, the timer
-- and the HTTP calls.
--
-- It sits beside apps/dictation because it lives on dictation's resources. The
-- microphone is a second ffmpeg on the same input device dictation uses, which
-- CoreAudio allows: this was measured capturing alongside a live agent call on
-- 2026-10-12, and nothing here takes the microphone away from anyone. The
-- transcription goes to the same warm STT server dictation runs, on the batch
-- route, which queues behind a live stream instead of preempting it, so a tick
-- that lands mid-dictation costs that take a few milliseconds and never its
-- transcript.
--
-- The voice agent is only the thing it wakes, and it is reached over HTTP: GET
-- /status to know whether a call is open, POST /start, POST /heard. Nothing
-- else crosses. apps/voice_agent is looked up, never required: it is symlinked
-- in from another repo and may not be installed, and when it is not loaded the
-- microphone closes and the tile says why. A call started with no supervisor
-- would have no menu bar and no hotkey to end it.
--
-- A call opened this way starts with the sentence the word was part of, not
-- with the silence after it. The capture that heard "Codec" also holds the
-- seconds in front of it, so once /start answers — which is when the session's
-- own microphone opens — that whole span is transcribed and posted to /heard.
-- See sendPreroll.
--
-- Everything this file builds belongs to its context: the capture, the tick
-- and the tile. M.dispose() gives all of it back, and with it the microphone.

local ww = require("lib.wake_word")
local utils = require("lib.utils")

local ctx = require("lib.context").new("Wake word")

local FFMPEG = "/opt/homebrew/bin/ffmpeg"
-- Same variable the daemon reads (PARAKEET_URL in voice_agent/config.py), and
-- the same server apps/dictation runs on :8765. One model, one process, three
-- callers.
local STT = os.getenv("PARAKEET_URL") or "http://127.0.0.1:8765"
-- Same variable the daemon and apps/voice_agent read (VOICE_AGENT_PORT), so
-- moving the port moves all three at once.
local PORT = tonumber(os.getenv("VOICE_AGENT_PORT")) or 8792
local BASE = "http://127.0.0.1:" .. PORT

-- `polled` is the daemon's state as this app last heard it, nil before the
-- first answer. `lastState` and `callEndedAt` exist for one edge: the moment a
-- call closes, when the window is still full of it. `lastFired` is when the
-- word last started a call, so the overlapping window cannot start a second one
-- on the same utterance. `agentAway` is set while apps/voice_agent is not
-- loaded, so its going and coming back are each logged once.
local M = { tile = nil, capture = nil, stopCapture = nil, timer = nil,
            polled = nil, polling = false, lastState = nil, callEndedAt = nil,
            lastFired = nil, agentAway = false, title = nil }

-- The capture and the two clips cut from it, read from lib/wake_word when this
-- file loads. A spec points those at scratch paths before requiring it, since
-- starting the capture deletes the old file and the live one is in use.
M.paths = { raw = ww.RAW, wav = ww.WAV, preroll = ww.PREROLL_WAV }

local function logf(fmt, ...) utils.logf(ww.LOG, fmt, ...) end

function M.enabled()
  return ww.enabled(hs.settings.get(ww.SETTING))
end

-- ── Neighbours ─────────────────────────────────────────────────────────────
-- Both looked up in package.loaded on every use rather than required: requiring
-- would load a plugin the user switched off, and a re-enabled plugin is a new
-- table.

local function agentPlugin()
  local va = package.loaded["apps.voice_agent"]
  return type(va) == "table" and va or nil
end

-- Wrapped: this is read on every tick, and a dictation that threw must not take
-- the wake word down with it. No dictation reads as not dictating, which is
-- the truth: nothing else is holding the microphone.
local function dictating()
  local dict = package.loaded["apps.dictation"]
  if type(dict) ~= "table" or type(dict.isRecording) ~= "function" then return false end
  local answered, recording = pcall(dict.isRecording)
  return answered and recording == true
end

-- Whichever microphone dictation is set to, so the two always hear the same
-- room and the Dictate menu stays the one place a microphone is chosen. Falls
-- back to the system input, then to avfoundation's first audio device.
local function mic()
  local dict = package.loaded["apps.dictation"]
  if type(dict) == "table" and type(dict.micName) == "string" and dict.micName ~= "" then
    return dict.micName
  end
  local ok, name = pcall(function() return hs.audiodevice.defaultInputDevice():name() end)
  if ok and type(name) == "string" and name ~= "" then return name end
  return "0"
end

local function callState()
  return ww.callState(M.polled, agentPlugin())
end

-- ── Tile ───────────────────────────────────────────────────────────────────
-- Called on every tick, so the hub is only told when something changed.
local function render()
  if not M.tile then return end
  local row = ww.menu(M.enabled(), callState(), dictating(), M.capture ~= nil)
  if row.title == M.title then return end
  M.title = row.title
  M.tile:setTitle(ww.GLYPH[row.state])
  M.tile:setTooltip(row.title)
end

-- ── Capture ────────────────────────────────────────────────────────────────
local function stopCapture()
  if M.stopCapture then M.stopCapture() end
  M.capture, M.stopCapture = nil, nil
end

-- One long-lived ffmpeg appending 16 kHz mono PCM to RAW. Restarted when the
-- file gets big (see the tick) rather than rotated in place: ffmpeg owns that
-- handle, and truncating a file underneath a writer appending to it only leaves
-- a hole where the audio was.
local function startCapture()
  stopCapture()
  if not hs.fs.attributes(FFMPEG) then
    logf("no ffmpeg at %s; wake word cannot listen", FFMPEG)
    return
  end
  os.remove(M.paths.raw)
  local device = mic()
  local capture, done
  capture, done = ctx:task(FFMPEG, function(code, _, err)
    done()
    if M.capture == capture then M.capture, M.stopCapture = nil, nil end
    -- Code 0 is a rotation or a dispose; anything else is worth the log line,
    -- since a wake word that silently stopped listening looks identical to one
    -- that is listening and never hears the word.
    if code ~= 0 then
      logf("capture exited code=%d%s", code, err and err ~= "" and (": " .. err:sub(1, 160)) or "")
    end
  end, ww.captureArgs(device, M.paths.raw))
  M.capture, M.stopCapture = capture, done
  capture:start()
  logf("listening on %q for %q", device, ww.WORD)
end

-- The microphone is open only while it could lead somewhere: switched on, and
-- with apps/voice_agent loaded to supervise the call. Called at load and on
-- every tick; the agent plugin's going and coming back are edges, so each is
-- logged once and a capture that failed to start is not retried every tick.
local function syncAgent()
  if not M.enabled() then return end
  local present = agentPlugin() ~= nil
  if not present and not M.agentAway then
    M.agentAway = true
    logf("apps.voice_agent is not loaded; nothing to wake, so the microphone is closed")
    stopCapture()
  elseif present and M.agentAway then
    M.agentAway = false
    logf("apps.voice_agent is loaded again")
    startCapture()
  end
end

-- ── The daemon ─────────────────────────────────────────────────────────────
-- Asked once a tick, and the answer is used by the next one: a tick does not
-- wait on it. One request at a time, so a daemon that hangs does not collect a
-- queue of them.
local function poll()
  if M.polling then return end
  M.polling = true
  hs.http.asyncGet(BASE .. "/status", nil, function(code, body, _)
    M.polling = false
    M.polled = ww.daemonState(code, body)
  end)
end

-- When a call closes, the window is still full of it. Noted on the tick that
-- first sees the call gone, which is at most a poll late: settling only waits
-- longer for it.
local function noteCallEnd(state, now)
  if M.lastState == "live" and state ~= "live" then M.callEndedAt = now end
  M.lastState = state
end

-- Hand the agent what the user said before its microphone was open. `text` is
-- already the finished utterance (ww.utterance); a daemon too old to have the
-- route says 404 and the call simply carries on without it.
local function sendHeard(text)
  local body = hs.json.encode({ text = text })
  hs.http.asyncPost(BASE .. "/heard", body, { ["Content-Type"] = "application/json" },
    function(code, respBody, _)
      if code == 404 then
        logf("daemon has no /heard route; restart it to pick up the preroll")
        return
      end
      if code ~= 200 then
        logf("daemon refused the preroll: %s %s", tostring(code), tostring(respBody):sub(1, 120))
        return
      end
      logf("preroll %q", text)
    end)
end

-- The preroll, read once the call's own microphone is live.
--
-- `startByte` is where the window that heard the wake word began, so the span
-- read here runs from before the sentence to the moment /start answered. That
-- is the whole of what the session cannot hear for itself: everything earlier
-- is in this clip, everything later is going into the live pipeline. Cutting
-- at the daemon's answer rather than at a timer is what keeps the two from
-- overlapping or leaving a hole.
--
-- `fallback` is the window transcript that matched the wake word in the first
-- place. It is already paid for and it already holds the sentence, so a second
-- transcription that fails costs the start gap and nothing more.
local function sendPreroll(startByte, fallback)
  local function giveUp(why)
    local text = ww.utterance(fallback)
    logf("preroll fell back to the window transcript (%s)", why)
    if text then sendHeard(text) end
  end

  local f = io.open(M.paths.raw, "rb")
  if not f then return giveUp("no capture file") end
  local size = f:seek("end")
  local offset, length = ww.preroll(size, startByte)
  local pcm
  if offset then
    f:seek("set", offset)
    pcm = f:read(length)
  end
  f:close()
  if not pcm or #pcm < 2 then return giveUp("nothing captured") end

  local out = io.open(M.paths.preroll, "wb")
  if not out then return giveUp("cannot write the clip") end
  out:write(ww.wavHeader(#pcm))
  out:write(pcm)
  out:close()

  hs.http.asyncPost(STT .. "/transcribe", M.paths.preroll, {}, function(code, body, _)
    if code ~= 200 or type(body) ~= "string" then
      return giveUp("STT answered " .. tostring(code))
    end
    -- Prefer the longer clip, but only when it still has the wake word in it.
    -- A transcript that lost the word is a transcript of something else —
    -- a rotation mid-flight, or a span so long the model dropped the front —
    -- and the window that did match is the better answer.
    if not ww.match(body) then return giveUp("the longer clip lost the wake word") end
    local text = ww.utterance(body)
    if not text then
      logf("nothing said before %q; opening the call listening", ww.WORD)
      return
    end
    logf("preroll over %.1fs: %q", #pcm / ww.BYTES_PER_S, text)
    sendHeard(text)
  end)
end

-- Ask the agent to start. Deliberately /start and not /toggle: /toggle on a
-- call that is already open would close it, and "Codec" must never be the word
-- that hangs up.
--
-- `startByte` is where the matching window began in the capture file, carried
-- through from the tick so the preroll can be read from the same place the
-- wake word was heard.
local function wakeStart(heard, startByte)
  local now = hs.timer.secondsSinceEpoch()
  if not ww.fire(now, M.lastFired) then return end
  -- The state may have moved while the transcription was in flight.
  if not ww.listening(M.enabled(), callState(), dictating(),
                      ww.settled(now, M.callEndedAt)) then return end
  M.lastFired = now
  logf("heard %q in %q", ww.WORD, heard)
  hs.alert.show(ww.WORD .. " — starting a call", 1.2)
  hs.http.asyncPost(BASE .. "/start", "{}", { ["Content-Type"] = "application/json" },
    function(code, body, _)
      -- /start answers with the same payload as /status, so the call is known
      -- to be live from here rather than from the next poll.
      M.polled = ww.daemonState(code, body)
      -- The agent's menu bar polls slowly while idle and did not see this
      -- request go by, so it is asked to look now rather than show 🎙 over an
      -- open call for up to ten seconds.
      local va = agentPlugin()
      if va and type(va.refresh) == "function" then pcall(va.refresh) end
      if code ~= 200 then
        logf("daemon refused /start: %s %s", tostring(code), tostring(body):sub(1, 120))
        return
      end
      -- The preroll is read now because this is when the session's own
      -- microphone opens: everything up to here is ours to pass on, everything
      -- after it the session hears for itself.
      sendPreroll(startByte, heard)
    end)
end

-- One look at the last few seconds of the capture. Cheap when the room is
-- quiet: a file read and some arithmetic, and the STT server is never touched.
local function tick()
  syncAgent()
  render()
  if not M.enabled() or M.agentAway then return end
  poll()
  local now = hs.timer.secondsSinceEpoch()
  local state = callState()
  noteCallEnd(state, now)
  local f = io.open(M.paths.raw, "rb")
  if not f then return end
  local size = f:seek("end")
  local offset, length = ww.window(size)
  local pcm
  if offset then
    f:seek("set", offset)
    pcm = f:read(length)
  end
  f:close()
  -- Checked on every tick, listening or not: the capture keeps running through
  -- calls and dictation takes, so it keeps growing through them too.
  if ww.needsRotate(size) then
    logf("capture file reached %.0f MB; starting a fresh one", size / 1048576)
    startCapture()
    return
  end
  if not ww.listening(true, state, dictating(), ww.settled(now, M.callEndedAt)) then return end
  if not pcm or #pcm < 2 then return end
  if ww.rms(pcm) < ww.RMS_FLOOR then return end
  local out = io.open(M.paths.wav, "wb")
  if not out then return end
  out:write(ww.wavHeader(#pcm))
  out:write(pcm)
  out:close()
  -- The body is the path, which is what POST /transcribe takes
  -- (parakeet_server.py). Nothing is uploaded; both processes read the same
  -- disk.
  hs.http.asyncPost(STT .. "/transcribe", M.paths.wav, {}, function(code, body, _)
    if code ~= 200 or type(body) ~= "string" then return end
    -- `offset` goes with the transcript: it is where this window started, and
    -- the preroll is read from there once the call is up.
    if ww.match(body) then wakeStart(body, offset) end
  end)
end

-- The menu's one write. The capture follows the setting immediately so that
-- switching the wake word off also closes the microphone, rather than leaving
-- it open on a feature the user just said no to.
function M.set(on)
  hs.settings.set(ww.SETTING, on and true or false)
  logf("switched %s", on and "on" or "off")
  M.agentAway = false
  if on then
    if agentPlugin() then startCapture() else syncAgent() end
  else
    stopCapture()
  end
  render()
end

function M.toggle() M.set(not M.enabled()) end

-- ── Wiring ─────────────────────────────────────────────────────────────────
M.tile = ctx:tile("Wake word")
if M.tile then
  M.tile:setMenu(function()
    -- The tick is ticked when the wake word is switched on; the words after the
    -- colon say whether it is actually listening right now, which is a
    -- different question while a call is open or dictation has the microphone.
    local row = ww.menu(M.enabled(), callState(), dictating(), M.capture ~= nil)
    return {
      { title = row.title, switch = true, checked = row.checked, fn = function() M.toggle() end },
      { title = "-" },
      { title = "Open log", fn = function() hs.execute("open -a Console " .. ww.LOG) end },
    }
  end)
end

-- On by default, so a fresh install hears the word without being told to. The
-- tick runs whether or not capture is up: it is also what notices a capture
-- that has grown too big, and it costs a failed io.open when there is none.
if M.enabled() then
  if agentPlugin() then startCapture() else syncAgent() end
end
M.timer = ctx:timer(ww.TICK_S, tick)
render()

-- Switch the plugin off: the capture, the tick and the tile, and with the
-- capture the microphone.
function M.dispose()
  -- Before ctx:dispose, which would also kill the capture: this clears the
  -- handles too, so a re-enabled plugin does not find a dead task in M.
  stopCapture()
  ctx:dispose()
  M.tile, M.timer, M.title = nil, nil, nil
  M.polled, M.polling, M.lastState, M.callEndedAt, M.lastFired = nil, false, nil, nil, nil
  M.agentAway = false
end

return M
