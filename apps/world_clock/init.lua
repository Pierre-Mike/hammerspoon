-- World clock: the time in a few other cities, in a widget on the hub
-- panel's Widgets page. Open the panel (click the notch or press Cmd+`) to read it.
--
-- The widget names each city's time zone and the panel works out the time,
-- the day and the gap from here, ticking every second while it is open, so
-- nothing runs here while the panel is closed.
--
-- The tile picks the cities. The choice is the plugin's `cities` setting, and
-- an entry written as "Label=Area/Zone" there adds a city the list below does
-- not have:
--   hs -c 'require("lib.plugins").objects.world_clock.settings.set("cities", "Seattle,Lagos=Africa/Lagos")'

local menu = require("lib.ui").menu

-- West to east, which is also the order the widget shows them in.
local CITIES = {
  { "Honolulu", "Pacific/Honolulu" }, { "Seattle", "America/Los_Angeles" },
  { "Denver", "America/Denver" },     { "Chicago", "America/Chicago" },
  { "New York", "America/New_York" }, { "São Paulo", "America/Sao_Paulo" },
  { "London", "Europe/London" },      { "Paris", "Europe/Paris" },
  { "Dubai", "Asia/Dubai" },          { "Mumbai", "Asia/Kolkata" },
  { "Singapore", "Asia/Singapore" },  { "Tokyo", "Asia/Tokyo" },
  { "Sydney", "Australia/Sydney" },
}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- The setting as { label, zone } pairs: the listed cities in list order, then
-- any "Label=Zone" entries in the order written. Unknown names are dropped.
local function parse(s)
  local picked, custom = {}, {}
  for part in tostring(s or ""):gmatch("[^,]+") do
    local entry = trim(part)
    local label, zone = entry:match("^(.-)%s*=%s*(.+)$")
    if label and label ~= "" then custom[#custom + 1] = { label, zone }
    elseif entry ~= "" then picked[entry] = true end
  end
  local out = {}
  for _, c in ipairs(CITIES) do if picked[c[1]] then out[#out + 1] = c end end
  for _, c in ipairs(custom) do out[#out + 1] = c end
  return out
end

-- The setting with one listed city switched. Written back clean: custom
-- entries kept as "Label=Zone", names the list does not know dropped.
local listed = {}
for _, c in ipairs(CITIES) do listed[c[1]] = c[2] end

local function toggled(s, name)
  local keep, on = {}, false
  for _, c in ipairs(parse(s)) do
    if c[1] == name and listed[name] == c[2] then on = true
    else keep[#keep + 1] = listed[c[1]] == c[2] and c[1] or (c[1] .. "=" .. c[2]) end
  end
  if not on then keep[#keep + 1] = name end
  return table.concat(keep, ",")
end

return function(plugin)
  local M = { parse = parse, toggled = toggled, CITIES = CITIES }

  local function cities() return parse(plugin.settings.get("cities")) end

  M.tile = plugin.tile()
  M.tile:setTitle("🕐")

  local function refresh()
    local n = #cities()
    M.tile:setTooltip(n == 0 and "No cities picked" or string.format("%d %s", n, n == 1 and "city" or "cities"))
    if M.widget then M.widget:update() end
  end

  function M.items()
    local out = {}
    for _, c in ipairs(cities()) do out[#out + 1] = { label = c[1], clock = c[2] } end
    if #out == 0 then out[1] = { label = "No cities", detail = "Pick some in the World clock tile" } end
    return out
  end

  function M.toggle(name)
    plugin.settings.set("cities", toggled(plugin.settings.get("cities"), name))
  end

  M.widget = plugin.widget(M.items, { title = "Around the world" })
  -- A setting changed from a shell redraws the same as one changed here.
  plugin.on("settings", refresh)

  M.tile:setMenu(function()
    local on, rows = {}, { menu.text("Shown on the panel's Widgets page") }
    for _, c in ipairs(cities()) do on[c[1]] = true end
    for _, c in ipairs(CITIES) do
      rows[#rows + 1] = menu.switch(c[1], on[c[1]], function() M.toggle(c[1]) end)
    end
    return rows
  end)
  refresh()

  return M
end
