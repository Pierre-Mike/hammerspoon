require("hs.ipc")  -- enables `hs -c '<lua>'` from a shell
-- A killed `hs -c` must not break print for every plugin: see lib/ipc_guard.lua.
require("lib.ipc_guard").install(hs.ipc)

-- Plugins find themselves: anything under apps/ with an init.lua, and any single
-- .lua file there, is loaded. Dropping a folder in is enough — this file does not
-- name it — and a plugin that throws on require now fails alone instead of taking
-- down everything after it in a require list.
--
-- The list below is only the ones whose sequence matters. It is also tile order,
-- because menuhub draws in load order, so it keeps the hub reading the way it
-- always has. Anything not named here loads after them, alphabetically.
local plugins = require("lib.plugins")

plugins.loadAll({
  "dictation",
  "brown_noise",
  "noseguard",
  "tts",
  "lmstudio",
  "dsh",
  "shokz_mute",
  "keystroke_typer",
  -- Beside the typer: dictation calls both, and the bar types through it.
  "text_actions",
  "ovis_ocr",
  -- Before voice_agent, which is the thing that leases the public address:
  -- the service reads better above its caller in the hub.
  "tailscale_funnel",
  -- Symlinked in by ~/Github/pipecat-voice-agent/hammerspoon/install.sh. On a
  -- fresh clone of this repo it is simply not there, and discovery skips it
  -- rather than this file having to ask.
  "voice_agent",
})

-- The Plugins tile: switch one off, or see which failed, without editing a file.
plugins.install()
