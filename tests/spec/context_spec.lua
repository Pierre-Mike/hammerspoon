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

describe("context event taps", function()
  -- A tap that was built and never started is not watching anything, and a tap
  -- still running after dispose is swallowing keys on behalf of a module that
  -- is gone. Both are checked on the same handle.
  local function tapStub()
    local real = hs.eventtap.new
    hs.eventtap.new = function(types, fn)
      return { types = types, fn = fn, running = false,
               start = function(s) s.running = true;  return s end,
               stop  = function(s) s.running = false; return s end }
    end
    return function() hs.eventtap.new = real end
  end

  it("starts the tap and stops it on dispose", function()
    local restore = tapStub()
    local ctx = context.new("t")
    local tap = ctx:eventtap(hs.eventtap.event.types.flagsChanged, function() end)
    restore()

    assert.is_true(tap.running)
    assert.equals(1, ctx:count())
    ctx:dispose()
    assert.is_false(tap.running)
  end)

  it("stops one tap early without touching the other", function()
    local restore = tapStub()
    local ctx = context.new("t")
    local flags = ctx:eventtap(1, function() end)
    local _, releaseKeys = ctx:eventtap(2, function() end)
    restore()

    releaseKeys()
    assert.equals(1, ctx:count())
    assert.is_true(flags.running)
  end)

  it("takes a single event type or a list of them", function()
    local ctx, seen = context.new("t"), {}
    local real = hs.eventtap.new
    hs.eventtap.new = function(types) seen[#seen + 1] = types; return real(types) end

    ctx:eventtap(7, function() end)
    ctx:eventtap({ 7, 8 }, function() end)

    hs.eventtap.new = real
    assert.same({ 7 }, seen[1])
    assert.same({ 7, 8 }, seen[2])
  end)
end)

describe("context servers", function()
  it("binds the port, serves, and gives it back on dispose", function()
    local ctx = context.new("t")
    local srv = ctx:httpserver(8790, function() return "ok", 200, {} end)
    assert.equals(8790, srv.port)
    assert.is_true(srv.running)
    assert.is_function(srv.callback)
    ctx:dispose()
    assert.is_false(srv.running)
  end)
end)

describe("context watchers", function()
  local realAudio, realCaffeinate

  before_each(function()
    realAudio, realCaffeinate = hs.audiodevice, hs.caffeinate
  end)

  after_each(function()
    hs.audiodevice, hs.caffeinate = realAudio, realCaffeinate
    local aw = require("lib.audiowatch")
    aw.handlers, aw.order, aw.started = {}, {}, nil
  end)

  it("unsubscribes the shared audio handler on dispose", function()
    local stopped = false
    hs.audiodevice = { watcher = {
      setCallback = function() end, start = function() end,
      stop = function() stopped = true end,
    } }
    local aw = require("lib.audiowatch")
    aw.handlers, aw.order, aw.started = {}, {}, nil

    local ctx = context.new("Dictation")
    ctx:watcher("audio", "dictation", function() end)
    assert.is_function(aw.handlers["dictation"])

    ctx:dispose()
    assert.is_nil(aw.handlers["dictation"])
    assert.same({}, aw.order)
    -- Nothing left listening, so the system watcher is not kept awake either.
    assert.is_true(stopped)
  end)

  it("registers the audio handler under the context's own name by default", function()
    hs.audiodevice = { watcher = { setCallback = function() end, start = function() end } }
    local aw = require("lib.audiowatch")
    aw.handlers, aw.order, aw.started = {}, {}, nil

    context.new("Dictation"):watcher("audio", function() end)
    assert.is_function(aw.handlers["Dictation"])
  end)

  it("starts a machine-wide watcher and stops it on dispose", function()
    local stopped, handler = false, nil
    hs.caffeinate = { watcher = {
      systemDidWake = 1,
      new = function(fn)
        handler = fn
        return { start = function(s) return s end, stop = function() stopped = true end }
      end,
    } }

    local ctx, woke = context.new("t"), false
    ctx:watcher("caffeinate", function() woke = true end)
    handler(1)
    assert.is_true(woke)

    ctx:dispose()
    assert.is_true(stopped)
  end)

  it("hands back nothing when this Mac has no such watcher", function()
    hs.caffeinate = nil
    local ctx = context.new("t")
    local w, release = ctx:watcher("caffeinate", function() end)
    assert.is_nil(w)
    assert.equals(0, ctx:count())
    release()                       -- a plugin that releases anyway is fine
  end)

  it("watches one path and stops watching it on dispose", function()
    local ctx = context.new("t")
    local w = ctx:watcher("path", "/tmp/thing", function() end)
    local stopped = false
    w.stop = function() stopped = true end
    assert.equals("/tmp/thing", w.path)
    ctx:dispose()
    assert.is_true(stopped)
  end)

  it("says so when the kind is a typo", function()
    local ctx = context.new("t")
    assert.has_error(function() ctx:watcher("caffinate", function() end) end,
                     "context: no watcher of kind caffinate")
  end)
end)

describe("context canvas", function()
  it("deletes the overlay on dispose", function()
    local ctx = context.new("t")
    local c = ctx:canvas({ x = 0, y = 0, w = 10, h = 10 })
    local gone = false
    c.delete = function() gone = true end
    ctx:dispose()
    assert.is_true(gone)
  end)

  it("takes the previous one down when a name is reused", function()
    local ctx = context.new("t")
    local first = ctx:canvas("hud", { x = 0, y = 0, w = 10, h = 10 })
    local gone = false
    first.delete = function() gone = true end

    local second = ctx:canvas("hud", { x = 0, y = 0, w = 20, h = 20 })
    assert.is_true(gone)
    assert.are_not.equal(first, second)
    -- One overlay held, not two: this is what keeps a panel that is redrawn on
    -- every spoken word from stacking a window per redraw.
    assert.equals(1, ctx:count())
  end)

  it("forgets a named overlay that was released early", function()
    local ctx = context.new("t")
    local _, release = ctx:canvas("hud", { x = 0, y = 0, w = 10, h = 10 })
    release()
    assert.equals(0, ctx:count())
    ctx:canvas("hud", { x = 0, y = 0, w = 10, h = 10 })
    assert.equals(1, ctx:count())
  end)
end)

describe("context sound", function()
  it("stops a playing sound on dispose", function()
    local ctx = context.new("t")
    local snd = ctx:sound("/tmp/noise_brown.wav")
    snd:play()
    assert.is_true(snd.playing)
    ctx:dispose()
    assert.is_false(snd.playing)
  end)

  it("reads a bare name as one of macOS's own sounds", function()
    local ctx, asked = context.new("t"), {}
    local byName, byFile = hs.sound.getByName, hs.sound.getByFile
    hs.sound.getByName = function(n) asked[#asked + 1] = "name:" .. n; return byName(n) end
    hs.sound.getByFile = function(p) asked[#asked + 1] = "file:" .. p; return byFile(p) end

    ctx:sound("Sosumi")
    ctx:sound("/System/Library/Sounds/Sosumi.aiff")

    hs.sound.getByName, hs.sound.getByFile = byName, byFile
    assert.same({ "name:Sosumi", "file:/System/Library/Sounds/Sosumi.aiff" }, asked)
  end)

  it("hands back nothing for a sound that will not load", function()
    local ctx = context.new("t")
    local byName = hs.sound.getByName
    hs.sound.getByName = function() return nil end

    local snd, release = ctx:sound("NoSuchSound")
    hs.sound.getByName = byName

    assert.is_nil(snd)
    assert.equals(0, ctx:count())
    release()
  end)
end)

describe("context globals", function()
  it("publishes the name and takes it back on dispose", function()
    local ctx = context.new("t")
    _G.ctxSpecGlobal = nil
    local fn = function() return 42 end
    ctx:global("ctxSpecGlobal", fn)
    assert.equals(42, _G.ctxSpecGlobal())
    ctx:dispose()
    assert.is_nil(_G.ctxSpecGlobal)
  end)

  it("puts the previous binding back", function()
    local old = function() return "old" end
    _G.ctxSpecGlobal = old
    local ctx = context.new("t")
    ctx:global("ctxSpecGlobal", function() return "new" end)
    assert.equals("new", _G.ctxSpecGlobal())
    ctx:dispose()
    assert.equals(old, _G.ctxSpecGlobal)
    _G.ctxSpecGlobal = nil
  end)

  it("leaves a name something else has claimed since", function()
    local ctx = context.new("t")
    ctx:global("ctxSpecGlobal", function() return "mine" end)
    local theirs = function() return "theirs" end
    _G.ctxSpecGlobal = theirs
    ctx:dispose()
    assert.equals(theirs, _G.ctxSpecGlobal)
    _G.ctxSpecGlobal = nil
  end)
end)
