-- Mac status: battery, memory and free disk, in a widget at the top of the
-- hub panel. Read when the panel draws and every 10 seconds while it is open,
-- so nothing runs while it is closed. No tile: there is nothing to set.
--
-- Memory is Activity Monitor's "Memory Used", worked out by lib/lmstudio the
-- same way LM Studio's tile counts room for a model.

local lms = require("lib.lmstudio")

local GB = 1024 ^ 3

-- Pure. hs.battery's answers as one item; nil on a Mac with no battery.
local function battery(pct, charging, plugged, minutes)
  if type(pct) ~= "number" or pct < 0 then return nil end
  local detail
  if charging then detail = "Charging"
  elseif plugged then detail = "On power"
  elseif type(minutes) == "number" and minutes > 0 then
    detail = string.format("%d:%02d left", math.floor(minutes / 60), minutes % 60)
  else detail = "On battery" end
  return { label = "Battery", value = string.format("%d%%", math.floor(pct + 0.5)), detail = detail }
end

-- Pure. lib/lmstudio.memory's table as one item.
local function memory(m)
  if not m then return nil end
  return { label = "Memory", value = string.format("%d%%", math.floor(100 * m.used / m.total + 0.5)),
           detail = string.format("%.0f of %.0f GB", m.used / GB, m.total / GB) }
end

-- Pure. The startup volume's free and total bytes as one item.
local function disk(free, total)
  if type(free) ~= "number" or type(total) ~= "number" or total <= 0 then return nil end
  return { label = "Disk", value = string.format("%.0f GB", free / 1e9),
           detail = string.format("free of %.0f GB", total / 1e9) }
end

return function(plugin)
  local M = { battery = battery, memory = memory, disk = disk }

  function M.items()
    local out = {}
    local function add(it) if it then out[#out + 1] = it end end
    add(battery(hs.battery.percentage(), hs.battery.isCharging(),
                hs.battery.powerSource() == "AC Power", hs.battery.timeRemaining()))
    add(memory(lms.memory(hs.host.vmStat())))
    local ok, vols = pcall(hs.fs.volume.allVolumes)
    local root = ok and type(vols) == "table" and vols["/"] or {}
    -- "Important usage" counts purgeable space as free, as Finder does.
    add(disk(root.NSURLVolumeAvailableCapacityForImportantUsageKey or root.NSURLVolumeAvailableCapacityKey,
             root.NSURLVolumeTotalCapacityKey))
    return out
  end

  M.widget = plugin.widget(M.items, { title = "This Mac", every = 10 })
  return M
end
