-- One panel for every Hammerspoon app, hanging from the notch.
--
-- Instead of `hs.menubar.new()`, an app calls `hub.item("Name")` and gets back a
-- proxy with the same methods it already used (setTitle, setIcon, setMenu,
-- setTooltip, setClickCallback). Adding an app adds a tile, not a new icon in
-- the menu bar. There is no icon in the menu bar at all: the panel lives in
-- the notch.
--
-- Click the notch, or press Cmd+`, and a Control Center-style panel
-- (lib/menuhub_panel.html) grows out of it, black like the karaoke island, with
-- one tile per app: its live glyph, name and status. A tile opens the app's
-- menu in the same design (grouped lists, checkmarks, drill-in submenus,
-- actions that run in place), or runs its click callback. Typing filters the
-- tiles and Return opens the first. Option-click the notch for the plain
-- dropdown instead. A screen without a notch has the same target in the
-- middle of its menu bar.
--
-- The panel opens on its Widgets page, with the tiles under Plugins in the
-- sidebar. A widget is something a plugin wants seen at a glance, like
-- the time in other cities. A plugin adds one with ctx:widget (lib/context).

local M = { entries = {}, widgets = {}, panel = nil, view = nil }
-- view: nil = the tile grid, else { entry = <entry>, path = { item indexes } }

local notch = require("lib.notch")

M.HOTKEY = { mods = { "cmd" }, key = "`" }
-- The design decides how wide the panel is, so a three-column grid has room.
M.PANEL_WIDTH = require("lib.theme").panel.width
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

-- Pure: the widgets as the panel draws them. A widget's render returns its
-- items, or { title, items }; each item is
--   { label, value, detail }   three lines: a name, the big text, a note
--   { label, clock = "Asia/Tokyo" }   the time there, kept current by the panel
-- A widget with a submit function is a console instead: render returns
--   { title, lines = { { who = "you" | "reply" | "note", text } }, prompt, status, busy }
-- and the panel draws the lines over a prompt the user can type into.
-- A render that throws costs its own widget a line saying so, not the panel.
local function str(v) return v ~= nil and tostring(v) or nil end

local WHO = { you = true, reply = true, note = true }

