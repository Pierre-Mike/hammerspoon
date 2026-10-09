-- Type the clipboard as real keystrokes, one character at a time.
--
-- Cmd+V hands an app a finished block of text. Plenty of places refuse it or
-- mangle it: password fields, remote consoles and VNC/RDP sessions, terminals
-- in bracketed-paste mode, kiosk forms that listen for keydown and never read
-- the field, Citrix, and anything that strips a paste for "security". This
-- sends the clipboard the other way, as individual key events on the system
-- event tap, so the receiving app cannot tell it from a person at the keyboard.
--
-- ┌─ CONFIGURE ───────────────────────────────────────────────────────────────┐
-- │ HOTKEY    The chord that starts typing, and cancels it while it runs.     │
-- │           Three modifiers plus a letter is not a chord a hand lands on by  │
-- │           accident, which matters for a key that replays the clipboard     │
-- │           into whatever happens to be focused. Mods are any of "cmd",      │
-- │           "shift", "alt", "ctrl"; key is a name from hs.keycodes.map.      │
-- │ DELAY     Seconds between characters. 0.012 is faster than a person and    │
-- │           still slow enough for Electron and remote-desktop clients to     │
-- │           keep up. Raise it if characters arrive out of order or go        │
-- │           missing; 0.04 is about human typing speed.                      │
-- │ NEWLINE   "return" types a real Return. Use "shift-return" in Slack or     │
-- │           Teams, where a bare Return sends the message instead of break-   │
-- │           ing the line.                                                    │
-- │ MAXCHARS  Refuse anything longer. A 2 MB clipboard typed at DELAY would    │
-- │           hold the keyboard hostage for hours.                            │
-- └───────────────────────────────────────────────────────────────────────────┘
local HOTKEY   = { mods = { "cmd", "shift", "alt" }, key = "t" }
local DELAY    = 0.012
local NEWLINE  = "return"
local MAXCHARS = 20000

local context = require("lib.context")

local M = { delay = DELAY, newline = NEWLINE, maxChars = MAXCHARS }

-- ── Pure core ───────────────────────────────────────────────────────────────
-- No hs.* below this line until the next banner, so the hard parts (splitting
-- UTF-8, deciding what counts as one keypress) are testable on their own.

