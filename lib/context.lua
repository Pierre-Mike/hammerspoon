-- One plugin, one context: everything a plugin builds is registered here, so
-- disposing the context takes all of it back in a single call.
--
-- Hammerspoon has no unload. An app module calls hs.timer.doEvery, hs.task.new
-- or hs.hotkey.bind at require time and those handles live until hs.reload()
-- throws the whole Lua state away. That is fine while every app in apps/ is one
-- we wrote and the only lifecycle is "reload everything". It stops being fine
-- the moment a plugin can be switched off on its own, or came from someone
-- else: a timer whose module is gone still fires, a hotkey still swallows its
-- key, and a task still holds its port.
--
-- So a plugin never calls the hs.* constructors directly. It calls ctx:timer(),
-- ctx:task(), ctx:tile() and friends, which build the same object and remember
-- how to undo it.
--
-- Every constructor returns `handle, release`. The handle is the real hs object
-- with its own methods, so calling code reads exactly as it did before. The
-- second value tears that one effect down early and forgets it — a plugin that
-- kills its own task calls release() instead of task:terminate(), so the
-- context stops holding a handle to a dead process. Code that never needs early
-- teardown just ignores it.

local M = {}

-- Where a teardown failure is reported. A seam, so a test can listen for one
-- instead of letting it print.
function M.warn(msg) print(msg) end

local Context = {}
Context.__index = Context

function M.new(name)
  return setmetatable({
    name      = name,
    _effects  = {},     -- id -> teardown fn, id ascending in build order
    _seq      = 0,
    _disposed = false,
    _canvas   = {},     -- name -> release, for the overlays that are singletons
  }, Context)
end

-- Register a teardown directly. The escape hatch for anything without a wrapper
-- below, and what the wrappers are built on.
--
-- Registering on a context that is already disposed runs the teardown at once
-- rather than storing it: a callback that arrives after teardown must not be
-- able to re-arm a plugin that is supposed to be gone.
function Context:effect(stop)
  if self._disposed then pcall(stop); return function() end end
  self._seq = self._seq + 1
  local id = self._seq
  self._effects[id] = stop
  return function()
    local fn = self._effects[id]
    if not fn then return end       -- already released, or disposed
    self._effects[id] = nil
    pcall(fn)
  end
end

-- Unwind in reverse build order, so a plugin comes apart the way it went
-- together: the tile a timer redraws outlives the timer. Every step is pcall'd,
-- because one teardown that throws must not strand the rest — a plugin failing
-- without taking its neighbours down is the whole point.
function Context:dispose()
  if self._disposed then return end
  self._disposed = true
  local ids = {}
  for id in pairs(self._effects) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return a > b end)
  for _, id in ipairs(ids) do
    local fn = self._effects[id]
    self._effects[id] = nil
    if fn then
      local ok, err = pcall(fn)
      if not ok then M.warn(string.format("[%s] teardown failed: %s", self.name, err)) end
    end
  end
end

-- How many effects are still held. The number a test asserts on, and the number
-- that should come back to zero after dispose.
function Context:count()
  local n = 0
  for _ in pairs(self._effects) do n = n + 1 end
  return n
end

-- ── Timers ─────────────────────────────────────────────────────────────────
function Context:timer(interval, fn)
  local t = hs.timer.doEvery(interval, fn)
  return t, self:effect(function() t:stop() end)
end

-- A one-shot forgets itself as it fires. Without that, a plugin that re-arms a
-- timeout on every start — apps/dsh arms three per start — would grow its
-- teardown list for the life of the session.
function Context:after(delay, fn)
  local release
  local t = hs.timer.doAfter(delay, function()
    if release then release() end
    fn()
  end)
  release = self:effect(function() t:stop() end)
  return t, release
end

-- ── Processes ──────────────────────────────────────────────────────────────
-- Same arguments as hs.task.new, which takes its stream callback and its
-- argument list in either of two shapes, so they are passed through untouched.
-- A plugin disposed mid-run leaves no orphan behind.
function Context:task(...)
  local t = hs.task.new(...)
  return t, self:effect(function() t:terminate() end)
end

-- ── Keys and URLs ──────────────────────────────────────────────────────────
function Context:hotkey(mods, key, pressed, released, repeated)
  local h = hs.hotkey.bind(mods, key, pressed, released, repeated)
  return h, self:effect(function() h:delete() end)
end

