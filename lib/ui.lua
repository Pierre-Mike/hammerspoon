-- The components every plugin draws with. A plugin picks one, hands it words
-- and a meaning, and lib/theme decides what it looks like.
--
--   local ui = ctx:ui()
--   ui:toast("Copied", { tone = "success" })        one message, replaces the last
--   local _, hide = ui:hud("Recording", { tone = "recording" })
--   local bar = ui:bar("bar", { pick = run })        a row of buttons that never takes focus
--   ui:notify("Model loaded")                       Notification Center
--   ui:surface("panel", frame)                      a themed blank, for drawing your own
--
-- and, for hub menus, the row builders in ui.menu.
--
-- Everything is built through the plugin's context, so a toast or a bar on
-- screen goes away with the plugin like any other effect. Every constructor
-- returns `handle, release` in the context's own convention.
--
-- The split is the same as the rest of lib/: the element builders and layout
-- below are pure and tested headless, and only the Kit methods touch hs.*.

local theme = require("lib.theme")

local unpack = table.unpack or unpack

local M = { theme = theme, menu = {} }

-- ── Measuring ──────────────────────────────────────────────────────────────
-- Code points, not bytes: "“" is three bytes and one character wide.
local function chars(s)
  return select(2, tostring(s):gsub("[^\128-\191]", ""))
end

-- Pure. A system-font average, for a test with no window server, and for a
-- Hammerspoon that cannot measure.
function M.estimateWidth(text, size)
  return math.ceil(chars(text) * (size or theme.text.body) * 0.58)
end

-- Width of a single line of `text`. hs.drawing's measurer is the one
-- Hammerspoon function that sizes text without a canvas to hang it on; a probe
-- canvas would work too, but it is a window, and a spec counting canvases
-- would count it.
function M.measure(text, size, font)
  size = size or theme.text.body
  font = font or theme.font.regular
  local d = rawget(_G, "hs") and hs.drawing
  if d and d.getTextDrawingSize then
    local ok, got = pcall(d.getTextDrawingSize, tostring(text), { size = size, font = font })
    if ok and type(got) == "table" and tonumber(got.w) then return math.ceil(got.w) end
  end
  return M.estimateWidth(text, size)
end

-- Height a line of `size` takes, for vertical centring.
local function lineHeight(size) return math.ceil(size * theme.leading) end

-- ── Placement ──────────────────────────────────────────────────────────────
-- Pure. Where a surface of w × h sits on `screen` (an hs.screen frame):
--   center   the middle, for state that holds: a recording HUD
--   lower    two-thirds down, where macOS puts its own volume HUD: toasts
--   bottom   just above the Dock, for something to act on: a button bar
--   caption  higher than bottom, for text that grows upward as it arrives
--   top      under the menu bar
function M.place(screen, w, h, where)
  local x = screen.x + (screen.w - w) / 2
  local y
  if where == "center" then
    y = screen.y + (screen.h - h) / 2
  elseif where == "lower" then
    y = screen.y + screen.h * 0.72 - h / 2
  elseif where == "top" then
    y = screen.y + theme.inset.top
  elseif where == "caption" then
    y = screen.y + screen.h - h - theme.inset.caption
  else
    y = screen.y + screen.h - h - theme.inset.bottom
  end
  return { x = math.floor(x), y = math.floor(y), w = w, h = h }
end

-- ── Elements ───────────────────────────────────────────────────────────────
-- Pure builders for hs.canvas elements. A plugin drawing its own surface uses
-- these instead of writing color tables, so its pixels follow the theme too.

-- A role from theme.color, or a tone from theme.tones.
local function paint(name)
  return theme.color[name] or theme.tone(name)
end

-- The panel behind everything: surface color, hairline edge, rounded.
--   opts.radius  a number, or a theme.radius key
--   opts.solid   opaque black with no edge, for something that should read as
--                part of the machine
--   opts.island  hangs from the top edge: the top corners sit above the
--                surface so only the bottom two show rounded
function M.backdrop(w, h, opts)
  opts = opts or {}
  local r = opts.radius or (opts.island and "island") or "lg"
  if type(r) == "string" then r = theme.radius[r] end
  local el = {
    type = "rectangle",
    action = opts.solid and "fill" or "strokeAndFill",
    fillColor = opts.solid and theme.color.surfaceSolid or theme.color.surface,
    roundedRectRadii = { xRadius = r, yRadius = r },
    frame = { x = 0, y = 0, w = w, h = h },
  }
  if not opts.solid then el.strokeColor, el.strokeWidth = theme.color.edge, 1 end
  if opts.island then el.frame = { x = 0, y = -r, w = w, h = h + r } end
  return el
