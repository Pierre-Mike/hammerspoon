_G.hs = require("hs")
local plugins = require("lib.plugins")
local menuhub = require("lib.menuhub")

describe("the mac status plugin", function()
  local status, p

  before_each(function()
    menuhub.widgets = {}
    hs.battery = { percentage = function() return 82.4 end, isCharging = function() return false end,
                   powerSource = function() return "Battery Power" end, timeRemaining = function() return 151 end }
    hs.fs.volume = { allVolumes = function()
      return { ["/"] = { NSURLVolumeAvailableCapacityForImportantUsageKey = 311e9, NSURLVolumeTotalCapacityKey = 995e9 } }
    end }
    package.loaded["apps.mac_status.init"] = nil
    local entry = require("apps.mac_status.init")
    status, p = plugins.activate("mac_status", entry, assert(plugins.check("mac_status", dofile("apps/mac_status/plugin.lua"))))
  end)

  after_each(function() p.ctx:dispose(); hs.battery, hs.fs.volume = nil, nil end)

  it("shows battery, memory and disk, redrawn every 10 seconds", function()
    local w = menuhub.glance(menuhub.widgets)[1]
    assert.equals("This Mac", w.title)
    assert.same({ label = "Battery", value = "82%", detail = "2:31 left" }, w.items[1])
    assert.equals("Memory", w.items[2].label)
    assert.same({ label = "Disk", value = "311 GB", detail = "free of 995 GB" }, w.items[3])
    assert.equals(10, menuhub.tickEvery(menuhub.widgets))
  end)

  it("words the battery by where the power comes from", function()
    assert.equals("Charging", status.battery(50, true, true, 0).detail)
    assert.equals("On power", status.battery(100, false, true, -2).detail)
    assert.equals("On battery", status.battery(60, false, false, -1).detail)
    assert.is_nil(status.battery(-1))
  end)
end)
