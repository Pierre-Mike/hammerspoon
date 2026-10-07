-- lib/tap_guard re-arms event taps macOS has switched off (after sleep, under
-- load, or while secure input is on). The taps are fakes with the hs.eventtap
-- methods the guard calls.
local guard = require("lib.tap_guard")

local function fakeTap(enabled)
  local t = { enabled = enabled, starts = 0 }
  function t:isEnabled() return self.enabled end
  function t:start() self.starts = self.starts + 1; self.enabled = true; return self end
  return t
end

describe("tap_guard.rearm", function()
  it("restarts a tap macOS disabled and reports its name", function()
    local flags, keys = fakeTap(false), fakeTap(true)
    local names = guard.rearm({ flags = flags, keys = keys })
    assert.same({ "flags" }, names)
    assert.equals(1, flags.starts)
    assert.equals(0, keys.starts)
    assert.is_true(flags:isEnabled())
  end)

  it("reports every tap it restarted, in name order", function()
    assert.same({ "flags", "keys" }, guard.rearm({ keys = fakeTap(false), flags = fakeTap(false) }))
  end)

  it("leaves running taps and missing taps alone", function()
    assert.same({}, guard.rearm({ flags = fakeTap(true), keys = nil }))
  end)
end)

describe("tap_guard.missedRelease", function()
  -- While the tap was off, Fn's key-up may have been lost. If we still think Fn
  -- is held but the keyboard says it is not, the take must be ended.
  it("is true when Fn is believed down but no longer held", function()
    assert.is_true(guard.missedRelease(true, {}))
  end)

  it("is false when Fn is still held or was never down", function()
    assert.is_false(guard.missedRelease(true, { fn = true }))
    assert.is_false(guard.missedRelease(false, {}))
  end)
end)
