-- The plugin registry: find what is in apps/, load it, and let one be switched
-- off without editing any file.
--
-- init.lua used to name every app in a require list, which meant three things.
-- Adding a plugin was editing someone else's file, which is the part a stranger
-- cannot do. One module that threw on require took down every app after it in
-- the list. And switching an app off meant commenting out a line and reloading.
--
-- So apps/ is the registry. Anything in it with an init.lua, or any single .lua
-- file, is a plugin. Each is required inside a pcall, so a plugin that fails
-- fails alone and says so on its row in the Plugins tile.
--
-- SWITCHING OFF IS ONLY AS GOOD AS THE PLUGIN. A plugin built on lib.context
-- exposes dispose() and genuinely goes away: timers stopped, tile gone, child
-- processes terminated. One that is not can only be stopped from loading next
-- time, because nothing knows what it registered. The menu says which is which
-- rather than pretending the switch means the same thing in both cases.

local context = require("lib.context")

local M = {
  loaded = {},   -- name -> the module table it returned
  failed = {},   -- name -> why it did not load
  order  = {},   -- the order loadAll planned, which is also the tile order
  ctx    = nil,
}

M.DIR          = "apps"
M.DISABLED_KEY = "plugins.disabled"

-- ── Discovery and order ────────────────────────────────────────────────────
-- A plugin is apps/<name>/init.lua or apps/<name>.lua. Symlinked plugins
-- resolve like any other, so one living in another repo needs no special case.
function M.discover(dir)
  dir = dir or ((hs.configdir or ".") .. "/" .. M.DIR)
  local names = {}
  -- hs.fs.dir hands back an iterator AND the directory object it walks, and the
  -- iterator is useless without it. pcall so a missing apps/ is an empty list
  -- rather than a config that will not load.
  local ok, iter, dirObj = pcall(hs.fs.dir, dir)
  if not ok or type(iter) ~= "function" then return names end
  for f in iter, dirObj do
    if f ~= "." and f ~= ".." then
      local single = f:match("^(.+)%.lua$")
      if single then
        names[#names + 1] = single
      elseif hs.fs.attributes(dir .. "/" .. f .. "/init.lua") then
        names[#names + 1] = f
      end
    end
  end
  table.sort(names)
  return names
end

-- Pure. `first` names the plugins whose order matters and fixes their sequence;
-- everything else follows alphabetically. Order is load order, and menuhub
-- draws tiles in registration order, so this is also the row order in the hub.
-- A name in `first` that is not installed is skipped rather than failing, so
-- the list can outlive a plugin.
function M.plan(found, first)
  local have, seen, out = {}, {}, {}
  for _, n in ipairs(found) do have[n] = true end
  for _, n in ipairs(first or {}) do
    if have[n] and not seen[n] then out[#out + 1] = n; seen[n] = true end
  end
  for _, n in ipairs(found) do
    if not seen[n] then out[#out + 1] = n; seen[n] = true end
  end
  return out
end

-- ── What is switched off ───────────────────────────────────────────────────
function M.disabled()
  local raw, set = hs.settings.get(M.DISABLED_KEY), {}
  if type(raw) == "table" then for _, n in ipairs(raw) do set[n] = true end end
  return set
end

function M.setDisabled(set)
  local list = {}
  for n, off in pairs(set) do if off then list[#list + 1] = n end end
  table.sort(list)
  hs.settings.set(M.DISABLED_KEY, list)
end

-- ── Loading ────────────────────────────────────────────────────────────────
function M.load(name)
  if M.loaded[name] then return M.loaded[name] end
  local ok, mod = pcall(require, M.DIR .. "." .. name)
  if not ok then
    M.failed[name] = tostring(mod)
    M.warn(string.format("[plugins] %s did not load: %s", name, tostring(mod)))
    return nil, mod
  end
  M.failed[name] = nil
  -- A module with no return statement hands back `true`; keep a table either
  -- way so callers can ask it for dispose() without checking its type first.
  M.loaded[name] = type(mod) == "table" and mod or {}
  return M.loaded[name]
end

-- Can this plugin be taken out where it stands, or only stopped from loading?
function M.canDispose(name)
  local mod = M.loaded[name]
  return mod ~= nil and type(mod.dispose) == "function"
end

-- Returns true if the plugin actually went away, false if it is still resident
-- and only a reload will finish the job.
function M.unload(name)
  local mod = M.loaded[name]
  M.loaded[name] = nil
  -- Dropped from the cache so re-enabling runs the module again rather than
  -- handing back the already-disposed table.
  package.loaded[M.DIR .. "." .. name] = nil
  if mod and type(mod.dispose) == "function" then
    local ok, err = pcall(mod.dispose)
    if not ok then M.warn(string.format("[plugins] %s dispose failed: %s", name, tostring(err))) end
    return ok
  end
  return false
end

function M.enable(name)
  local set = M.disabled(); set[name] = nil; M.setDisabled(set)
  return M.load(name)
end

function M.disable(name)
  local set = M.disabled(); set[name] = true; M.setDisabled(set)
  return M.unload(name)
end

function M.toggle(name)
  if M.disabled()[name] then M.enable(name) else M.disable(name) end
end

function M.loadAll(first)
  M.order = M.plan(M.discover(), first)
  local off = M.disabled()
  for _, name in ipairs(M.order) do
    if not off[name] then M.load(name) end
  end
  return M.order
end

-- ── The Plugins tile ───────────────────────────────────────────────────────
function M.state()
  local off, out = M.disabled(), {}
  for _, name in ipairs(M.order) do
    out[#out + 1] = {
      name   = name,
      on     = not off[name],
      failed = M.failed[name],
      live   = M.canDispose(name),
    }
  end
  return out
end

-- Pure given `toggle`: the hub menu for the tile. A plugin that is on but has
-- no dispose() says so on its own row, because switching it off there will not
-- take it out of the running config until the next reload.
function M.rows(state, toggle)
  local items, on = {}, 0
  for _, p in ipairs(state or {}) do
    local label = p.name
    if p.failed then
      label = label .. "  ⚠︎ did not load"
    elseif p.on and not p.live then
      label = label .. "  (reload to remove)"
    end
    if p.on and not p.failed then on = on + 1 end
    items[#items + 1] = {
      title = label, switch = true, checked = p.on and not p.failed,
      fn = function() toggle(p.name) end,
    }
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = string.format("%d of %d running", on, #(state or {})),
                        disabled = true }
  return items
end

function M.install()
  if M.ctx then return M.ctx end
  M.ctx = context.new("Plugins")
  local tile = M.ctx:tile("Plugins")
  tile:setTitle("🧩")
  tile:setTooltip(string.format("%d plugins", #M.order))
  tile:setMenu(function() return M.rows(M.state(), M.toggle) end)
  return M.ctx
end

function M.warn(msg) print(msg) end

return M
