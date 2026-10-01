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

local function reset()
  plugins.loaded, plugins.failed, plugins.order, plugins.ctx = {}, {}, {}, nil
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
