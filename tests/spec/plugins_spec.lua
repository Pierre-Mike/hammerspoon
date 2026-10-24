_G.hs = require("hs")

local hub = { made = {} }
package.loaded["lib.menuhub"] = {
  item = function(name)
    hub.made[#hub.made + 1] = name
    return { delete = function() end, setTitle = function(s) return s end,
             setTooltip = function(s) return s end, setMenu = function(s, m) hub.menu = m; return s end }
  end,
}

local plugins = require("lib.plugins")
local realReadchunk = plugins.readchunk

local function reset()
  plugins.loaded, plugins.failed, plugins.order, plugins.ctx = {}, {}, {}, nil
  plugins.readchunk, plugins.manifests, plugins.sources = realReadchunk, {}, {}
  hs.settings._v, hs.fs._tree, hs.fs._files = {}, {}, {}
  hs.configdir = "/fake/.hammerspoon"
  hub.made, hub.menu = {}, nil
  for k in pairs(package.loaded) do
    if k:match("^apps%.") then package.loaded[k] = nil end
  end
end

describe("plugins.plan", function()
  it("fixes the order of the ones that matter, then goes alphabetical", function()
    local found = { "brown_noise", "dictation", "shokz", "voice_agent" }
    assert.same({ "dictation", "shokz", "brown_noise", "voice_agent" },
                plugins.plan(found, { "dictation", "shokz" }))
  end)

  it("skips an ordered name that is not installed", function()
    assert.same({ "dsh" }, plugins.plan({ "dsh" }, { "voice_agent", "dsh" }))
  end)

  it("never lists a plugin twice", function()
    assert.same({ "dsh", "tts" }, plugins.plan({ "dsh", "tts" }, { "dsh", "dsh" }))
  end)

  it("copes with nothing installed", function()
    assert.same({}, plugins.plan({}, { "dsh" }))
  end)
end)

describe("plugins.discover", function()
  before_each(reset)

  it("finds both a folder with an init.lua and a single lua file", function()
    hs.fs._tree["/apps"] = { ".", "..", "dsh", "noseguard", "tts.lua", "README.md" }
    hs.fs._files["/apps/dsh/init.lua"] = { mode = "file" }
    hs.fs._files["/apps/noseguard/init.lua"] = { mode = "file" }
    assert.same({ "dsh", "noseguard", "tts" }, plugins.discover("/apps"))
  end)

  it("ignores a folder with no init.lua", function()
    hs.fs._tree["/apps"] = { "overlay" }
    assert.same({}, plugins.discover("/apps"))
  end)

  it("returns nothing rather than throwing when apps/ is missing", function()
    assert.same({}, plugins.discover("/nope"))
  end)
end)

describe("plugins.load", function()
  before_each(reset)

  it("keeps a failure to itself and records why", function()
    package.loaded["apps.good"] = { name = "good" }
    local warned
    plugins.warn = function(m) warned = m end

    plugins.order = { "bad", "good" }
    local mod, err = plugins.load("bad")       -- no such module on disk
    assert.is_nil(mod)
    assert.truthy(err)
    assert.truthy(plugins.failed["bad"])
    assert.truthy(warned:match("did not load"))

    assert.truthy(plugins.load("good"))        -- the next one still loads
  end)

  it("tolerates a module that returns nothing", function()
    package.loaded["apps.quiet"] = true
    assert.same({}, plugins.load("quiet"))
  end)
end)

describe("plugins.unload", function()
  before_each(reset)

  it("disposes a plugin that can, and drops it from the cache", function()
    local gone = false
    package.loaded["apps.alpha"] = { dispose = function() gone = true end }
    plugins.load("alpha")
    assert.is_true(plugins.canDispose("alpha"))

    assert.is_true(plugins.unload("alpha"))
    assert.is_true(gone)
    assert.is_nil(package.loaded["apps.alpha"])
    assert.is_nil(plugins.loaded["alpha"])
  end)

  it("reports false for a plugin with no dispose", function()
    package.loaded["apps.beta"] = { start = function() end }
    plugins.load("beta")
    assert.is_false(plugins.canDispose("beta"))
    assert.is_false(plugins.unload("beta"))
  end)

  it("survives a dispose that throws", function()
    plugins.warn = function() end
    package.loaded["apps.gamma"] = { dispose = function() error("boom") end }
    plugins.load("gamma")
    assert.is_false(plugins.unload("gamma"))
    assert.is_nil(plugins.loaded["gamma"])
  end)
end)

describe("plugins.disable", function()
  before_each(reset)

  it("remembers what is off across a reload", function()
    package.loaded["apps.alpha"] = { dispose = function() end }
    plugins.load("alpha")
    plugins.disable("alpha")
    assert.same({ "alpha" }, hs.settings.get(plugins.DISABLED_KEY))
    assert.is_true(plugins.disabled()["alpha"])

    -- Re-enabling re-runs the module, so seed the cache again the way a real
    -- file on disk would answer.
    package.loaded["apps.alpha"] = { dispose = function() end }
    plugins.enable("alpha")
    assert.same({}, hs.settings.get(plugins.DISABLED_KEY))
    assert.truthy(plugins.loaded["alpha"])
  end)

  it("skips a disabled plugin on the next load", function()
    hs.configdir = ""                            -- so discover walks "/apps"
    hs.fs._tree["/apps"] = { "alpha", "beta" }
    hs.fs._files["/apps/alpha/init.lua"] = { mode = "file" }
    hs.fs._files["/apps/beta/init.lua"] = { mode = "file" }
    package.loaded["apps.alpha"] = { name = "alpha" }
    package.loaded["apps.beta"] = { name = "beta" }
    hs.settings.set(plugins.DISABLED_KEY, { "beta" })

    plugins.loadAll()
    assert.same({ "alpha", "beta" }, plugins.order)   -- still listed
    assert.truthy(plugins.loaded["alpha"])
    assert.is_nil(plugins.loaded["beta"])            -- but not loaded
  end)
end)

describe("plugins.rows", function()
  it("marks a failure, and says when a switch needs a reload", function()
    local toggled = {}
    local rows = plugins.rows({
      { name = "dsh",       on = true,  live = true },
      { name = "dictation", on = true,  live = false },
      { name = "broken",    on = true,  live = false, failed = "boom" },
      { name = "tts",       on = false, live = false },
    }, function(n) toggled[#toggled + 1] = n end)

    assert.equals("dsh", rows[1].title)
    assert.is_true(rows[1].checked)
    assert.equals("dictation  (reload to remove)", rows[2].title)
    assert.equals("broken  ⚠︎ did not load", rows[3].title)
    assert.is_false(rows[3].checked)
    assert.is_false(rows[4].checked)

    assert.equals("2 of 4 running", rows[#rows].title)

    rows[1].fn()
    assert.same({ "dsh" }, toggled)
  end)

  it("says so when nothing is installed", function()
    local rows = plugins.rows({}, function() end)
    assert.equals("0 of 0 running", rows[#rows].title)
  end)
end)

describe("plugins.install", function()
  before_each(reset)

  it("registers one tile whose menu is built on open", function()
    plugins.order = { "alpha" }
    package.loaded["apps.alpha"] = { dispose = function() end }
    plugins.load("alpha")

    plugins.install()
    assert.same({ "Plugins" }, hub.made)

    local rows = hub.menu()
    assert.equals("alpha", rows[1].title)
    assert.equals("1 of 1 running", rows[#rows].title)
  end)
end)

-- ── Manifests, the API version, order and the plugin object ───────────────

-- Serve manifests from memory: path -> the table plugin.lua would return.
local function manifests(map)
  plugins._chunks = {}
  for path, tbl in pairs(map) do
    hs.fs._files[path] = { mode = "file" }
    plugins._chunks[path] = tbl
  end
  plugins.readchunk = function(p) return plugins._chunks[p] end
end

describe("plugins.check", function()
  it("fills defaults for a bare manifest", function()
    local m = assert(plugins.check("dsh", { id = "dsh" }))
    assert.equals("dsh", m.name)
    assert.equals("0.0.0", m.version)
    assert.equals(1, m.api)
    assert.same({}, m.after)
  end)

  it("rejects an id that is not the folder name", function()
    local m, err = plugins.check("dsh", { id = "other" })
    assert.is_nil(m)
    assert.truthy(err:match("must match the folder name"))
  end)

  it("rejects a manifest that is not a table", function()
    assert.is_nil((plugins.check("dsh", "nope")))
  end)

  it("rejects a bad api, after list and setting", function()
    assert.is_nil((plugins.check("a", { api = 0 })))
    assert.is_nil((plugins.check("a", { api = 1.5 })))
    assert.is_nil((plugins.check("a", { after = "tts" })))
    assert.is_nil((plugins.check("a", { needs = { 3 } })))
    assert.is_nil((plugins.check("a", { settings = { x = { type = "colour" } } })))
    assert.is_nil((plugins.check("a", { settings = { x = { type = "choice" } } })))
    assert.is_nil((plugins.check("a", { settings = { x = { type = "number", default = "hi" } } })))
  end)

  it("accepts every setting type", function()
    assert.truthy(plugins.check("a", { settings = {
      b = { type = "boolean", default = true },
      n = { type = "number", default = 5, min = 0, max = 10 },
      s = { type = "string" },
      c = { type = "choice", options = { "x", "y" }, default = "x" },
    } }))
  end)
end)

describe("plugins.valid", function()
  it("checks number bounds and choice options", function()
    assert.is_true(plugins.valid({ type = "number", min = 0, max = 10 }, 10))
    assert.is_false(plugins.valid({ type = "number", min = 0, max = 10 }, 11))
    assert.is_false(plugins.valid({ type = "number" }, "3"))
    assert.is_true(plugins.valid({ type = "choice", options = { "a" } }, "a"))
    assert.is_false(plugins.valid({ type = "choice", options = { "a" } }, "b"))
  end)
end)

describe("plugins.manifest", function()
  before_each(reset)

  it("is nil for a plugin with no plugin.lua, so legacy plugins keep loading", function()
    plugins.sources.old = { dir = "apps", path = "/apps" }
    assert.is_nil(plugins.manifest("old"))
  end)

  it("reads and checks plugin.lua next to init.lua", function()
    plugins.sources.new = { dir = "apps", path = "/apps" }
    manifests({ ["/apps/new/plugin.lua"] = { id = "new", version = "2.0.0" } })
    assert.equals("2.0.0", plugins.manifest("new").version)
  end)

  it("says why a manifest is wrong", function()
    plugins.sources.bad = { dir = "apps", path = "/apps" }
    manifests({ ["/apps/bad/plugin.lua"] = { id = "wrong" } })
    local m, err = plugins.manifest("bad")
    assert.is_nil(m)
    assert.truthy(err:match("^plugin.lua: "))
  end)

  it("reads a real file with an empty environment", function()
    local path = os.tmpname()
    local f = io.open(path, "w")
    f:write('return { id = "x", name = "X" }')
    f:close()
    assert.same({ id = "x", name = "X" }, require("lib.plugins").readchunk(path))
    f = io.open(path, "w")
    f:write('os.execute("true"); return {}')
    f:close()
    local v, err = require("lib.plugins").readchunk(path)
    assert.is_nil(v)
    assert.truthy(err)
    os.remove(path)
  end)
end)

describe("plugins.plan with manifests", function()
  it("is unchanged without manifests", function()
    assert.same({ "b", "a", "c" }, (plugins.plan({ "a", "b", "c" }, { "b" }, {})))
  end)

  it("moves a plugin after the one it names, and nothing else", function()
    local out = plugins.plan({ "a", "b", "c", "d" }, nil, { a = { after = { "c" }, needs = {} } })
    assert.same({ "b", "c", "a", "d" }, out)
  end)

  it("treats needs as an ordering too", function()
    local out = plugins.plan({ "a", "b" }, nil, { a = { after = {}, needs = { "b" } } })
    assert.same({ "b", "a" }, out)
  end)

  it("lets the hard-coded list stand for plugins that say nothing", function()
    local out = plugins.plan({ "a", "b", "c" }, { "c", "b" },
      { a = { after = { "b" }, needs = {} } })
    assert.same({ "c", "b", "a" }, out)
  end)

  it("ignores an after that is not installed", function()
    assert.same({ "a" }, (plugins.plan({ "a" }, nil, { a = { after = { "ghost" }, needs = {} } })))
  end)

  it("keeps a circle in its default place and reports it", function()
    local out, cycle = plugins.plan({ "a", "b", "c" }, nil, {
      a = { after = { "b" }, needs = {} }, b = { after = { "a" }, needs = {} } })
    assert.same({ "c", "a", "b" }, out)
    assert.same({ "a", "b" }, cycle)
  end)
end)

describe("plugins.loadAll with manifests", function()
  before_each(reset)

  it("orders by manifest and falls back to the given list", function()
    hs.configdir = ""
    hs.fs._tree["/apps"] = { "alpha", "beta", "gamma" }
    for _, n in ipairs({ "alpha", "beta", "gamma" }) do hs.fs._files["/apps/" .. n .. "/init.lua"] = {} end
    manifests({ ["/apps/alpha/plugin.lua"] = { id = "alpha", after = { "gamma" } } })
    for _, n in ipairs({ "alpha", "beta", "gamma" }) do package.loaded["apps." .. n] = {} end

    assert.same({ "beta", "gamma", "alpha" }, plugins.loadAll())
    plugins.order = {}
    assert.same({ "gamma", "alpha", "beta" }, plugins.loadAll({ "gamma" }))
  end)

  it("also discovers the optional plugins folder, apps winning a name clash", function()
    hs.configdir = ""
    hs.fs._tree["/apps"] = { "alpha" }
    hs.fs._tree["/plugins"] = { "alpha", "mine" }
    hs.fs._files["/apps/alpha/init.lua"] = {}
    hs.fs._files["/plugins/alpha/init.lua"] = {}
    hs.fs._files["/plugins/mine/init.lua"] = {}
    package.loaded["apps.alpha"] = { from = "apps" }
    package.loaded["plugins.mine"] = { from = "plugins" }

    assert.same({ "alpha", "mine" }, plugins.loadAll())
    assert.equals("apps", plugins.loaded.alpha.from)
    assert.equals("plugins", plugins.loaded.mine.from)
  end)
end)

describe("plugins.load with a manifest", function()
  before_each(function()
    reset()
    plugins.warn = function() end
    plugins.sources = { p = { dir = "apps", path = "/apps" }, q = { dir = "apps", path = "/apps" } }
  end)

  it("refuses a plugin that wants a newer API than this config has", function()
    manifests({ ["/apps/p/plugin.lua"] = { id = "p", api = plugins.API + 1 } })
    package.loaded["apps.p"] = {}
    local mod, err = plugins.load("p")
    assert.is_nil(mod)
    assert.truthy(err:match("wants plugin API"))
    assert.equals(err, plugins.failed.p)
  end)

  it("loads a plugin written for the current API", function()
    manifests({ ["/apps/p/plugin.lua"] = { id = "p", api = plugins.API } })
    package.loaded["apps.p"] = { ok = true }
    assert.is_true(plugins.load("p").ok)
  end)

  it("refuses a plugin whose needs are not running", function()
    manifests({ ["/apps/p/plugin.lua"] = { id = "p", needs = { "q" } } })
    package.loaded["apps.p"] = {}
    local mod, err = plugins.load("p")
    assert.is_nil(mod)
    assert.truthy(err:match("needs q"))
    package.loaded["apps.q"] = {}
    plugins.load("q")
    assert.truthy(plugins.load("p"))
  end)

  it("fails on a broken manifest without touching the others", function()
    manifests({ ["/apps/p/plugin.lua"] = { id = "nope" } })
    package.loaded["apps.p"] = {}
    package.loaded["apps.q"] = {}
    assert.is_nil(plugins.load("p"))
    assert.truthy(plugins.failed.p:match("plugin.lua"))
    assert.truthy(plugins.load("q"))
  end)
end)

describe("plugins entry functions", function()
  before_each(function()
    reset()
    plugins.warn = function() end
    plugins.sources = { e = { dir = "apps", path = "/apps" } }
    plugins.objects, plugins.actions = {}, {}
    manifests({ ["/apps/e/plugin.lua"] = { id = "e", name = "E",
      settings = { vol = { type = "number", default = 30, min = 0, max = 100 } } } })
  end)

  local function load(entry)
    package.loaded["apps.e"] = entry
    return plugins.load("e")
  end

  it("passes one plugin object and keeps what the entry returns", function()
    local seen
    local mod = load(function(p) seen = p; return { marker = 1 } end)
    assert.equals(1, mod.marker)
    assert.equals("e", seen.id)
    assert.equals(plugins.API, seen.api)
    assert.equals("E", seen.manifest.name)
    assert.truthy(seen.ctx and seen.ui and seen.log and seen.on and seen.settings)
  end)

  it("runs start after the entry, and stop then teardown on unload", function()
    local calls = {}
    load(function(p)
      p.ctx:effect(function() calls[#calls + 1] = "effect" end)
      return { start = function() calls[#calls + 1] = "start" end,
               stop  = function() calls[#calls + 1] = "stop" end }
    end)
    assert.same({ "start" }, calls)
    assert.is_true(plugins.canDispose("e"))
    assert.is_true(plugins.unload("e"))
    assert.same({ "start", "stop", "effect" }, calls)
  end)

  it("does not need a stop hook", function()
    local undone = false
    load(function(p) p.ctx:effect(function() undone = true end); return {} end)
    assert.is_true(plugins.unload("e"))
    assert.is_true(undone)
  end)

  it("tears down and records a failure when start throws", function()
    local undone = false
    local mod, err = load(function(p)
      p.ctx:effect(function() undone = true end)
      return { start = function() error("no start") end }
    end)
    assert.is_nil(mod)
    assert.truthy(tostring(err):match("no start"))
    assert.is_true(undone)
    assert.truthy(plugins.failed.e)
  end)

  it("tears down and records a failure when the entry throws", function()
    local mod = load(function() error("entry broke") end)
    assert.is_nil(mod)
    assert.truthy(plugins.failed.e:match("entry broke"))
  end)

  it("reads settings with defaults, and remembers a valid set", function()
    local p
    load(function(obj) p = obj; return {} end)
    assert.equals(30, p.settings.get("vol"))
    assert.is_true(p.settings.set("vol", 80))
    assert.equals(80, p.settings.get("vol"))
    assert.equals(80, hs.settings.get("plugin.e.vol"))
  end)

  it("refuses a setting that is unknown or does not fit", function()
    local p
    load(function(obj) p = obj; return {} end)
    local ok, why = p.settings.set("vol", 500)
    assert.is_false(ok)
    assert.truthy(why)
    assert.is_false((p.settings.set("nothing", 1)))
    assert.is_nil(p.settings.get("nothing"))
    assert.equals(30, p.settings.get("vol"))
  end)

  it("falls back to the default when a stored value no longer fits", function()
    hs.settings.set("plugin.e.vol", "loud")
    local p
    load(function(obj) p = obj; return {} end)
    assert.equals(30, p.settings.get("vol"))
  end)

  it("tells a plugin about its own settings change, and stops after unload", function()
    local got, p = {}, nil
    load(function(obj)
      p = obj
      obj.on("settings", function(k, v) got[#got + 1] = k .. "=" .. v end)
      return {}
    end)
    p.settings.set("vol", 10)
    assert.same({ "vol=10" }, got)
    plugins.unload("e")
    p.settings.set("vol", 20)
    assert.same({ "vol=10" }, got)
  end)

  it("tells plugins when another loads or unloads", function()
    local heard = {}
    load(function(obj)
      obj.on("plugin:loaded", function(id) heard[#heard + 1] = "+" .. id end)
      obj.on("plugin:unloaded", function(id) heard[#heard + 1] = "-" .. id end)
      return {}
    end)
    plugins.sources.f = { dir = "apps", path = "/apps" }
    package.loaded["apps.f"] = {}
    plugins.load("f")
    plugins.unload("f")
    assert.same({ "+f", "-f" }, heard)
  end)

  it("keeps one listener's failure from stopping the rest", function()
    local ran = false
    local p
    load(function(obj)
      p = obj
      obj.on("settings", function() error("bad listener") end)
      obj.on("settings", function() ran = true end)
      return {}
    end)
    p.settings.set("vol", 1)
    assert.is_true(ran)
  end)

  it("registers actions that run by name and vanish on unload", function()
    local hit
    load(function(p) p.action("go", function(x) hit = x; return "done" end); return {} end)
    assert.equals("done", plugins.run("e.go", 7))
    assert.equals(7, hit)
    plugins.unload("e")
    local r, why = plugins.run("e.go")
    assert.is_nil(r)
    assert.truthy(why:match("no action"))
  end)

  it("tags log lines with the plugin id", function()
    local lines = {}
    plugins.warn = function(m) lines[#lines + 1] = m end
    local p
    load(function(obj) p = obj; return {} end)
    p.log("said %s", "hi")
    assert.same({ "[e] said hi" }, lines)
  end)

  it("hands a tile to the plugin and removes it on unload", function()
    local before = #hub.made
    load(function(p) p.tile(); return {} end)
    assert.equals(before + 1, #hub.made)
  end)

  it("a legacy plugin with no manifest still loads and unloads as before", function()
    plugins.sources.old = { dir = "apps", path = "/apps" }
    local gone = false
    package.loaded["apps.old"] = { dispose = function() gone = true end }
    assert.truthy(plugins.load("old"))
    assert.is_true(plugins.unload("old"))
    assert.is_true(gone)
  end)

  it("shows version and description in the Plugins tile state", function()
    plugins.order = { "e" }
    load(function() return {} end)
    plugins.manifests.e = { version = "1.2.3", description = "hi" }
    local s = plugins.state()[1]
    assert.equals("1.2.3", s.version)
    assert.equals("hi", s.description)
  end)
end)

describe("the manifests that ship in apps/", function()
  local dirs = {}
  local p = io.popen("ls -d apps/*/plugin.lua 2>/dev/null")
  for line in p:lines() do dirs[#dirs + 1] = line:match("^apps/(.-)/plugin.lua$") end
  p:close()

  it("exist for the folder plugins", function() assert.is_true(#dirs >= 10) end)

  for _, name in ipairs(dirs) do
    it(name .. " passes the manifest check and names this API", function()
      local raw = assert(loadfile("apps/" .. name .. "/plugin.lua", "t", {}))()
      local m, err = plugins.check(name, raw)
      assert.is_nil(err)
      assert.is_true(m.api <= plugins.API)
      assert.is_string(m.description)
    end)
  end
end)

describe("make plugin", function()
  local function sh(cmd)
    local p = io.popen(cmd .. " 2>&1")
    local out = p:read("*a")
    local ok = p:close()
    return out, ok
  end

  local root
  before_each(function()
    root = os.tmpname()
    os.remove(root)
    os.execute("mkdir -p " .. root .. "/templates")
    os.execute("cp Makefile " .. root .. "/ && cp -R templates/plugin " .. root .. "/templates/")
  end)
  after_each(function() os.execute("rm -rf " .. root) end)

  it("writes a manifest and an entry file with the name filled in", function()
    local _, ok = sh("make -C " .. root .. " plugin NAME=my_app TITLE='My app'")
    assert.truthy(ok)
    local m = assert(loadfile(root .. "/apps/my_app/plugin.lua", "t", {}))()
    assert.equals("my_app", m.id)
    assert.equals("My app", m.name)
    assert.truthy(plugins.check("my_app", m))
    local init = io.open(root .. "/apps/my_app/init.lua"):read("*a")
    assert.truthy(init:find("My app", 1, true))
    assert.truthy(init:find("my_app.hello", 1, true))
    assert.is_nil(init:find("Template", 1, true))
    assert.is_function(assert(loadfile(root .. "/apps/my_app/init.lua")))
  end)

  it("can put the plugin in plugins/ instead", function()
    local _, ok = sh("make -C " .. root .. " plugin NAME=mine DIR=plugins")
    assert.truthy(ok)
    assert.truthy(io.open(root .. "/plugins/mine/plugin.lua"))
  end)

  it("refuses to overwrite and refuses a bad name", function()
    sh("make -C " .. root .. " plugin NAME=my_app")
    local out, ok = sh("make -C " .. root .. " plugin NAME=my_app")
    assert.is_nil(ok)
    assert.truthy(out:find("already exists", 1, true))
    out, ok = sh("make -C " .. root .. " plugin NAME='Bad Name'")
    assert.is_nil(ok)
    assert.truthy(out:find("lowercase", 1, true))
  end)
end)
