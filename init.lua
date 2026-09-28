require("hs.ipc")  -- enables `hs -c '<lua>'` from a shell

require("apps.dictation")
require("apps.brown_noise")
require("apps.volume_tap")
require("apps.noseguard")
require("apps.tts")
require("apps.shokz")        -- before voice_agent, which claims one of its chords
require("apps.shokz_mute")

-- Symlinked in by ~/Github/pipecat-voice-agent/hammerspoon/install.sh; absent on
-- a fresh clone of this repo, so only loaded when installed.
if hs.fs.attributes(hs.configdir .. "/apps/voice_agent/init.lua") then require("apps.voice_agent") end
