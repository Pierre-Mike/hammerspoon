-- Turn the Shokz OpenComm2 volume buttons into general-purpose triggers.
--
-- Why only the volume buttons: over plain Bluetooth the OpenComm2 gives macOS
-- very little to hook.
--   * Multifunction button — reaches the Mac through mediaremoted and is
--     delivered straight to the now-playing app. It never becomes a CGEvent,
--     so hs.eventtap cannot see it (measured: 3/3 presses toggled playback
--     while an eventtap on systemDefined logged nothing).
--   * Mute button — not transmitted to a computer at all without the Loop
--     dongle, and only does anything mid-call.
--   * Volume+ long press — this is the power button. It turns the headset off.
--   * Volume-/+ short press — changes the output device's volume, which IS
--     observable. That is what this module is built on.
--
-- This does not conflict with apps/volume_tap: that taps systemDefined media
-- keys (which the Logitech Zone's USB dongle emits), while the Shokz never
-- produces any, so the two never see the same event.

local gestures = require("lib.shokz_gestures")
local utils = require("lib.utils")

local LOG = "/tmp/hs-shokz.log"
local WINDOW = 0.6 -- seconds; both presses of a chord must land inside this

local M = { watchers = {}, enabled = true }

local function logf(fmt, ...) utils.logf(LOG, fmt, ...) end

-- ── Actions ────────────────────────────────────────────────────────────────
-- Remap these. Each fires on a net-zero volume chord, so the volume ends up
-- exactly where it started.
--
--   down_up : tap volume- then immediately volume+   (preferred — starts on
--             volume-, so a slip cannot become a volume+ long press, which is
--             the headset's power-off)
--   up_down : tap volume+ then immediately volume-
--
-- To wire one to dictation the way apps/volume_tap does:
--   local dictate = require("apps.dictation")
--   shokz.actions.down_up = function()
--     if dictate.isRecording() then dictate.stopVoice() else dictate.startSupervisorVoice() end
--   end
M.actions = {
  up_down = function() hs.alert.show("⬆⬇  Shokz: up→down", 1.2) end,
  down_up = function() hs.alert.show("⬇⬆  Shokz: down→up", 1.2) end,
}

-- ── Wiring ─────────────────────────────────────────────────────────────────
local recognize = gestures.newRecognizer(WINDOW)
local lastVol = nil

local function isShokz(dev)
  local n = dev and dev:name()
  return n ~= nil and n:match("Shokz") ~= nil
end

local function onVolumeChanged(dev)
  if not M.enabled or not isShokz(dev) then return end
  local v = dev:volume()
  if type(v) ~= "number" then return end -- nil while the profile is switching

  -- The watcher fires 5-6 times per change; only the first sees a real delta.
  if lastVol and math.abs(v - lastVol) < 0.001 then return end
  local prev = lastVol
  lastVol = v
  if not prev then return end

  local source = gestures.classify(v)
  local dir = (v > prev) and "up" or "down"
  local now = hs.timer.secondsSinceEpoch()

  -- Only headset presses drive gestures; the Mac's own volume keys stay normal.
  if source ~= "headset" then
    logf("t=%.3f vol %.3f → %.3f dir=%s source=%s (ignored)", now, prev, v, dir, source)
    return
  end

  local chord, state = recognize(dir, now)
  logf("t=%.3f vol %.3f → %.3f dir=%s source=%s gap=%s kept=%d%s",
    now, prev, v, dir, source,
    state.gap and string.format("%.3f", state.gap) or "-",
    state.n,
    chord and (" → GESTURE " .. chord) or "")

  if not chord then return end
  local fn = M.actions[chord]
  if fn then
    local ok, err = pcall(fn)
    if not ok then logf("action %s failed: %s", chord, tostring(err)) end
  end
end

-- A CoreAudio device watcher cannot be re-registered inside a single Hammerspoon
-- session: watcherStop() on one Lua wrapper does not detach the underlying
-- listener, and calling watcherCallback on a fresh wrapper for the same device
-- does not take over from it. Re-requiring this module therefore left the OLD
-- closure handling every volume change while the new one sat inert.
--
-- So register once per device and keep the registration in a global, then just
-- re-point the handler on reload. A full hs.reload() rebuilds the Lua state and
-- clears this anyway; the global only matters for a partial reload.
local REG = _G.__shokz_registration
if not REG then
  REG = { uid = nil, handler = nil }
  _G.__shokz_registration = REG
end

function M.attach()
  local dev = hs.audiodevice.defaultOutputDevice()
  if not isShokz(dev) then
    logf("default output is %s — Shokz not active, idle", dev and dev:name() or "nil")
    REG.handler = nil
    lastVol = nil
    return
  end
  lastVol = dev:volume()
  -- Always re-point, so a reloaded module owns the behaviour even when the
  -- existing registration is reused.
  REG.handler = function() onVolumeChanged(dev) end

  local uid = dev:uid()
  if REG.uid ~= uid then
    dev:watcherCallback(function(_, event)
      if event == "vmvc" and REG.handler then REG.handler() end
    end)
    dev:watcherStart()
    REG.uid = uid
    M.watchers = { dev }
    logf("attached to %s (vol=%.3f) [new registration]", dev:name(), lastVol or -1)
  else
    logf("attached to %s (vol=%.3f) [reused registration]", dev:name(), lastVol or -1)
  end
end

-- Re-attach when the headset connects, disconnects, or the default output moves
-- — including the A2DP↔HFP profile switch, which replaces the device object.
hs.audiodevice.watcher.setCallback(function(ev)
  if ev == "dOut" or ev == "dev#" then M.attach() end
end)
hs.audiodevice.watcher.start()

M.attach()
logf("shokz started (window=%.2fs)", WINDOW)

return M
