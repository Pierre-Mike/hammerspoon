_G.hs = require("hs")
local plugins = require("lib.plugins")
local menuhub = require("lib.menuhub")

describe("the world clock plugin", function()
  local clock, p

  before_each(function()
    hs.settings._v = {}
    menuhub.widgets = {}
    package.loaded["apps.world_clock.init"] = nil
    local entry = require("apps.world_clock.init")
    local manifest = assert(plugins.check("world_clock", dofile("apps/world_clock/plugin.lua")))
    clock, p = plugins.activate("world_clock", entry, manifest)
  end)

  after_each(function() p.ctx:dispose() end)

  local function shown()
    local out = {}
    for _, it in ipairs(menuhub.glance(menuhub.widgets)[1].items) do out[#out + 1] = it.label end
    return out
  end

  it("puts a clock per city on the widgets page, west to east", function()
    local w = menuhub.glance(menuhub.widgets)[1]
    assert.equals("Around the world", w.title)
    assert.same({ "Seattle", "New York", "Paris" }, shown())
    assert.equals("Europe/Paris", w.items[3].clock)
  end)

  it("switches a city from the tile", function()
    clock.toggle("Paris")
    clock.toggle("Tokyo")
    clock.toggle("London")
    assert.same({ "Seattle", "New York", "London", "Tokyo" }, shown())
    assert.equals("4 cities", clock.tile._e.tooltip)
  end)

  it("keeps a city written as Label=Zone", function()
    p.settings.set("cities", "Tokyo, Lagos = Africa/Lagos, Nowhere")
    assert.same({ "Tokyo", "Lagos" }, shown())
    clock.toggle("Tokyo")
    assert.equals("Lagos=Africa/Lagos", p.settings.get("cities"))
  end)

  it("says how to add cities when none are picked", function()
    p.settings.set("cities", "")
    assert.same({ "No cities" }, shown())
    assert.equals("No cities picked", clock.tile._e.tooltip)
  end)

  it("takes its widget and tile with it when switched off", function()
    p.ctx:dispose()
    assert.equals(0, #menuhub.widgets)
  end)
end)
