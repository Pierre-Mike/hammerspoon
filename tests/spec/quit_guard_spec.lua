-- lib/quit_guard decides what Cmd+W and Cmd+Q do in an app that should not be
-- closed by accident: Windows App, where Cmd+W ends the Cloud PC session.
local guard = require("lib.quit_guard")

local WINAPP = "com.microsoft.rdc.macos"
local guarded = { [WINAPP] = true }

local function press(over)
  local p = { bundleID = WINAPP, key = "w", mods = { cmd = true }, now = 10 }
  for k, v in pairs(over or {}) do p[k] = v end
  return p
end

describe("quit_guard.decide", function()
  it("blocks Cmd+W and Cmd+Q in a guarded app", function()
    assert.equals("block", guard.decide(guarded, nil, press()))
    assert.equals("block", guard.decide(guarded, nil, press({ key = "q" })))
  end)

  it("blocks Cmd+Shift+W too, which closes every window", function()
    assert.equals("block", guard.decide(guarded, nil, press({ mods = { cmd = true, shift = true } })))
  end)

  it("passes the same keys in an app that is not guarded", function()
    assert.equals("pass", guard.decide(guarded, nil, press({ bundleID = "com.apple.Safari" })))
    assert.equals("pass", guard.decide(guarded, nil, press({ bundleID = false })))
  end)

  it("passes other keys and other chords in a guarded app", function()
    assert.equals("pass", guard.decide(guarded, nil, press({ key = "c" })))
    assert.equals("pass", guard.decide(guarded, nil, press({ mods = {} })))
    assert.equals("pass", guard.decide(guarded, nil, press({ mods = { ctrl = true } })))
    assert.equals("pass", guard.decide(guarded, nil, press({ mods = { cmd = true, alt = true } })))
    assert.equals("pass", guard.decide(guarded, nil, press({ mods = { cmd = true, ctrl = true } })))
  end)

  it("lets a second press of the same chord through inside the window", function()
    local last = { bundleID = WINAPP, key = "q", at = 10 }
    assert.equals("allow", guard.decide(guarded, last, press({ key = "q", now = 10.5 })))
  end)

  it("blocks again once the window has passed", function()
    local last = { bundleID = WINAPP, key = "q", at = 10 }
    assert.equals("block", guard.decide(guarded, last, press({ key = "q", now = 10 + guard.WINDOW + 0.1 })))
  end)

  it("does not count a different chord as the second press", function()
    local last = { bundleID = WINAPP, key = "w", at = 10 }
    assert.equals("block", guard.decide(guarded, last, press({ key = "q", now = 10.2 })))
  end)
end)

describe("quit_guard set helpers", function()
  it("round-trips a set through a sorted list", function()
    local set = guard.toSet({ "b", "a" })
    assert.is_true(set.a and set.b)
    assert.same({ "a", "b" }, guard.toList(set))
  end)

  it("treats a missing or malformed stored value as the defaults", function()
    assert.same(guard.toSet(guard.DEFAULTS), guard.toSet(nil))
    assert.same(guard.toSet(guard.DEFAULTS), guard.toSet("junk"))
  end)

  it("keeps an empty list empty, so a user can unguard everything", function()
    assert.same({}, guard.toSet({}))
  end)
end)
