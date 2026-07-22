local earcon = require("lib.earcon")

local function cfg(overrides)
  local base = {
    enabled = true,
    START   = "Tink",
    STOP    = "Pop",
    SENT    = "Submarine",
    VOLUME  = 0.5,
  }
  if overrides then
    for k, v in pairs(overrides) do base[k] = v end
  end
  return base
end

describe("earcon.resolve", function()
  it("returns nil when cfg is nil", function()
    assert.is_nil(earcon.resolve(nil, "start"))
  end)

  it("returns nil when disabled", function()
    assert.is_nil(earcon.resolve(cfg({ enabled = false }), "start"))
    assert.is_nil(earcon.resolve(cfg({ enabled = false }), "stop"))
    assert.is_nil(earcon.resolve(cfg({ enabled = false }), "sent"))
  end)

  it("resolves start to the START system sound", function()
    local r = earcon.resolve(cfg(), "start")
    assert.equals("system", r.kind)
    assert.equals("Tink", r.ref)
    assert.equals(0.5, r.volume)
  end)

  it("resolves stop to the STOP system sound", function()
    local r = earcon.resolve(cfg(), "stop")
    assert.equals("system", r.kind)
    assert.equals("Pop", r.ref)
  end)

  it("resolves sent to the SENT system sound", function()
    local r = earcon.resolve(cfg(), "sent")
    assert.equals("system", r.kind)
    assert.equals("Submarine", r.ref)
  end)

  it("treats an absolute path as a file ref", function()
    local r = earcon.resolve(cfg({ START = "/tmp/hi.wav" }), "start")
    assert.equals("file", r.kind)
    assert.equals("/tmp/hi.wav", r.ref)
  end)

  it("returns nil for an unknown kind", function()
    assert.is_nil(earcon.resolve(cfg(), "middle"))
    assert.is_nil(earcon.resolve(cfg(), ""))
    assert.is_nil(earcon.resolve(cfg(), nil))
  end)

  it("returns nil when the slot is empty or missing", function()
    assert.is_nil(earcon.resolve(cfg({ START = "" }), "start"))
    -- "missing" branch: build a config with STOP explicitly absent (Lua table
    -- literals collapse `KEY = nil` to nothing, so we merge and then clear).
    local no_stop = cfg(); no_stop.STOP = nil
    assert.is_nil(earcon.resolve(no_stop, "stop"))
    assert.is_nil(earcon.resolve(cfg({ SENT = 42 }), "sent"))
  end)

  it("clamps volume to [0,1]", function()
    assert.equals(0, earcon.resolve(cfg({ VOLUME = -3 }),  "start").volume)
    assert.equals(1, earcon.resolve(cfg({ VOLUME =  9 }),  "start").volume)
    assert.equals(1, earcon.resolve(cfg({ VOLUME = "x" }), "start").volume)
  end)
end)

describe("earcon.play", function()
  local function recorder()
    local calls = {}
    return {
      calls = calls,
      system = function(name, vol) calls[#calls + 1] = { "system", name, vol } end,
      file   = function(path, vol) calls[#calls + 1] = { "file",   path, vol } end,
    }
  end

  it("dispatches system sounds via player.system", function()
    local p = recorder()
    assert.is_true(earcon.play(cfg(), "start", p))
    assert.equals(1, #p.calls)
    assert.same({ "system", "Tink", 0.5 }, p.calls[1])
  end)

  it("dispatches file paths via player.file", function()
    local p = recorder()
    assert.is_true(earcon.play(cfg({ STOP = "/tmp/bye.wav" }), "stop", p))
    assert.same({ "file", "/tmp/bye.wav", 0.5 }, p.calls[1])
  end)

  it("returns false and dispatches nothing when disabled", function()
    local p = recorder()
    assert.is_false(earcon.play(cfg({ enabled = false }), "start", p))
    assert.equals(0, #p.calls)
  end)

  it("returns false when the slot is empty", function()
    local p = recorder()
    assert.is_false(earcon.play(cfg({ STOP = "" }), "stop", p))
    assert.equals(0, #p.calls)
  end)

  it("returns false when player is nil", function()
    assert.is_false(earcon.play(cfg(), "start", nil))
  end)

  it("skips gracefully when the player lacks a handler for the resolved kind", function()
    local p = { system = nil, file = nil }
    assert.is_false(earcon.play(cfg(), "start", p))
    assert.is_false(earcon.play(cfg({ STOP = "/tmp/x.wav" }), "stop", p))
  end)

  it("passes distinct sounds for start vs stop vs sent", function()
    local p = recorder()
    earcon.play(cfg(), "start", p)
    earcon.play(cfg(), "stop",  p)
    earcon.play(cfg(), "sent",  p)
    assert.equals("Tink",      p.calls[1][2])
    assert.equals("Pop",       p.calls[2][2])
    assert.equals("Submarine", p.calls[3][2])
  end)
end)
