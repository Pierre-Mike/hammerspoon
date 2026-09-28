-- One menu-bar button for every Hammerspoon app.
--
-- Instead of `hs.menubar.new()`, an app calls `hub.item("Name")` and gets back a
-- proxy with the same methods it already used (setTitle, setIcon, setMenu,
-- setTooltip, setClickCallback). Each app becomes a row in the hub's dropdown:
-- its live title/icon is the row label, its menu becomes a submenu, and a
-- click callback becomes the row's action. Adding an app adds a row, not a
-- new icon in the menu bar.

local M = { entries = {}, bar = nil }

M.BAR_TITLE = "🔨"

-- Pure: turn registered entries into an hs.menubar menu table.
-- entry = { name, title, icon, menu (table|fn), click (fn), tooltip }
function M.build(entries, footer)
  local rows = {}
  for _, e in ipairs(entries) do
    local label = e.name
    if e.title and e.title ~= "" then label = e.title .. "  " .. e.name end
    local row = { title = label, image = e.icon, tooltip = e.tooltip }
    local sub = e.menu
    if type(sub) == "function" then sub = sub() end
    if sub then
      row.menu = sub
    elseif e.click then
      row.fn = function() e.click() end
    else
      row.disabled = true
    end
    rows[#rows + 1] = row
  end
  if footer and #footer > 0 then
    rows[#rows + 1] = { title = "-" }
    for _, f in ipairs(footer) do rows[#rows + 1] = f end
  end
  return rows
end

local FOOTER = {
  { title = "Reload Hammerspoon", fn = function() hs.reload() end },
  { title = "Open console",       fn = function() hs.openConsole() end },
}

local function ensureBar()
  if M.bar then return M.bar end
  M.bar = hs.menubar.new()
  if not M.bar then return nil end
  M.bar:setTitle(M.BAR_TITLE)
  -- Rebuilt on every open, so each app's current state is always shown.
  M.bar:setMenu(function() return M.build(M.entries, FOOTER) end)
  return M.bar
end

local Proxy = {}
Proxy.__index = Proxy

function Proxy:setTitle(t)          self._e.title = t;   return self end
function Proxy:setIcon(img)         self._e.icon = img;  return self end
function Proxy:setMenu(m)           self._e.menu = m;    return self end
function Proxy:setTooltip(t)        self._e.tooltip = t; return self end
function Proxy:setClickCallback(fn) self._e.click = fn;  return self end
function Proxy:title()              return self._e.title end

-- Register an app in the hub. Rows appear in registration (require) order.
function M.item(name)
  local e = { name = name }
  M.entries[#M.entries + 1] = e
  ensureBar()
  return setmetatable({ _e = e }, Proxy)
end

return M
