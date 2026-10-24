-- Text actions: rewrite a piece of text with Claude (simplify, improve, make it
-- formal, …) and put the result where the caller wants it.
--
-- A service first. Other plugins find it in the registry and call it:
--   ta.actions()                         the presets, { id, label }, in bar order
--   ta.run(text, id, done, opts)         done(rewritten | nil, why); returns cancel()
--   ta.showBar(text, opts)               the action bar; see showBar below
--   ta.hideBar()                         close it (a new dictation take does)
--   ta.runOnSelection(id)                rewrite the selection in place, no bar
-- apps/dictation is the first caller: the bar after each take, and its
-- "Clean up" switch runs the cleanup preset.
--
-- On its own: ⌘⌥⇧R opens the bar on the current selection (or the clipboard
-- when nothing is selected), and the Text actions tile runs any preset on the
-- clipboard.
--
-- Rewrites run `claude -p`, one short process per call, with the text on stdin
-- and no tools (lib/text_actions builds the command). That sends the text to
-- Anthropic, which is why dictation's switch says so.
--
-- Presets are the built-ins in lib/text_actions plus ~/.hammerspoon/
-- text_actions.json, which is git-ignored and re-read whenever it changes. The
-- format is in text_actions.example.json beside it.
--
-- Everything is owned by the context, so switching the plugin off in the hub
-- takes back the hotkeys, the bar, any claude process still running and the tile.

local core      = require("lib.text_actions")
local utils     = require("lib.utils")
local clipboard = require("lib.clipboard")
local plugins   = require("lib.plugins")

local ctx = require("lib.context").new("Text actions")

local LOG      = "/tmp/hs-text-actions.log"
local DIR      = hs.configdir or ((os.getenv("HOME") or "") .. "/.hammerspoon")
local PRESETS  = DIR .. "/text_actions.json"
local EXAMPLE  = DIR .. "/text_actions.example.json"
local HOTKEY   = { mods = { "cmd", "alt", "shift" }, key = "r" }

local M = {
  cfg  = nil,     -- lib/text_actions config: presets, model, claude, warnings
  last = nil,     -- one line about the last rewrite, for the tile
  bar  = nil,     -- the open bar's state, or nil
  BAR_SECONDS  = 6,     -- how long an untouched bar stays up
  DONE_SECONDS = 1.5,   -- how long the result line stays before the bar closes
}

local function logf(fmt, ...) utils.logf(LOG, fmt, ...) end

