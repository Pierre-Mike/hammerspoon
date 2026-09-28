local h = require("lib.hfp_mute")

-- Lines copied verbatim from `log stream` while the OpenComm2 mute button was
-- pressed. Keeping them literal is the point: the parser has to survive the
-- real format, not a tidied-up version of it.
local MUTED =
  "2026-08-19 09:44:47.205 Df bluetoothd[407:2582a2] " ..
  "[com.apple.bluetooth:Server.Handsfree] Received mic gain event " ..
  "from device A0:0C:E2:A1:75:75 - new gain is 0"

local UNMUTED =
  "2026-08-19 09:44:43.719 Df bluetoothd[407:2582a2] " ..
  "[com.apple.bluetooth:Server.Handsfree] Received mic gain event " ..
  "from device A0:0C:E2:A1:75:75 - new gain is 15"

describe("hfp_mute.parseLine", function()
  it("reads gain 0 as muted", function()
    local ev = h.parseLine(MUTED)
    assert.is_table(ev)
    assert.equals("A0:0C:E2:A1:75:75", ev.mac)
    assert.equals(0, ev.gain)
    assert.is_true(ev.muted)
  end)

  it("reads gain 15 as unmuted", function()
    local ev = h.parseLine(UNMUTED)
    assert.is_table(ev)
    assert.equals(15, ev.gain)
    assert.is_false(ev.muted)
  end)

  -- Any non-zero gain means the mic is live. Do not hard-code 15: the HFP
  -- range is 0..15 and a headset may report an intermediate value.
  it("treats any non-zero gain as unmuted", function()
    local ev = h.parseLine((MUTED:gsub("gain is 0", "gain is 7")))
    assert.equals(7, ev.gain)
    assert.is_false(ev.muted)
  end)

  -- The raw +SVGM line arrives ~80ms before the decoded one and carries a
  -- value that does not match the gain (09 for gain 15). Ignore it, or every
  -- press fires twice with one wrong reading.
  it("ignores the raw +SVGM line", function()
    assert.is_nil(h.parseLine(
      "2026-08-19 09:44:43.719 Df bluetoothd[407:259118] " ..
      "[com.apple.bluetooth:Server.Phonebook] Received AT CMD command +SVGM 09"))
  end)

  it("ignores unrelated lines and junk", function()
    assert.is_nil(h.parseLine("Filtering the log data using \"subsystem == ...\""))
    assert.is_nil(h.parseLine(""))
    assert.is_nil(h.parseLine(nil))
  end)
end)

describe("hfp_mute.matches", function()
  it("accepts any device when no filter is set", function()
    assert.is_true(h.matches({ mac = "A0:0C:E2:A1:75:75" }, nil))
  end)

  it("compares the address case-insensitively", function()
    assert.is_true(h.matches({ mac = "A0:0C:E2:A1:75:75" }, "a0:0c:e2:a1:75:75"))
    assert.is_false(h.matches({ mac = "A0:0C:E2:A1:75:75" }, "11:22:33:44:55:66"))
  end)
end)

describe("hfp_mute.logArgs", function()
  it("builds argv for `log stream` with a predicate that names the category", function()
    local argv = h.logArgs()
    assert.equals("stream", argv[1])
    local joined = table.concat(argv, " ")
    assert.truthy(joined:find("Server.Handsfree", 1, true))
    assert.truthy(joined:find("mic gain event", 1, true))
  end)
end)
