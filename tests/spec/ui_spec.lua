_G.hs = require("hs")

local ui      = require("lib.ui")
local theme   = require("lib.theme")
local context = require("lib.context")

-- Canvases that keep their elements by index and say whether they are gone,
-- and one-shot timers a spec fires by hand.
local canvases, after
local realNew, realAfter = hs.canvas.new, hs.timer.doAfter

local function stubs()
  canvases, after = {}, {}
  hs.canvas.new = function(frame)
    local c = { frame_ = frame, deleted = false, visible = false }
    function c:level() return self end
    function c:behavior() return self end
    function c:show() self.visible = true; return self end
    function c:delete() self.deleted = true end
    function c:frame(f) if f then self.frame_ = f end; return self.frame_ end
    function c:clickActivating(v) self.activating = v; return self end
    function c:canvasMouseEvents() return self end
    function c:mouseCallback(fn) self.mouse = fn; return self end
    function c:replaceElements(...)
      for i = 1, 64 do self[i] = nil end
      for i, el in ipairs({ ... }) do self[i] = el end
      return self
    end
    canvases[#canvases + 1] = c
    return c
  end
  hs.timer.doAfter = function(delay, fn)
    local t = { delay = delay, fn = fn, stopped = false }
    function t:stop() self.stopped = true end
    after[#after + 1] = t
    return t
  end
end

local function fire(delay)
  for _, t in ipairs(after) do
    if t.delay == delay and not t.stopped and not t.fired then t.fired = true; t.fn() end
  end
end

local function elements(c)
  local out = {}
  for i = 1, 64 do if c[i] then out[#out + 1] = c[i] end end
  return out
end

local function texts(c)
  local out = {}
  for _, el in ipairs(elements(c)) do if el.type == "text" then out[#out + 1] = el.text end end
  return out
end

local SCREEN = { x = 0, y = 0, w = 1440, h = 900 }

describe("ui.place", function()
  it("centres horizontally wherever it goes", function()
    for _, where in ipairs({ "center", "lower", "bottom", "caption", "top" }) do
      local f = ui.place(SCREEN, 400, 50, where)
      assert.equals(520, f.x, where)
    end
  end)

  it("keeps a bar below a caption, and both above the screen's bottom edge", function()
    local bar = ui.place(SCREEN, 400, 50, "bottom")
    local cap = ui.place(SCREEN, 400, 50, "caption")
    assert.is_true(cap.y < bar.y)
    assert.is_true(bar.y + bar.h <= SCREEN.h)
  end)

  -- Dictation shows its transcript and the rewrite bar at the same time.
  it("leaves room between a caption and a full bar", function()
    local barH = ui.barLayout({ title = "Rewrite", hint = "esc",
                                buttons = { { id = "a", label = "One" } } }).h
    local bar = ui.place(SCREEN, 400, barH, "bottom")
    local cap = ui.place(SCREEN, 400, 110, "caption")
    assert.is_true(cap.y + cap.h <= bar.y)
  end)

  it("follows a screen that does not start at the origin", function()
    local f = ui.place({ x = -1728, y = 275, w = 1728, h = 1117 }, 200, 64, "center")
    assert.equals(-1728 + 764, f.x)
    assert.equals(275 + 526, f.y)
  end)
end)

describe("ui element builders", function()
  it("draws every backdrop in the theme's surface color with a hairline edge", function()
    local b = ui.backdrop(300, 40)
    assert.equals(theme.color.surface, b.fillColor)
    assert.equals(theme.color.edge, b.strokeColor)
    assert.equals(theme.radius.lg, b.roundedRectRadii.xRadius)
  end)

  it("takes a radius by name", function()
    assert.equals(theme.radius.sm, ui.backdrop(10, 10, { radius = "sm" }).roundedRectRadii.xRadius)
  end)

  it("hangs an island's top corners above the screen", function()
    local b = ui.backdrop(300, 64, { island = true, solid = true })
    assert.equals(-theme.radius.island, b.frame.y)
    assert.equals(64 + theme.radius.island, b.frame.h)
    assert.equals(theme.color.surfaceSolid, b.fillColor)
    assert.is_nil(b.strokeColor)
  end)

  it("sizes and colors a label by role", function()
    local l = ui.label("hi", { x = 0, y = 0, w = 10, h = 10 }, { style = "caption", color = "textTertiary" })
    assert.equals(theme.text.caption, l.textSize)
    assert.equals(theme.color.textTertiary, l.textColor)
  end)

  it("colors a label by tone too", function()
    local l = ui.label("!", { x = 0, y = 0, w = 10, h = 10 }, { color = "danger" })
    assert.equals(theme.color.danger, l.textColor)
  end)

  it("gives a button a plate that reports its id, and lights the hot one", function()
    local plate, text = ui.button("go", "Go", { x = 0, y = 0, w = 60, h = 30 }, true)
    assert.equals("btn:go", plate.id)
    assert.is_true(plate.trackMouseDown)
    assert.equals(theme.color.accent, plate.fillColor)
    assert.equals("Go", text.text)
    local cold = ui.button("go", "Go", { x = 0, y = 0, w = 60, h = 30 }, false)
    assert.equals(theme.color.control, cold.fillColor)
  end)

  it("counts characters, not bytes, when it has to estimate", function()
    assert.equals(ui.estimateWidth("abc", 14), ui.estimateWidth("“b”", 14))
  end)
end)

describe("ui layouts", function()
  it("never draws a message narrower than the theme allows", function()
    assert.equals(theme.size.minWidth, ui.messageLayout("ok").w)
  end)

  it("adds a dot only when the message has a tone", function()
    local plain = ui.messageLayout("Copied")
    local toned = ui.messageLayout("Copied", { tone = "success" })
    local function dots(l)
      local n = 0
      for _, el in ipairs(l.elements) do if el.type == "circle" then n = n + 1 end end
      return n
    end
    assert.equals(0, dots(plain))
    assert.equals(1, dots(toned))
  end)

  it("caps a long message at its maximum width", function()
    local l = ui.messageLayout(string.rep("word ", 400), { maxWidth = 600 })
    assert.is_true(l.w <= 600)
  end)

  it("lays buttons left to right without overlap", function()
    local l = ui.barLayout({ title = "Rewrite", hint = "esc",
                             buttons = { { id = "a", label = "One" }, { id = "b", label = "Two" } } })
    local plates = {}
    for _, el in ipairs(l.elements) do if el.id then plates[#plates + 1] = el end end
    assert.equals(2, #plates)
    assert.is_true(plates[1].frame.x + plates[1].frame.w < plates[2].frame.x)
    assert.is_true(plates[2].frame.x + plates[2].frame.w <= l.w)
  end)
end)

describe("ui.menu", function()
  local menuhub = require("lib.menuhub")

  -- The builders exist so a row means the same thing in every tile, which is
  -- only true if the hub reads each one as the kind it claims to be.
  it("builds rows the hub reads as the kind they say", function()
    local rows = menuhub.items({
      ui.menu.switch("Play", true, function() end),
      ui.menu.choice("Brown", false, function() end),
      ui.menu.action("Reset", function() end),
      ui.menu.separator(),
      ui.menu.text("Idle"),
      ui.menu.slider("Volume", 40, { max = 100, unit = "%" }, function() end),
      ui.menu.submenu("More", { ui.menu.action("x", function() end) }),
    })
    local kinds = {}
    for _, r in ipairs(rows) do kinds[#kinds + 1] = r.kind end
    assert.same({ "switch", "check", "act", "sep", "info", "slider", "sub" }, kinds)
    assert.equals("%", rows[6].unit)
  end)

  it("greys out an action that asks to be", function()
    assert.is_true(ui.menu.action("x", function() end, { disabled = true }).disabled)
    assert.is_nil(ui.menu.action("x", function() end).disabled)
  end)
end)

describe("the kit", function()
  local ctx, kit

  before_each(function()
    stubs()
    ctx = context.new("Test")
    kit = ctx:ui()
  end)

  after_each(function()
    ctx:dispose()
    hs.canvas.new, hs.timer.doAfter = realNew, realAfter
  end)

  it("is one kit per context", function()
    assert.equals(kit, ctx:ui())
  end)

  it("shows a toast and takes it down when its time is up", function()
    local c = kit:toast("Copied", { seconds = 2 })
    assert.is_true(c.visible)
    assert.same({ "Copied" }, texts(c))
    fire(2)
    assert.is_true(c.deleted)
    assert.equals(0, ctx:count())
  end)

  -- hs.alert stacks; this is the reason the toast exists.
  it("keeps one toast on screen across every plugin", function()
    local other = context.new("Other")
    local first = kit:toast("one")
    local second = other:ui():toast("two")
    assert.is_true(first.deleted)
    assert.is_false(second.deleted)
    other:dispose()
  end)

  it("lets a toast be taken down early", function()
    local c, hide = kit:toast("bye")
    hide()
    assert.is_true(c.deleted)
    assert.equals(0, ctx:count())
  end)

  it("draws a HUD with a dot in the tone it was given", function()
    local c, hide = kit:hud("Recording", { tone = "recording" })
    local dot
    for _, el in ipairs(elements(c)) do if el.type == "circle" then dot = el end end
    assert.equals(theme.color.danger, dot.fillColor)
    hide()
    assert.is_true(c.deleted)
  end)

  it("replaces a HUD rather than stacking a second", function()
    local first = kit:hud("Recording")
    kit:hud("Transcribing", { tone = "working" })
    assert.is_true(first.deleted)
    assert.equals(1, ctx:count())
  end)

  it("draws a surface over every app with the backdrop already in place", function()
    local c = kit:surface("panel", { x = 0, y = 0, w = 200, h = 100 })
    assert.equals("rectangle", c[1].type)
    assert.equals(200, c[1].frame.w)
  end)

  it("takes everything it drew back when the plugin goes", function()
    local t = kit:toast("x")
    local h = kit:hud("y")
    ctx:dispose()
    assert.is_true(t.deleted)
    assert.is_true(h.deleted)
  end)

  describe("bar", function()
    local picked, hovered, bar

    before_each(function()
      picked, hovered = {}, {}
      bar = kit:bar("bar", { pick = function(id) picked[#picked + 1] = id end,
                             hover = function(inside) hovered[#hovered + 1] = inside end })
      bar:show({ title = "Rewrite", hint = "esc",
                 buttons = { { id = "a", label = "One" }, { id = "b", label = "Two" } } })
    end)

    it("never takes focus from the app being typed into", function()
      assert.is_false(canvases[1].activating)
    end)

    it("reports a click by the button's own id", function()
      canvases[1].mouse(canvases[1], "mouseDown", "btn:b")
      assert.same({ "b" }, picked)
    end)

    it("lights the button under the pointer and only that one", function()
      canvases[1].mouse(canvases[1], "mouseEnter", "btn:a")
      local lit = {}
      for _, el in ipairs(elements(canvases[1])) do
        if el.id then lit[el.id] = el.fillColor == theme.color.accent end
      end
      assert.same({ ["btn:a"] = true, ["btn:b"] = false }, lit)
    end)

    it("says when the pointer arrives and leaves", function()
      canvases[1].mouse(canvases[1], "mouseEnter", "_canvas_")
      canvases[1].mouse(canvases[1], "mouseExit", "_canvas_")
      assert.same({ true, false }, hovered)
    end)

    it("turns into a result line on the same canvas", function()
      bar:show({ message = "Copied ✓", tone = "success" })
      assert.equals(1, #canvases)
      assert.same({ "Copied ✓" }, texts(canvases[1]))
    end)

    it("closes", function()
      bar:close()
      assert.is_true(canvases[1].deleted)
      assert.equals(0, ctx:count())
    end)
  end)
end)