-- ── Presets ────────────────────────────────────────────────────────────────
function M.reload()
  local decoded
  local raw = utils.readFile(PRESETS)
  if raw and raw:match("%S") then
    local ok, v = pcall(hs.json.decode, raw)
    if ok then decoded = v else decoded = "unreadable" end
  end
  M.cfg = core.config(decoded)
  for _, w in ipairs(M.cfg.warnings) do logf("[presets] %s", w) end
  logf("[presets] %d presets, model %s", #M.cfg.presets, M.cfg.model)
end

function M.actions()
  local out = {}
  for _, p in ipairs(M.cfg.presets) do out[#out + 1] = { id = p.id, label = p.label } end
  return out
end

-- ── Running a rewrite ──────────────────────────────────────────────────────
-- Calls done exactly once: with the rewritten text, or with nil and a reason —
-- unknown preset, claude missing, an error reply, or no answer within
-- opts.timeout seconds. A reply that lands after that is ignored. Returns a
-- function that cancels the call (done is then not called at all).
function M.run(text, id, done, opts)
  opts = opts or {}
  local preset = core.find(M.cfg.presets, id)
  local finished, task, release, stopTimer = false, nil, nil, nil

  local input, dropInput
  local function cleanup()
    if stopTimer then stopTimer(); stopTimer = nil end
    if release then release(); release = nil end
    if dropInput then dropInput(); dropInput = nil end
  end

  local function finish(result, why)
    if finished then return end
    finished = true
    cleanup()
    if result then
      M.last = string.format("%s · %d → %d chars", preset.label, #text, #result)
    else
      M.last = string.format("%s failed: %s", preset and preset.label or tostring(id), tostring(why))
      logf("[run] %s: %s", tostring(id), tostring(why))
    end
    done(result, why)
  end

  if not preset then finish(nil, "unknown action " .. tostring(id)); return function() end end
  if type(text) ~= "string" or not text:match("%S") then
    finish(nil, "nothing to rewrite"); return function() end
  end
  if not (hs.fs.attributes(M.cfg.claude)) then
    finish(nil, "claude not found at " .. M.cfg.claude); return function() end
  end

  -- The text goes in on stdin, never on the command line. hs.task:setInput
  -- loses the race with claude, which decides there is no stdin before the data
  -- arrives, so the text is written to a private temp file (os.tmpname is
  -- mkstemp: mode 0600) and /bin/sh redirects it.
  input = os.tmpname()
  -- An effect, so a plugin switched off mid-rewrite still deletes the text.
  dropInput = ctx:effect(function() os.remove(input) end)
  local f = io.open(input, "w")
  if not f then finish(nil, "cannot write a temp file"); return function() end end
  f:write(text); f:close()

  local model = preset.model or M.cfg.model
  local started = hs.timer.secondsSinceEpoch()
  task, release = ctx:task("/bin/sh", function(code, out, err)
    -- The process is over: hand its effect back so the context does not hold a
    -- handle per rewrite for the rest of the session.
    if release then release(); release = nil end
    if finished then return end
    local ok, decoded = pcall(hs.json.decode, out or "")
    local result, why = core.parse(ok and decoded or nil, text, preset)
    if not result and not (ok and type(decoded) == "table") then
      why = string.format("claude exited %s: %s", tostring(code),
                          utils.truncate(utils.trim(err or out or "") or "", 160))
    end
    if result then
      local cost = ok and type(decoded) == "table" and tonumber(decoded.total_cost_usd)
      logf("[run] %s %s: %d → %d chars in %.1fs%s", preset.id, model, #text, #result,
           hs.timer.secondsSinceEpoch() - started, cost and string.format(" ($%.4f)", cost) or "")
    end
    finish(result, why)
  end, core.shellArgv(M.cfg.claude, input, core.argv(preset, M.cfg)))
  -- Started in /tmp: claude looks around its working directory, and Hammerspoon's
  -- is wherever it was launched from.
  if task.setWorkingDirectory then task:setWorkingDirectory("/tmp") end
  task:start()

  local _, stop = ctx:after(opts.timeout or core.ACTION_TIMEOUT, function()
    stopTimer = nil
    finish(nil, "no reply in " .. tostring(opts.timeout or core.ACTION_TIMEOUT) .. "s")
  end)
  stopTimer = stop

  return function()
    if finished then return end
    finished = true
    cleanup()
  end
end

-- ── Delivering a result ────────────────────────────────────────────────────
local function typer()
  -- Asked of the registry, like apps/dictation does: a plain require would
  -- bring back a typer the user switched off in the hub.
  local t = plugins.loaded["keystroke_typer"]
  if type(t) == "table" and type(t.type) == "function" then return t end
  return nil
end

-- `how` is "clipboard", "type", "replace-selection" or a function(text).
-- Returns the line the bar shows afterwards.
local function deliver(text, how)
  if type(how) == "function" then how(text); return "Done ✓" end
  hs.pasteboard.setContents(text)
  if how == "type" then
    local t = typer()
    if t then t.type(text, { replace = true, quiet = true }); return "Typing ✓" end
    return "Copied ✓  ⌘V to paste"
  end
  if how == "replace-selection" then
    -- The bar never takes focus, so the selection the text came from is still
    -- selected in the app the user is in. The rewrite stays on the clipboard,
    -- so ⌘V by hand still works where a synthetic paste is refused.
    ctx:after(0.05, function() hs.eventtap.keyStroke({ "cmd" }, "v", 0) end)
    return "Replaced ✓"
  end
  return "Copied ✓  ⌘V to paste"
end

-- ── The bar ────────────────────────────────────────────────────────────────
-- Drawn by lib/ui's bar, which is a canvas rather than a webview for this
-- plugin's sake: a click on it must not make Hammerspoon the frontmost app,
-- or "replace the selection" pastes into Hammerspoon and typing lands nowhere.

-- The buttons for this bar: the "keep" item first when the caller offered one.
local function barButtons(b)
  local out = {}
  if b.opts.keep then out[1] = { id = "__keep", label = b.opts.keep, key = 0 } end
  for _, it in ipairs(core.barItems(M.cfg.presets)) do out[#out + 1] = it end
  out[#out + 1] = { id = "__close", label = "✕" }
  return out
end

local TONE = { working = "working", failed = "danger", done = "success" }

local function render()
  local b = M.bar
  if not b then return end
  if b.mode == "choose" then
    local buttons = {}
    for _, it in ipairs(barButtons(b)) do
      buttons[#buttons + 1] = { id = it.id,
        label = it.key and string.format("%d %s", it.key, it.label) or it.label }
    end
    b.view:show({ title = "Rewrite “" .. utils.truncate((b.text:gsub("%s+", " ")), 70) .. "”",
                  hint = "⌥ number · esc", buttons = buttons })
  else
    b.view:show({ message = b.message, tone = TONE[b.mode] })
  end
end

local function stopCountdown()
  local b = M.bar
  if b and b.countdown then b.countdown(); b.countdown = nil end
end

local function close(reason)
  local b = M.bar
  if not b then return end
  M.bar = nil
  stopCountdown()
  if b.cancel then b.cancel() end
  for _, r in ipairs(b.keys) do r() end
  b.view:close()
  if b.opts.onClose then pcall(b.opts.onClose, reason) end
end

-- A bar holding text that is not anywhere else yet (opts.fallback) must not
-- drop it: timing out types it as it was, and any other way out leaves it on
-- the clipboard.
local function closeHolding(reason)
  local b = M.bar
  if b and b.opts.fallback and b.mode == "choose" then
    if reason == "timeout" then
      deliver(b.text, b.opts.deliver)
    else
      hs.pasteboard.setContents(b.text)
    end
    if b.opts.onResult then pcall(b.opts.onResult, b.text, nil) end
  end
  close(reason)
end

local function countdown(seconds)
  stopCountdown()
  local b = M.bar
  if not b then return end
  local _, stop = ctx:after(seconds, function()
    if M.bar == b then b.countdown = nil; closeHolding("timeout") end
  end)
  b.countdown = stop
end

local function finishWith(message, failed)
  local b = M.bar
  if not b then return end
  b.mode, b.message = failed and "failed" or "done", message
  render()
  countdown(failed and 2.6 or M.DONE_SECONDS)
end

local function choose(id)
  local b = M.bar
  if not b or b.mode ~= "choose" then return end
  if id == "__close" then return closeHolding("dismissed") end
  stopCountdown()
  if id == "__keep" then
    local line = deliver(b.text, b.opts.deliver)
    if b.opts.onResult then pcall(b.opts.onResult, b.text, nil) end
    return finishWith(line)
  end
  local preset = core.find(M.cfg.presets, id)
  if not preset then return end
  b.mode, b.message = "working", preset.label .. "…  " .. (preset.model or M.cfg.model)
  render()
  b.cancel = M.run(b.text, id, function(result, why)
    b.cancel = nil
    if M.bar ~= b then return end
    if not result then
      if b.opts.fallback then
        deliver(b.text, b.opts.deliver)
        if b.opts.onResult then pcall(b.opts.onResult, b.text, nil) end
        return finishWith("Kept the original: " .. utils.truncate(tostring(why), 60), true)
      end
      return finishWith("Couldn't rewrite: " .. utils.truncate(tostring(why), 70), true)
    end
    local line = deliver(result, b.opts.deliver)
    if b.opts.onResult then pcall(b.opts.onResult, result, id) end
    finishWith(line)
  end, { timeout = core.ACTION_TIMEOUT })
end

-- Open the bar on `text`.
--   opts.deliver   "clipboard" (default), "type", "replace-selection", or a
--                  function(text) for a caller that places the result itself
--   opts.onResult  function(text, id): what was delivered; id is nil when it
--                  was the original text
--   opts.keep      label for a button 0 that delivers the text unchanged
--   opts.fallback  the text is nowhere else yet: an untouched bar delivers it
--                  as it is, and dismissing it leaves it on the clipboard
--   opts.onClose   function(reason)
function M.showBar(text, opts)
  if type(text) ~= "string" or not text:match("%S") then return end
  closeHolding("replaced")
  local b = { text = text, opts = opts or {}, mode = "choose", keys = {} }
  b.opts.deliver = b.opts.deliver or "clipboard"
  b.view = ctx:ui():bar("bar", {
    pick = function(id) if M.bar == b then choose(id) end end,
    -- Hovering means the user is reading the bar: hold the countdown.
    hover = function(inside)
      if M.bar ~= b or b.mode ~= "choose" then return end
      if inside then stopCountdown() else countdown(M.BAR_SECONDS) end
    end,
  })
  M.bar = b
  for _, it in ipairs(barButtons(b)) do
    if it.key then
      local _, r = ctx:hotkey({ "alt" }, tostring(it.key), function() choose(it.id) end)
      b.keys[#b.keys + 1] = r
    end
  end
  -- Escape shadows keystroke_typer's own while the bar is up, so it does both
  -- jobs: stop typing that is still going, and close the bar.
  local _, esc = ctx:hotkey({}, "escape", function()
    local t = typer()
    if t and t.pending and t.pending() > 0 and t.cancel then t.cancel() end
    closeHolding("escape")
  end)
  b.keys[#b.keys + 1] = esc
  render()
  countdown(M.BAR_SECONDS)
end

function M.hideBar(reason) closeHolding(reason or "hidden") end

local function toast(message, seconds, tone)
  ctx:ui():toast(message, { seconds = seconds, tone = tone })
end

-- ── The selection ──────────────────────────────────────────────────────────
-- macOS has no "give me the selected text" API, so this borrows the clipboard
-- the way apps/tts does for Fn+S: press ⌘C, wait for the change count to move,
-- read it, put the user's clipboard back. cb(text) — nil when nothing was
-- selected.
local SEL_POLL, SEL_TIMEOUT = 0.03, 0.45
function M.grabSelection(cb)
  if M.grabbing then return end
  M.grabbing = true
  local before = hs.pasteboard.changeCount()
  local restore = clipboard.snapshot(hs.pasteboard)
  ctx:after(SEL_POLL, function()
    hs.eventtap.keyStroke({ "cmd" }, "c", 0)
    local waited, stop = 0, nil
    local _, release = ctx:timer(SEL_POLL, function()
      waited = waited + SEL_POLL
      local landed = hs.pasteboard.changeCount() ~= before
      if not landed and waited < SEL_TIMEOUT then return end
      stop()
      M.grabbing = false
      local text = landed and hs.pasteboard.getContents() or nil
      restore()
      if type(text) ~= "string" or not text:match("%S") then text = nil end
      cb(text)
    end)
    stop = release
  end)
end

local function clipboardText()
  local t = hs.pasteboard.getContents()
  if type(t) == "string" and t:match("%S") then return t end
  return nil
end

-- ⌘⌥⇧R: the bar on the selection, replacing it; or on the clipboard when
-- nothing is selected.
function M.barOnSelection()
  M.grabSelection(function(sel)
    if sel then return M.showBar(sel, { deliver = "replace-selection" }) end
    local clip = clipboardText()
    if clip then return M.showBar(clip, { deliver = "clipboard" }) end
    toast("Nothing selected and no text on the clipboard", 1.4)
  end)
end

-- Rewrite the selection in place with one preset, no bar. For a direct
-- shortcut, such as a future "simplify this code" key.
function M.runOnSelection(id)
  M.grabSelection(function(sel)
    if not sel then return toast("Nothing selected", 1.2) end
    toast((core.find(M.cfg.presets, id) or { label = id }).label .. "…", 1.0, "working")
    M.run(sel, id, function(result, why)
      if not result then return toast("Couldn't rewrite: " .. tostring(why), 2.0, "danger") end
      deliver(result, "replace-selection")
    end)
  end)
end

function M.runOnClipboard(id)
  local text = clipboardText()
  if not text then return toast("No text on the clipboard", 1.2) end
  toast((core.find(M.cfg.presets, id) or { label = id }).label .. "…", 1.0, "working")
  M.run(text, id, function(result, why)
    if not result then return toast("Couldn't rewrite: " .. tostring(why), 2.0, "danger") end
    hs.pasteboard.setContents(result)
    toast("Copied: " .. utils.truncate((result:gsub("%s+", " ")), 60), 1.6, "success")
  end)
end

-- ── Tile ───────────────────────────────────────────────────────────────────
function M.editPresets()
  if not hs.fs.attributes(PRESETS) then
    local example = utils.readFile(EXAMPLE) or "[]\n"
    local f = io.open(PRESETS, "w")
    if f then f:write(example); f:close() end
  end
  hs.execute("open -t " .. string.format("%q", PRESETS))
end

local function buildMenu()
  local items = {
    { title = "Model: " .. M.cfg.model .. " via claude -p", disabled = true },
  }
  if M.last then items[#items + 1] = { title = "Last: " .. M.last, disabled = true } end
  if #M.cfg.warnings > 0 then
    items[#items + 1] = { title = string.format("⚠︎ %d preset problems (see log)", #M.cfg.warnings),
                          disabled = true }
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Rewrite the selection…  ⌘⌥⇧R", fn = function() M.barOnSelection() end }
  local sub = {}
  for _, p in ipairs(M.cfg.presets) do
    sub[#sub + 1] = { title = p.label, fn = function() M.runOnClipboard(p.id) end }
  end
  items[#items + 1] = { title = "Rewrite the clipboard", menu = sub }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Edit presets…", fn = function() M.editPresets() end }
  items[#items + 1] = { title = "Reload presets", fn = function() M.reload() end }
  items[#items + 1] = { title = "Open log", fn = function() hs.execute("open " .. LOG) end }
  return items
end

-- Diagnostics: hs -c 'return hs.inspect(require("lib.plugins").loaded.text_actions.status())'
function M.status()
  return { model = M.cfg.model, claude = M.cfg.claude, presets = #M.cfg.presets,
           bar = M.bar and M.bar.mode or "closed", last = M.last }
end

-- ── init ───────────────────────────────────────────────────────────────────
M.reload()
M.menu = ctx:tile("Text actions")
M.menu:setTitle("✎")
M.menu:setMenu(buildMenu)
ctx:hotkey(HOTKEY.mods, HOTKEY.key, function() M.barOnSelection() end)
-- The config directory is watched rather than the file, so creating the file
-- for the first time is seen too.
ctx:watcher("path", DIR, function(paths)
  for _, p in ipairs(paths or {}) do
    if p:sub(-#"/text_actions.json") == "/text_actions.json" then return M.reload() end
  end
end)

function M.dispose()
  close("disposed")
  ctx:dispose()
end

return M
