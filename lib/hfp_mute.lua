-- Read a Bluetooth headset's mute button. Pure parsing, no hs.* dependency;
-- the wiring lives in apps/shokz_mute.
--
-- This corrects an assumption once recorded in the since-removed apps/shokz:
-- that the OpenComm2 mute button "is not transmitted to a computer at all
-- without the Loop dongle". It is. It travels over plain Bluetooth as an HFP
-- microphone-gain command (AT+VGM) on the service-level connection, and
-- bluetoothd writes one decoded line per press:
--
--   ... [com.apple.bluetooth:Server.Handsfree] Received mic gain event
--       from device A0:0C:E2:A1:75:75 - new gain is 0
--
-- Gain 0 is muted, anything above 0 is unmuted. Measured over 12 presses in
-- two runs: 12 events, no misses, no duplicates, exact alternation. Unlike reading
-- the volume buttons through volume changes, this needs no classification,
-- because the button reports absolute state rather than a nudge.
--
-- The headset also mutes in hardware: with the button down the input device
-- measures -84 dBFS, which is silence. So Teams can show you as live while
-- nobody hears you, and that gap is what apps/shokz_mute closes.
--
-- Do not read this from CoreAudio instead. macOS does mirror the gain onto the
-- input device's volume, but it does not hold: the level runs 1.0 -> 0.0 ->
-- 0.0099 -> 1.0 within 15 ms, so a poll sees nothing and a property listener
-- sees a meaningless bounce. The log line is the only stable form.

local M = {}

-- Filter inside the logging subsystem rather than in Lua. bluetoothd is very
-- chatty (21 MB of debug output in three minutes when unfiltered) and the
-- predicate keeps all of that out of this process.
M.PREDICATE = table.concat({
  'subsystem == "com.apple.bluetooth"',
  'category == "Server.Handsfree"',
  'eventMessage CONTAINS "mic gain event"',
}, " AND ")

-- argv for /usr/bin/log. Kept next to the parser so the two cannot drift.
function M.logArgs()
  return { "stream", "--style", "compact", "--predicate", M.PREDICATE }
end

-- Returns { mac = string, gain = number, muted = boolean }, or nil when the
-- line is not a mute report.
function M.parseLine(line)
  if type(line) ~= "string" then return nil end
  local mac, gain = line:match(
    "Received mic gain event from device ([%x:]+) %- new gain is (%d+)")
  if not mac then return nil end
  gain = tonumber(gain)
  return { mac = mac, gain = gain, muted = (gain == 0) }
end

-- A nil address means "any headset". Addresses are compared case-insensitively
-- because bluetoothd prints them uppercase while hs.audiodevice does not.
function M.matches(ev, mac)
  if not mac then return true end
  if not ev or not ev.mac then return false end
  return ev.mac:lower() == mac:lower()
end

return M
