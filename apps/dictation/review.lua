-- The review panel: a take waits here until you send it. Part of
-- apps/dictation, built on its context:
--
--   local rv = require("apps.dictation.review")({
--     ctx = ctx, rewrite = rw, typer = fn, onSent = fn(text) })
--   rv.open(text, { cleanup = true })   show it; cleanup runs the cleanup preset first
--   rv.heard(text, words)               the take's words from POST /words
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
--   ⌥0       back to the words as heard, or cancel a rewrite still running
--   esc      close it without sending
--
-- While a rewrite runs, ↩, ⇧↩ and the other presets wait for it: their
-- buttons are greyed out and the keys do nothing, so what is sent is always
-- what the panel shows once Claude is done.
--
-- Every word of the draft can be clicked. The row of buttons then becomes that
-- word's choices: what else the speech model heard there, "Edit…" and
-- "Delete". ↩ takes the first one and esc goes back. They are drawn in the
-- panel rather than in a native menu, because a menu opens under an overlay.
-- A word the model was unsure of is underlined, and pointing at it puts its
-- alternatives in the line above the draft. They come from
-- dictation, which sends the kept recording to the server's POST /words once
-- the take is saved (dictate/alternatives.py says how they are found). That
-- pass decodes the whole recording at once, which hears better than the live
-- stream the panel opened with, so its words replace the draft while the draft
-- is still the words as heard.
--
-- The clipboard always holds the draft, so a panel closed by esc or by the next
-- take has not lost anything: ⌘V still has it.
--
-- The panel never takes focus (lib/ui surfaces are focusless), which is what
-- lets ↩ paste into the app you were in. The edit box is the one exception: it
-- is a Hammerspoon dialog, so it takes the keyboard while it is up and hands it
-- back to the window you were in when it closes. The panel hides and lets go
-- of its keys while the box is up, so the box is never under it and ↩ there
-- confirms the box instead of pasting. Nothing here has a timeout: a take under review is waiting for you,
-- and sending it on a timer would put words wherever focus happened to be.

local core  = require("lib.text_actions")
local utils = require("lib.utils")
local UI    = require("lib.ui")
local theme = UI.theme

local unpack = table.unpack or unpack

local HINT    = "↩ paste · ⇧↩ type · ⌥ number rewrite · click a word · esc close"
local WAITING = "wait for the rewrite · ⌥0 cancel · esc close"
local PICKING = "↩ first choice · esc back"

local function lh(style) return math.ceil(theme.text[style] * theme.leading) end

-- ── Pure ───────────────────────────────────────────────────────────────────
local words