-- hs.urlevent routes one handler per name, so an abandoned binding keeps
-- answering hammerspoon://<name> on behalf of a plugin that is no longer there.
-- There is no unbind, so teardown rebinds the name to a handler that does
-- nothing — the URL stops doing damage even though it still resolves.
function Context:url(name, fn)
  hs.urlevent.bind(name, fn)
  return name, self:effect(function() hs.urlevent.bind(name, function() end) end)
end

-- A plugin's shell surface is a global function: `hs -c 'speak("hi")'` runs in
-- this Lua state, so apps/tts publishes speak() the only way a shell can reach
-- it. A global left pointing into a disposed plugin is a command that still
-- answers and no longer works.
--
-- Teardown puts the previous value back rather than clearing the name, so a
-- partial reload that registers over itself leaves the name where it was. It
-- only does so if the name is still ours: something that claimed it in the
-- meantime keeps it, because overwriting a live binding to "clean up" is the
-- same bug one step along.
function Context:global(name, fn)
  local prior = _G[name]
  _G[name] = fn
  return name, self:effect(function()
    if _G[name] == fn then _G[name] = prior end
  end)
end

-- ── Event taps ─────────────────────────────────────────────────────────────
-- The most dangerous thing a plugin can leave behind. A tap sits in front of
-- every keystroke on the machine, and one belonging to a module that is gone
-- still swallows the keys it claimed — apps/dictation's tap eats Fn, so an
-- abandoned one means Fn does nothing, for anyone, until a reload.
--
-- Started here, because a tap that is not running is not a tap and every caller
-- started it on the next line anyway. `types` takes one
-- hs.eventtap.event.types value or a list of them: the constructor wants a
-- list, a single type is what most callers have.
function Context:eventtap(types, fn)
  local tap = hs.eventtap.new(type(types) == "table" and types or { types }, fn)
  tap:start()
  return tap, self:effect(function() tap:stop() end)
end

-- ── Servers ────────────────────────────────────────────────────────────────
-- An abandoned listener is worse than a leak, because a port is exclusive: the
-- plugin cannot be switched off and on again, since its own replacement cannot
-- bind the port the old one is still holding.
--
-- The context's teardown closure is also what keeps the server alive. An
-- unreferenced hs.httpserver is collected soon after load and stops listening
-- with no error anywhere, which is why apps/tts used to have to park its
-- intake on a module field by hand.
function Context:httpserver(port, fn)
  local srv = hs.httpserver.new()
  srv:setPort(port)
  srv:setCallback(fn)
  srv:start()
  return srv, self:effect(function() srv:stop() end)
end

-- ── Watchers ───────────────────────────────────────────────────────────────
-- One method for every hs.*.watcher, because they are all the same shape —
-- new(fn), start(), stop() — and a plugin should not have to remember which
-- namespace a given watcher hides in.
--
--   ctx:watcher("caffeinate", fn)            sleep, wake, unlock
--   ctx:watcher("path", "/tmp/x", fn)        one file or directory
--   ctx:watcher("audio", "dictation", fn)    audio devices, see below
--
-- `path` is whatever the kind needs to name itself and is left out by the ones
-- that watch the whole machine; called without it, the handler lands there and
-- is shifted across.
local WATCHER_NS = {
  caffeinate  = function() return hs.caffeinate  and hs.caffeinate.watcher  end,
  usb         = function() return hs.usb         and hs.usb.watcher         end,
  screen      = function() return hs.screen      and hs.screen.watcher      end,
  application = function() return hs.application and hs.application.watcher end,
  battery     = function() return hs.battery     and hs.battery.watcher     end,
  wifi        = function() return hs.wifi        and hs.wifi.watcher        end,
  spaces      = function() return hs.spaces      and hs.spaces.watcher      end,
}

