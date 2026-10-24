-- Template: one line on what this plugin does.
--
-- Start a plugin from this file with `make plugin NAME=my_app`, which copies it
-- to apps/my_app/init.lua. It loads on the next reload; nothing else lists it.
--
-- Two rules keep every plugin switchable and every plugin looking the same:
--
--   1. Build through the context. ctx:timer, ctx:hotkey, ctx:task and the rest
--      are the hs.* constructors that also know how to undo themselves, which
--      is what lets the Plugins tile switch this off.
--
--   2. Draw through ctx:ui(). Pick a component: a toast for a message, a hud
--      for a state that holds, a bar for buttons, notify for Notification
--      Center, and the ui.menu rows for the tile. A surface is there for
--      drawing of your own. Never write a color, a font size or a corner
--      radius here: those live in lib/theme.lua, and that is what makes every
--      plugin look like one app.

local ctx  = require("lib.context").new("Template")
local ui   = ctx:ui()
local menu = require("lib.ui").menu

local M = { on = true, count = 0 }

M.tile = ctx:tile("Template")

local function refresh()
  M.tile:setTitle(M.on and "✨" or "✨💤")
  M.tile:setTooltip(string.format("Template · said hello %d times", M.count))
end

function M.hello()
  if not M.on then return end
  M.count = M.count + 1
  ui:toast("Hello from the template", { tone = "success" })
  refresh()
end

function M.busy()
  local _, hide = ui:hud("Working", { tone = "working" })
  ctx:after(1, hide)
end

-- A function, so the menu is built fresh each time the tile opens.
M.tile:setMenu(function()
  return {
    menu.switch("Enabled", M.on, function() M.on = not M.on; refresh() end),
    menu.text(string.format("Said hello %d times", M.count)),
    menu.separator(),
    menu.action("Say hello", M.hello, { disabled = not M.on }),
    menu.action("Show the HUD for a second", M.busy),
  }
end)
refresh()

function M.dispose() ctx:dispose() end

return M
