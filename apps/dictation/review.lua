-- The review panel: a take waits here until you send it. Part of
-- apps/dictation, built on its context:
--
--   local rv = require("apps.dictation.review")({
--     ctx = ctx, rewrite = rw, typer = fn, onSent = fn(text) })
--   rv.open(text, { cleanup = true })   show it; cleanup runs the cleanup preset first
--   rv.close(reason)                    take it down; the text stays on the clipboard
--
-- It sits where the live caption was, so the words you watched arrive turn
-- into the draft you approve without moving. While it is up it holds these
-- keys, and gives them back when it closes:
--
--   ↩        paste the draft at the cursor (⌘V)
--   ⇧↩       type it, one keystroke at a time, for a terminal or a remote
--            desktop that refuses a paste
--   ⌥1…⌥9    run a rewrite preset on the draft; the result becomes the draft
--   ⌥0       back to the words as heard
--   esc      close it without sending
--
-- The clipboard always holds the draft, so a panel closed by esc or by the next
-- take has not lost anything: ⌘V still has it.
--
-- The panel never takes focus (lib/ui surfaces are focusless), which is what
-- lets ↩ paste into the app you were in. Nothing here has a timeout: a take
-- under review is waiting for you, and sending it on a timer would put words
-- wherever focus happened to be.

local core  = require("lib.text_actions")
local utils = require("lib.utils")
local UI    = require("lib.ui")
local theme = UI.theme

local unpack = table.unpack or unpack

local HINT = "↩ paste · ⇧↩ type · ⌥ number rewrite · esc close"

local function lh(style) return math.ceil(theme.text[style] * theme.leading) end

