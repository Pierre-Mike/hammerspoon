_G.hs = require("hs")
local aw = require("lib.audiowatch")

describe("audiowatch.dispatch", function()
  it("calls every handler in registration order", function()
    local seen = {}
    aw.dispatch({ a = function(e) seen[#seen + 1] = "a:" .. e end,
                  b = function(e) seen[#seen + 1] = "b:" .. e end },
                { "a", "b" }, "dev#")
    assert.same({ "a:dev#", "b:dev#" }, seen)
  end)

  it("keeps going after a handler errors, and reports it", function()
    local seen, errs = {}, {}
    aw.dispatch({ bad = function() error("boom") end,
                  good = function() seen[#seen + 1] = "good" end },
                { "bad", "good" }, "dIn ", function(name) errs[#errs + 1] = name end)
    assert.same({ "good" }, seen)
    assert.same({ "bad" }, errs)
  end)
end)

describe("audiowatch.on", function()
  it("installs one system callback that reaches every app", function()
    local installs, cb = 0, nil
    hs.audiodevice = { watcher = {
      setCallback = function(fn) installs = installs + 1; cb = fn end,
      start = function() end,
    } }
    aw.handlers, aw.order, aw.started = {}, {}, nil

    local got = {}
    aw.on("dictation", function(e) got[#got + 1] = "dictation:" .. e end)
    aw.on("shokz", function(e) got[#got + 1] = "shokz:" .. e end)
    cb("dOut")

    assert.equals(1, installs)
    assert.same({ "dictation:dOut", "shokz:dOut" }, got)
  end)

  it("replaces a handler re-registered under the same name", function()
    aw.handlers, aw.order = {}, {}
    local got = {}
    aw.on("x", function() got[#got + 1] = 1 end)
    aw.on("x", function() got[#got + 1] = 2 end)
    aw.dispatch(aw.handlers, aw.order, "dev#")
    assert.same({ 2 }, got)
    assert.equals(1, #aw.order)
  end)
end)
