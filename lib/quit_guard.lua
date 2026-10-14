-- Decides what Cmd+W and Cmd+Q do in an app that must not be closed by a slip
-- of the hand — no hs.* dependency. In Windows App, Cmd+W is muscle memory for
-- "close this tab" and instead ends the whole Cloud PC session.
--
-- A guarded app swallows the first press and lets a second press of the same
-- chord through if it lands within WINDOW seconds, so quitting on purpose
-- still works without opening a menu.

local M = {}

M.WINDOW = 1.0

-- Windows App, the Cloud PC / Remote Desktop client.
M.DEFAULTS = { "com.microsoft.rdc.macos" }

-- Shift is allowed, because Cmd+Shift+W closes every window. Ctrl and Alt are
-- not: Cmd+Alt+W and friends are other shortcuts and not this one.
local function isCloseChord(key, mods)
  mods = mods or {}
  return (key == "w" or key == "q") and mods.cmd == true
     and not mods.ctrl and not mods.alt and not mods.fn
end

-- `guarded` is a set of bundle IDs. `last` is the press that was blocked most
-- recently, { bundleID, key, at }, or nil. `p` is the press being decided:
-- { bundleID, key, mods, now }. Returns "pass" (not ours), "block" (swallow
-- it), or "allow" (the confirming second press, let it through).
function M.decide(guarded, last, p)
  if not (p.bundleID and guarded[p.bundleID]) then return "pass" end
  if not isCloseChord(p.key, p.mods) then return "pass" end
  if last and last.bundleID == p.bundleID and last.key == p.key
     and p.now - last.at <= M.WINDOW then
    return "allow"
  end
  return "block"
end

-- hs.settings stores lists, the tap wants a set. Anything that is not a list is
-- a first run or a corrupt value, and both mean the defaults.
function M.toSet(list)
  if type(list) ~= "table" then list = M.DEFAULTS end
  local set = {}
  for _, id in ipairs(list) do set[id] = true end
  return set
end

function M.toList(set)
  local list = {}
  for id, on in pairs(set) do if on then list[#list + 1] = id end end
  table.sort(list)
  return list
end

return M