-- The buttons for state R, in the order drawn; the first is the one ↩
-- presses. `key` is the ⌥ digit. While a rewrite runs, everything but ⌥0,
-- which cancels it, is disabled. While a word is picked they are its choices.
local function buttons(R, presets)
  local w = R.picking and words(R)[R.picking]
  if w then
    local out = {}
    for k, alt in ipairs(w.alts or {}) do out[#out + 1] = { id = "alt:" .. k, label = alt } end
    out[#out + 1] = { id = "edit", label = "Edit…" }
    out[#out + 1] = { id = "delete", label = "Delete" }
    out[#out + 1] = { id = "back", label = "Back" }
    return out
  end
  local busy = R.mode == "working"
  local out = { { id = "paste", label = "Paste ↩", disabled = busy },
                { id = "type", label = "Type ⇧↩", disabled = busy } }
  if busy then
    out[#out + 1] = { id = "original", label = "0 Cancel", key = 0 }
  elseif R.draft ~= R.original then
    out[#out + 1] = { id = "original", label = "0 Original", key = 0 }
  end
  for _, it in ipairs(core.barItems(presets)) do
    out[#out + 1] = { id = it.id, label = string.format("%d %s", it.key, it.label), key = it.key,
                      disabled = busy }
  end
  return out
end

-- The draft as words, each { text, alts, unsure }: the ones POST /words sent
-- while the draft is still them, else the draft split on spaces, so a rewrite
-- can be fixed one word at a time too.
function words(R)
  if R.words then return R.words end
  local out = {}
  for w in R.draft:gmatch("%S+") do out[#out + 1] = { text = w } end
  return out
end

local function join(list)
  local out = {}
  for _, w in ipairs(list) do out[#out + 1] = w.text end
  return table.concat(out, " ")
end

-- The word under the pointer, from a hover id "word:<n>".
local function hovered(R, hover)
  local n = type(hover) == "string" and tonumber(hover:match("^word:(%d+)$"))
  return n and words(R)[n], n
end

-- The line above the draft: what it is, what is happening to it, or what the
-- model said about the word under the pointer.
local function status(R, hover)
  if R.mode == "working" then return R.message, "working" end
  if R.mode == "failed" then return R.message, "danger" end
  local picked = R.picking and words(R)[R.picking]
  if picked then
    return "“" .. picked.text .. "” · " .. ((picked.alts and #picked.alts > 0)
      and "pick what you said, or edit it" or "edit or delete it"), "draft"
  end
  local w = hovered(R, hover)
  if w then
    if w.alts and #w.alts > 0 then
      return "Could be " .. table.concat(w.alts, " · ") .. " · click to pick", "draft"
    end
    if w.unsure then return "Not sure of this word · click to fix it", "draft" end
    return "Click to change or delete this word", "draft"
  end
  local line = "Review · " .. (R.label or "as heard")
  if R.edited then line = line .. " · edited" end
  local n = 0
  for _, x in ipairs(words(R)) do if x.unsure then n = n + 1 end end
  if n > 0 then line = line .. string.format(" · %d %s to check", n, n == 1 and "word" or "words") end
  return line, "draft"
end

-- Widths of words already measured, by size. Hovering redraws the panel, and
-- measuring a long take word by word on every redraw is what this saves.
local widths, measured = {}, 0
local function width(text, size)
  local k = size .. "\0" .. text
  if not widths[k] then
    if measured > 2000 then widths, measured = {}, 0 end
    widths[k], measured = UI.measure(text, size), measured + 1
  end
  return widths[k]
end

-- Words into lines `inner` wide, each line a list of { n, x, w }. A word wider
-- than a line gets a line of its own and is cut to fit it.
local function flow(list, inner, size)
  local space = math.max(1, width("a b", size) - width("ab", size))
  local lines, x = { {} }, 0
  for n, w in ipairs(list) do
    local ww = math.min(width(w.text, size), inner)
    if x > 0 and x + ww > inner then lines[#lines + 1], x = {}, 0 end
    local line = lines[#lines]
    line[#line + 1] = { n = n, x = x, w = ww }
    x = x + ww + space
  end
  return lines
end

-- The panel for R on `screen` (an hs.screen frame), as { w, h, elements }.
-- Buttons wrap to a second row when they do not fit. A draft too long for 70%
-- of the screen shows its last lines, the part just spoken, after a "…".
local function layout(R, presets, screen, hover)
  local w = math.min(1000, math.floor(screen.w * 0.72))
  local pad, gap, bh = theme.space.xl, theme.space.sm, theme.size.control
  local inner = w - 2 * pad
  local busy = R.mode == "working"

  local placed, x, row = {}, 0, 0
  for _, b in ipairs(buttons(R, presets)) do
    local bw = UI.buttonWidth(b.label)
    if x > 0 and x + bw > inner then x, row = 0, row + 1 end
    placed[#placed + 1] = { b = b, x = pad + x, row = row, w = bw }
    x = x + bw + gap
  end
  local buttonsH = (row + 1) * bh + row * gap

  local size, lineH = theme.text.title, lh("title")
  local list = words(R)
  local lines = flow(list, inner, size)
  local headH = lh("footnote")
  local fixed = pad + headH + theme.space.md + theme.space.lg + buttonsH + pad
  local maxLines = math.max(1, math.floor((math.floor(screen.h * 0.7) - fixed) / lineH))
  local first = math.max(1, #lines - maxLines + 1)
  local shown = #lines - first + 1
  local h = fixed + shown * lineH

  local line, tone = status(R, hover)
  local r = theme.size.dot - 2
  local dotW = 2 * r + theme.space.sm
  local hint = busy and WAITING or (R.picking and PICKING) or HINT
  local hintW = UI.measure(hint, theme.text.caption) + 4
  local els = { UI.backdrop(w, h, { radius = "lg" }) }
  els[#els + 1] = UI.dot(pad + r, pad + headH / 2, tone, r)
  els[#els + 1] = UI.label(line, { x = pad + dotW, y = pad, w = inner - dotW - hintW - gap, h = headH },
                           { style = "footnote", color = "textSecondary", truncate = true })
  els[#els + 1] = UI.label(hint, { x = w - pad - hintW, y = pad + 1, w = hintW, h = lh("caption") },
                           { style = "caption", color = "textTertiary", align = "right" })

  local textY = pad + headH + theme.space.md
  if first > 1 then
    local ell = width("…", size)
    els[#els + 1] = UI.label("…", { x = pad - ell - 2, y = textY, w = ell + 2, h = lineH + 2 }, { style = "title" })
  end
  for li = first, #lines do
    local y = textY + (li - first) * lineH
    for _, p in ipairs(lines[li]) do
      local word, id = list[p.n], "word:" .. p.n
      local frame = { x = pad + p.x, y = y, w = p.w, h = lineH }
      for _, mark in ipairs(UI.wordMarks(frame, { hot = not busy and (hover == id or R.picking == p.n),
                                                  tone = word.unsure and "draft" or nil })) do
        els[#els + 1] = mark
      end
      local label = UI.label(word.text, { x = frame.x, y = y, w = p.w + 4, h = lineH + 2 },
                             { style = "title", truncate = true })
      if not busy then label.id, label.trackMouseEnterExit, label.trackMouseDown = id, true, true end
      els[#els + 1] = label
    end
  end

  local top = textY + shown * lineH + theme.space.lg
  local onWord = type(hover) == "string" and hover:match("^word:")
  for i, p in ipairs(placed) do
    local plate, label = UI.button(p.b.id, p.b.label,
      { x = p.x, y = top + p.row * (bh + gap), w = p.w, h = bh },
      hover == "btn:" .. p.b.id or ((hover == nil or onWord) and i == 1), p.b.disabled)
    els[#els + 1] = plate
    els[#els + 1] = label
  end
  return { w = w, h = h, elements = els }
end

-- ── The panel ──────────────────────────────────────────────────────────────
local function new(host)
  local ctx, rw = host.ctx, host.rewrite
  local P = { current = nil }
  local bindKeys

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
          if P.current ~= R or type(id) ~= "string" then return end
          local kind, what = id:match("^(%a+):(.+)$")
          if kind ~= "btn" and kind ~= "word" then return end
          if msg == "mouseEnter" or msg == "mouseExit" then
            if msg == "mouseEnter" then R.hover = id elseif R.hover == id then R.hover = nil end
            draw()
          elseif msg == "mouseDown" then
            if kind == "btn" then P.pick(what) else P.pickWord(tonumber(what)) end
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

  local function releaseKeys(R)
    for _, release in ipairs(R.keys) do release() end
    R.keys = {}
  end

  function P.close(reason)
    local R = P.current
    if not R then return end
    P.current = nil
    stopRewrite(R)
    releaseKeys(R)
    if R.release then R.release() end
    if host.onClose then pcall(host.onClose, reason) end
  end

  -- `list` is the draft's words when they carry more than the text (the ones
  -- POST /words sent); nil splits the draft on spaces when asked.
  local function setDraft(R, text, label, list)
    R.draft, R.label, R.words, R.edited, R.picking = text, label, list, false, nil
    hs.pasteboard.setContents(text)
  end

  -- Send the draft. "paste" puts it on the clipboard and presses ⌘V a moment
  -- later, once the panel's own key is up; "type" hands it to the typer.
  function P.send(how)
    local R = P.current
    if not R or R.mode == "working" or R.picking then return end
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
    if not R or R.mode == "working" then return end
    local preset = core.find(presets(), id)
    if not preset then return end
    stopRewrite(R)
    R.mode, R.message, R.hover, R.picking =
      "working", preset.label .. "…  " .. (preset.model or (rw.cfg and rw.cfg.model) or ""), nil, nil
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

  -- Also the way out of a rewrite still running: it stops, and the panel is
  -- back on the words as heard.
  function P.original()
    local R = P.current
    if not R or (R.draft == R.original and R.mode ~= "working") then return end
    stopRewrite(R)
    R.mode = "review"
    setDraft(R, R.original, nil, R.heardWords)
    draw()
  end

  function P.pick(id)
    local R = P.current
    if R and R.picking then
      local n, w = R.picking, words(R)[R.picking]
      local k = tonumber(id:match("^alt:(%d+)$"))
      if k and w.alts and w.alts[k] then return P.setWord(n, w.alts[k]) end
      if id == "edit" then return P.editWord(n) end
      if id == "delete" then return P.setWord(n, "") end
      return P.back()
    end
    if id == "paste" or id == "type" then return P.send(id) end
    if id == "original" then return P.original() end
    P.rewrite(id)
  end

  -- Word n of the draft becomes `text`, which may be several words, or goes
  -- when `text` is blank. The other words keep what the model said about them.
  function P.setWord(n, text)
    local R = P.current
    if not R or R.mode == "working" then return end
    local list = {}
    for i, w in ipairs(words(R)) do
      if i ~= n then
        list[#list + 1] = w
      else
        for part in tostring(text):gmatch("%S+") do list[#list + 1] = { text = part } end
      end
    end
    local label = R.label
    if R.mode == "failed" then R.mode = "review" end
    setDraft(R, join(list), label, list)
    R.edited, R.hover = true, nil
    draw()
  end

  -- Run fn with the panel out of the way: hidden, so a dialog is never under
  -- it, and its keys given back, so ↩ and esc reach the dialog. Both come back
  -- after if the panel is still up.
  local function aside(R, fn)
    releaseKeys(R)
    if R.canvas and R.canvas.hide then R.canvas:hide() end
    local ok, err = pcall(fn)
    if P.current == R then
      if #R.keys == 0 then bindKeys(R) end
      draw()
    end
    if not ok then error(err, 0) end
  end

  -- The edit box: Hammerspoon's text prompt. It needs the keyboard, so the
  -- window that had it gets it back afterwards. Returns the text, trimmed,
  -- or nil when cancelled.
  local function ask(title, info, text)
    local front = hs.window.frontmostWindow()
    hs.focus()
    local button, typed = hs.dialog.textPrompt(title, info, text, "Change", "Cancel")
    if front then front:focus() end
    if button ~= "Change" then return nil end
    return utils.trim(typed or "")
  end

  function P.editWord(n)
    local R = P.current
    if not R or R.mode == "working" then return end
    local w = words(R)[n]
    if not w then return end
    local info = (w.alts and #w.alts > 0) and ("Could also be " .. table.concat(w.alts, " · "))
      or "Leave it empty to delete the word."
    local typed
    aside(R, function() typed = ask("Change “" .. w.text .. "”", info, w.text) end)
    if P.current ~= R then return end
    if typed and typed ~= w.text then return P.setWord(n, typed) end
    P.back()
  end

  -- A click on word n: the buttons become its choices. A second click on it
  -- goes back.
  function P.pickWord(n)
    local R = P.current
    if not R or R.mode == "working" or not words(R)[n] then return end
    R.picking = (R.picking ~= n) and n or nil
    R.hover = nil
    draw()
  end

  function P.back()
    local R = P.current
    if not R or not R.picking then return end
    R.picking, R.hover = nil, nil
    draw()
  end

  -- The take's words as POST /words decoded them from the whole recording,
  -- for the take the panel opened on as `text`. They become the draft while
  -- the draft is still the words as heard; a draft already rewritten or
  -- edited stays, and ⌥0 brings these back. Returns true when they were taken.
  function P.heard(text, res)
    local R = P.current
    if not R or R.heardFrom ~= text or type(res) ~= "table" or type(res.words) ~= "table" then
      return false
    end
    local list = {}
    for _, w in ipairs(res.words) do
      if type(w) == "table" and type(w.text) == "string" and w.text:match("%S") then
        list[#list + 1] = { text = w.text, unsure = w.unsure == true,
                            alts = type(w.alts) == "table" and w.alts or {} }
      end
    end
    if #list == 0 then return false end
    local showing = R.draft == R.original and R.mode ~= "working" and not R.edited
    R.original, R.heardWords = join(list), list
    if showing then setDraft(R, R.original, R.label, list) end
    draw()
    return true
  end

  function P.dismiss()
    if not P.current then return end
    P.close("dismissed")
    ctx:ui():toast("Not sent · it's on the clipboard")
  end

  function bindKeys(R)
    local function bind(mods, key, fn)
      R.keys[#R.keys + 1] = select(2, ctx:hotkey(mods, key, function() if P.current == R then fn() end end))
    end
    bind({}, "return", function()
      if R.picking then return P.pick(buttons(R, presets())[1].id) end
      P.send("paste")
    end)
    bind({ "shift" }, "return", function() P.send("type") end)
    bind({}, "escape", function()
      if R.picking then return P.back() end
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
    local R = { original = text, draft = text, heardFrom = text, mode = "review", keys = {} }
    P.current = R
    hs.pasteboard.setContents(text)
    bindKeys(R)
    draw()
    if opts.cleanup then P.rewrite("cleanup", { timeout = core.CLEANUP_TIMEOUT }) end
  end

  function P.isOpen() return P.current ~= nil end

  return P
end

return setmetatable({ buttons = buttons, layout = layout, status = status, words = words, flow = flow }, {
  __call = function(_, host) return new(host) end,
})
