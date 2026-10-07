local ax = require("lib.teams_ax")

describe("teams_ax.mutedFromLabel", function()
  it("reads the label as the action the button performs, not the state", function()
    assert.is_true(ax.mutedFromLabel("Unmute mic"))
    assert.is_false(ax.mutedFromLabel("Mute mic"))
  end)

  it("returns nil for anything that is not the mic button", function()
    assert.is_nil(ax.mutedFromLabel("Turn camera off"))
    assert.is_nil(ax.mutedFromLabel("Mute mic settings"))
    assert.is_nil(ax.mutedFromLabel(nil))
    assert.is_nil(ax.mutedFromLabel(42))
  end)
end)

-- Plain tables stand in for hs.axuielement objects: both answer el.AXRole,
-- el.AXDescription, el.AXChildren and so on by indexing.
local function button(label) return { AXRole = "AXButton", AXDescription = label } end
local function group(...) return { AXRole = "AXGroup", AXChildren = { ... } } end

local function nest(depth, leaf)
  local node = leaf
  for _ = 1, depth do node = group(node) end
  return node
end

describe("teams_ax.findMuteButton", function()
  it("finds the mic button deep in the tree", function()
    local target = button("Unmute mic")
    local tree = group(button("Leave"), nest(18, group(button("Turn camera off"), target)))
    assert.equals(target, ax.findMuteButton(tree))
  end)

  it("ignores a matching label on something that is not a button", function()
    local tree = group({ AXRole = "AXStaticText", AXDescription = "Mute mic" })
    assert.is_nil(ax.findMuteButton(tree))
  end)

  it("falls back to AXTitle when there is no description", function()
    local target = { AXRole = "AXButton", AXTitle = "Mute mic" }
    assert.equals(target, ax.findMuteButton(group(target)))
  end)

  it("stops at the depth limit instead of walking forever", function()
    assert.is_nil(ax.findMuteButton(nest(30, button("Mute mic")), 25))
    assert.is_not_nil(ax.findMuteButton(nest(20, button("Mute mic")), 25))
  end)

  it("returns nil for a missing root", function()
    assert.is_nil(ax.findMuteButton(nil))
  end)
end)

describe("teams_ax.readButton", function()
  it("reads a live button and returns nil once the reference is stale", function()
    assert.is_true(ax.readButton(button("Unmute mic")))
    assert.is_nil(ax.readButton({}))
    assert.is_nil(ax.readButton(nil))
  end)
end)

describe("teams_ax.searchOrder", function()
  it("puts the compact view (non-standard windows) before the meeting window", function()
    local main    = { id = 1, standard = true }
    local compact = { id = 2, standard = false }
    local chat    = { id = 3, standard = true }
    local order = ax.searchOrder({ main, compact, chat })
    assert.same({ 2, 1, 3 }, { order[1].id, order[2].id, order[3].id })
  end)
end)

describe("teams_ax.plan", function()
  it("does nothing when Teams already matches the headset", function()
    assert.equals("none", ax.plan(true, true))
    assert.equals("none", ax.plan(false, false))
  end)

  it("toggles when Teams disagrees with the headset", function()
    assert.equals("toggle", ax.plan(true, false))
    assert.equals("toggle", ax.plan(false, true))
  end)

  it("toggles blind, as before, when Teams' state cannot be read", function()
    assert.equals("blind", ax.plan(true, nil))
    assert.equals("blind", ax.plan(false, nil))
  end)
end)

describe("teams_ax.verifyStep", function()
  local MAX = 10

  it("is done as soon as Teams reads the headset's state", function()
    assert.equals("done", ax.verifyStep("keystroke", 1, MAX, true, true))
    assert.equals("done", ax.verifyStep("click", 3, MAX, false, false))
  end)

  it("keeps waiting while retries remain", function()
    assert.equals("wait", ax.verifyStep("keystroke", 1, MAX, false, true))
    assert.equals("wait", ax.verifyStep("keystroke", 9, MAX, nil, true))
  end)

  it("falls back to a click once the keystroke budget is spent", function()
    assert.equals("click", ax.verifyStep("keystroke", MAX, MAX, false, true))
  end)

  it("gives up once the click budget is spent too", function()
    assert.equals("fail", ax.verifyStep("click", MAX, MAX, false, true))
    assert.equals("fail", ax.verifyStep("click", MAX, MAX, nil, true))
  end)
end)

describe("teams_ax.clickPoint", function()
  it("aims at the centre of the button", function()
    assert.same({ x = 110, y = 220 },
      ax.clickPoint({ x = 100, y = 200 }, { w = 20, h = 40 }))
  end)

  it("returns nil when the frame is unknown", function()
    assert.is_nil(ax.clickPoint(nil, { w = 1, h = 1 }))
    assert.is_nil(ax.clickPoint({ x = 1, y = 1 }, nil))
  end)
end)
