-- Where the notch is, for anything that hangs from it: the karaoke island and
-- the hub panel.
--
-- Hammerspoon has no API for the notch. What it can see is the menu bar: about
-- 37 pt tall on a notched MacBook, against 24 to 30 on every other screen. On
-- a screen without a notch, the same spot (the middle of the menu bar) stands
-- in for it, so a plugin never has to ask which kind of screen it is on.
--
-- Everything here is pure except screenUnder, so it is tested headless.

local M = {}

-- The notch on a 14" and a 16" MacBook Pro is about 200 pt wide. The hit
-- target on a screen without one is narrower, because the middle of an
-- ordinary menu bar can hold a long app menu.
M.WIDTH      = 200
M.BARE_WIDTH = 160

function M.hasNotch(name, full, frame)
  return tostring(name or ""):find("Built%-in") ~= nil and (frame.y - full.y) >= 32
end

-- How tall the menu bar is, which on a notched screen is how far down the
-- notch reaches. An auto-hidden menu bar reports none, so 24 stands in.
function M.barHeight(full, frame)
  local h = frame.y - full.y
  return h > 0 and h or 24
end

-- A w × h frame centred on the top edge of `full` (an hs.screen fullFrame).
function M.frame(full, w, h)
  return { x = full.x + math.floor((full.w - w) / 2), y = full.y, w = w, h = h }
end

-- The notch itself, or the middle of the menu bar on a screen without one:
-- the rectangle a click there should land in.
function M.target(name, full, frame)
  local notch = M.hasNotch(name, full, frame)
  return M.frame(full, notch and M.WIDTH or M.BARE_WIDTH, M.barHeight(full, frame)), notch
end

-- The screen the pointer is on, else the main one: where a hotkey should open
-- something, since the hand is already there.
function M.screenUnder()
  local ok, s = pcall(function() return hs.mouse.getCurrentScreen() end)
  if ok and s then return s end
  return hs.screen.mainScreen()
end

return M
