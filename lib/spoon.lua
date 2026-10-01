-- Load a third-party Spoon into a context, so it arrives with a hub tile and
-- leaves without a trace.
--
-- Spoons are Hammerspoon's own plugin format and the reason this shim exists: a
-- folder under Spoons/, a table carrying name/version/author, and by convention
-- :init(), :start(), :stop() and :bindHotkeys(). People already publish them,
-- so a plugin system that speaks Spoon starts with an ecosystem instead of
-- asking for one.
--
-- What hs.loadSpoon() does not give us is a way to take a Spoon back out.
-- :stop() is a convention rather than a contract: plenty of Spoons do not have
-- one, and plenty of the ones that do leave a timer or a hotkey running behind
-- it. So the shim works from both ends.
--
--   • It registers :stop() as a teardown, which is all a well-behaved Spoon
--     needs, and runs it first so the Spoon shuts itself down in its own order.
--   • While :bindHotkeys() and :start() run, it swaps the hs.* constructors for
--     recording ones, so the handles a Spoon builds for itself are tracked
--     whether or not its :stop() remembers them.
--
-- That capture is honest about its reach. It sees constructors called DURING
-- those two calls and nothing else, so a Spoon that arms a timer later, from
-- inside one of its own callbacks, still escapes it. Without the Spoon's
-- cooperation that is the ceiling, and it is worth being plain about: this
-- makes a careless Spoon survivable, not safe.

local context = require("lib.context")

local M = {}

-- The constructors worth intercepting, and how each handle is undone. Anything
-- missing from the running Hammerspoon (or from the test mock) is skipped
-- rather than stubbed, so this list can name more than a given host provides.
local CAPTURED = {
  { mod = "timer",    fn = "doEvery", stop = function(h) h:stop() end },
  { mod = "timer",    fn = "doAfter", stop = function(h) h:stop() end },
  { mod = "timer",    fn = "new",     stop = function(h) h:stop() end },
  { mod = "hotkey",   fn = "bind",    stop = function(h) h:delete() end },
  { mod = "hotkey",   fn = "new",     stop = function(h) h:delete() end },
  { mod = "task",     fn = "new",     stop = function(h) h:terminate() end },
  { mod = "menubar",  fn = "new",     stop = function(h) h:delete() end },
  { mod = "eventtap", fn = "new",     stop = function(h) h:stop() end },
}

-- Run `fn` with the constructors above recording into `ctx`. The originals go
-- back on whether fn returns or throws, because leaving a recording constructor
-- installed would quietly attribute the next plugin's timers to this one.
function M.capture(ctx, fn)
  local saved = {}
  for _, c in ipairs(CAPTURED) do
    local mod = hs[c.mod]
    if type(mod) == "table" and type(mod[c.fn]) == "function" then
      local orig = mod[c.fn]
      saved[#saved + 1] = { mod = mod, name = c.fn, orig = orig }
      mod[c.fn] = function(...)
        local handle = orig(...)
        if handle ~= nil then ctx:effect(function() c.stop(handle) end) end
        return handle
      end
    end
  end
  local ok, err = pcall(fn)
  for _, s in ipairs(saved) do s.mod[s.name] = s.orig end
  return ok, err
end

-- Pure: the one-line identity a Spoon exposes, for its tooltip. Authors are
-- written "Name <email>" by convention and the address is noise on a tooltip.
function M.describe(obj)
  obj = obj or {}
  local bits = { tostring(obj.name or "Spoon") }
  if obj.version then bits[#bits + 1] = "v" .. tostring(obj.version) end
  if obj.author then bits[#bits + 1] = (tostring(obj.author):gsub("%s*<[^>]*>%s*$", "")) end
  return table.concat(bits, " · ")
end

-- Load, start and register a Spoon. Returns `ctx, obj` — dispose the context to
-- remove the Spoon — or `nil, reason` if it never got off the ground.
--
-- opts.hotkeys  passed to :bindHotkeys() when the Spoon offers one
-- opts.title    tile name, defaulting to the Spoon's own
-- opts.icon     tile glyph
-- opts.menu     tile menu, table or function, as menuhub takes it
-- opts.tile     false for a Spoon that should run without one
function M.load(name, opts)
  opts = opts or {}

  local ok, obj = pcall(hs.loadSpoon, name, false)
  if not ok or type(obj) ~= "table" then
    return nil, string.format("Spoon %s did not load: %s", name, tostring(obj))
  end

  local ctx = context.new(name)

  local started, err = M.capture(ctx, function()
    if opts.hotkeys and type(obj.bindHotkeys) == "function" then
      obj:bindHotkeys(opts.hotkeys)
    end
    if type(obj.start) == "function" then obj:start() end
  end)
  if not started then
    ctx:dispose()
    return nil, string.format("Spoon %s failed to start: %s", name, tostring(err))
  end

  -- Registered after the capture so it tears down before it: dispose runs in
  -- reverse, the Spoon gets to stop itself properly, and only then do we sweep
  -- up whatever it left holding.
  if type(obj.stop) == "function" then
    ctx:effect(function() obj:stop() end)
  end

  if opts.tile ~= false then
    local tile = ctx:tile(opts.title or obj.name or name)
    tile:setTitle(opts.icon or "🥄")
    tile:setTooltip(M.describe(obj))
    if opts.menu then tile:setMenu(opts.menu) end
  end

  return ctx, obj
end

return M
