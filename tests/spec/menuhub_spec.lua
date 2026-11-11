_G.hs = require("hs")
local hub = require("lib.menuhub")

describe("menuhub.build", function()
  it("labels a row with the app's live title then its name", function()
    local rows = hub.build({ { name = "Noise", title = "🔊", click = function() end } })
    assert.equals("🔊  Noise", rows[1].title)
  end)

  it("uses the bare name when the title is empty", function()
    local rows = hub.build({ { name = "Dictation", title = "", icon = "IMG", menu = {} } })
    assert.equals("Dictation", rows[1].title)
    assert.equals("IMG", rows[1].image)
  end)

  it("resolves a function menu into a submenu at build time", function()
    local calls = 0
    local rows = hub.build({ { name = "TTS", menu = function() calls = calls + 1; return { { title = "Stop" } } end } })
    assert.equals(1, calls)
    assert.equals("Stop", rows[1].menu[1].title)
  end)

  it("turns a click callback into the row action", function()
    local clicked = false
    local rows = hub.build({ { name = "Noise", click = function() clicked = true end } })
    rows[1].fn()
    assert.is_true(clicked)
    assert.is_nil(rows[1].menu)
  end)

  it("disables a row with neither menu nor click", function()
    local rows = hub.build({ { name = "Idle" } })
    assert.is_true(rows[1].disabled)
  end)

  it("appends the footer after a separator", function()
    local rows = hub.build({ { name = "A" } }, { { title = "Reload" } })
    assert.equals("-", rows[2].title)
    assert.equals("Reload", rows[3].title)
  end)
end)

