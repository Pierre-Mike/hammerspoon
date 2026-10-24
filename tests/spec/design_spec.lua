-- Every design in designs/ has to build and stay readable before anyone
-- switches to it. A design is a guess at a look; this is what stops a guess
-- from making a toast unreadable on the next reload.

_G.hs = require("hs")

local design = require("lib.design")
local theme  = require("lib.theme")

local DIR = "./designs"

describe("lib/design", function()
  local warned
  before_each(function()
    warned = {}
    design.warn = function(m) warned[#warned + 1] = m end
    hs.settings._v = {}
  end)

  it("lists default first, then the rest alphabetically, without drafts", function()
    local list = design.list(DIR)
    assert.equals("default", list[1])
    for i = 3, #list do assert.is_true(list[i - 1] < list[i]) end
    for _, n in ipairs(list) do assert.is_nil(n:match("^_")) end
  end)

  it("is the default until a design is chosen", function()
    assert.equals("default", design.current())
    hs.settings._v[design.KEY] = "warm"
    assert.equals("warm", design.current())
  end)

  it("falls back to the default, and says so, for a design that is not there", function()
    local t, name = design.overrides("nope", DIR)
    assert.same({}, t)
    assert.equals("default", name)
    assert.equals(1, #warned)
  end)

  it("falls back for a design that does not return a table", function()
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p '" .. dir .. "'")
    local f = assert(io.open(dir .. "/broken.lua", "w"))
    f:write("return 42"); f:close()
    local t, name = design.overrides("broken", dir)
    assert.same({}, t)
    assert.equals("default", name)
    os.execute("rm -rf '" .. dir .. "'")
  end)

  it("shows the preview once after a switch", function()
    hs.settings._v[design.PREVIEW] = true
    assert.is_true(design.takePreview())
    assert.is_false(design.takePreview())
  end)
end)

describe("theme.build", function()
  it("is the defaults when nothing is overridden", function()
    local t = theme.build({})
    assert.equals(theme.palette.dark.blue, string.format("#%02x%02x%02x",
      math.floor(t.color.accent.red * 255 + 0.5), math.floor(t.color.accent.green * 255 + 0.5),
      math.floor(t.color.accent.blue * 255 + 0.5)))
    assert.equals(theme.text.body, t.text.body)
  end)

  it("takes an accent by palette name, for the overlays and the hub", function()
    local t = theme.build({ accent = "orange" })
    assert.same(theme.rgb(t.palette.dark.orange), t.color.accent)
    assert.equals(t.palette.light.orange, t.hub.light.accent)
  end)

  it("takes an accent as a hex color", function()
    local t = theme.build({ accent = "#f26822" })
    assert.same(theme.rgb("#f26822"), t.color.accent)
    assert.equals("#f26822", t.hub.dark.accent)
  end)

  it("refuses an accent the palette does not have", function()
    assert.has_error(function() theme.build({ accent = "teal-ish" }) end)
  end)

  it("reads colors written as hex, hex and alpha, or canvas tables", function()
    local t = theme.build({ color = { surface = "#102030", edge = { "#ffffff", 0.5 },
                                      control = { white = 1, alpha = 0.3 } } })
    assert.equals(1, t.color.surface.alpha)
    assert.equals(0.5, t.color.edge.alpha)
    assert.equals(0.3, t.color.control.alpha)
  end)

  it("keeps the defaults beside the keys a design replaces", function()
    local t = theme.build({ radius = { md = 20 } })
    assert.equals(20, t.radius.md)
    assert.equals(theme.radius.sm, t.radius.sm)
  end)

  it("writes button labels in whichever of black and white reads on the accent", function()
    assert.equals(1, theme.build({ accent = "blue" }).color.onAccent.white)
    assert.equals(0, theme.build({ accent = "yellow" }).color.onAccent.white)
  end)

  it("puts the panel's sizes in the CSS", function()
    local css = theme.css(theme.build({ panel = { columns = 3, tileHeight = 48 } }))
    assert.truthy(css:find("--columns: 3;", 1, true))
    assert.truthy(css:find("--tile-height: 48px;", 1, true))
  end)
end)

describe("theme.contrast", function()
  it("is 21 for black on white and 1 for a color on itself", function()
    assert.near(21, theme.contrast({ white = 0 }, { white = 1 }), 0.01)
    assert.near(1, theme.contrast(theme.rgb("#336699"), theme.rgb("#336699")), 0.001)
  end)

  it("blends a see-through color over what it sits on", function()
    local solid = theme.contrast({ white = 1 }, { white = 0 })
    local faint = theme.contrast({ white = 1, alpha = 0.3 }, { white = 0 })
    assert.is_true(faint < solid)
  end)
end)

-- The bar each design must clear. Body text at WCAG AA for small text, the
-- quieter lines a step down, and a button label on the accent at the large
-- text level.
local FLOOR = { text = 7, textSecondary = 4.5, textTertiary = 3 }

-- A design that follows the system is checked in both appearances, because
-- the user will see both.
for _, name in ipairs(design.list(DIR)) do
  describe("design " .. name, function()
    local d = design.overrides(name, DIR)
    local t = theme.build(d)

    it("builds", function()
      assert.is_table(t.color)
    end)

    it("says what it is", function()
      assert.is_string(d.name)
      assert.is_string(d.description)
    end)

    local modes = t.overlaySetting == "auto" and { "dark", "light" } or { t.overlaySetting }
    for _, mode in ipairs(modes) do
      local m = theme.build(d, mode)

      for role, floor in pairs(FLOOR) do
        it(role .. " reads on its surface (" .. mode .. ")", function()
          local c = theme.contrast(m.color[role], m.color.surface)
          assert(c >= floor, string.format("%s on surface is %.2f:1, needs %.1f:1", role, c, floor))
        end)
      end

      it("button labels read on the accent (" .. mode .. ")", function()
        local c = theme.contrast(m.color.onAccent, m.color.accent)
        assert(c >= 3, string.format("label on accent is %.2f:1, needs 3:1", c))
      end)
    end

    it("gives the hub the same variables in light and dark", function()
      local css = theme.css(t)
      local light = css:match("^:root {(.-)}")
      local dark = css:match("prefers%-color%-scheme: dark%) { :root {(.-)}")
      local function names(s)
        local out = {}
        for n in s:gmatch("%-%-([%w-]+):") do out[#out + 1] = n end
        table.sort(out)
        return table.concat(out, ",")
      end
      assert.equals(names(light), names(dark))
    end)
  end)
end

describe("following the system appearance", function()
  it("builds light overlays in light and dark ones in dark", function()
    assert.equals("light", theme.build({}, "light").overlay)
    assert.equals("dark", theme.build({}, "dark").overlay)
  end)

  it("stays where a design pins it", function()
    assert.equals("dark", theme.build({ overlay = "dark" }, "light").overlay)
    assert.equals("light", theme.build({ overlay = "light" }, "dark").overlay)
  end)

  it("lays a per-appearance block over the shared one", function()
    local d = { color = { surface = "#111111" }, light = { color = { surface = "#eeeeee" } } }
    assert.same(theme.rgb("#111111"), theme.build(d, "dark").color.surface)
    assert.same(theme.rgb("#eeeeee"), theme.build(d, "light").color.surface)
  end)

  -- Plugins hold color tables from load time, so a switch has to rewrite the
  -- tables they hold, not hand out new ones.
  it("rewrites the colors plugins already hold, and tells listeners", function()
    local held, heard = theme.color.text, {}
    local before = held.white
    local off = theme.onChange(function(mode) heard[#heard + 1] = mode end)

    assert.is_true(theme.refresh("light"))
    assert.equals(held, theme.color.text)
    assert.are_not.equal(before, held.white)
    assert.is_false(theme.refresh("light"))   -- already there

    assert.is_true(theme.refresh("dark"))
    assert.equals(before, held.white)
    assert.same({ "light", "dark" }, heard)
    off()
  end)

  it("ignores the system when the design is pinned", function()
    local was = theme.overlaySetting
    theme.overlaySetting = "dark"
    assert.is_false(theme.refresh("light"))
    theme.overlaySetting = was
  end)
end)
