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
  it("shares one menu bar across every app and keeps registration order", function()
    local made = 0
    local realNew = hs.menubar.new
    hs.menubar.new = function() made = made + 1; return realNew() end
    hub.entries, hub.bar = {}, nil

    local a = hub.item("First"):setTitle("1")
    hub.item("Second"):setTooltip("tip")

    assert.equals(1, made)
    assert.equals("First", hub.entries[1].name)
    assert.equals("1", a:title())
    assert.equals("tip", hub.entries[2].tooltip)
    hs.menubar.new = realNew
  end)

  it("delete removes only that app's row", function()
    hub.entries, hub.bar = {}, nil
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
