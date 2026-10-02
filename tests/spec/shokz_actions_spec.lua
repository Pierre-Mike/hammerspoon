local a = require("lib.shokz_actions")

local function catalog()
  local c = a.newCatalog()
  a.add(c, { id = "alert", label = "Show which chord fired", fn = function() end })
  a.add(c, { id = "none",  label = "Do nothing",             fn = function() end })
  a.add(c, { id = "noise", label = "Toggle noise",           fn = function() end })
  return c
end

describe("shokz_actions.choice", function()
  it("falls back to the default with nothing saved", function()
    assert.equals("alert", a.choice(catalog(), nil, "down_up"))
  end)

  it("uses a saved choice", function()
    assert.equals("noise", a.choice(catalog(), { down_up = "noise" }, "down_up"))
    assert.equals("alert", a.choice(catalog(), { down_up = "noise" }, "up_down"))
  end)

  it("ignores a saved choice whose action no longer exists", function()
    assert.equals("alert", a.choice(catalog(), { down_up = "gone" }, "down_up"))
  end)

  it("ignores a saved choice whose plugin is switched off", function()
    local c = catalog()
    a.add(c, { id = "tts", label = "Speak", fn = function() end,
               available = function() return false end })
    assert.equals("alert", a.choice(c, { down_up = "tts" }, "down_up"))
  end)

  it("treats an available() that throws as unavailable", function()
    local c = catalog()
    a.add(c, { id = "tts", label = "Speak", fn = function() end,
               available = function() error("boom") end })
    assert.equals("alert", a.choice(c, { down_up = "tts" }, "down_up"))
  end)

  it("lets an app that wired the chord in code take it over the default", function()
    local c = catalog()
    a.add(c, { id = "code:down_up", label = "voice_agent", fn = function() end })
    assert.equals("code:down_up", a.choice(c, nil, "down_up"))
    assert.equals("alert", a.choice(c, nil, "up_down"))
  end)

  it("keeps the user's saved choice over a code-wired one", function()
    local c = catalog()
    a.add(c, { id = "code:down_up", label = "voice_agent", fn = function() end })
    assert.equals("none", a.choice(c, { down_up = "none" }, "down_up"))
  end)
end)

describe("shokz_actions.add", function()
  it("replaces an existing id without moving it", function()
    local c = catalog()
    local newer = function() end
    a.add(c, { id = "alert", label = "Alert v2", fn = newer })
    assert.same({ "alert", "none", "noise" }, c.order)
    assert.equals(newer, c.byId.alert.fn)
  end)
end)

describe("shokz_actions.menu", function()
  it("gives each chord a drill-in row titled with its current action", function()
    local rows = a.menu(catalog(), { up_down = "noise" }, function() end)
    assert.equals(2, #rows)
    assert.equals("Volume − then +:  Show which chord fired", rows[1].title)
    assert.equals("Volume + then −:  Toggle noise", rows[2].title)
  end)

  it("ticks the current action and lists only usable ones", function()
    local c = catalog()
    a.add(c, { id = "tts", label = "Speak", fn = function() end,
               available = function() return false end })
    local sub = a.menu(c, { down_up = "none" }, function() end)[1].menu
    local titles, ticked = {}, nil
    for _, r in ipairs(sub) do
      titles[#titles + 1] = r.title
      if r.checked then ticked = r.title end
    end
    assert.same({ "Show which chord fired", "Do nothing", "Toggle noise" }, titles)
    assert.equals("Do nothing", ticked)
  end)

  it("reports the chord and action id when a row is picked", function()
    local got
    local rows = a.menu(catalog(), nil, function(chord, id) got = { chord, id } end)
    rows[2].menu[3].fn()
    assert.same({ "up_down", "noise" }, got)
  end)
end)