end

-- A line of text.
--   opts.style  a theme.text key (default body)
--   opts.color  a theme.color role or a tone (default text)
--   opts.bold, opts.align ("left" | "center" | "right"), opts.truncate
function M.label(text, frame, opts)
  opts = opts or {}
  return {
    type = "text", text = text, frame = frame,
    textSize = theme.text[opts.style or "body"] or theme.text.body,
    textFont = opts.bold and theme.font.bold or theme.font.regular,
    textColor = paint(opts.color or "text"),
    textAlignment = opts.align or "left",
    textLineBreak = opts.truncate and "truncateTail" or nil,
  }
end

-- A status dot. `tone` is a meaning: "recording", "working", "success"...
function M.dot(cx, cy, tone, radius)
  return { type = "circle", action = "fill", fillColor = theme.tone(tone),
           center = { x = cx, y = cy }, radius = radius or theme.size.dot }
end

-- A button: its plate and its label, two elements. `id` comes back in mouse
-- events as "btn:<id>". `hot` is the hovered or default one.
function M.button(id, label, frame, hot)
  local size = theme.text.body
  local top = math.floor((frame.h - lineHeight(size)) / 2) + 1
  return {
    type = "rectangle", action = "fill", id = "btn:" .. id,
    fillColor = hot and theme.color.accent or theme.color.control,
    roundedRectRadii = { xRadius = theme.radius.sm, yRadius = theme.radius.sm },
    frame = frame, trackMouseDown = true, trackMouseEnterExit = true,
  }, M.label(label, { x = frame.x, y = frame.y + top, w = frame.w, h = frame.h - top },
             { align = "center", color = hot and "onAccent" or "text" })
end

function M.buttonWidth(label)
  return M.measure(label, theme.text.body) + 2 * theme.space.md
end

