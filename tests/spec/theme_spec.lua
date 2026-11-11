local theme = require("lib.theme")

describe("theme.rgb", function()
  it("turns a hex color into an hs.canvas color", function()
    local c = theme.rgb("#ff8000", 0.5)
    assert.equals(1, c.red)
    assert.near(128 / 255, c.green, 1e-9)
    assert.equals(0, c.blue)
    assert.equals(0.5, c.alpha)
  end)

  it("is opaque unless told otherwise", function()
    assert.equals(1, theme.rgb("000000").alpha)
  end)

  it("refuses something that is not a color", function()
    assert.has_error(function() theme.rgb("blue") end)
  end)
end)

describe("theme.tone", function()
  it("maps a meaning to a color", function()
    assert.equals(theme.color.danger, theme.tone("recording"))
    assert.equals(theme.color.warning, theme.tone("working"))
    assert.equals(theme.color.success, theme.tone("success"))
  end)

  it("takes a color role directly", function()
    assert.equals(theme.color.accent, theme.tone("accent"))
  end)

  -- A typo in a status dot must not cost the message it sits on.
  it("falls back to neutral for a name it does not know", function()
    assert.equals(theme.color.textSecondary, theme.tone("recordnig"))
    assert.equals(theme.color.textSecondary, theme.tone(nil))
  end)

  it("names a color for every tone", function()
    for name, role in pairs(theme.tones) do
      assert.is_table(theme.color[role], name)
    end
  end)
end)

describe("theme.css", function()
  local css = theme.css()

  it("declares the same variables for light and dark", function()
    local light, dark = css:match("^:root {(.-)}"), css:match("prefers%-color%-scheme: dark%) { :root {(.-)}")
    assert.is_string(light)
    assert.is_string(dark)
    local function names(s)
      local out = {}
      for n in s:gmatch("%-%-([%w-]+):") do out[#out + 1] = n end
      table.sort(out)
      return table.concat(out, ",")
    end
    assert.equals(names(light), names(dark))
  end)

  -- One palette: the hub's accent is the overlays' accent.
  it("takes its accents from the palette", function()
    assert.truthy(css:find("--accent: " .. theme.palette.light.blue, 1, true))
    assert.truthy(css:find("--accent: " .. theme.palette.dark.blue, 1, true))
  end)

  it("carries the corner radii", function()
    assert.truthy(css:find("--radius-md: " .. theme.radius.md .. "px", 1, true))
  end)

  it("is the same on every call", function()
    assert.equals(css, theme.css())
  end)
end)

-- The hub panel as an island: one appearance, the overlays', and black like
-- the notch when that is dark.
describe("theme.islandCss", function()
  it("is solid black with no edge on dark overlays", function()
    local css = theme.islandCss(theme.build({ overlay = "dark" }))
    assert.truthy(css:find("--card: rgba(0, 0, 0, 1);", 1, true))
    assert.truthy(css:find("--edge: transparent;", 1, true))
    assert.is_nil(css:find("prefers-color-scheme", 1, true))
  end)

  it("keeps the panel's own card on light overlays", function()
    local t = theme.build({ overlay = "light" })
    assert.truthy(theme.islandCss(t):find("--card: " .. t.hub.light.card, 1, true))
  end)

  it("carries the island corner", function()
    assert.truthy(theme.islandCss():find("--radius-island: " .. theme.radius.island .. "px", 1, true))
  end)
end)