-- Decode the UTF-8 sequence starting at byte i. Returns the codepoint and how
-- many bytes it took. A malformed byte comes back as its own one-byte
-- codepoint rather than raising: one bad byte in a clipboard should not stop
-- the other four thousand from being typed.
local function decode(s, i)
  local b = s:byte(i)
  if not b then return nil, 0 end
  if b < 0xC0 then return b, 1 end                  -- ASCII, or a stray continuation byte
  local n = (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4
  local cp = b - (n == 2 and 0xC0 or n == 3 and 0xE0 or 0xF0)
  for k = 1, n - 1 do
    local c = s:byte(i + k)
    if not c or c < 0x80 or c > 0xBF then return b, 1 end   -- truncated; take the lead byte alone
    cp = cp * 64 + (c - 0x80)
  end
  return cp, n
end

-- Codepoints that modify the one before them rather than standing alone. Typed
-- on their own they land as a stray accent or a lone skin tone, so they ride
-- along with the character they belong to.
local function joins(cp)
  return (cp >= 0x0300  and cp <= 0x036F)    -- combining diacritical marks
      or (cp >= 0x1AB0  and cp <= 0x1AFF)    -- combining diacriticals extended
      or (cp >= 0x1DC0  and cp <= 0x1DFF)    -- combining diacriticals supplement
      or (cp >= 0x20D0  and cp <= 0x20FF)    -- combining marks for symbols, incl. keycap U+20E3
      or (cp >= 0xFE00  and cp <= 0xFE0F)    -- variation selectors
      or (cp >= 0xFE20  and cp <= 0xFE2F)    -- combining half marks
      or (cp >= 0x1F3FB and cp <= 0x1F3FF)   -- emoji skin tone modifiers
      or (cp >= 0xE0100 and cp <= 0xE01EF)   -- variation selectors supplement
      or cp == 0x200D                        -- zero width joiner
end

local function regional(cp) return cp >= 0x1F1E6 and cp <= 0x1F1FF end

-- Split text into the units a person would call "one character": a base
-- codepoint plus whatever attaches to it. é written as e + U+0301 is one
-- keypress here, a flag is its two regional indicators, and 👩‍💻 is the whole
-- joined sequence rather than a woman followed by a laptop.
function M.clusters(text)
  local out, i, n = {}, 1, #(text or "")
  local afterZWJ, openPair = false, false
  while i <= n do
    local cp, len = decode(text, i)
    if not cp then break end
    local merge = #out > 0 and (afterZWJ or joins(cp) or (openPair and regional(cp)))
    if merge then
      out[#out] = out[#out] .. text:sub(i, i + len - 1)
    else
      out[#out + 1] = text:sub(i, i + len - 1)
    end
    afterZWJ = (cp == 0x200D)
    -- A flag is exactly two regional indicators, so the second closes the pair
    -- instead of opening another and swallowing the next flag's first half.
    openPair = regional(cp) and not merge
    i = i + len
  end
  return out
end

-- The characters this layout can produce by pressing one key, Shift at most.
--
-- `base` has hs.keycodes.map's shape: a character or key name to its keycode.
-- `shifted(code)` answers what that key gives with Shift held, or nil when the
-- caller has no way to ask the layout.
--
-- Pure, so a spec hands it a fake layout and asserts on the table instead of on
-- whatever keyboard the machine running the test happens to have.
function M.buildKeymap(base, shifted)
  local map = {}
  local function put(ch, code, mods)
    -- One codepoint only. "space" and "f13" are key names rather than
    -- characters, and a dead key the layout reports as "" has nothing to type.
    if type(ch) ~= "string" then return end
    local cp, len = decode(ch, 1)
    if not cp or len ~= #ch then return end
    if map[ch] == nil then map[ch] = { key = code, mods = mods } end
  end
  for name, code in pairs(base or {}) do
    if type(name) == "string" and type(code) == "number" then
      put(name, code, {})
      -- Shift plus a letter is that letter's capital on every Latin layout,
      -- which is worth having even where the layout cannot be probed.
      if name:match("^[a-z]$") then put(name:upper(), code, { "shift" }) end
      if shifted then put(shifted(code), code, { "shift" }) end
    end
  end
  return map
end

-- Turn text into the steps to post. Anything the keyboard can actually type
-- becomes a real key press rather than synthesised text, because the apps this
-- module exists for read the keycode and ignore the character attached to the
-- event. A unicode "\n" leaves a literal control character in a terminal and
-- does nothing at all in a single-line field, a unicode tab will not move focus
-- between form fields, and a remote desktop in scancode mode reads the keycode
-- alone. Only a character the layout has no key for falls through to
-- synthesised text, where there is nothing better to send.
function M.plan(text, newline, keymap)
  -- CRLF and a bare CR both mean one line break. Typed literally they give a
  -- blank line in half the apps and a stray ^M in the other half.
  text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local steps = {}
  for _, c in ipairs(M.clusters(text)) do
    if c == "\n" then
      steps[#steps + 1] = { kind = "key", key = "return",
                            mods = (newline == "shift-return") and { "shift" } or {} }
    elseif c == "\t" then
      steps[#steps + 1] = { kind = "key", key = "tab", mods = {} }
    elseif c == " " then
      steps[#steps + 1] = { kind = "key", key = "space", mods = {} }
    elseif keymap and keymap[c] then
      -- A key this layout actually has. Pressing it is what a person would do,
      -- and it is the only form a remote desktop in scancode mode can read.
      steps[#steps + 1] = { kind = "key", key = keymap[c].key, mods = keymap[c].mods }
    else
      steps[#steps + 1] = { kind = "text", text = c }
    end
  end
  return steps
end

-- ── The live layout ─────────────────────────────────────────────────────────
-- hs.* again from here. This is the part that asks the keyboard what it can do.

-- What the key at `code` gives with Shift held, on the layout the user is
-- really typing on. Building the event and reading its character back is free:
-- the event is never posted.
local function shiftedChar(code)
  local ok, ch = pcall(function()
    return hs.eventtap.event.newKeyEvent({ "shift" }, code, true):getCharacters(false)
  end)
  if ok and type(ch) == "string" and ch ~= "" then return ch end
  return nil
end

-- Shifted punctuation and digits on a US keyboard. Used only where the layout
-- refuses to be probed, so that "!" and "?" still go out as key presses instead
-- of down the path a remote desktop mistranslates. Letters are already covered
-- by the capitalisation rule in buildKeymap and are not repeated here.
local US_SHIFT = {
  ["1"] = "!",  ["2"] = "@",  ["3"] = "#",  ["4"] = "$",  ["5"] = "%",
  ["6"] = "^",  ["7"] = "&",  ["8"] = "*",  ["9"] = "(",  ["0"] = ")",
  ["-"] = "_",  ["="] = "+",  ["["] = "{",  ["]"] = "}",  ["\\"] = "|",
  [";"] = ":",  ["'"] = '"',  [","] = "<",  ["."] = ">",  ["/"] = "?",
  ["`"] = "~",
}

-- Rebuilt at the start of every run rather than cached for the session, so
-- switching input source between two runs cannot leave the typer pressing the
-- keys of a layout the user has already left.
function M.layout()
  local base = hs.keycodes.map or {}
  -- One probe decides whether probing works at all: a build of Hammerspoon that
  -- will not hand back a character for "a" will not hand one back for anything.
  local probes = base.a and shiftedChar(base.a) ~= nil
  local map = M.buildKeymap(base, probes and shiftedChar or nil)
  if not probes then
    for ch, sh in pairs(US_SHIFT) do
      local code = base[ch]
      if code and map[sh] == nil then map[sh] = { key = code, mods = { "shift" } } end
    end
  end
  return map
end

-- ── Posting ─────────────────────────────────────────────────────────────────

function M.post(step)
  if step.kind == "key" then
    -- 0 microseconds between down and up: the pacing is the timer's job, and a
    -- blocking sleep here would freeze every other Hammerspoon callback.
    hs.eventtap.keyStroke(step.mods, step.key, 0)
    return
  end
  -- A key event carrying a unicode string is how a character with no key on
  -- this layout still arrives as a keypress. The receiving app sees a keydown
  -- and a keyup with that character attached, which is exactly what it would
  -- see from a dead-key sequence or an input method.
  --
  -- Flags are cleared on every event. Without that, a modifier still physically
  -- held turns the next character into a shortcut, and the first thing typed
  -- after the trigger chord would be Cmd+whatever.
  for _, down in ipairs({ true, false }) do
    local e = hs.eventtap.event.newKeyEvent(0, down)
    e:setFlags({})
    e:setUnicodeString(step.text)
    e:post()
  end
end

-- ── Running ─────────────────────────────────────────────────────────────────

local ctx = context.new("keystroke_typer")
local esc                                   -- cancel key, live only while typing
local run = { active = false, steps = nil, i = 0, release = nil }

local function stop(message)
  if run.release then run.release(); run.release = nil end
  run.active, run.steps, run.i = false, nil, 0
  if esc then esc:disable() end
  if message then hs.alert.show(message, 1.2) end
end

function M.cancel()
  if run.active then stop("Typing cancelled") end
end

local function tick()
  local step = run.steps and run.steps[run.i + 1]
  if not step then return stop(nil) end
  run.i = run.i + 1
  local ok, err = pcall(M.post, step)
  if not ok then stop("Keystroke typer: " .. tostring(err)) end
end

local function holding()
  local m = hs.eventtap.checkKeyboardModifiers()
  -- Caps lock and fn are left out: caps lock is a latch the user may simply
  -- have on, and fn is held down by the dictation plugin's own hotkey.
  return m.cmd or m.alt or m.ctrl or m.shift or false
end

-- The trigger chord is still held when the hotkey fires. Typing into that would
-- send Cmd+Shift+Alt+<every character>, so the first character waits for the
-- user's hand to come off the keys. The deadline is there so a stuck modifier
-- means a late start rather than nothing happening at all.
local function whenHandsAreOff(fn, deadline)
  deadline = deadline or (hs.timer.secondsSinceEpoch() + 3)
  if not holding() or hs.timer.secondsSinceEpoch() >= deadline then return fn() end
  ctx:after(0.02, function() whenHandsAreOff(fn, deadline) end)
end

-- Type any text. Exposed so other plugins and `hs -c` can reach it:
--   hs -c 'require("apps.keystroke_typer").type("hello")'
--
-- opts.replace  A run already going is dropped and the new text typed instead.
--               The hotkey is a toggle — pressing it twice stops typing — and
--               without this a caller handing over fresh text would hit that
--               toggle and get silence. apps/dictation passes it: the take the
--               user just spoke is the one they want at the cursor.
-- opts.quiet    No "Typing N characters" alert. For a caller that already shows
--               the user what is happening; apps/dictation has its own HUD, and
--               an alert per utterance is noise.
function M.type(text, opts)
  opts = opts or {}
  if run.active then
    if not opts.replace then return M.cancel() end
    stop(nil)
  end
  if type(text) ~= "string" or text == "" then
    return hs.alert.show("Nothing to type", 1.2)
  end

  local steps = M.plan(text, M.newline, M.layout())
  if #steps > M.maxChars then
    return hs.alert.show(string.format("Too long: %d characters (limit %d)",
      #steps, M.maxChars), 2)
  end

  run.active, run.steps, run.i = true, steps, 0
  if esc then esc:enable() end
  if not opts.quiet then
    hs.alert.show(string.format("Typing %d characters — esc to cancel", #steps), 1.2)
  end

  whenHandsAreOff(function()
    if not run.active then return end         -- cancelled during the wait
    local _, release = ctx:timer(M.delay, tick)
    run.release = release
  end)
end

function M.typeClipboard()
  if run.active then return M.cancel() end
  local text = hs.pasteboard.getContents()
  if type(text) ~= "string" or text == "" then
    return hs.alert.show("Clipboard holds no text", 1.2)
  end
  M.type(text)
end

-- Diagnostics: hs -c 'return hs.inspect(require("apps.keystroke_typer").status())'
function M.status()
  return {
    hotkey   = table.concat(HOTKEY.mods, "+") .. "+" .. HOTKEY.key,
    typing   = run.active,
    progress = run.steps and string.format("%d/%d", run.i, #run.steps) or "idle",
    delay    = M.delay,
    newline  = M.newline,
    maxChars = M.maxChars,
  }
end

-- ── Lifecycle ───────────────────────────────────────────────────────────────

function M.start()
  ctx:hotkey(HOTKEY.mods, HOTKEY.key, M.typeClipboard)
  -- Bound once and kept disabled, because a global Escape hotkey that is always
  -- live would swallow Escape from every other app. It is only armed for as
  -- long as a run lasts.
  esc = ctx:hotkey({}, "escape", M.cancel)
  esc:disable()
end

-- Everything this plugin owns is held by the context, so switching it off in
-- the Plugins tile genuinely releases the hotkeys instead of leaving them to
-- eat Cmd+Shift+Alt+T on behalf of a module that is gone.
function M.dispose()
  stop(nil)
  ctx:dispose()
  esc = nil
end

-- Guards a partial reload, where re-requiring this file would bind a second
-- copy of the same hotkey on top of the first.
local PREV = _G.__keystroke_typer
if PREV and PREV.dispose then pcall(PREV.dispose) end
_G.__keystroke_typer = M

M.start()

return M
