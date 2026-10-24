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
local design  = require("lib.design")

local M = {
  loaded    = {},   -- name -> the module table it returned
  failed    = {},   -- name -> why it did not load
  order     = {},   -- the order loadAll planned, which is also the tile order
  sources   = {},   -- name -> { dir = "apps" | "plugins", path = <directory on disk> }
  manifests = {},   -- name -> the checked plugin.lua, for plugins that have one
  objects   = {},   -- name -> the plugin object handed to an entry function
  actions   = {},   -- "id.name" -> fn, from plugin.action
  cycles    = {},   -- names whose after/needs go in a circle
  ctx       = nil,
}

M.DIR          = "apps"
M.EXTRA_DIR    = "plugins"      -- optional: a second place to drop plugins
M.MANIFEST     = "plugin.lua"
M.DISABLED_KEY = "plugins.disabled"

-- The version of the plugin API this config provides. A manifest names the one
-- it was written for in `api`; a plugin that asks for a newer one than this does
-- not load, and says why. Bump it only when an existing plugin would break.
M.API = 1

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

-- Everything loadAll can see: apps/ first, then the optional plugins/ folder.
-- A name in both belongs to apps/, because that is the one the repo ships.
-- Fills M.sources so load() knows which folder to require from.
function M.discoverAll()
  local base = (hs.configdir or ".") .. "/"
  local names = {}
  M.sources = {}
  for _, dir in ipairs({ M.DIR, M.EXTRA_DIR }) do
    for _, n in ipairs(M.discover(base .. dir)) do
      if not M.sources[n] then
        M.sources[n] = { dir = dir, path = base .. dir }
        names[#names + 1] = n
      end
    end
  end
  table.sort(names)
  return names
end

-- ── Manifests ──────────────────────────────────────────────────────────────
-- A plugin folder may carry a plugin.lua that returns plain data: who the plugin
-- is, what it needs and where it sits in the order. It is read, never run as
-- part of the plugin: the chunk gets an empty environment, so it cannot call
-- anything, and a plugin with no manifest keeps loading exactly as before.
--
--   return {
--     id = "my_app", name = "My app", version = "1.0.0", api = 1,
--     author = "you", description = "One line.",
--     after = { "dictation" },                 -- load after these if present
--     needs = { "tts" },                       -- refuse to load unless these run
--     settings = { volume = { type = "number", default = 50, min = 0, max = 100 } },
--   }
function M.readchunk(path)
  local fn, err = loadfile(path, "t", {})
  if not fn then return nil, err end
  local ok, value = pcall(fn)
  if not ok then return nil, value end
  return value
end

local function isList(v)
  if type(v) ~= "table" then return false end
  for _, x in ipairs(v) do if type(x) ~= "string" then return false end end
  return true
end

local SETTING_TYPES = { boolean = true, number = true, string = true, choice = true }

-- Pure. Checks a manifest table and fills the defaults; returns it, or nil and
-- the first thing wrong with it.
function M.check(name, raw)
  if type(raw) ~= "table" then return nil, "plugin.lua must return a table" end
  local m = {
    id = raw.id or name, name = raw.name or name, version = raw.version or "0.0.0",
    api = raw.api or 1, author = raw.author, description = raw.description,
    after = raw.after or {}, needs = raw.needs or {}, settings = raw.settings or {},
  }
  if type(m.id) ~= "string" or m.id ~= name then
    return nil, string.format("id %q must match the folder name %q", tostring(raw.id), name)
  end
  if type(m.api) ~= "number" or m.api < 1 or m.api % 1 ~= 0 then
    return nil, "api must be a whole number from 1"
  end
  for _, field in ipairs({ "name", "version" }) do
    if type(m[field]) ~= "string" then return nil, field .. " must be a string" end
  end
  for _, field in ipairs({ "after", "needs" }) do
    if not isList(m[field]) then return nil, field .. " must be a list of plugin names" end
  end
  if type(m.settings) ~= "table" then return nil, "settings must be a table" end
  for key, def in pairs(m.settings) do
    if type(def) ~= "table" or not SETTING_TYPES[def.type] then
      return nil, string.format("setting %q needs a type of boolean, number, string or choice", tostring(key))
    end
    if def.type == "choice" and not isList(def.options) then
      return nil, string.format("setting %q is a choice and needs a list of options", tostring(key))
    end
    if def.default ~= nil and not M.valid(def, def.default) then
      return nil, string.format("setting %q has a default that does not fit its type", tostring(key))
    end
  end
  return m
end

-- Does `value` fit a setting definition?
function M.valid(def, value)
  if def.type == "boolean" then return type(value) == "boolean" end
  if def.type == "string" then return type(value) == "string" end
  if def.type == "number" then
    return type(value) == "number"
       and (def.min == nil or value >= def.min) and (def.max == nil or value <= def.max)
  end
  if def.type == "choice" then
    for _, o in ipairs(def.options or {}) do if o == value then return true end end
  end
  return false
end

-- The manifest for a plugin: nil when it has none (a legacy plugin), or nil and
-- why when it has one that is wrong.
function M.manifest(name)
  local src = M.sources[name] or { path = (hs.configdir or ".") .. "/" .. M.DIR }
  local path = src.path .. "/" .. name .. "/" .. M.MANIFEST
  if not hs.fs.attributes(path) then return nil end
  local raw, err = M.readchunk(path)
  if raw == nil then return nil, "plugin.lua: " .. tostring(err) end
  local m, why = M.check(name, raw)
  if not m then return nil, "plugin.lua: " .. why end
  return m
end

-- Pure. `first` names the plugins whose order matters and fixes their sequence;
-- everything else follows alphabetically. Order is load order, and menuhub
-- draws tiles in registration order, so this is also the row order in the hub.
-- A name in `first` that is not installed is skipped rather than failing, so
-- the list can outlive a plugin.
--
-- `manifests` (name -> checked manifest) refines that order. A plugin that says
-- `after` or `needs` another is moved to follow it, and nothing else moves: the
-- list above is the fallback for every plugin that states no preference. A
-- circle of dependencies cannot be ordered, so those plugins keep their place
-- and are returned in the second value.
function M.plan(found, first, manifests)
  local have, seen, base = {}, {}, {}
  for _, n in ipairs(found) do have[n] = true end
  for _, n in ipairs(first or {}) do
    if have[n] and not seen[n] then base[#base + 1] = n; seen[n] = true end
  end
  for _, n in ipairs(found) do
    if not seen[n] then base[#base + 1] = n; seen[n] = true end
  end
  if not manifests or next(manifests) == nil then return base, {} end

  local function deps(n)
    local m, out = manifests[n], {}
    if not m then return out end
    for _, list in ipairs({ m.after or {}, m.needs or {} }) do
      for _, d in ipairs(list) do if have[d] and d ~= n then out[#out + 1] = d end end
    end
    return out
  end

  local out, done, pending = {}, {}, base
  while #pending > 0 do
    local rest, moved = {}, false
    for _, n in ipairs(pending) do
      local ready = not moved
      if ready then
        for _, d in ipairs(deps(n)) do if not done[d] then ready = false; break end end
      end
      if ready then out[#out + 1] = n; done[n] = true; moved = true
      else rest[#rest + 1] = n end
    end
    if not moved then
      for _, n in ipairs(rest) do out[#out + 1] = n end
      return out, rest
    end
    pending = rest
  end
  return out, {}
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

-- ── The plugin object ─────────────────────────────────────────────────────
-- What an entry function receives. A plugin written as
--
--   return function(plugin) ... return { start = fn, stop = fn } end
--
-- gets one object instead of requiring half a dozen libs. Everything it builds
-- through `plugin` is undone when it is switched off.
--
--   plugin.id, plugin.manifest, plugin.api
--   plugin.ctx                      the lib/context.lua behind everything below
--   plugin.ui                       toasts, huds, bars (lib/ui.lua)
--   plugin.log(fmt, ...)            a line in the Hammerspoon console, tagged with the id
--   plugin.settings.get(key)        a value from the manifest's schema, or its default
--   plugin.settings.set(key, v)     true, or false and why; remembered across reloads
--   plugin.on(event, fn)            "start", "stop", "settings", or "plugin:loaded" /
--                                   "plugin:unloaded" for the others; returns an off() fn
--   plugin.tile(title)              the hub tile
--   plugin.action(name, fn)         a named thing other code can run: plugins.run("id.name")
function M.settingKey(id, key) return "plugin." .. id .. "." .. key end

function M.newObject(name, manifest)
  local id = manifest and manifest.id or name
  local ctx = context.new(manifest and manifest.name or name)
  local listeners = {}
  local p = { id = id, manifest = manifest, api = M.API, ctx = ctx }

  p.ui = ctx:ui()
  function p.log(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    M.warn(string.format("[%s] %s", id, ok and line or tostring(fmt)))
  end

  function p.on(event, fn)
    local list = listeners[event] or {}
    listeners[event] = list
    list[#list + 1] = fn
    return ctx:effect(function()
      for i, f in ipairs(list) do if f == fn then table.remove(list, i); break end end
    end)
  end
  function p.emit(event, ...)
    for _, fn in ipairs({ table.unpack(listeners[event] or {}) }) do
      local ok, err = pcall(fn, ...)
      if not ok then p.log("%s listener failed: %s", event, tostring(err)) end
    end
  end

  local schema = manifest and manifest.settings or {}
  p.settings = {
    get = function(key)
      local def = schema[key]
      if not def then return nil end
      local v = hs.settings.get(M.settingKey(id, key))
      if v ~= nil and M.valid(def, v) then return v end
      return def.default
    end,
    set = function(key, value)
      local def = schema[key]
      if not def then return false, "no setting " .. tostring(key) end
      if not M.valid(def, value) then
        return false, string.format("%s does not fit %s", tostring(value), def.type)
      end
      hs.settings.set(M.settingKey(id, key), value)
      p.emit("settings", key, value)
      return true
    end,
  }

  function p.tile(title) return ctx:tile(title or (manifest and manifest.name) or name) end
  function p.action(action, fn)
    local full = id .. "." .. action
    M.actions[full] = fn
    return ctx:effect(function() if M.actions[full] == fn then M.actions[full] = nil end end)
  end
  return p
end

function M.run(action, ...)
  local fn = M.actions[action]
  if not fn then return nil, "no action " .. tostring(action) end
  return fn(...)
end

-- Local to the plugin system: tell every plugin that a neighbour came or went.
local function announce(event, id)
  for name, other in pairs(M.objects) do
    if name ~= id then other.emit(event, id) end
  end
end

-- Runs an entry function against a fresh plugin object, then its start hook.
-- Returns the module (whatever the entry returned, as a table) and the object.
-- On any failure the half-built plugin is torn down, so a throw in start()
-- leaves no tile or timer behind.
function M.activate(name, entry, manifest)
  local p = M.newObject(name, manifest)
  local ok, mod = pcall(entry, p)
  if ok then
    mod = type(mod) == "table" and mod or {}
    if type(mod.start) == "function" then
      ok, mod = pcall(function() mod.start(p); return mod end)
    end
  end
  if not ok then
    p.ctx:dispose()
    return nil, mod
  end
  M.objects[name] = p
  p.emit("start")
  return mod, p
end

-- ── Loading ────────────────────────────────────────────────────────────────
-- Why a plugin must not load: its manifest is wrong, wants a newer API than
-- this config has, or needs a plugin that is not running.
function M.refusal(name)
  local m, err = M.manifest(name)
  if err then return err end
  if not m then return nil end
  M.manifests[name] = m
  if m.api > M.API then
    return string.format("wants plugin API %d, this config provides %d", m.api, M.API)
  end
  for _, need in ipairs(m.needs) do
    if not M.loaded[need] then return string.format("needs %s, which is not running", need) end
  end
  return nil
end

function M.load(name)
  if M.loaded[name] then return M.loaded[name] end
  local why = M.refusal(name)
  if why then
    M.failed[name] = why
    M.warn(string.format("[plugins] %s did not load: %s", name, why))
    return nil, why
  end
  local src = M.sources[name]
  local modname = (src and src.dir or M.DIR) .. "." .. name
  local ok, mod = pcall(require, modname)
  local p
  if ok and type(mod) == "function" then
    -- Entry style: the module is a function, run it with the plugin object.
    local entry = mod
    package.loaded[modname] = nil
    mod, p = M.activate(name, entry, M.manifests[name])
    ok = mod ~= nil
    if not ok then mod = p end
  end
  if not ok then
    M.failed[name] = tostring(mod)
    M.warn(string.format("[plugins] %s did not load: %s", name, tostring(mod)))
    return nil, mod
  end
  M.failed[name] = nil
  -- A module with no return statement hands back `true`; keep a table either
  -- way so callers can ask it for dispose() without checking its type first.
  M.loaded[name] = type(mod) == "table" and mod or {}
  announce("plugin:loaded", name)
  return M.loaded[name]
end

-- Can this plugin be taken out where it stands, or only stopped from loading?
function M.canDispose(name)
  local mod = M.loaded[name]
  return mod ~= nil and (M.objects[name] ~= nil or type(mod.dispose) == "function")
end

-- Returns true if the plugin actually went away, false if it is still resident
-- and only a reload will finish the job.
function M.unload(name)
  local mod = M.loaded[name]
  M.loaded[name] = nil
  -- Dropped from the cache so re-enabling runs the module again rather than
  -- handing back the already-disposed table.
  local src = M.sources[name]
  package.loaded[(src and src.dir or M.DIR) .. "." .. name] = nil
  local gone, p = false, M.objects[name]
  if p then
    M.objects[name] = nil
    p.emit("stop")
    -- stop is optional: the context undoes everything the plugin built anyway.
    if mod and type(mod.stop) == "function" then
      local ok, err = pcall(mod.stop, p)
      if not ok then M.warn(string.format("[plugins] %s stop failed: %s", name, tostring(err))) end
    end
    p.ctx:dispose()
    gone = true
  end
  if mod and type(mod.dispose) == "function" then
    local ok, err = pcall(mod.dispose)
    if not ok then M.warn(string.format("[plugins] %s dispose failed: %s", name, tostring(err))) end
    gone = ok or gone
  end
  if mod then announce("plugin:unloaded", name) end
  return gone
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
  local found = M.discoverAll()
  M.manifests = {}
  -- A broken manifest is reported by load(); here it only means no ordering hints.
  for _, name in ipairs(found) do
    local m = M.manifest(name)
    if m then M.manifests[name] = m end
  end
  M.order, M.cycles = M.plan(found, first, M.manifests)
  for _, name in ipairs(M.cycles) do
    M.warn(string.format("[plugins] %s is in a circle of after/needs; it keeps its default place", name))
  end
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
    local m = M.manifests[name]
    out[#out + 1] = {
      name   = name,
      on     = not off[name],
      failed = M.failed[name],
      live   = M.canDispose(name),
      version = m and m.version, description = m and m.description,
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
  -- Every component of the shared look, drawn once, so a change to
  -- lib/theme.lua can be looked at: from here, or `hs -c 'uiGallery()'`.
  local function gallery() require("lib.ui").gallery(M.ctx:ui()) end
  M.ctx:global("uiGallery", gallery)
  M.ctx:global("uiDesign", M.useDesign)
  M.ctx:global("uiShoot", function(dir) return require("lib.ui").shoot(M.ctx:ui(), dir or "/tmp/hs-design") end)
  tile:setMenu(function()
    local rows = M.rows(M.state(), M.toggle)
    table.insert(rows, #rows, require("lib.ui").menu.submenu("Design", M.designRows))
    table.insert(rows, #rows, { title = "Preview the UI kit", fn = gallery })
    return rows
  end)
  -- macOS switching between light and dark. A design that follows the system
  -- rebuilds its overlay colors in place, no reload; the short wait is because
  -- the notification can arrive before interfaceStyle() reports the new value.
  local dn = hs.distributednotifications
  if dn and dn.new then
    local watcher = dn.new(function()
      M.ctx:after(0.3, function() require("lib.theme").refresh() end)
    end, "AppleInterfaceThemeChangedNotification")
    watcher:start()
    M.ctx:effect(function() watcher:stop() end)
  end
  -- A reload that uiDesign() asked for: show the new look straight away.
  if design.takePreview() then M.ctx:after(1.5, gallery) end
  return M.ctx
end

-- ── Designs ────────────────────────────────────────────────────────────────
-- The Design submenu: one row per file in designs/, the active one ticked.
-- Picking one switches and reloads (lib/design.use).
function M.designRows()
  local menu = require("lib.ui").menu
  local current, rows = design.current(), {}
  for _, name in ipairs(design.list()) do
    local d = design.overrides(name)
    local label = d.name or name
    if d.description then label = label .. "  ·  " .. d.description end
    rows[#rows + 1] = menu.choice(label, name == current, function() design.use(name) end)
  end
  rows[#rows + 1] = menu.separator()
  rows[#rows + 1] = menu.text("Edit or add files in designs/, then pick one here")
  return rows
end

-- hs -c 'uiDesign()'          the active design and the ones on disk
-- hs -c 'uiDesign("warm")'    switch to designs/warm.lua and reload
function M.useDesign(name)
  local list = design.list()
  if name == nil then
    return string.format("design: %s (available: %s)", design.current(), table.concat(list, ", "))
  end
  for _, n in ipairs(list) do
    if n == name then design.use(name); return "switching to " .. name end
  end
  return string.format("no design %q in designs/ (available: %s)", tostring(name), table.concat(list, ", "))
end

function M.warn(msg) print(msg) end

return M
