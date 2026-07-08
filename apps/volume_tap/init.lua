-- Voice control for the Orchestrator.
--   START recording: either
--     (a) press the bound Logitech button   (RECORD_KEYCODE, preferred), or
--     (b) long-press volume-DOWN >= HOLD     (fallback — no accidental double-tap)
--   STOP recording: single volume-UP  → stop + send transcript
--
-- Why the change: the old double-tap volume-DOWN fired constantly by accident.
-- Volume keys are NSSystemDefined events; decode with e:systemKey().
-- Reuses the dictation pipeline (ffmpeg → parakeet → zellij write-chars).

-- ── Trigger config ─────────────────────────────────────────────────────────
-- Set RECORD_KEYCODE to the keycode your Logitech button emits, then reload.
-- Capture it with: see /tmp/hs-capture.log (run the capture eventtap), or
--   hs -c 'hs.eventtap.new({hs.eventtap.event.types.keyDown},function(e) print(e:getKeyCode()) return false end):start()'
-- Until set (nil), the long-press volume-DOWN fallback is the trigger.
local RECORD_KEYCODE = nil
local HOLD = 0.6   -- seconds volume-DOWN must be held to start recording

local dictate = require("apps.dictation")

local M = { holdTimer = nil }

local LOG = "/tmp/hs-volume-tap.log"
local function logf(fmt, ...)
  local f = io.open(LOG, "a")
  if f then f:write(os.date("%H:%M:%S "), string.format(fmt, ...), "\n"); f:close() end
end

local function startRecord(src)
  if dictate.isRecording() then return end
  logf("%s → start supervisor voice", src)
  dictate.startSupervisorVoice()
end

-- ── Logitech button (keyDown) ────────────────────────────────────────────────
M.keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
  if not RECORD_KEYCODE then return false end
  if e:getKeyCode() ~= RECORD_KEYCODE then return false end
  if dictate.isRecording() then return false end
  startRecord("logitech-button")
  return true   -- swallow so the button does nothing else
end)

-- ── Volume keys (systemDefined): long-press DOWN = start, UP = stop ───────────
M.tap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(e)
  local d = e:systemKey()
  if not d or d.repeated then return false end

  if d.key == "SOUND_DOWN" then
    if dictate.isRecording() then return false end
    if d.down then
      -- arm a hold timer; if released before HOLD, it's a normal volume change
      if M.holdTimer then M.holdTimer:stop() end
      M.holdTimer = hs.timer.doAfter(HOLD, function()
        M.holdTimer = nil
        startRecord("long-press-down")
      end)
      return false   -- let the first volume tick through
    else
      -- key released: cancel pending hold (it was a short press)
      if M.holdTimer then M.holdTimer:stop(); M.holdTimer = nil end
      return false
    end

  elseif d.key == "SOUND_UP" then
    if d.down and dictate.isRecording() then
      logf("up → stop + send")
      dictate.stopVoice()
      return true   -- swallow: don't bump volume mid-send
    end
    return false

  elseif d.key == "PLAY" then
    -- Logitech Zone headset button mapped to Play/Pause → use as a toggle.
    -- Map Double-press → Play/Pause in Logi software; set Short-press to an
    -- inert function (Headset Status Report) so it can't fire by accident.
    if d.down then
      if dictate.isRecording() then
        logf("PLAY → stop + send")
        dictate.stopVoice()
      else
        startRecord("headset-play")
      end
      return true   -- swallow so media playback isn't toggled
    end
    return false
  end

  return false
end)

M.tap:start()
M.keyTap:start()
logf("volume_tap started (RECORD_KEYCODE=%s HOLD=%.2f)", tostring(RECORD_KEYCODE), HOLD)

return M
