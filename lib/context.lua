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
