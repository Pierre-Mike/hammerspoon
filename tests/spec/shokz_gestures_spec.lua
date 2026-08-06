local g = require("lib.shokz_gestures")

describe("shokz_gestures.classify", function()
  -- Levels captured from the real headset while it was in A2DP (music) mode.
  it("recognises the AVRCP 0-127 grid as headset", function()
    assert.equals("headset", g.classify(66.929130554199)) -- 85/127
    assert.equals("headset", g.classify(74.015747070312)) -- 94/127
  end)

  -- After the headset switched to HFP the same buttons report on a 0-15 grid.
  it("recognises the HFP 0-15 grid as headset", function()
    assert.equals("headset", g.classify(53.333335876465)) -- 8/15
    assert.equals("headset", g.classify(60.000003814697)) -- 9/15
  end)

  it("recognises the Mac's 16-step grid as mackey", function()
    assert.equals("mackey", g.classify(62.5))  -- 10/16
    assert.equals("mackey", g.classify(68.75)) -- 11/16
    assert.equals("mackey", g.classify(25.0))  -- 4/16
  end)

  -- 0 and 100 sit on every grid, so they cannot be attributed to a source.
  it("reports the shared endpoints as ambiguous", function()
    assert.equals("ambiguous", g.classify(0))
    assert.equals("ambiguous", g.classify(100))
  end)

  it("reports an off-grid level as ambiguous", function()
    assert.equals("ambiguous", g.classify(33.7))
  end)
end)

describe("shokz_gestures.newRecognizer", function()
  it("fires up_down on volume+ then volume-", function()
    local r = g.newRecognizer(0.6)
    assert.is_nil(r("up", 1.0))
    assert.equals("up_down", r("down", 1.2))
  end)

  it("fires down_up on volume- then volume+", function()
    local r = g.newRecognizer(0.6)
    assert.is_nil(r("down", 1.0))
    assert.equals("down_up", r("up", 1.2))
  end)

  it("ignores two presses in the same direction", function()
    local r = g.newRecognizer(0.6)
    assert.is_nil(r("up", 1.0))
    assert.is_nil(r("up", 1.2))
  end)

  it("ignores an opposite pair that is too slow", function()
    local r = g.newRecognizer(0.6)
    assert.is_nil(r("up", 1.0))
    assert.is_nil(r("down", 2.0))
  end)

  -- Overshooting the volume and correcting it is three presses, not a gesture.
  it("ignores up, up, down as a volume correction", function()
    local r = g.newRecognizer(0.6)
    assert.is_nil(r("up", 1.0))
    assert.is_nil(r("up", 1.1))
    assert.is_nil(r("down", 1.2))
  end)

  it("consumes the pair so a third press starts fresh", function()
    local r = g.newRecognizer(0.6)
    r("up", 1.0)
    assert.equals("up_down", r("down", 1.2))
    assert.is_nil(r("up", 1.3))
    assert.equals("up_down", r("down", 1.4))
  end)

  -- A press that ages out of the window must not pair with a later one.
  it("drops presses older than the window", function()
    local r = g.newRecognizer(0.6)
    assert.is_nil(r("up", 1.0))
    assert.is_nil(r("up", 5.0))
    assert.equals("up_down", r("down", 5.2))
  end)
end)