-- ── Pure ───────────────────────────────────────────────────────────────────
-- The buttons for state R, in the order drawn. `key` is the ⌥ digit.
local function buttons(R, presets)
  local out = { { id = "paste", label = "Paste ↩" }, { id = "type", label = "Type ⇧↩" } }
  if R.draft ~= R.original then out[#out + 1] = { id = "original", label = "0 Original", key = 0 } end
  for _, it in ipairs(core.barItems(presets)) do
    out[#out + 1] = { id = it.id, label = string.format("%d %s", it.key, it.label), key = it.key }
  end
  return out
end

-- The line above the draft: what it is, or what is happening to it.
local function status(R)
  if R.mode == "working" then return R.message, "working" end
  if R.mode == "failed" then return R.message, "danger" end
  return R.label and ("Review · " .. R.label) or "Review · as heard", "draft"
end

-- Drop whole UTF-8 characters off the front of `s` until it is at most `n`
-- bytes, so a cut never lands inside one.
local function tail(s, n)
  if #s <= n then return s end
  local from = #s - n + 1
  while from <= #s and s:byte(from) >= 0x80 and s:byte(from) < 0xC0 do from = from + 1 end
  return "…" .. s:sub(from)
end

-- The panel for R on `screen` (an hs.screen frame), as { w, h, elements }.
-- Buttons wrap to a second row when they do not fit. A draft too long for 70%
-- of the screen shows its end, the part just spoken.
local function layout(R, presets, screen, hover)
  local w = math.min(1000, math.floor(screen.w * 0.72))
  local pad, gap, bh = theme.space.xl, theme.space.sm, theme.size.control
  local inner = w - 2 * pad

  local placed, x, row = {}, 0, 0
  for _, b in ipairs(buttons(R, presets)) do
    local bw = UI.buttonWidth(b.label)
    if x > 0 and x + bw > inner then x, row = 0, row + 1 end
    placed[#placed + 1] = { b = b, x = pad + x, row = row, w = bw }
    x = x + bw + gap
  end
  local buttonsH = (row + 1) * bh + row * gap

  local size, lineH = theme.text.title, lh("title")
  local cpl = math.max(8, math.floor(inner / (size * 0.52)))
  local headH = lh("footnote")
  local fixed = pad + headH + theme.space.md + theme.space.lg + buttonsH + pad
  local maxLines = math.max(1, math.floor((math.floor(screen.h * 0.7) - fixed) / lineH))
  local text = R.draft
  local lines = utils.countWrappedLines(text, cpl)
  if lines > maxLines then text = tail(text, maxLines * cpl - 2); lines = maxLines end
  local h = fixed + lines * lineH

  local line, tone = status(R)
  local r = theme.size.dot - 2
  local dotW = 2 * r + theme.space.sm
  local hintW = UI.measure(HINT, theme.text.caption) + 4
  local els = { UI.backdrop(w, h, { radius = "lg" }) }
  els[#els + 1] = UI.dot(pad + r, pad + headH / 2, tone, r)
  els[#els + 1] = UI.label(line, { x = pad + dotW, y = pad, w = inner - dotW - hintW - gap, h = headH },
                           { style = "footnote", color = "textSecondary", truncate = true })
  els[#els + 1] = UI.label(HINT, { x = w - pad - hintW, y = pad + 1, w = hintW, h = lh("caption") },
                           { style = "caption", color = "textTertiary", align = "right" })
  local textY = pad + headH + theme.space.md
  els[#els + 1] = UI.label(text, { x = pad, y = textY, w = inner, h = lines * lineH + 4 }, { style = "title" })
  local top = textY + lines * lineH + theme.space.lg
  for _, p in ipairs(placed) do
    local plate, label = UI.button(p.b.id, p.b.label,
      { x = p.x, y = top + p.row * (bh + gap), w = p.w, h = bh },
      hover == "btn:" .. p.b.id or (hover == nil and p.b.id == "paste"))
    els[#els + 1] = plate
    els[#els + 1] = label
  end
  return { w = w, h = h, elements = els }
end

-- ── The panel ──────────────────────────────────────────────────────────────
local function new(host)
  local ctx, rw = host.ctx, host.rewrite
  local P = { current = nil }

  local function presets() return rw.cfg and rw.cfg.presets or {} end

  local function draw()
    local R = P.current
    if not R then return end
    local screen = hs.screen.mainScreen():frame()
    local lay = layout(R, presets(), screen, R.hover)
    local frame = UI.place(screen, lay.w, lay.h, "caption")
    if not R.canvas then
      R.canvas, R.release = ctx:ui():surface("review", frame, { focusless = true, backdrop = false })
      local c = R.canvas
      if c.canvasMouseEvents then c:canvasMouseEvents(true, false, true, false) end
      if c.mouseCallback then
        c:mouseCallback(function(_, msg, id)
          if P.current ~= R or type(id) ~= "string" or not id:match("^btn:") then return end
          if msg == "mouseEnter" or msg == "mouseExit" then
            R.hover = (msg == "mouseEnter") and id or nil
            draw()
          elseif msg == "mouseDown" then
            P.pick(id:sub(5))
          end
        end)
      end
    else
      R.canvas:frame(frame)
    end
    R.canvas:replaceElements(unpack(lay.elements))
    R.canvas:show()
  end

  local function stopRewrite(R)
    if R.cancel then R.cancel(); R.cancel = nil end
  end

  function P.close(reason)
    local R = P.current
    if not R then return end
    P.current = nil
    stopRewrite(R)
    for _, release in ipairs(R.keys) do release() end
    if R.release then R.release() end
    if host.onClose then pcall(host.onClose, reason) end
  end

  local function setDraft(R, text, label)
    R.draft, R.label = text, label
    hs.pasteboard.setContents(text)
  end

  -- Send the draft. "paste" puts it on the clipboard and presses ⌘V a moment
  -- later, once the panel's own key is up; "type" hands it to the typer.
  function P.send(how)
    local R = P.current
    if not R then return end
    local text = R.draft
    P.close("sent")
    hs.pasteboard.setContents(text)
    if host.onSent then pcall(host.onSent, text) end
    if how == "type" then
      local t = host.typer and host.typer()
      if t then t.type(text, { replace = true, quiet = true }); return end
      ctx:ui():toast("Copied · the typer is off, ⌘V to paste")
      return
    end
    ctx:after(0.05, function() hs.eventtap.keyStroke({ "cmd" }, "v", 0) end)
  end

  function P.rewrite(id, opts)
    local R = P.current
    if not R then return end
    local preset = core.find(presets(), id)
    if not preset then return end
    stopRewrite(R)
    R.mode, R.message = "working", preset.label .. "…  " .. (preset.model or (rw.cfg and rw.cfg.model) or "")
    draw()
    R.cancel = rw.run(R.draft, id, function(result, why)
      R.cancel = nil
      if P.current ~= R then return end
      if not result then
        R.mode, R.message = "failed", "Couldn't rewrite: " .. utils.truncate(tostring(why), 60) .. " · kept the draft"
      else
        R.mode = "review"
        setDraft(R, result, preset.label)
      end
      draw()
    end, { timeout = (opts and opts.timeout) or core.ACTION_TIMEOUT })
  end

  function P.original()
    local R = P.current
    if not R or R.draft == R.original then return end
    stopRewrite(R)
    R.mode = "review"
    setDraft(R, R.original, nil)
    draw()
  end

  function P.pick(id)
    if id == "paste" or id == "type" then return P.send(id) end
    if id == "original" then return P.original() end
    P.rewrite(id)
  end

  function P.dismiss()
    if not P.current then return end
    P.close("dismissed")
    ctx:ui():toast("Not sent · it's on the clipboard")
  end

  local function bindKeys(R)
    local function bind(mods, key, fn)
      R.keys[#R.keys + 1] = select(2, ctx:hotkey(mods, key, function() if P.current == R then fn() end end))
    end
    bind({}, "return", function() P.send("paste") end)
    bind({ "shift" }, "return", function() P.send("type") end)
    bind({}, "escape", function()
      -- Shadows keystroke_typer's own Escape while up, so it does both jobs:
      -- stop typing still going from an earlier take, and close the panel.
      local t = host.typer and host.typer()
      if t and t.pending and t.pending() > 0 and t.cancel then t.cancel() end
      P.dismiss()
    end)
    bind({ "alt" }, "0", P.original)
    for _, it in ipairs(core.barItems(presets())) do
      bind({ "alt" }, tostring(it.key), function() P.rewrite(it.id) end)
    end
  end

  -- opts.cleanup   run the cleanup preset straight away (dictation's switch)
  function P.open(text, opts)
    if type(text) ~= "string" or not text:match("%S") then return end
    opts = opts or {}
    P.close("replaced")
    local R = { original = text, draft = text, mode = "review", keys = {} }
    P.current = R
    hs.pasteboard.setContents(text)
    bindKeys(R)
    draw()
    if opts.cleanup then P.rewrite("cleanup", { timeout = core.CLEANUP_TIMEOUT }) end
  end

  function P.isOpen() return P.current ~= nil end

  return P
end

return setmetatable({ buttons = buttons, layout = layout, status = status }, {
  __call = function(_, host) return new(host) end,
})
