-- The worked example in the README is the first thing an outsider copies, so it
-- is run here: the manifest must pass the check, and the plugin must load, draw
-- a tile, answer its action and go away.

_G.hs = require("hs")

local menuhub = require("lib.menuhub")
local plugins = require("lib.plugins")

-- The two lua blocks under "Write a plugin" that start with the hello manifest
-- and the hello entry function.
local function blocks()
  local text = io.open("README.md"):read("*a")
  local section = text:match("## Write a plugin(.-)## API reference")
  local out = {}
  for code in section:gmatch("```lua\n(.-)```") do out[#out + 1] = code end
  return out
end

describe("the README worked example", function()
  local manifest, entry, p

  before_each(function()
    hs.settings._v = {}
    local b = blocks()
    manifest = assert(plugins.check("hello", assert(load(b[1], "manifest", "t", {}))()))
    entry = assert(load(b[2], "init"))()
  end)

  after_each(function() if p then p.ctx:dispose() end end)

  it("has a manifest that passes the check", function()
    assert.equals("hello", manifest.id)
    assert.equals(1, manifest.api)
    assert.equals("Hello", manifest.settings.greeting.default)
  end)

  it("loads, answers its action and goes away completely", function()
    local before = #menuhub.entries
    local mod
    mod, p = plugins.activate("hello", entry, manifest)
    assert.is_table(mod)
    assert.equals(before + 1, #menuhub.entries)

    plugins.run("hello.greet")
    local ok, why = plugins.run("hello.nothing")
    assert.is_nil(ok)
    assert.truthy(why)

    p.ctx:dispose()
    assert.equals(before, #menuhub.entries)
    assert.is_nil(plugins.actions["hello.greet"])
    p = nil
  end)
end)
