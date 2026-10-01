_G.hs = require("hs")

-- The hub is a service, not part of what a context does, so the tile test gets
-- a stand-in that records instead of drawing a menu bar.
local hub = { made = {}, deleted = {} }
package.loaded["lib.menuhub"] = {
  item = function(name)
    hub.made[#hub.made + 1] = name
    return { delete = function() hub.deleted[#hub.deleted + 1] = name end }
  end,
}

local context = require("lib.context")

describe("context effects", function()
  before_each(function()
    hub.made, hub.deleted = {}, {}
  end)

  it("runs every teardown on dispose", function()
    local ctx = context.new("t")
    local log = {}
    ctx:effect(function() log[#log + 1] = "a" end)
    ctx:effect(function() log[#log + 1] = "b" end)
    assert.equals(2, ctx:count())
    ctx:dispose()
    assert.same({ "b", "a" }, log)   -- reverse build order
    assert.equals(0, ctx:count())
  end)

  it("is idempotent", function()
    local ctx, n = context.new("t"), 0
    ctx:effect(function() n = n + 1 end)
    ctx:dispose()
    ctx:dispose()
    assert.equals(1, n)
  end)

  it("release runs the teardown once, then forgets it", function()
    local ctx, n = context.new("t"), 0
    local release = ctx:effect(function() n = n + 1 end)
    release()
    assert.equals(1, n)
    assert.equals(0, ctx:count())
    release()
    ctx:dispose()
    assert.equals(1, n)
  end)

  it("keeps unwinding when one teardown throws", function()
    local ctx, log = context.new("t"), {}
    local warned
    local realWarn = context.warn
    context.warn = function(msg) warned = msg end

    ctx:effect(function() log[#log + 1] = "first" end)
    ctx:effect(function() error("boom") end)
    ctx:effect(function() log[#log + 1] = "last" end)
    ctx:dispose()

    context.warn = realWarn
    assert.same({ "last", "first" }, log)
    assert.truthy(warned and warned:match("teardown failed"))
  end)

  it("runs a late effect immediately rather than storing it", function()
    local ctx, n = context.new("t"), 0
    ctx:dispose()
    ctx:effect(function() n = n + 1 end)
    assert.equals(1, n)
    assert.equals(0, ctx:count())
  end)
end)

describe("context constructors", function()
  it("tracks a repeating timer and stops it on dispose", function()
    local ctx = context.new("t")
    local t = ctx:timer(15, function() end)
    local stopped = false
    t.stop = function() stopped = true end
    assert.equals(1, ctx:count())
    ctx:dispose()
    assert.is_true(stopped)
  end)

  it("lets a one-shot forget itself when it fires", function()
    local ctx, fired = context.new("t"), false
    local t = ctx:after(4, function() fired = true end)
    assert.equals(1, ctx:count())
    t.start()                       -- the mock fires a timer on demand
    assert.is_true(fired)
    assert.equals(0, ctx:count())   -- nothing left to tear down
  end)

  it("does not grow its teardown list across repeated one-shots", function()
    local ctx = context.new("t")
    for _ = 1, 50 do ctx:after(1, function() end).start() end
    assert.equals(0, ctx:count())
  end)

  it("terminates a task on dispose", function()
    local ctx = context.new("t")
    local task = ctx:task("/bin/sh", function() end, { "-c", "true" })
    local killed = false
    task.terminate = function() killed = true end
    ctx:dispose()
    assert.is_true(killed)
  end)

  it("deletes a hotkey on dispose", function()
    local ctx = context.new("t")
    local key = ctx:hotkey({ "cmd" }, "d", function() end)
    local gone = false
    key.delete = function() gone = true end
    ctx:dispose()
    assert.is_true(gone)
  end)

  it("rebinds a url handler to nothing on dispose", function()
    local ctx, bound = context.new("t"), {}
    local real = hs.urlevent.bind
    hs.urlevent.bind = function(name, fn) bound[#bound + 1] = { name = name, fn = fn } end

    local mine = function() end
    ctx:url("noseguard", mine)
    assert.equals(mine, bound[1].fn)
    ctx:dispose()

    hs.urlevent.bind = real
    assert.equals(2, #bound)
    assert.equals("noseguard", bound[2].name)
    assert.not_equals(mine, bound[2].fn)
  end)

  it("takes its hub tile back on dispose", function()
    local ctx = context.new("t")
    ctx:tile("DSH")
    assert.same({ "DSH" }, hub.made)
    assert.same({}, hub.deleted)
    ctx:dispose()
    assert.same({ "DSH" }, hub.deleted)
  end)
end)

describe("context atExit", function()
  before_each(function() context.resetAtExit() end)
  after_each(function() context.resetAtExit() end)

  it("lets two plugins both run at quit", function()
    local a, b = context.new("a"), context.new("b")
    local log = {}
    a:atExit(function() log[#log + 1] = "a" end)
    b:atExit(function() log[#log + 1] = "b" end)
    hs.shutdownCallback()
    table.sort(log)
    assert.same({ "a", "b" }, log)
  end)

  it("keeps a callback that was already in the slot", function()
    local log = {}
    hs.shutdownCallback = function() log[#log + 1] = "prior" end
    context.new("a"):atExit(function() log[#log + 1] = "mine" end)
    hs.shutdownCallback()
    assert.same({ "prior", "mine" }, log)
  end)

  it("stops calling a plugin once it is disposed", function()
    local ctx, n = context.new("a"), 0
    ctx:atExit(function() n = n + 1 end)
    ctx:dispose()
    hs.shutdownCallback()
    assert.equals(0, n)
  end)

  it("keeps going when one handler throws", function()
    local a, b, ran = context.new("a"), context.new("b"), false
    a:atExit(function() error("boom") end)
    b:atExit(function() ran = true end)
    hs.shutdownCallback()
    assert.is_true(ran)
  end)
end)
