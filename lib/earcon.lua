-- Earcons: short audible cues for dictation start/stop.
--
-- Why this module exists: when the operator triggers dictation while looking
-- away from the screen, there is no visual confirmation that mic capture has
-- actually begun. A crisp system-sound "tink" on start and a softer "pop" on
-- stop makes the state audible without going through the pocket-tts /speak
-- pipeline (which queues, synthesises, and adds ~hundreds of ms of latency).
--
-- Pure logic lives here (config resolution + kind→spec mapping). The impure
-- playback (hs.sound.getByName / hs.sound.soundFromFile / :play()) is injected
-- via a `player` table so this module is unit-testable without Hammerspoon.

local M = {}

-- Resolve the sound reference for a given event kind from a config table
-- shaped like lib/config.EARCONS:
--
--   { enabled = true, START = "Tink", STOP = "Pop", SENT = "Submarine",
--     VOLUME = 0.45 }
--
-- The kind is a lowercase string ("start", "stop", "sent", …) that is
-- uppercased to look up the slot in cfg — so future events can be added by
-- just adding a new UPPERCASE key to the config table.
--
-- Returns either:
--   { kind = "system", ref = <name>,  volume = <n> }   -- macOS system sound
--   { kind = "file",   ref = <path>,  volume = <n> }   -- absolute path on disk
--   nil                                                -- disabled / no sound
--
-- Guarantees: never throws, never blocks, never touches hs.*.
function M.resolve(cfg, kind)
  if not cfg then return nil end
  if cfg.enabled == false then return nil end
  if type(kind) ~= "string" or kind == "" then return nil end
  local name = cfg[kind:upper()]
  if type(name) ~= "string" or name == "" then return nil end
  local vol = cfg.VOLUME
  if type(vol) ~= "number" then vol = 1.0 end
  if vol < 0 then vol = 0 elseif vol > 1 then vol = 1 end
  if name:sub(1, 1) == "/" then
    return { kind = "file", ref = name, volume = vol }
  end
  return { kind = "system", ref = name, volume = vol }
end

-- Dispatch the resolved cue to the injected player. `player` is a table with
-- optional keys:
--   player.system(name, volume)  -- play a macOS system sound by name
--   player.file(path,   volume)  -- play a file at an absolute path
--
-- Returns true when a cue was dispatched, false otherwise. Non-blocking is the
-- caller's responsibility (hs.sound:play() is non-blocking by default).
function M.play(cfg, kind, player)
  local spec = M.resolve(cfg, kind)
  if not spec or not player then return false end
  if spec.kind == "system" and type(player.system) == "function" then
    player.system(spec.ref, spec.volume)
    return true
  end
  if spec.kind == "file" and type(player.file) == "function" then
    player.file(spec.ref, spec.volume)
    return true
  end
  return false
end

return M
