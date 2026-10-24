-- Template: one line on what this plugin does.
--
-- Start a plugin from this folder with `make plugin NAME=my_app`, which copies
-- it to apps/my_app/. It loads on the next reload; nothing else lists it.
-- plugin.lua next to this file is the manifest.
--
-- The file returns a function. The plugin system calls it with one object, and
-- everything built through that object is undone when the plugin is switched
-- off. Two rules keep every plugin switchable and every plugin looking alike:
--
--   1. Build through the plugin. plugin.ctx:timer, :hotkey, :task and the rest
--      are the hs.* constructors that also know how to undo themselves.
--
--   2. Draw through plugin.ui. Pick a component: a toast for a message, a hud
--      for a state that holds, a bar for buttons, notify for Notification
--      Center, and the ui.menu rows for the tile. Never write a color, a font
--      size or a corner radius here: those live in lib/theme.lua, and that is
--      what makes every plugin look like one app.

local menu = require("lib.ui").menu

return function(plugin)
  local ctx, ui = plugin.ctx, plugin.ui
  local M = { on = true, count = 0 }

  M.tile = plugin.tile()

  local function refresh()
    M.tile:setTitle(M.on and "✨" or "✨💤")
    M.tile:setTooltip(string.format("Template · said hello %d times", M.count))
  end

  function M.hello()
    if not M.on then return end
    M.count = M.count + 1
    ui:toast(plugin.settings.get("greeting"), { tone = "success" })
    refresh()
  end

  function M.busy()
    local _, hide = ui:hud("Working", { tone = "working" })
    ctx:after(1, hide)
  end

  -- Other code can run this as plugins.run("template.hello").
  plugin.action("hello", M.hello)

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

  -- Optional. Runs after this function returns, and again on each switch-on.
  function M.start() plugin.log("started") end
  -- Optional. Timers, tiles, hotkeys and the rest are already undone for you.
  function M.stop() plugin.log("stopped") end

  return M
end
