-- Keeps hs.eventtap taps alive — no hs.* dependency. macOS switches a global
-- event tap off without telling anyone: after sleep, when a callback is slow
-- under load, or while secure input is on. A dead Fn tap means dictation stops
-- until the next reload, so apps/dictation checks on a timer and on wake.

local M = {}

-- `taps` maps a name to an hs.eventtap. Restarts each one that reports itself
-- disabled and returns the names it restarted, sorted.
function M.rearm(taps)
  local names = {}
  for name, tap in pairs(taps or {}) do
    if tap and tap.isEnabled and not tap:isEnabled() then
      tap:start()
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

-- While a tap is off, Fn's key-up can be lost. True when the module still
-- believes Fn is held but the live modifier state says it is not.
function M.missedRelease(fnDown, mods)
  return fnDown == true and not (mods and mods.fn)
end

return M