local function console(got)
  local lines = {}
  for _, l in ipairs(type(got.lines) == "table" and got.lines or {}) do
    if type(l) == "table" then
      lines[#lines + 1] = { who = WHO[l.who] and l.who or "note", text = str(l.text) or "" }
    end
  end
  return { kind = "console", lines = lines, prompt = str(got.prompt), status = str(got.status),
           busy = got.busy and true or false }
end

function M.glance(widgets)
  local out = {}
  for i, w in ipairs(widgets or {}) do
    local ok, got = pcall(w.render)
    local title, items, card = w.name, {}, nil
    if not ok then
      items = { { label = "Couldn't draw", detail = tostring(got) } }
    elseif type(got) == "table" then
      title = got.title or title
      if w.submit then
        card = console(got)
      else
        for _, it in ipairs(got.items or got) do
          if type(it) == "table" then
            items[#items + 1] = { label = str(it.label), value = str(it.value),
                                  detail = str(it.detail), clock = str(it.clock) }
          end
        end
      end
    end
    card = card or { kind = "glance", items = items }
    card.index, card.title, card.click = i, title, w.click ~= nil
    out[#out + 1] = card
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

-- Pure: what the panel should draw for the current view. Widgets show on the
-- tile grid only. A detail model also carries `menu`, the raw rows it was
-- drawn from, so a click is looked up in what the user saw instead of making
-- the app build its menu again: Dictation lists its microphones to build one.
-- A view marked `loading` is an app just opened, drawn with no rows first so
-- the panel answers the click before a slow menu is built.
function M.model(entries, view, encode, widgets)
  local tiles = M.tiles(entries, encode)
  if view then
    for i, e in ipairs(entries) do
      if e == view.entry and view.loading then
        return { view = "detail", app = tiles[i], items = {}, loading = true, depth = 1, crumbs = {} }
      elseif e == view.entry then
        local menu, crumbs = M.resolve(e, view.path)
        if menu then
          -- Breadcrumbs name the level *above*: the app, then each submenu.
          local back = { e.name }
          for k = 1, #crumbs - 1 do back[#back + 1] = crumbs[k] end
          return {
            view = "detail", app = tiles[i], items = M.items(menu), menu = menu,
            title = crumbs[#crumbs], depth = #crumbs + 1,
            crumbs = #crumbs > 0 and back or {},
          }
        end
      end
    end
  end
  return { view = "home", tiles = tiles, widgets = M.glance(widgets), depth = 0 }
end

-- Pure: the panel's HTML with lib/theme's colors and corners in place of its
-- /*@theme*/ marker. A function replacement, because the CSS is full of the
-- `%` that a replacement string would read as a capture.
function M.themed(html)
  local css = require("lib.theme").islandCss()
  return (html:gsub("/%*@theme%*/", function() return css end, 1))
end

-- Pure: how wide the panel is on a screen, and how many tile columns fit. A
-- third of the screen, because it is open only while it is being used, and
-- never narrower than the design's own width or fewer columns than it asks.
M.TILE_MIN = 180   -- CSS pixels a tile needs for its glyph, name and status
M.NAV      = 132   -- the sidebar, --nav in the page

function M.size(full, panel)
  local w = math.max(panel.width, math.floor(full.w / 3))
  local room = w - 3 * panel.pad - M.NAV
  local columns = math.max(panel.columns, math.floor(room / M.TILE_MIN))
  return w, columns
end

-- Pure: where the panel goes on a screen. It hangs from the top edge, centred
-- on the notch, and its content starts below the notch: `top` is how far down
-- that is, 0 on a screen without one. It may grow to most of the screen's
-- height and scrolls past that.
function M.place(screen, w, h, maxH)
  local full, frame = screen.full, screen.frame
  local hasNotch = notch.hasNotch(screen.name, full, frame)
  maxH = maxH or math.max(M.PANEL_MAX_H, math.floor(full.h * 0.8))
  h = math.min(h, maxH, full.h - 40)
  return notch.frame(full, w, h), hasNotch and notch.barHeight(full, frame) or 0
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
M.isOpen = isOpen

local function stopTicking()
  if M.ticker then M.ticker:stop(); M.ticker = nil end
end

-- Pure: a key from the tap as the page's key() wants it, by its DOM name, or
-- nil to let it through. Anything held with Cmd, Ctrl or Option goes to the
-- app it was meant for, so Cmd+Tab and the hotkey itself still work. Cmd+V is
-- the one exception: it pastes into whatever the panel is typing into.
local KEYS = { [53] = "Escape", [36] = "Enter", [76] = "Enter", [51] = "Backspace", [48] = "Tab" }

function M.keyName(code, chars, flags)
  flags = flags or {}
  if flags.cmd and code == 9 and not (flags.ctrl or flags.alt) then return "Paste" end
  if flags.cmd or flags.ctrl or flags.alt then return nil end
  if KEYS[code] then return KEYS[code] end
  if type(chars) == "string" and chars ~= "" and not chars:find("%c") then return chars end
  return nil
end

local function stopTap()
  if M.tap then M.tap:stop(); M.tap = nil end
end

local function hidePanel()
  stopTicking()
  stopTap()
  if M.panel then M.panel:hide(0.12) end
end

local function pushTiles()
  if not M.panel then return end
  local model = M.model(M.entries, M.view, encodeImage, M.widgets)
  if model.view == "home" then M.view = nil end
  if M.view then M.view.menu = model.menu end
  model.menu = nil
  M.panel:evaluateJavaScript("render(" .. hs.json.encode(model) .. ")")
end

-- Only the widgets, for a widget that asked to be redrawn: redrawing the
-- whole grid would restart its animation and lose the filter.
local function pushWidgets()
  if not (isOpen() and M.view == nil) then return end
  M.panel:evaluateJavaScript("glance(" .. hs.json.encode(M.glance(M.widgets)) .. ")")
end

-- Coalesced, because a console widget asks once per streamed word.
local function widgetsChanged()
  if not isOpen() or M.view or M.pendingWidgets then return end
  M.pendingWidgets = hs.timer.doAfter(0.05, function() M.pendingWidgets = nil; pushWidgets() end)
end

-- The shortest `every` any widget asked for, or nil when none did.
function M.tickEvery(widgets)
  local every
  for _, w in ipairs(widgets or {}) do
    if type(w.every) == "number" and w.every > 0 then every = math.min(every or w.every, w.every) end
  end
  return every
end

local function startTicking()
  stopTicking()
  local every = M.tickEvery(M.widgets)
  if every then M.ticker = hs.timer.doEvery(every, pushWidgets) end
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

local function screenFacts(s)
  return { name = s:name(), full = s:fullFrame(), frame = s:frame() }
end

local function placePanel(h)
  local facts = screenFacts(M.screen or hs.screen.mainScreen())
  local w, columns = M.size(facts.full, require("lib.theme").panel)
  local frame, top = M.place(facts, w, h or M.panel:frame().h)
  M.panel:frame(frame)
  local shape = top .. "," .. columns
  if shape ~= M.shape then
    M.shape = shape
    M.panel:evaluateJavaScript("island(" .. shape .. ")")
  end
end

-- The rows the user is looking at, as they were drawn.
local function shownMenu()
  return M.view and (M.view.menu or M.resolve(M.view.entry, M.view.path))
end

local function onMessage(msg)
  local b = msg.body or {}
  if b.cmd == "ready" then
    M.shape = nil
    placePanel()
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
      -- The app's name and glyph now, its menu a moment later: building the
      -- menu can take most of a second, and the click should not wait on it.
      M.view = { entry = e, path = {}, loading = true }
      pushTiles()
      local view = M.view
      M.loading = hs.timer.doAfter(0.02, function()
        M.loading = nil
        if M.view ~= view then return end
        view.loading = nil
        pushTiles()
      end)
    elseif e.click then
      hidePanel(); e.click()
    end
  elseif b.cmd == "widget" then
    local w = M.widgets[b.index]
    if w and w.click then hidePanel(); w.click() end
  elseif b.cmd == "submit" then
    local w = M.widgets[b.index]
    if w and w.submit and type(b.text) == "string" then
      local ok, err = pcall(w.submit, b.text)
      if not ok then print("[menuhub] " .. w.name .. ": " .. tostring(err)) end
    end
  elseif b.cmd == "home" then
    -- The sidebar, from inside an app's menu.
    M.view = nil
    pushTiles()
  elseif b.cmd == "back" then
    if M.view and #M.view.path > 0 then
      table.remove(M.view.path)
    else
      M.view = nil
    end
    pushTiles()
  elseif b.cmd == "slide" then
    -- Live while dragging, so no redraw: that would reset the thumb mid-drag.
    local menu = shownMenu()
    local it = menu and menu[b.i]
    if it and type(it.slider) == "table" and it.slider.fn then
      local ok, err = pcall(it.slider.fn, tonumber(b.v))
      if not ok then print("[menuhub] " .. M.text(it.title) .. ": " .. tostring(err)) end
    end
  elseif b.cmd == "item" then
    if not M.view or M.view.loading then return end
    local menu = shownMenu()
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

-- Above the menu bar, so it can cover the notch, and without a shadow, so it
-- reads as part of the screen the way the karaoke island does.
local function ensurePanel()
  if M.panel then return M.panel end
  local ucc = hs.webview.usercontent.new("hub"):setCallback(onMessage)
  M.panel = hs.webview.new({ x = 0, y = 0, w = M.PANEL_WIDTH, h = 300 }, {}, ucc)
    :windowStyle({ "borderless" })
    :transparent(true)
    :shadow(false)
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
  M.panel:html(M.themed(html))
  return M.panel
end

-- Keys and clicks while the panel is open come from a tap, not the page. A
-- borderless webview opened by a hotkey does not reliably become the key
-- window, and then typing would land in the app underneath. The tap hands
-- keys to the page and swallows them; a click outside the panel closes it,
-- which focus alone would miss when the panel never had focus.
local function startTap()
  stopTap()
  local types = hs.eventtap.event.types
  M.tap = hs.eventtap.new({ types.keyDown, types.leftMouseDown, types.rightMouseDown }, function(ev)
    if not isOpen() then stopTap(); return false end
    if ev:getType() == types.keyDown then
      local k = M.keyName(ev:getKeyCode(), ev:getCharacters(), ev:getFlags())
      if not k then return false end
      local args = { k }
      if k == "Paste" then args[2] = hs.pasteboard.getContents() or "" end
      M.panel:evaluateJavaScript("key.apply(null, " .. hs.json.encode(args) .. ")")
      return true
    end
    local p, f = hs.mouse.absolutePosition(), M.panel:frame()
    if p.x < f.x or p.x > f.x + f.w or p.y < f.y or p.y > f.y + f.h then hidePanel() end
    return false
  end)
  M.tap:start()
end

-- Opens on `screen`, else the one under the pointer.
function M.togglePanel(screen)
  if isOpen() then hidePanel(); return end
  M.screen = screen or notch.screenUnder()
  local fresh = not M.panel
  ensurePanel()
  M.view = nil
  -- A new webview places itself when its page says "ready"; an old one is
  -- placed now, since the screen may have changed since it last opened.
  if not fresh then
    placePanel()
    -- First, so the page is back on Widgets before the grid is drawn.
    M.panel:evaluateJavaScript("opened()")
    pushTiles()
  end
  M.panel:show()
  hs.focus()
  pcall(function() M.panel:hswindow():focus() end)
  startTicking()
  startTap()
end

-- Pure: does a change to `entry` need the open panel redrawn? On the grid,
-- any change does. In an app's menu, only a change to that same app does:
-- redrawing a menu means the app builds it again, and every tile retitling
-- itself used to rebuild whichever menu was open.
function M.redraws(view, entry)
  if not view then return true end
  return entry == view.entry and not view.loading
end

-- Proxies call this on every change, so an open panel stays live. Coalesced:
-- dictation can set its title several times in one tick. An open menu is
-- redrawn at most once a second, for the same reason.
local function changed(entry)
  if not isOpen() or M.pending or not M.redraws(M.view, entry) then return end
  M.pending = hs.timer.doAfter(M.view and 1 or 0.05, function() M.pending = nil; pushTiles() end)
end

-- ── The notch ──────────────────────────────────────────────────────────────
-- An invisible target over the notch on every screen (the middle of the menu
-- bar where there is none). A click opens the panel on that screen;
-- Option-click pops the plain dropdown. Nearly clear rather than clear,
-- because macOS sends a click on a fully transparent pixel to the window
-- underneath.
local function armTargets(ctx)
  for _, release in ipairs(M.targets or {}) do release() end
  M.targets = {}
  for i, s in ipairs(hs.screen.allScreens()) do
    local facts = screenFacts(s)
    local frame = notch.target(facts.name, facts.full, facts.frame)
    local c, release = ctx:canvas("notch" .. i, frame)
    c:level(hs.canvas.windowLevels.status)
    c:behavior({ "canJoinAllSpaces", "stationary" })
    c[1] = { type = "rectangle", action = "fill", fillColor = { white = 0, alpha = 0.01 },
             trackMouseDown = true, frame = { x = 0, y = 0, w = frame.w, h = frame.h } }
    c:mouseCallback(function(_, msg)
      if msg ~= "mouseDown" then return end
      local mods = hs.eventtap.checkKeyboardModifiers()
      if mods and mods.alt then
        popup(M.build(M.entries, FOOTER), { x = frame.x, y = frame.y + frame.h })
      else
        M.togglePanel(s)
      end
    end)
    c:show()
    M.targets[#M.targets + 1] = release
  end
end

-- Called once, by lib/plugins, with the context that owns the notch targets,
-- the hotkey and the panel, so all three leave together.
function M.install(ctx)
  ctx:hotkey(M.HOTKEY.mods, M.HOTKEY.key, function() M.togglePanel() end)
  armTargets(ctx)
  -- The page is built ahead, hidden, once every plugin has its tile, so the
  -- first open shows it instead of waiting for WebKit to load it.
  ctx:after(2, function() pcall(ensurePanel) end)
  -- Screens plugged in, unplugged or rearranged move the notch targets.
  ctx:watcher("screen", function() armTargets(ctx) end)
  -- The island follows the overlays' light or dark, which is baked into the
  -- page, so the page is thrown away and built fresh on the next open.
  ctx:effect(require("lib.theme").onChange(function()
    if M.panel then hidePanel(); M.panel:delete(); M.panel = nil end
  end))
  ctx:effect(function()
    stopTicking()
    stopTap()
    if M.panel then M.panel:delete(); M.panel = nil end
  end)
end

-- ── Proxy ──────────────────────────────────────────────────────────────────
local Proxy = {}
Proxy.__index = Proxy

local function setter(field)
  return function(self, v) self._e[field] = v; changed(self._e); return self end
end

Proxy.setTitle         = setter("title")
Proxy.setIcon          = setter("icon")
Proxy.setMenu          = setter("menu")
Proxy.setTooltip       = setter("tooltip")
Proxy.setClickCallback = setter("click")
function Proxy:title() return self._e.title end

-- Drop this app's tile (hs.menubar's delete).
function Proxy:delete()
  for i, e in ipairs(M.entries) do
    if e == self._e then table.remove(M.entries, i); changed(e); return end
  end
end

-- Register an app in the hub. Tiles appear in registration (require) order.
function M.item(name)
  local e = { name = name }
  M.entries[#M.entries + 1] = e
  return setmetatable({ _e = e }, Proxy)
end

-- ── Widgets ────────────────────────────────────────────────────────────────
local Widget = {}
Widget.__index = Widget

-- Draw it again now, for a widget whose numbers just changed. Only the
-- widgets are redrawn, and only while the grid is showing.
function Widget:update() widgetsChanged(); return self end

function Widget:delete()
  for i, w in ipairs(M.widgets) do
    if w == self._w then table.remove(M.widgets, i); widgetsChanged(); return end
  end
end

-- Register a widget on the Widgets page. render() is asked each time the panel
-- draws, so it should be quick: read state, do not fetch it.
--   opts.every   seconds between redraws while the panel is open
--   opts.click   run when the widget is clicked; the panel closes first
--   opts.submit  makes it a console: fn(text) gets what the user typed at
--                its prompt (see glance for what render returns then)
function M.widget(name, render, opts)
  opts = opts or {}
  local w = { name = name, render = render, every = opts.every, click = opts.click,
              submit = opts.submit }
  M.widgets[#M.widgets + 1] = w
  widgetsChanged()
  return setmetatable({ _w = w }, Widget)
end

return M
