-- One menu-bar button for every Hammerspoon app.
--
-- Instead of `hs.menubar.new()`, an app calls `hub.item("Name")` and gets back a
-- proxy with the same methods it already used (setTitle, setIcon, setMenu,
-- setTooltip, setClickCallback). Adding an app adds a tile, not a new icon in
-- the menu bar.
--
-- Clicking the button opens a Control Center-style panel (lib/menuhub_panel.html)
-- with one tile per app: its live glyph, name and status. A tile opens the
-- app's menu in the same design (grouped lists, checkmarks, drill-in submenus,
-- actions that run in place), or runs its click callback. Option-click the
-- button for the plain dropdown instead.

local M = { entries = {}, bar = nil, panel = nil, view = nil }
-- view: nil = the tile grid, else { entry = <entry>, path = { item indexes } }

M.BAR_TITLE = "🔨"
M.PANEL_WIDTH = 360
M.PANEL_MAX_H = 640

local HERE = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
M.PANEL_HTML = HERE .. "menuhub_panel.html"

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

-- Pure: a tile's one-line status, from the first line of the app's tooltip.
-- A leading "Dictate · " or "Voice agent: " just repeats the tile's name, so it
-- is dropped when it shares the name's first four letters.
function M.statusOf(name, tooltip)
  if not tooltip or tooltip == "" then return nil end
  local line = tooltip:match("^[^\n]*")
  local prefix, rest = line:match("^(.-)%s*[:·]%s+(.+)$")
  if prefix and #prefix >= 4
     and prefix:sub(1, 4):lower() == name:sub(1, 4):lower() then
    line = rest
  end
  return (line:gsub("^%l", string.upper))
end

-- Pure: the panel's view model. `encode` turns an hs.image into a data URL; it
-- is injected so this stays testable without hs.image.
function M.tiles(entries, encode)
  local out = {}
  for i, e in ipairs(entries) do
    local kind = (e.menu and "menu") or (e.click and "click") or "none"
    local glyph = (e.title and e.title ~= "") and e.title or nil
    out[#out + 1] = {
      index   = i,
      name    = e.name,
      glyph   = glyph,
      image   = (not glyph and e.icon and encode) and encode(e.icon) or nil,
      status  = M.statusOf(e.name, e.tooltip),
      tooltip = e.tooltip,
      kind    = kind,
    }
  end
  return out
end

-- Pure: menu titles may be hs.styledtext; the panel only needs the string.
function M.text(t)
  if type(t) == "string" then return t end
  if t == nil then return "" end
  local ok, s = pcall(function() return t:getString() end)
  return ok and s or tostring(t)
end

