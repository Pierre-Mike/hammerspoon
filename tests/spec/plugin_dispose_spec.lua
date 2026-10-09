-- What "switched off" means, per plugin.
--
-- lib/plugins can only really take a plugin out of a running config if that
-- plugin exposes dispose() and dispose() genuinely releases everything — a
-- plugin whose dispose() returns without stopping its timer is worse than one
-- with no dispose() at all, because the Plugins tile stops saying "reload to
-- remove" and starts lying.
--
-- So these specs load each plugin against stubs that record, call dispose(),
-- and assert on what came back: the tile, the port, the globals, the child
-- processes, the sound. They are deliberately about teardown only; what each
-- plugin does while it is running is covered by its own spec.

_G.hs = require("hs")

local context = require("lib.context")

-- One hub for all of them, recording what was made and what was given back.
local hub = { made = {}, deleted = {} }
package.loaded["lib.menuhub"] = {
  item = function(name)
    hub.made[#hub.made + 1] = name
    return {
      setTitle = function() end, setIcon = function() end,
      setTooltip = function() end, setMenu = function() end,
      delete = function() hub.deleted[#hub.deleted + 1] = name end,
    }
  end,
}

-- Every process any of them spawns, so a dispose can be checked against it.
local tasks
hs.task.new = function(path, cb, a, b)
  local t = { path = path, cb = cb, args = (type(a) == "table" and a) or b or {},
              started = false, terminated = false }
  t.start = function(self) self.started = true; return self end
  t.terminate = function(self) self.terminated = true; return self end
  t.isRunning = function(self) return self.started and not self.terminated end
  t.setEnvironment = function(self, env) self.env = env; return self end
  t.setWorkingDirectory = function(self, d) self.cwd = d; return self end
  tasks[#tasks + 1] = t
  return t
end

local function running()
  local out = {}
  for _, t in ipairs(tasks) do if t.started and not t.terminated then out[#out + 1] = t end end
  return out
end

-- Taps that can be switched off, like macOS's are. The stock mock's start and
-- stop are no-ops, so a tap left running after dispose would look exactly like
-- one that was released -- and the tap is the handle it matters most about.
local taps
hs.eventtap.new = function(types, fn)
  local t = { types = types, fn = fn, running = false }
  t.start = function(self) self.running = true;  return self end
  t.stop  = function(self) self.running = false; return self end
  taps[#taps + 1] = t
  return t
end

-- Every context any plugin builds. The context is a local inside each file, so
-- there is no handle to ask for; M.new is wrapped instead and the answer is the
-- sum over all of them.
local realNew = context.new
local built
local function recording()
  built = {}
  context.new = function(name)
    local c = realNew(name)
    built[#built + 1] = c
    return c
  end
end
local function held()
  local n = 0
  for _, c in ipairs(built) do n = n + c:count() end
  return n
end

local function load(name)
  package.loaded["apps." .. name] = nil
  return require("apps." .. name)
end

-- Shared by every plugin here: the two namespaces that are absent from the
-- stock mock, in the one shape that satisfies all of them -- an empty machine
-- with no input devices and nothing running.
local function reset()
  tasks, taps = {}, {}
  hub.made, hub.deleted = {}, {}
  hs.settings._v = {}
  hs.httpserver._servers = {}
  hs.websocket._sockets = {}
  hs.application = { get = function() return nil end,
                     frontmostApplication = function() return nil end }
  hs.audiodevice = { allInputDevices = function() return {} end,
                     defaultOutputDevice = function() return nil end,
                     watcher = { setCallback = function() end,
                                 start = function() end, stop = function() end } }
  context.resetAtExit()
  recording()
end

describe("brown_noise dispose", function()
  before_each(reset)
  after_each(function() context.resetAtExit() end)

  it("stops the noise and takes the tile back", function()
    local noise = load("brown_noise")
    noise.play()
    assert.is_true(noise.playing)
    assert.is_true(noise.sound.playing)
    assert.same({ "Noise" }, hub.made)

    local sound = noise.sound
    noise.dispose()

    -- The WAV loops forever, so this is the one that would otherwise still be
    -- playing with nothing left that could stop it.
    assert.is_false(sound.playing)
    assert.is_false(noise.playing)
    assert.same({ "Noise" }, hub.deleted)
  end)

  it("holds one sound across a colour switch, not one per switch", function()
    local noise = load("brown_noise")
    noise.play()
    local first = noise.sound
    noise.setColor("pink")
    noise.setColor("white")

    assert.is_false(first.playing)
    assert.are_not.equal(first, noise.sound)
    noise.dispose()
    assert.is_nil(noise.sound)
  end)
end)

describe("tts dispose", function()
  before_each(reset)
  after_each(function()
    context.resetAtExit()
    _G.speak, _G.speakStop, _G.speakSelection = nil, nil, nil
  end)

  it("gives the port back", function()
    local tts = load("tts")
    local intake = hs.httpserver._servers[1]
    assert.equals(8790, intake.port)
    assert.is_true(intake.running)

    tts.dispose()
    -- Without this the plugin cannot be switched on again: its own replacement
    -- would find :8790 held by the instance that is supposed to be gone.
    assert.is_false(intake.running)
  end)

  it("unpublishes the speak() globals", function()
    local tts = load("tts")
    assert.is_function(_G.speak)
    assert.is_function(_G.speakStop)
    assert.is_function(_G.speakSelection)

    tts.dispose()
    assert.is_nil(_G.speak)
    assert.is_nil(_G.speakStop)
    assert.is_nil(_G.speakSelection)
  end)

  it("terminates both voice servers", function()
    local tts = load("tts")
    -- Each instance frees its port first and launches the server from that
    -- shell's exit, so the two servers only exist once the kills report done.
    -- Snapshotted first: firing a callback appends the server it launches, and
    -- iterating the live list would report that one as exited too.
    local kills = {}
    for _, t in ipairs(tasks) do
      if t.args[2] and tostring(t.args[2]):find("lsof", 1, true) then kills[#kills + 1] = t end
    end
    for _, t in ipairs(kills) do t.cb(0, "", "") end
    assert.truthy(tts.server)
    assert.truthy(tts.frServer)
    assert.equals(2, #running())

    tts.dispose()
    -- Each holds a port and a model in memory. Left behind, they are both a
    -- few gigabytes and the reason the next instance cannot bind 8791.
    assert.same({}, running())
    assert.same({ "Speech queue" }, hub.deleted)
  end)

  it("stops answering hammerspoon://speak", function()
    local bound = {}
    local real = hs.urlevent.bind
    hs.urlevent.bind = function(name, fn) bound[name] = fn end

    local tts = load("tts")
    local mine = bound["speak"]
    tts.dispose()
    hs.urlevent.bind = real

    assert.is_function(mine)
    -- hs.urlevent has no unbind, so the name still resolves; what matters is
    -- that it no longer reaches the plugin.
    assert.is_function(bound["speak"])
    assert.are_not.equal(mine, bound["speak"])
  end)
end)

describe("lmstudio dispose", function()
  before_each(reset)
  after_each(function() context.resetAtExit() end)

  it("stops the poll and takes the tile back", function()
    local lm = load("lmstudio")
    assert.same({ "LM Studio" }, hub.made)
    local stopped = false
    lm.timer.stop = function() stopped = true end

    lm.dispose()
    assert.is_true(stopped)
    assert.same({ "LM Studio" }, hub.deleted)
  end)

  it("leaves the LM Studio server and its model alone", function()
    local lm = load("lmstudio")
    lm.dispose()
    -- Nothing here is ours to unload: the tile only ever observed them, and a
    -- dispose that unloaded a 15 GB model because a menu went away would be a
    -- surprising way to lose it.
    for _, t in ipairs(tasks) do
      assert.are_not.equal("unload", t.args[1])
    end
  end)
end)

describe("shokz_mute dispose", function()
  before_each(function()
    reset()
    _G.__shokz_mute = nil
  end)
  after_each(function() context.resetAtExit() end)

  it("closes the socket, kills the log stream, and takes the tile back", function()
    local shokz = load("shokz_mute")
    local sock = hs.websocket._sockets[1]
    assert.truthy(sock)
    assert.same({ "Shokz mute" }, hub.made)
    assert.is_true(#running() > 0)

    shokz.dispose()

    assert.equals("closed", sock.state)
    -- Measured once: a reload left a second `log stream` with PPID 1. One per
    -- switch-off would be the same bug by another route.
    assert.same({}, running())
    assert.same({ "Shokz mute" }, hub.deleted)
    assert.is_false(shokz.enabled)
  end)

  it("stops being called at quit", function()
    local shokz = load("shokz_mute")
    shokz.dispose()
    -- A disposed plugin that still ran at quit would reach into state it has
    -- already given back.
    local before = #running()
    hs.shutdownCallback()
    assert.equals(before, #running())
  end)

  it("leaves another plugin's quit hook alone", function()
    local reaped = false
    context.new("NoseGuard"):atExit(function() reaped = true end)
    load("shokz_mute").dispose()

    hs.shutdownCallback()
    -- This file used to take hs.shutdownCallback and chain onto whatever was
    -- already there, which only worked while it knew who was first.
    assert.is_true(reaped)
  end)
end)

describe("dictation dispose", function()
  before_each(reset)
  after_each(function()
    context.resetAtExit()
    _G.dictatePreview, _G.dictateHide, _G.dictateFrame = nil, nil, nil
  end)

  it("releases the Fn tap and the chord tap", function()
    local d = load("dictation")
    assert.equals(2, #taps)
    for _, t in ipairs(taps) do assert.is_true(t.running) end

    d.dispose()
    -- The one that costs the whole machine. A tap left in front of every
    -- keystroke on behalf of a plugin that is gone still eats Fn, for every
    -- app, until a reload -- so Fn would simply stop doing anything.
    for _, t in ipairs(taps) do assert.is_false(t.running) end
  end)

  it("unpublishes the dictate* debug globals", function()
    local d = load("dictation")
    assert.is_function(_G.dictatePreview)
    assert.is_function(_G.dictateHide)
    assert.is_function(_G.dictateFrame)

    d.dispose()
    -- Three `hs -c` commands that answer and no longer work would be worse
    -- than three that are simply not there.
    assert.is_nil(_G.dictatePreview)
    assert.is_nil(_G.dictateHide)
    assert.is_nil(_G.dictateFrame)
  end)

  it("gives back the warm server, the tile and the listener registry", function()
    local d = load("dictation")
    assert.same({ "Dictation" }, hub.made)

    d.dispose()
    -- :8765 and a multi-gigabyte model. Held, they are the reason the plugin
    -- could not be switched on again: its own replacement would find the port
    -- taken by the instance that is supposed to be gone.
    assert.same({}, running())
    assert.same({ "Dictation" }, hub.deleted)
    assert.same({}, d.listeners)
  end)
end)

-- ── Switched off and on again ──────────────────────────────────────────────
-- What the Plugins tile promises, stated once for every plugin rather than per
-- handle. The specs above each check one plugin against the handles it is known
-- to build; this one checks the arithmetic that has to hold whatever a plugin
-- builds, including anything added later: after dispose() its context holds
-- nothing, and a second load leaves one tile in the hub rather than two.
--
-- Two full rounds, because the failures worth catching only show on the second:
-- a hotkey or a port claimed again while the first is still held, a tile drawn
-- beside the one that never left.
describe("every plugin", function()
  -- Symlinked in from ~/Github/pipecat-voice-agent, so on a clone of this repo
  -- alone it is not there. Skipped rather than failed, the same way lib/plugins
  -- skips it at load.
  local PLUGINS = { "brown_noise", "tts", "lmstudio", "shokz_mute", "dictation" }
  if hs.fs.attributes and io.open("apps/voice_agent/init.lua") then
    PLUGINS[#PLUGINS + 1] = "voice_agent"
  end

  before_each(function()
    reset()
    _G.__shokz_mute = nil
    -- voice_agent stops before it builds anything if there is no interpreter.
    hs.fs._files[os.getenv("HOME") .. "/Github/pipecat-voice-agent/.venv/bin/python"] =
      { mode = "file" }
  end)
  after_each(function()
    context.resetAtExit()
    _G.speak, _G.speakStop, _G.speakSelection = nil, nil, nil
    _G.dictatePreview, _G.dictateHide, _G.dictateFrame = nil, nil, nil
  end)

  for _, name in ipairs(PLUGINS) do
    it(name .. " comes back empty, twice", function()
      for round = 1, 2 do
        local plugin = load(name)
        assert.is_function(plugin.dispose, name .. " has no dispose()")
        assert.equals(round, #hub.made, name .. " drew no tile on round " .. round)
        -- One tile live at a time: made minus deleted, not made.
        assert.equals(1, #hub.made - #hub.deleted, name .. " left a second tile up")

        plugin.dispose()
        assert.equals(0, #hub.made - #hub.deleted, name .. " kept its tile")
        assert.equals(0, held(), name .. " still holds effects after dispose")
      end
    end)
  end
end)
