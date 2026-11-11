local notch = require("lib.notch")

describe("notch", function()
  local builtin = { name = "Built-in Retina Display",
                    full = { x = 0, y = 0, w = 1512, h = 982 }, frame = { x = 0, y = 38, w = 1512, h = 944 } }
  local external = { name = "LG UltraFine",
                     full = { x = 0, y = 0, w = 2560, h = 1440 }, frame = { x = 0, y = 25, w = 2560, h = 1415 } }

  it("targets the notch on a notched screen", function()
    local f, has = notch.target(builtin.name, builtin.full, builtin.frame)
    assert.is_true(has)
    assert.same({ x = 656, y = 0, w = notch.WIDTH, h = 38 }, f)
  end)

  it("targets the middle of the menu bar elsewhere", function()
    local f, has = notch.target(external.name, external.full, external.frame)
    assert.is_false(has)
    assert.same({ x = 1200, y = 0, w = notch.BARE_WIDTH, h = 25 }, f)
  end)

  it("stands 24 in for a menu bar that hides itself", function()
    assert.equals(24, notch.barHeight({ y = 0 }, { y = 0 }))
  end)
end)