-- Pure: an hs.menubar menu table as flat rows for the detail view.
-- kind: sep | sub (has a submenu) | check (checked is set) | act | info, plus
-- two the panel understands and a plain dropdown ignores:
--   switch  { title, switch = true, checked, fn }   an on/off toggle
--   slider  { title, slider = { value, min, max, step, unit, fn(v) } }
function M.items(menu)
  local out = {}
  for i, it in ipairs(menu or {}) do
    local title = M.text(it.title)
    local kind
    if title == "-" then kind = "sep"
    elseif type(it.slider) == "table" then kind = "slider"
    elseif it.switch and it.fn then kind = "switch"
    elseif it.menu then kind = "sub"
    elseif it.fn and it.checked ~= nil then kind = "check"
    elseif it.fn then kind = "act"
    else kind = "info" end
    out[#out + 1] = {
      i = i, kind = kind, title = title,
      checked = it.checked and true or false,
      disabled = (kind ~= "info" and it.disabled) and true or nil,
    }
    if kind == "slider" then
      local sl, row = it.slider, out[#out]
      row.min, row.max = sl.min or 0, sl.max or 100
      row.step, row.unit = sl.step or 1, sl.unit or ""
      row.value = math.max(row.min, math.min(row.max, tonumber(sl.value) or row.min))
    end
  end
  -- Some apps draw their own ticks: "✓ Medium" beside "   Tight", space-padded
  -- to line up. Within a run of such rows, the tick and the padding both mean
  -- "a choice", so they become check rows with the tick moved to the right.
  local run = {}
  local function flush()
    local ticked = false
    for _, r in ipairs(run) do if r.title:match("^%s*✓%s") then ticked = true end end
    if ticked then
      for _, r in ipairs(run) do
        local tick = r.title:match("^%s*✓%s+")
        if tick or r.title:match("^%s%s") then
          r.kind, r.checked = "check", tick ~= nil
          r.title = r.title:gsub("^%s*✓", ""):gsub("^%s+", "")
        end
      end
    end
    run = {}
  end
  for _, r in ipairs(out) do
    if r.kind == "act" then run[#run + 1] = r
    elseif r.kind ~= "check" then flush() end
  end
  flush()
  return out
end

-- Pure: walk an entry's menu down `path` (item indexes into nested submenus).
-- Returns the raw item list at that depth and the submenu titles on the way,
-- or nil when the path no longer exists (the app rebuilt its menu).
function M.resolve(entry, path)
  local menu = entry.menu
  if type(menu) == "function" then menu = menu() end
  local crumbs = {}
  for _, idx in ipairs(path or {}) do
    local it = menu and menu[idx]
    if not (it and it.menu) then return nil end
    crumbs[#crumbs + 1] = M.text(it.title)
    menu = it.menu
    if type(menu) == "function" then menu = menu() end
  end
  if type(menu) ~= "table" then return nil end
  return menu, crumbs
end

-- Pure: what the panel should draw for the current view.
function M.model(entries, view, encode)
  local tiles = M.tiles(entries, encode)
  if view then
    for i, e in ipairs(entries) do
      if e == view.entry then
        local menu, crumbs = M.resolve(e, view.path)
        if menu then
          -- Breadcrumbs name the level *above*: the app, then each submenu.
          local back = { e.name }
          for k = 1, #crumbs - 1 do back[#back + 1] = crumbs[k] end
          return {
            view = "detail", app = tiles[i], items = M.items(menu),
            title = crumbs[#crumbs], depth = #crumbs + 1,
            crumbs = #crumbs > 0 and back or {},
          }
        end
      end
    end
  end
  return { view = "home", tiles = tiles, depth = 0 }
end

local FOOTER = {
  { title = "Reload Hammerspoon", fn = function() hs.reload() end },
  { title = "Open console",       fn = function() hs.openConsole() end },
}

-- ── Panel ──────────────────────────────────────────────────────────────────
local function encodeImage(img)
  local ok, url = pcall(function() return img:encodeAsURLString() end)
  return ok and url or nil
end

local function isOpen() return M.panel and M.panel:isVisible() end

local function hidePanel()
  if M.panel then M.panel:hide() end
end

local function pushTiles()
  if not M.panel then return end
  local model = M.model(M.entries, M.view, encodeImage)
  if model.view == "home" then M.view = nil end
  M.panel:evaluateJavaScript("render(" .. hs.json.encode(model) .. ")")
end

-- Popup a menu table at a screen point. A hidden menubar item is the one
-- Hammerspoon object that can show a native menu anywhere.
local function popup(menu, point)
  if type(menu) == "function" then menu = menu() end
  if not menu then return end
  M.popper = M.popper or hs.menubar.new(false)
  M.popper:setMenu(menu)
  M.popper:popupMenu(point)
end

-- The screen whose menu bar holds the button, else the main one.
local function barScreen(bf)
  if bf then
    for _, s in ipairs(hs.screen.allScreens()) do
      local f = s:fullFrame()
      if bf.x >= f.x and bf.x < f.x + f.w then return s end
    end
  end
  return hs.screen.mainScreen()
end

local function placePanel(h)
  local bf = M.bar and M.bar:frame()
  local screen = barScreen(bf):fullFrame()
  local w = M.PANEL_WIDTH
  local x = bf and (bf.x + bf.w - w) or (screen.x + screen.w - w - 8)
  x = math.max(screen.x + 8, math.min(x, screen.x + screen.w - w - 8))
  -- An auto-hidden menu bar reports its item above the screen (y < 0), so
  -- anchor to where the bar sits when shown.
  local barH = bf and bf.h or 24
  local y = math.max(bf and bf.y or screen.y, screen.y) + barH + 6
  h = math.min(h or M.panel:frame().h, M.PANEL_MAX_H, screen.y + screen.h - y - 20)
  M.panel:frame({ x = x, y = y, w = w, h = h })
end

local function onMessage(msg)
  local b = msg.body or {}
  if b.cmd == "ready" then
    pushTiles()
  elseif b.cmd == "size" then
    placePanel(b.h)
  elseif b.cmd == "close" then
    hidePanel()
  elseif b.cmd == "reload" then
    hs.reload()
  elseif b.cmd == "console" then
    hidePanel(); hs.openConsole()
  elseif b.cmd == "open" then
    local e = M.entries[b.index]
    if not e then return end
    if e.menu then
      M.view = { entry = e, path = {} }
      pushTiles()
    elseif e.click then
      hidePanel(); e.click()
    end
  elseif b.cmd == "back" then
    if M.view and #M.view.path > 0 then
      table.remove(M.view.path)
    else
      M.view = nil
    end
    pushTiles()
  elseif b.cmd == "slide" then
    -- Live while dragging, so no redraw: that would reset the thumb mid-drag.
    local menu = M.view and M.resolve(M.view.entry, M.view.path)
    local it = menu and menu[b.i]
    if it and type(it.slider) == "table" and it.slider.fn then
      local ok, err = pcall(it.slider.fn, tonumber(b.v))
      if not ok then print("[menuhub] " .. M.text(it.title) .. ": " .. tostring(err)) end
    end
  elseif b.cmd == "item" then
    if not M.view then return end
    local menu = M.resolve(M.view.entry, M.view.path)
    local it = menu and menu[b.i]
    if not it then pushTiles(); return end
    if it.menu then
      M.view.path[#M.view.path + 1] = b.i
      pushTiles()
    elseif it.fn then
      local ok, err = pcall(it.fn, {}, it)
      if not ok then print("[menuhub] " .. M.text(it.title) .. ": " .. tostring(err)) end
      -- Apps update their state (and menu) in the action; redraw once it lands.
      M.refresh = hs.timer.doAfter(0.1, function() M.refresh = nil; if isOpen() then pushTiles() end end)
    end
  end
end

local function ensurePanel()
  if M.panel then return M.panel end
  local ucc = hs.webview.usercontent.new("hub"):setCallback(onMessage)
  M.panel = hs.webview.new({ x = 0, y = 0, w = M.PANEL_WIDTH, h = 300 }, {}, ucc)
    :windowStyle({ "borderless" })
    :transparent(true)
    :shadow(true)
    :allowTextEntry(true)
    :level(hs.drawing.windowLevels.popUpMenu)
    :behavior(hs.drawing.windowBehaviors.canJoinAllSpaces
            + hs.drawing.windowBehaviors.transient)
    :windowCallback(function(action, _, state)
      if action == "focusChange" and not state then hidePanel() end
    end)
  local f = io.open(M.PANEL_HTML, "r")
  local html = f and f:read("*a") or "<p>missing menuhub_panel.html</p>"
  if f then f:close() end
  M.panel:html(html)
  return M.panel
end

function M.togglePanel()
  if isOpen() then hidePanel(); return end
  ensurePanel()
  M.view = nil
  placePanel()
  pushTiles()
  M.panel:show()
  hs.focus()
  pcall(function() M.panel:hswindow():focus() end)
end

-- Proxies call this on every change, so an open panel stays live. Coalesced:
-- dictation can set its title several times in one tick.
local function changed()
  if not isOpen() or M.pending then return end
  M.pending = hs.timer.doAfter(0.05, function() M.pending = nil; pushTiles() end)
end

local function ensureBar()
  if M.bar then return M.bar end
  M.bar = hs.menubar.new()
  if not M.bar then return nil end
  M.bar:setTitle(M.BAR_TITLE)
  M.bar:setClickCallback(function(mods)
    if mods and mods.alt then
      local f = M.bar:frame()
      popup(M.build(M.entries, FOOTER), { x = f.x, y = f.y + f.h })
    else
      M.togglePanel()
    end
  end)
  return M.bar
end

-- ── Proxy ──────────────────────────────────────────────────────────────────
local Proxy = {}
Proxy.__index = Proxy

local function setter(field)
  return function(self, v) self._e[field] = v; changed(); return self end
end

Proxy.setTitle         = setter("title")
Proxy.setIcon          = setter("icon")
Proxy.setMenu          = setter("menu")
Proxy.setTooltip       = setter("tooltip")
Proxy.setClickCallback = setter("click")
function Proxy:title() return self._e.title end

-- Drop this app's tile (hs.menubar's delete). The hub button itself stays.
function Proxy:delete()
  for i, e in ipairs(M.entries) do
    if e == self._e then table.remove(M.entries, i); changed(); return end
  end
end

-- Register an app in the hub. Tiles appear in registration (require) order.
function M.item(name)
  local e = { name = name }
  M.entries[#M.entries + 1] = e
  ensureBar()
  return setmetatable({ _e = e }, Proxy)
end

return M
