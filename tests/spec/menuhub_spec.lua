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
