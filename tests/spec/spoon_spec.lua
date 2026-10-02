_G.hs = require("hs")

local hub = { made = {}, deleted = {} }
package.loaded["lib.menuhub"] = {
  item = function(name)
    hub.made[#hub.made + 1] = name
    return {
      delete       = function() hub.deleted[#hub.deleted + 1] = name end,
      setTitle     = function(s) return s end,
      setTooltip   = function(s, v) hub.tooltip = v; return s end,
      setMenu      = function(s) return s end,
    }
  end,
}

local spoon = require("lib.spoon")

-- A stand-in for the Spoon on disk. `leak` is the thing a careless :stop()
-- forgets about, which is the case the capture exists for.
local function fakeSpoon(over)
  local obj = {
    name = "Caffeine", version = "1.4", author = "Someone <someone@example.com>",
    log = {},
  }
  for k, v in pairs(over or {}) do obj[k] = v end
  obj.start = obj.start or function(self)
    self.started = true
    self.leak = hs.timer.doEvery(60, function() end)
  end
  obj.bindHotkeys = obj.bindHotkeys or function(self, map) self.keys = map end
  return obj
end

describe("spoon.describe", function()
  it("names, versions and strips the author's address", function()
    assert.equals("Caffeine · v1.4 · Someone", spoon.describe(fakeSpoon()))
  end)

  it("survives a Spoon that declares nothing", function()
    assert.equals("Spoon", spoon.describe({}))
    assert.equals("Spoon", spoon.describe(nil))
  end)
end)

describe("spoon.capture", function()
  it("tracks handles built while it is on, and nothing after", function()
    local ctx = require("lib.context").new("t")
    spoon.capture(ctx, function()
      hs.timer.doEvery(1, function() end)
      hs.hotkey.bind({ "cmd" }, "x", function() end)
    end)
    assert.equals(2, ctx:count())

    hs.timer.doEvery(1, function() end)       -- outside the window
    assert.equals(2, ctx:count())
  end)

  it("puts the real constructors back even when the body throws", function()
    local ctx = require("lib.context").new("t")
    local before = hs.timer.doEvery
    local ok = spoon.capture(ctx, function() error("boom") end)
    assert.is_false(ok)
    assert.equals(before, hs.timer.doEvery)
  end)
end)

describe("spoon.load", function()
  before_each(function()
    hub.made, hub.deleted, hub.tooltip = {}, {}, nil
  end)

  it("starts the Spoon, binds its keys and gives it a tile", function()
    local obj = fakeSpoon()
    hs.loadSpoon = function() return obj end

    local ctx = spoon.load("Caffeine", { hotkeys = { toggle = { { "cmd" }, "c" } } })
    assert.truthy(ctx)
    assert.is_true(obj.started)
    assert.same({ toggle = { { "cmd" }, "c" } }, obj.keys)
    assert.same({ "Caffeine" }, hub.made)
    assert.equals("Caffeine · v1.4 · Someone", hub.tooltip)
  end)

  it("lets the Spoon stop itself before sweeping up what it left", function()
    local order = {}
    local obj = fakeSpoon({ stop = function(self) order[#order + 1] = "stop" end })
    hs.loadSpoon = function() return obj end

    local ctx = spoon.load("Caffeine", { tile = false })
    obj.leak.stop = function() order[#order + 1] = "leaked timer" end
    ctx:dispose()

    assert.same({ "stop", "leaked timer" }, order)
  end)

  it("tears down a timer the Spoon's own stop forgot", function()
    local obj = fakeSpoon({ stop = function() end })   -- never touches self.leak
    hs.loadSpoon = function() return obj end

    local stopped = false
    local ctx = spoon.load("Caffeine", { tile = false })
    obj.leak.stop = function() stopped = true end
    ctx:dispose()

    assert.is_true(stopped)
  end)

  it("reports a Spoon that is not installed", function()
    hs.loadSpoon = function(name) error("Unable to locate Spoon " .. name) end
    local ctx, err = spoon.load("Missing")
    assert.is_nil(ctx)
    assert.truthy(err:match("did not load"))
  end)

  it("leaves nothing behind when start throws", function()
    local obj = fakeSpoon({ start = function(self)
      self.leak = hs.timer.doEvery(60, function() end)
      error("no API key")
    end })
    hs.loadSpoon = function() return obj end

    local ctx, err = spoon.load("Caffeine")
    assert.is_nil(ctx)
    assert.truthy(err:match("failed to start"))
    assert.same({}, hub.made)
  end)
end)