function Context:watcher(kind, path, fn)
  if fn == nil and type(path) == "function" then path, fn = nil, path end

  -- hs.audiodevice.watcher holds one callback for the whole config, so this
  -- one is a shared service rather than an object: lib/audiowatch owns the
  -- system callback and fans it out by name. `path` is the name to register
  -- under, and teardown takes that name back out — which is the part a plugin
  -- could not do for itself before, because the registry had no way to forget.
  if kind == "audio" or kind == "audiodevice" then
    local name = path or self.name
    local aw = require("lib.audiowatch")
    aw.on(name, fn)
    return name, self:effect(function() aw.off(name) end)
  end

  if kind == "path" then
    if not hs.pathwatcher then return nil, function() end end
    local w = hs.pathwatcher.new(path, fn)
    w:start()
    return w, self:effect(function() w:stop() end)
  end

  local lookup = WATCHER_NS[kind]
  -- A kind that is not in the table is a typo, which is worth saying out loud:
  -- returning nothing would read as "this Mac has no such watcher" and the
  -- plugin would carry on quietly doing less than it was written to do.
  if not lookup then error("context: no watcher of kind " .. tostring(kind), 2) end
  local ns = lookup()
  -- The namespace itself being absent is an environment fact, not a mistake:
  -- an older Hammerspoon, or a spec running headless. The plugin asks for the
  -- watcher it wants and carries on without one, instead of guarding the call.
  if not ns then return nil, function() end end
  local w = ns.new(fn)
  w:start()
  return w, self:effect(function() w:stop() end)
end

-- ── Overlays ───────────────────────────────────────────────────────────────
-- A canvas is a window. One left behind floats over every space with nothing
-- left that could delete it — apps/dictation's preview panel would sit in the
-- middle of the screen for the rest of the session.
--
-- Named, because every canvas in this config is a singleton that gets rebuilt
-- rather than added to: a HUD, a notification, a live preview. Asking for a
-- name that is already drawn takes the old one down first, so the code that
-- rebuilds one no longer has to remember to delete the last. `frame` is the
-- rect hs.canvas.new wants; pass it alone for a canvas that needs no name.
function Context:canvas(name, frame)
  if type(name) == "table" then name, frame = nil, name end
  if name and self._canvas[name] then self._canvas[name]() end
  local c = hs.canvas.new(frame)
  local release = self:effect(function()
    if name then self._canvas[name] = nil end
    c:delete()
  end)
  if name then self._canvas[name] = release end
  return c, release
end

-- ── Sound ──────────────────────────────────────────────────────────────────
-- A sound that is playing when its plugin goes away keeps playing, and
-- apps/brown_noise loops its WAV forever: "switched off" would mean "still
-- making noise, with nothing left to stop it".
--
-- A name with no slash in it is one of macOS's own sounds, anything else is a
-- file. Both shapes are already in use — dictation's earcons are system
-- sounds, the noise machine's are WAVs beside this file — so the distinction
-- is made here once instead of at every call site.
--
-- A sound that will not load comes back nil rather than raising. An earcon is
-- decoration: a missing .aiff must never cost a dictation.
function Context:sound(path)
  local ok, snd
  if type(path) == "string" and path:find("/", 1, true) then
    ok, snd = pcall(hs.sound.getByFile, path)
    -- Older builds name the same constructor soundFromFile.
    if not ok or not snd then ok, snd = pcall(hs.sound.soundFromFile, path) end
  else
    ok, snd = pcall(hs.sound.getByName, path)
  end
  if not ok or not snd then return nil, function() end end
  return snd, self:effect(function() snd:stop() end)
end

-- ── Quitting ───────────────────────────────────────────────────────────────
-- hs.shutdownCallback is one global slot, so the last plugin to set it wins and
-- the one it replaced stops running at quit without either of them noticing.
-- apps/noseguard holds it today to reap its camera daemon; the next plugin that
-- wanted one would have taken that away silently.
--
-- So every context registers here instead, one shared callback fans out, and a
-- disposed plugin stops being called. Anything already in the slot when the
-- first context arrives is kept and still runs first.
--
-- Returns release only: there is no handle to hold.
local atExit, atExitSeq, installed = {}, 0, false

function Context:atExit(fn)
  if not installed then
    installed = true
    local prior = hs.shutdownCallback
    hs.shutdownCallback = function()
      if prior then pcall(prior) end
      for _, h in pairs(atExit) do pcall(h) end
    end
  end
  atExitSeq = atExitSeq + 1
  local id = atExitSeq
  atExit[id] = fn
  return self:effect(function() atExit[id] = nil end)
end

-- Test seam: forget every registration and release the global slot.
function M.resetAtExit()
  atExit, installed = {}, false
  hs.shutdownCallback = nil
end

-- ── Menu hub ───────────────────────────────────────────────────────────────
-- The hub is this config's one shared service. A plugin asks its context for a
-- tile instead of requiring the hub itself, so the tile leaves with the plugin,
-- and so a context can one day hand out a different hub — or none, for a plugin
-- running headless in a test — without the plugin knowing.
function Context:tile(name)
  local tile = require("lib.menuhub").item(name)
  return tile, self:effect(function() tile:delete() end)
end

return M
