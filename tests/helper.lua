-- Loaded by busted before any spec (tests/.busted).
--
-- The plugins log to fixed paths under /tmp (/tmp/hs-dictate.log,
-- /tmp/hs-voice-agent.log, ...), and those are the logs read when something
-- goes wrong on this Mac. A spec that loads a plugin writes there too, so a
-- test run used to leave "voice_agent started" ten times and a dictation take
-- that said "bonjour" in the middle of the real history. Every open of an
-- hs-*.log goes to one scratch file instead, whichever way the plugin opens it:
-- through lib/utils.logf or with its own io.open.

local scratch = os.tmpname()
local realOpen = io.open

io.open = function(path, mode)
  if type(path) == "string" and path:match("^/tmp/hs%-[^/]*%.log$") then
    return realOpen(scratch, mode)
  end
  return realOpen(path, mode)
end