describe("menuhub.item", function()
  -- The panel hangs from the notch, so no app puts anything in the menu bar.
  it("adds nothing to the menu bar and keeps registration order", function()
    local made = 0
    local realNew = hs.menubar.new
    hs.menubar.new = function() made = made + 1; return realNew() end
    hub.entries = {}

    local a = hub.item("First"):setTitle("1")
    hub.item("Second"):setTooltip("tip")

    assert.equals(0, made)
    assert.equals("First", hub.entries[1].name)
    assert.equals("1", a:title())
    assert.equals("tip", hub.entries[2].tooltip)
    hs.menubar.new = realNew
  end)

  it("delete removes only that app's row", function()
    hub.entries = {}
    local a = hub.item("A")
    hub.item("B")
    a:delete()
    assert.equals(1, #hub.entries)
    assert.equals("B", hub.entries[1].name)
  end)
end)

describe("menuhub.statusOf", function()
  it("drops a prefix that repeats the app name", function()
    assert.equals("Ready, microphone off", hub.statusOf("Voice agent", "Voice agent: ready, microphone off\nmodel: x"))
    assert.equals("Parakeet · 0.6b", hub.statusOf("Dictation", "Dictate · parakeet · 0.6b"))
  end)

  it("keeps a prefix that is its own label", function()
    assert.equals("Headset: live", hub.statusOf("Shokz mute", "Headset: live\nTeams: connected"))
  end)

  it("returns nil without a tooltip", function()
    assert.is_nil(hub.statusOf("Noise", nil))
    assert.is_nil(hub.statusOf("Noise", ""))
  end)
end)

describe("menuhub.tiles", function()
  it("prefers the title glyph, falls back to the encoded icon", function()
    local t = hub.tiles({
      { name = "Noise", title = "🟤", click = function() end },
      { name = "Dictation", title = "", icon = "IMG", menu = {} },
      { name = "Idle" },
    }, function(img) return "data:" .. img end)
    assert.same({ "🟤", nil, "click" }, { t[1].glyph, t[1].image, t[1].kind })
    assert.same({ nil, "data:IMG", "menu" }, { t[2].glyph, t[2].image, t[2].kind })
    assert.equals("none", t[3].kind)
    assert.equals(3, t[3].index)
  end)
end)

describe("menuhub.items", function()
  it("classifies each kind of menu row", function()
    local rows = hub.items({
      { title = "Touches today: 3", disabled = true },
      { title = "-" },
      { title = "Stop watching", fn = function() end },
      { title = "Tight", checked = true, fn = function() end },
      { title = "Loose", checked = false, fn = function() end },
      { title = "Voice", menu = {} },
      { title = "Later", fn = function() end, disabled = true },
    })
    local kinds = {}
    for _, r in ipairs(rows) do kinds[#kinds + 1] = r.kind end
    assert.same({ "info", "sep", "act", "check", "check", "sub", "act" }, kinds)
    assert.is_true(rows[4].checked)
    assert.is_false(rows[5].checked)
    assert.is_true(rows[7].disabled)
    assert.is_nil(rows[1].disabled)
  end)
end)

describe("menuhub.resolve / model", function()
  local entry = { name = "TTS", menu = function()
    return { { title = "Stop", fn = function() end },
             { title = "Default voice", menu = { { title = "alba", checked = true, fn = function() end } } } }
  end }

  it("walks into a submenu and names the path", function()
    local menu, crumbs = hub.resolve(entry, { 2 })
    assert.equals("alba", menu[1].title)
    assert.same({ "Default voice" }, crumbs)
  end)

  it("returns nil for a path the app no longer has", function()
    assert.is_nil(hub.resolve(entry, { 1 }))
    assert.is_nil(hub.resolve(entry, { 9 }))
  end)

  it("builds a detail model whose back button names the level above", function()
    local m = hub.model({ entry }, { entry = entry, path = { 2 } })
    assert.equals("detail", m.view)
    assert.equals("Default voice", m.title)
    assert.same({ "TTS" }, m.crumbs)
    assert.equals(2, m.depth)
    local top = hub.model({ entry }, { entry = entry, path = {} })
    assert.same({}, top.crumbs)
    assert.equals("Stop", top.items[1].title)
  end)

  it("falls back to the grid when the viewed app is gone", function()
    local m = hub.model({}, { entry = entry, path = {} })
    assert.equals("home", m.view)
  end)
end)

describe("menuhub.items hand-drawn ticks", function()
  local fn = function() end

  it("turns a ✓/space-padded run into check rows", function()
    local rows = hub.items({
      { title = "Nose zone", disabled = true },
      { title = "    Tight (13 mm)", fn = fn },
      { title = "  ✓ Medium (17 mm)", fn = fn },
      { title = "-" },
      { title = "Test flash", fn = fn },
    })
    assert.same({ "check", "Tight (13 mm)", false }, { rows[2].kind, rows[2].title, rows[2].checked })
    assert.same({ "check", "Medium (17 mm)", true }, { rows[3].kind, rows[3].title, rows[3].checked })
    assert.equals("act", rows[5].kind)
  end)

  it("leaves unpadded neighbours of a lone tick as actions", function()
    local rows = hub.items({
      { title = "✓ Log detection detail", fn = fn },
      { title = "Test flash", fn = fn },
    })
    assert.same({ "check", true }, { rows[1].kind, rows[1].checked })
    assert.equals("act", rows[2].kind)
  end)
end)

describe("menuhub.items switch and slider", function()
  it("reads a switch row and a clamped slider row", function()
    local rows = hub.items({
      { title = "Play", switch = true, checked = true, fn = function() end },
      { title = "Volume", slider = { value = 140, min = 0, max = 100, unit = "%", fn = function() end } },
    })
    assert.same({ "switch", true }, { rows[1].kind, rows[1].checked })
    assert.same({ "slider", 100, 0, 100, 1, "%" },
      { rows[2].kind, rows[2].value, rows[2].min, rows[2].max, rows[2].step, rows[2].unit })
  end)

  it("treats a switch without an action as info", function()
    assert.equals("info", hub.items({ { title = "Play", switch = true } })[1].kind)
  end)
end)

-- The panel's colors live in lib/theme, not in the HTML, so the hub and the
-- overlays cannot drift apart.
describe("menuhub.themed", function()
  it("puts the theme's variables where the panel's marker is", function()
    local out = hub.themed("<style>/*@theme*/ body {}</style>")
    assert.is_nil(out:find("@theme", 1, true))
    assert.truthy(out:find(require("lib.theme").islandCss(), 1, true))
  end)

  it("ships a panel that carries the marker", function()
    local f = assert(io.open(hub.PANEL_HTML, "r"))
    local html = f:read("*a"); f:close()
    assert.truthy(html:find("/*@theme*/", 1, true))
    -- Nothing left over from before: the panel names no accent of its own.
    assert.is_nil(html:find("--accent:", 1, true))
  end)
end)

describe("menuhub.glance", function()
  it("draws a widget's items, and its own title when it gives one", function()
    local out = hub.glance({
      { name = "Clock", render = function()
          return { { label = "Tokyo", clock = "Asia/Tokyo" }, { label = "Jobs", value = 3, detail = "running" } }
        end },
      { name = "Queue", render = function() return { title = "Print queue", items = { { value = "Empty" } } } end,
        click = function() end },
    })
    assert.same({ label = "Tokyo", clock = "Asia/Tokyo" }, out[1].items[1])
    assert.same({ label = "Jobs", value = "3", detail = "running" }, out[1].items[2])
    assert.equals("Clock", out[1].title)
    assert.is_false(out[1].click)
    assert.equals("Print queue", out[2].title)
    assert.is_true(out[2].click)
    assert.equals(2, out[2].index)
  end)

  it("keeps a widget that throws to one line, not the panel", function()
    local out = hub.glance({
      { name = "Broken", render = function() error("boom") end },
      { name = "Fine", render = function() return { { value = "ok" } } end },
    })
    assert.equals("Couldn't draw", out[1].items[1].label)
    assert.truthy(out[1].items[1].detail:find("boom", 1, true))
    assert.equals("ok", out[2].items[1].value)
  end)

  it("puts widgets on the grid and not in an app's menu", function()
    local entry = { name = "TTS", menu = { { title = "Stop", fn = function() end } } }
    local widgets = { { name = "W", render = function() return {} end } }
    assert.equals(1, #hub.model({ entry }, nil, nil, widgets).widgets)
    assert.is_nil(hub.model({ entry }, { entry = entry, path = {} }, nil, widgets).widgets)
  end)
end)

describe("menuhub.widget", function()
  before_each(function() hub.widgets = {} end)

  it("registers in order and deletes only itself", function()
    local a = hub.widget("A", function() return {} end)
    hub.widget("B", function() return {} end, { every = 5 })
    assert.same({ "A", "B" }, { hub.widgets[1].name, hub.widgets[2].name })
    a:delete()
    assert.equals(1, #hub.widgets)
    assert.equals("B", hub.widgets[1].name)
  end)

  it("ticks at the shortest interval any widget asked for", function()
    assert.is_nil(hub.tickEvery({ { name = "A" } }))
    assert.equals(2, hub.tickEvery({ { every = 10 }, { every = 2 }, {} }))
  end)

  it("leaves with the plugin's context", function()
    local ctx = require("lib.context").new("Test")
    ctx:widget("Mine", function() return {} end)
    assert.equals(1, #hub.widgets)
    ctx:dispose()
    assert.equals(0, #hub.widgets)
  end)
end)

-- The panel hangs from the top edge, centred on the notch.
describe("menuhub.place", function()
  it("starts the content below the notch on a notched screen", function()
    local frame, top = hub.place({ name = "Built-in Retina Display",
      full = { x = 0, y = 0, w = 1512, h = 982 }, frame = { x = 0, y = 38, w = 1512, h = 944 } }, 360, 400)
    assert.same({ x = 576, y = 0, w = 360, h = 400 }, frame)
    assert.equals(38, top)
  end)

  it("hangs from the menu bar's middle on a screen without one", function()
    local frame, top = hub.place({ name = "LG UltraFine",
      full = { x = 1512, y = -300, w = 2560, h = 1440 }, frame = { x = 1512, y = -275, w = 2560, h = 1415 } }, 360, 2000)
    -- Taller than asked for is capped at most of the screen, then scrolls.
    assert.same({ x = 1512 + 1100, y = -300, w = 360, h = math.floor(1440 * 0.8) }, frame)
    assert.equals(0, top)
  end)
end)

-- Keys reach the panel through a tap, so the tap decides what it may take.
describe("menuhub.keyName", function()
  it("names the keys the panel acts on", function()
    assert.equals("Escape", hub.keyName(53, "\27", {}))
    assert.equals("Enter", hub.keyName(36, "\r", {}))
    assert.equals("Backspace", hub.keyName(51, "\127", {}))
    assert.equals("n", hub.keyName(45, "n", {}))
    assert.equals("é", hub.keyName(14, "é", {}))
  end)

  it("lets through anything held with Cmd, Ctrl or Option, and keys with no text", function()
    assert.is_nil(hub.keyName(50, "`", { cmd = true }))
    assert.is_nil(hub.keyName(8, "c", { ctrl = true }))
    assert.is_nil(hub.keyName(45, "n", { alt = true }))
    assert.is_nil(hub.keyName(123, "", {}))
  end)

  it("takes Tab to move to a console, and Cmd+V to paste into it", function()
    assert.equals("Tab", hub.keyName(48, "\t", {}))
    assert.equals("Paste", hub.keyName(9, "v", { cmd = true }))
    assert.is_nil(hub.keyName(9, "v", { cmd = true, alt = true }))
  end)
end)

-- A third of the screen while it is open, with as many columns as fit.
describe("menuhub.size", function()
  local panel = { width = 360, columns = 2, pad = 14 }

  it("takes a third of the screen and fits columns beside the sidebar", function()
    local w, columns = hub.size({ w = 1728 }, panel)
    assert.equals(576, w)
    assert.equals(2, columns)
    w, columns = hub.size({ w = 3440 }, panel)
    assert.equals(1146, w)
    assert.equals(5, columns)
  end)

  it("never goes below the design's width or columns", function()
    assert.same({ 360, 2 }, { hub.size({ w = 900 }, panel) })
    assert.same({ 440, 3 }, { hub.size({ w = 900 }, { width = 440, columns = 3, pad = 14 }) })
  end)
end)

describe("menuhub.glance consoles", function()
  it("draws a widget with submit as a console", function()
    local out = hub.glance({ { name = "Claude", submit = function() end, render = function()
      return { lines = { { who = "you", text = "hi" }, { who = "reply", text = "Hello" }, { who = "bogus", text = 3 } },
               prompt = "Ask", status = "Thinking…", busy = true }
    end } })
    local c = out[1]
    assert.equals("console", c.kind)
    assert.same({ { who = "you", text = "hi" }, { who = "reply", text = "Hello" }, { who = "note", text = "3" } }, c.lines)
    assert.same({ "Ask", "Thinking…", true }, { c.prompt, c.status, c.busy })
  end)

  it("keeps an ordinary widget a glance", function()
    assert.equals("glance", hub.glance({ { name = "W", render = function() return {} end } })[1].kind)
  end)
end)

-- An open menu is rebuilt only for its own app, never because another tile
-- retitled itself.
describe("menuhub.redraws", function()
  local a, b = {}, {}
  it("redraws the grid for any change", function()
    assert.is_true(hub.redraws(nil, a))
  end)
  it("redraws a menu only for its own app, and not while it loads", function()
    assert.is_true(hub.redraws({ entry = a }, a))
    assert.is_false(hub.redraws({ entry = a }, b))
    assert.is_false(hub.redraws({ entry = a, loading = true }, a))
  end)
end)

describe("menuhub.model loading", function()
  it("draws an app's name before its menu is built", function()
    local built = 0
    local entry = { name = "Slow", menu = function() built = built + 1; return { { title = "x", fn = function() end } } end }
    local m = hub.model({ entry }, { entry = entry, path = {}, loading = true })
    assert.same({ "detail", true, 0 }, { m.view, m.loading, built })
    m = hub.model({ entry }, { entry = entry, path = {} })
    assert.equals(1, built)
    assert.equals("x", m.menu[1].title)
  end)
end)
