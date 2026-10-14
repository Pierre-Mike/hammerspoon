-- Quit guard: Cmd+W and Cmd+Q do nothing on the first press in the apps you
-- pick, and go through on a second press within a second. Windows App is
-- guarded out of the box, because Cmd+W there ends the Cloud PC session.
--
-- The rule itself is lib/quit_guard (pure, specced). This file owns the key
-- tap, the list of guarded apps in hs.settings, and the Quit guard tile, where
-- an app is added from the frontmost window or switched off again.
--
-- A swallowed key never reaches the app, so the remote Windows session does
-- not see Cmd+W either. That is the point: nothing closes.

local ctx      = require("lib.context").new("Quit guard")
local rule     = require("lib.quit_guard")
local tapGuard = require("lib.tap_guard")

local M = {}

M.SETTINGS_KEY = "quit_guard.apps"
local TAP_CHECK = 5   -- seconds between checks that macOS has not killed the tap

M.guarded = rule.toSet(hs.settings.get(M.SETTINGS_KEY))
M.last    = nil   -- the press most recently blocked, for the double-press rule
M.lastApp = nil   -- last frontmost app that is not Hammerspoon, for "Guard …"

local function save()
  hs.settings.set(M.SETTINGS_KEY, rule.toList(M.guarded))
end

local function nameFor(id)
  local ok, name = pcall(hs.application.nameForBundleID, id)
  return (ok and name) or id
end

-- ── The tap ────────────────────────────────────────────────────────────────
local function onKey(e)
  local app = hs.application.frontmostApplication()
  local press = {
    bundleID = app and app:bundleID(),
    key      = hs.keycodes.map[e:getKeyCode()],
    mods     = e:getFlags(),
    now      = hs.timer.secondsSinceEpoch(),
  }
  local verdict = rule.decide(M.guarded, M.last, press)
  if verdict == "pass" then return false end
  if verdict == "allow" then M.last = nil; return false end

  M.last = { bundleID = press.bundleID, key = press.key, at = press.now }
  hs.alert.closeAll()
  hs.alert.show(string.format("⌘%s blocked in %s · press again to %s",
    press.key:upper(), app:name(), press.key == "q" and "quit" or "close"), 1)
  return true
end

M.tap = ctx:eventtap(hs.eventtap.event.types.keyDown, onKey)
ctx:timer(TAP_CHECK, function() tapGuard.rearm({ keys = M.tap }) end)

-- Clicking the hub does not make Hammerspoon frontmost in every case, but when
-- it does, "Guard the frontmost app" must still mean the app you were just in.
ctx:watcher("application", function(_, event, app)
  if event == hs.application.watcher.activated and app
     and app:bundleID() ~= hs.processInfo.bundleID then
    M.lastApp = app
  end
end)

-- ── Tile ───────────────────────────────────────────────────────────────────
M.menu = ctx:tile("Quit guard")

local function refresh()
  local n = #rule.toList(M.guarded)
  M.menu:setTitle("🛡️")
  M.menu:setTooltip(n == 1 and "1 app guarded" or (n .. " apps guarded"))
end

function M.guard(id)   if id then M.guarded[id] = true; save(); refresh() end end
function M.unguard(id) M.guarded[id] = nil; save(); refresh() end

M.menu:setMenu(function()
  local items = { { title = "Cmd+W / Cmd+Q need a double press in:", disabled = true } }
  local list = rule.toList(M.guarded)
  for _, id in ipairs(list) do
    items[#items + 1] = { title = nameFor(id), switch = true, checked = true,
                          fn = function() M.unguard(id) end }
  end
  if #list == 0 then items[#items + 1] = { title = "(no apps)", disabled = true } end

  items[#items + 1] = { title = "-" }
  local front = hs.application.frontmostApplication()
  if front and front:bundleID() == hs.processInfo.bundleID then front = M.lastApp end
  local id = front and front:bundleID()
  if id and not M.guarded[id] then
    items[#items + 1] = { title = "Guard " .. front:name(), fn = function() M.guard(id) end }
  end
  return items
end)
refresh()

function M.dispose()
  ctx:dispose()
end

return M