-- ── Layouts ────────────────────────────────────────────────────────────────
-- Pure: a one-line message with an optional status dot, as { w, h, elements }.
-- The toast and the bar's result line are both this.
function M.messageLayout(text, opts)
  opts = opts or {}
  local size = theme.text[opts.style or "body"]
  local pad, r = theme.space.lg, theme.size.dot - 2
  local dotW = opts.tone and (2 * r + theme.space.sm) or 0
  local maxW = opts.maxWidth or 900
  local tw = math.min(M.measure(text, size), maxW - 2 * pad - dotW)
  local w = math.max(theme.size.minWidth, tw + dotW + 2 * pad)
  local h = lineHeight(size) + 2 * theme.space.md + 4
  -- The dot and the words are centred together, not the words alone.
  local left = math.floor((w - tw - dotW) / 2)
  local els = { M.backdrop(w, h, { radius = "md" }) }
  if opts.tone then els[#els + 1] = M.dot(left + r, h / 2, opts.tone, r) end
  els[#els + 1] = M.label(text,
    { x = left + dotW, y = math.floor((h - lineHeight(size)) / 2), w = tw + 2, h = lineHeight(size) },
    { style = opts.style, truncate = true, color = opts.color })
  return { w = w, h = h, elements = els }
end

-- Pure: the HUD, a dot and one word in the middle of the screen.
function M.hudLayout(text, opts)
  opts = opts or {}
  local size, pad, r = theme.text.display, theme.space.xl, theme.size.dot + 1
  local tw = M.measure(text, size)
  local w = math.max(theme.size.minWidth, pad + 2 * r + theme.space.md + tw + pad)
  local h = 64
  return { w = w, h = h, elements = {
    M.backdrop(w, h, { radius = "lg" }),
    M.dot(pad + r, h / 2, opts.tone or "neutral", r),
    M.label(text, { x = pad + 2 * r + theme.space.md, y = math.floor((h - lineHeight(size)) / 2),
                    w = w - (pad + 2 * r + theme.space.md) - pad / 2, h = lineHeight(size) },
            { style = "display", truncate = true }),
  } }
end

-- Pure: a bar of buttons under a title line.
--   state.title    what the buttons act on, left
--   state.hint     the keys that drive it, right, quieter
--   state.buttons  { { id, label }, ... } drawn in order
--   hover          the "btn:<id>" under the pointer
function M.barLayout(state, hover)
  local pad, gap, bh = theme.space.md, theme.space.sm, theme.size.control
  local headH = (state.title or state.hint) and (lineHeight(theme.text.footnote) + theme.space.sm) or 0
  local top = pad + headH
  local placed, x = {}, pad
  for _, b in ipairs(state.buttons or {}) do
    local bw = M.buttonWidth(b.label)
    placed[#placed + 1] = { b = b, x = x, w = bw }
    x = x + bw + gap
  end
  local w = math.max(theme.size.minWidth + 80, x - gap + pad)
  local h = top + bh + pad
  local els = { M.backdrop(w, h, { radius = "md" }) }
  local hintW = state.hint and (M.measure(state.hint, theme.text.caption) + 4) or 0
  if state.title then
    els[#els + 1] = M.label(state.title,
      { x = pad, y = pad - 2, w = w - 2 * pad - hintW - gap, h = lineHeight(theme.text.footnote) },
      { style = "footnote", color = "textSecondary", truncate = true })
  end
  if state.hint then
    els[#els + 1] = M.label(state.hint,
      { x = w - pad - hintW, y = pad - 1, w = hintW, h = lineHeight(theme.text.caption) },
      { style = "caption", color = "textTertiary", align = "right" })
  end
  for _, p in ipairs(placed) do
    local plate, text = M.button(p.b.id, p.b.label, { x = p.x, y = top, w = p.w, h = bh },
                                 hover == "btn:" .. p.b.id)
    els[#els + 1] = plate
    els[#els + 1] = text
  end
  return { w = w, h = h, elements = els }
end

-- ── Menu rows ──────────────────────────────────────────────────────────────
-- Pure. Every hub tile's menu is built from these, so a switch in one app is a
-- switch in all of them. They are plain hs.menubar rows with the extra fields
-- the hub panel understands (lib/menuhub.items), so the option-click dropdown
-- still shows them as an ordinary menu.
local menu = M.menu

function menu.switch(title, on, fn)
  return { title = title, switch = true, checked = on and true or false, fn = fn }
end

-- One of several: the hub draws a ✓ on the right.
function menu.choice(title, selected, fn)
  return { title = title, checked = selected and true or false, fn = fn }
end

-- Something to do. opts.disabled greys it out.
function menu.action(title, fn, opts)
  return { title = title, fn = fn, disabled = (opts and opts.disabled) or nil }
end

-- A line to read, not press. First in a group, the hub turns it into the
-- group's caption.
function menu.text(title)
  return { title = title, disabled = true }
end

-- spec: { min, max, step, unit }
function menu.slider(title, value, spec, fn)
  spec = spec or {}
  return { title = title, slider = { value = value, min = spec.min or 0, max = spec.max or 100,
                                     step = spec.step or 1, unit = spec.unit or "", fn = fn } }
end

-- `items` is a table, or a function that builds one when opened.
function menu.submenu(title, items)
  return { title = title, menu = items }
end

function menu.separator() return { title = "-" } end

-- ── The kit ────────────────────────────────────────────────────────────────
local Kit = {}
Kit.__index = Kit

function M.new(ctx)
  return setmetatable({ ctx = ctx }, Kit)
end

local function screenFrame() return hs.screen.mainScreen():frame() end

-- A themed blank canvas: over every app and on every space, with the backdrop
-- already drawn as element 1. For a plugin whose drawing is its own (a lyric
-- sweep, a growing transcript); anything a component covers should use the
-- component instead.
--   opts.focusless  clicks never bring Hammerspoon forward, so whatever the
--                   user was typing into keeps the keyboard
--   opts.backdrop   false to start empty, for a caller that redraws
--                   everything with replaceElements and brings its own
--   plus backdrop()'s radius, solid and island
function Kit:surface(name, frame, opts)
  opts = opts or {}
  local c, release = self.ctx:canvas(name, frame)
  c:level(hs.canvas.windowLevels.overlay)
  c:behavior({ "canJoinAllSpaces", "stationary" })
  if opts.focusless and c.clickActivating then c:clickActivating(false) end
  if opts.backdrop ~= false then c[1] = M.backdrop(frame.w, frame.h, opts) end
  return c, release
end

-- One toast on screen for the whole config, not one per plugin: a new one
-- from any plugin replaces whatever is up. hs.alert stacks its messages at the
-- bottom of the screen, which is why apps/dictation stopped using it.
local current

-- opts.tone     adds a status dot: "success", "danger", "working"...
-- opts.seconds  how long it stays (theme.motion.toast)
-- opts.where    a place() name, default "lower"
-- Returns the canvas and a function that takes it down early.
function Kit:toast(text, opts)
  opts = opts or {}
  if current then current() end
  local f = screenFrame()
  local layout = M.messageLayout(tostring(text), { tone = opts.tone, maxWidth = math.floor(f.w * 0.8) })
  local c, release = self:surface("toast", M.place(f, layout.w, layout.h, opts.where or "lower"),
                                  { backdrop = false })
  for i, el in ipairs(layout.elements) do c[i] = el end
  c:show(theme.motion.fade)
  local stop
  local function done()
    if stop then stop() end
    release()
    if current == done then current = nil end
  end
  stop = select(2, self.ctx:after(opts.seconds or theme.motion.toast, done))
  current = done
  return c, done
end

-- A state that holds until the plugin says otherwise: "Recording",
-- "Transcribing". Asking again replaces it. Hide it with the release.
function Kit:hud(text, opts)
  opts = opts or {}
  local layout = M.hudLayout(tostring(text), opts)
  local c, release = self:surface("hud", M.place(screenFrame(), layout.w, layout.h, opts.where or "center"),
                                  { backdrop = false })
  for i, el in ipairs(layout.elements) do c[i] = el end
  c:show()
  return c, release
end

-- fn(appearance) when macOS switches between light and dark and the design
-- follows it. Components drawn after the switch are already right; this is for
-- a surface that stays up, like the karaoke island, to redraw itself. Leaves
-- with the plugin.
function Kit:onAppearance(fn)
  return fn, self.ctx:effect(theme.onChange(fn))
end

-- Notification Center, titled with the plugin's name unless opts.title says
-- otherwise. opts.subtitle, opts.onClick.
function Kit:notify(text, opts)
  opts = opts or {}
  local attrs = { title = opts.title or self.ctx.name, subTitle = opts.subtitle,
                  informativeText = text, withdrawAfter = opts.withdrawAfter }
  local n = opts.onClick and hs.notify.new(function() opts.onClick() end, attrs)
                         or hs.notify.new(attrs)
  n:send()
  return n
end

-- ── Bar ────────────────────────────────────────────────────────────────────
-- A row of buttons to act on something, drawn on a canvas rather than a
-- webview because a click on it must never make Hammerspoon the frontmost
-- app: apps/text_actions pastes into whatever was focused, and a bar that took
-- focus would paste into itself.
--
--   local bar = ui:bar("bar", { pick = function(id) end, hover = function(inside) end })
--   bar:show({ title = "Rewrite “…”", hint = "⌥ number · esc", buttons = { { id, label } } })
--   bar:show({ message = "Copied ✓", tone = "success" })    the same bar, now a result line
--   bar:close()
local Bar = {}
Bar.__index = Bar

function Kit:bar(name, on)
  return setmetatable({ kit = self, name = name or "bar", on = on or {} }, Bar)
end

function Bar:show(state)
  self.state = state
  self:draw()
  return self
end

function Bar:draw()
  local s, f = self.state, screenFrame()
  local layout = s.message
    and M.messageLayout(s.message, { tone = s.tone, maxWidth = math.floor(f.w * 0.8) })
    or M.barLayout(s, self.hover)
  local frame = M.place(f, layout.w, layout.h, s.where or "bottom")
  if not self.canvas then
    self.canvas, self.release = self.kit:surface(self.name, frame, { focusless = true, backdrop = false })
    local c = self.canvas
    if c.canvasMouseEvents then c:canvasMouseEvents(false, false, true, false) end
    if c.mouseCallback then c:mouseCallback(function(_, msg, id) self:mouse(msg, id) end) end
  else
    self.canvas:frame(frame)
  end
  self.canvas:replaceElements(unpack(layout.elements))
  self.canvas:show()
end

-- "_canvas_" is the bar itself: hover reports the pointer arriving and
-- leaving, which is how a caller holds a countdown while the user reads.
function Bar:mouse(msg, id)
  if id == "_canvas_" then
    if self.on.hover and (msg == "mouseEnter" or msg == "mouseExit") then
      self.on.hover(msg == "mouseEnter")
    end
    return
  end
  if type(id) ~= "string" or not id:match("^btn:") then return end
  if msg == "mouseEnter" or msg == "mouseExit" then
    self.hover = (msg == "mouseEnter") and id or nil
    if self.state and not self.state.message then self:draw() end
  elseif msg == "mouseDown" and self.on.pick then
    self.on.pick(id:sub(5))
  end
end

function Bar:close()
  if self.release then self.release() end
  self.canvas, self.release, self.hover, self.state = nil, nil, nil, nil
end

-- ── Gallery ────────────────────────────────────────────────────────────────
-- Every component once, a second apart, so a theme change can be looked at
-- rather than imagined. `hs -c 'uiGallery()'`, or the Plugins tile.
function M.gallery(kit)
  local ctx = kit.ctx
  kit:toast("Design: " .. tostring(theme.name) .. " · a toast replaces the one before it",
            { tone = "success", seconds = 1.9 })
  ctx:after(2.0, function()
    local _, hide = kit:hud("Recording", { tone = "recording" })
    ctx:after(1.4, function()
      hide()
      local bar
      bar = kit:bar("gallery-bar", { pick = function(id)
        if id == "close" then return bar:close() end
        bar:show({ message = "Picked " .. id, tone = "success" })
        ctx:after(1.2, function() bar:close() end)
      end })
      bar:show({ title = "A bar of buttons", hint = "click one · closes in 6 s",
                 buttons = { { id = "one", label = "First" }, { id = "two", label = "Second" },
                             { id = "close", label = "✕" } } })
      ctx:after(6, function() bar:close() end)
    end)
  end)
end

-- Every component drawn, photographed and taken down again, one PNG each in
-- `dir`: toast, hud, bar (its first button lit, as under the pointer), and
-- hub (the panel open on its tile grid). For judging a design from the
-- pictures rather than from memory: `hs -c 'uiShoot("/tmp/hs-design")'`,
-- then read the files about four seconds later.
function M.shoot(kit, dir)
  local ctx = kit.ctx
  os.execute("mkdir -p " .. string.format("%q", dir))
  local function save(name, frame)
    local m = 16
    local shot = hs.screen.mainScreen():snapshot()
    shot:croppedCopy({ x = frame.x - m, y = frame.y - m, w = frame.w + 2 * m, h = frame.h + 2 * m })
        :saveToFile(dir .. "/" .. name .. ".png")
  end
  local toast, hideToast = kit:toast("Copied: the quick brown fox", { tone = "success", seconds = 5 })
  ctx:after(0.4, function()
    save("toast", toast:frame()); hideToast()
    local hud, hideHud = kit:hud("Recording", { tone = "recording" })
    ctx:after(0.4, function()
      save("hud", hud:frame()); hideHud()
      local bar = kit:bar("shoot-bar")
      bar:show({ title = "Rewrite “so um move it to thursday”", hint = "⌥ number · esc",
                 buttons = { { id = "a", label = "1 Clean up" }, { id = "b", label = "2 Simplify" },
                             { id = "c", label = "3 Formal" }, { id = "x", label = "✕" } } })
      bar:mouse("mouseEnter", "btn:a")
      ctx:after(0.4, function()
        save("bar", bar.canvas:frame()); bar:close()
        local hub = require("lib.menuhub")
        hub.togglePanel()
        ctx:after(0.9, function()
          if hub.panel then save("hub", hub.panel:frame()) end
          hub.togglePanel()
        end)
      end)
    end)
  end)
  return dir
end

return M
