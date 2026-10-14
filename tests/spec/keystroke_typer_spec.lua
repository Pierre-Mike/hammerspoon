_G.hs = require("hs")

local typer = require("apps.keystroke_typer")

-- Replay what the module posted as the text an app would end up holding, so a
-- failure reads as "you typed the wrong thing" rather than as a diff of event
-- records. Only keydowns count: every keypress goes out as a down and an up,
-- and counting both would double everything.
--
-- A key press resolves through the layout, from its keycode and its modifiers,
-- and never from a character attached to the event. That is what a remote
-- desktop in scancode mode does. Reading it any other way is how a typer that
-- sends keycode 0 for every character passes its own tests while putting a row
-- of "A" into a Windows session.
local KEYTEXT = { ["return"] = "\n", tab = "\t", space = " " }

local function pressed(e)
  if KEYTEXT[e.key] then return KEYTEXT[e.key] end
  local shift = false
  for _, m in ipairs(e.mods or {}) do if m == "shift" then shift = true end end
  return hs.keycodes.charFor(e.key, shift) or ("<" .. tostring(e.key) .. ">")
end

local function typed()
  local out = {}
  for _, e in ipairs(hs.eventtap._sent) do
    if not e.down then
      -- a keyup: the same character again
    elseif e.kind == "key" then
      out[#out + 1] = pressed(e)
    else
      out[#out + 1] = e.text
    end
  end
  return table.concat(out)
end

-- Keydowns only, which is one per keypress.
local function downs()
  local n = 0
  for _, e in ipairs(hs.eventtap._sent) do if e.down then n = n + 1 end end
  return n
end

-- One tick per step, plus one more for the loop to find nothing left and stop.
local function drain()
  local timer = hs.timer._every[#hs.timer._every]
  for _ = 1, 4000 do
    timer.fn()
    if not typer.status().typing then return end
  end
  error("the typing loop never finished")
end

local function run(text)
  hs.eventtap._sent = {}
  hs.pasteboard.setContents(nil, text)
  typer.typeClipboard()
  drain()
  return typed()
end

describe("keystroke_typer.clusters", function()
  it("splits ASCII one character per keypress", function()
    assert.same({ "h", "i", "!" }, typer.clusters("hi!"))
  end)

  it("keeps a multi-byte character whole", function()
    assert.same({ "é", "字", "😀" }, typer.clusters("é字😀"))
  end)

  it("carries a combining accent with the letter it modifies", function()
    -- "e" followed by U+0301. Typed apart, the accent lands on its own.
    assert.same({ "e\u{0301}" }, typer.clusters("e\u{0301}"))
  end)

  it("keeps a skin tone with its emoji", function()
    assert.same({ "👍\u{1F3FD}" }, typer.clusters("👍\u{1F3FD}"))
  end)

  it("keeps a zero-width-joiner sequence whole", function()
    assert.same({ "👩\u{200D}💻" }, typer.clusters("👩\u{200D}💻"))
  end)

  it("pairs regional indicators into one flag each", function()
    assert.same({ "🇫🇷", "🇺🇸" }, typer.clusters("🇫🇷🇺🇸"))
  end)

  it("hands back a malformed byte instead of raising", function()
    assert.same({ "a", "\xFF", "b" }, typer.clusters("a\xFFb"))
  end)

  it("is empty for empty input", function()
    assert.same({}, typer.clusters(""))
    assert.same({}, typer.clusters(nil))
  end)
end)

describe("keystroke_typer.plan", function()
  it("sends newline, tab and space as real key presses", function()
    assert.same({
      { kind = "key", key = "return", mods = {} },
      { kind = "key", key = "tab",    mods = {} },
      { kind = "key", key = "space",  mods = {} },
    }, typer.plan("\n\t "))
  end)

  it("collapses CRLF and a bare CR to one Return", function()
    assert.equals(3, #typer.plan("a\r\nb"))       -- "a", Return, "b"
    assert.equals(1, #typer.plan("\r\n"))
    assert.same({ kind = "key", key = "return", mods = {} }, typer.plan("\r\n")[1])
    assert.same({ kind = "key", key = "return", mods = {} }, typer.plan("\r")[1])
  end)

  it("shifts Return when asked, for apps where bare Return sends", function()
    assert.same({ "shift" }, typer.plan("\n", "shift-return")[1].mods)
  end)

  it("sends everything else as text", function()
    assert.same({ kind = "text", text = "é" }, typer.plan("é")[1])
  end)
end)

describe("keystroke_typer typing", function()
  before_each(function()
    typer.cancel()
    hs.eventtap._sent = {}
    hs.timer._every = {}
  end)

  it("reproduces the clipboard exactly", function()
    local text = "Hello, world!\n\tTabbed — naïve 😀 ok\nlast"
    assert.equals(text, run(text))
  end)

  it("presses a real key for every character the keyboard has", function()
    run("abc")
    assert.equals(3, downs())
    for _, e in ipairs(hs.eventtap._sent) do
      assert.equals("key", e.kind)
    end
  end)

  -- A key event is posted to the HID tap, where whatever the user is holding is
  -- in play. Live dictation types for a whole take with Fn held down, so every
  -- event has to say what it is and nothing else.
  it("posts a keydown and a keyup for a real key too", function()
    run("a")
    assert.equals(2, #hs.eventtap._sent)
    assert.is_true(hs.eventtap._sent[1].down)
    assert.is_false(hs.eventtap._sent[2].down)
  end)

  it("sets the flags a key needs and no others", function()
    run("aA\t")
    for _, e in ipairs(hs.eventtap._sent) do
      assert.is_table(e.flags)
    end
    -- "a" and Tab carry nothing; "A" carries Shift and only Shift.
    assert.same({}, hs.eventtap._sent[1].flags)
    assert.same({ shift = true }, hs.eventtap._sent[3].flags)
    assert.same({}, hs.eventtap._sent[5].flags)
  end)

  -- apps/dictation's chord tap is live for the whole take and fires on a bare
  -- Fn+C. Without a mark on our own events, typing the letter "c" cancels the
  -- take that is producing it.
  it("stamps every event as the typer's own", function()
    local synthetic = require("lib.synthetic")
    local USER_DATA = hs.eventtap.event.properties.eventSourceUserData
    run("cé")
    assert.is_true(#hs.eventtap._sent > 0)
    for _, e in ipairs(hs.eventtap._sent) do
      assert.is_true(synthetic.isTyper(e.props[USER_DATA]))
    end
  end)

  it("posts a keydown and a keyup for a character with no key", function()
    run("éé")
    local downs, ups = 0, 0
    for _, e in ipairs(hs.eventtap._sent) do
      if e.kind == "text" then
        if e.down then downs = downs + 1 else ups = ups + 1 end
      end
    end
    assert.equals(2, downs)
    assert.equals(2, ups)
  end)

  it("clears modifier flags on every synthesised event", function()
    run("éà")
    for _, e in ipairs(hs.eventtap._sent) do
      assert.same({}, e.flags)
    end
  end)

  it("types one character per tick", function()
    hs.pasteboard.setContents(nil, "abcd")
    typer.typeClipboard()
    local timer = hs.timer._every[#hs.timer._every]
    timer.fn()
    assert.equals("a", typed())
    timer.fn()
    assert.equals("ab", typed())
    assert.equals("2/4", typer.status().progress)
    typer.cancel()
    assert.is_false(typer.status().typing)
  end)

  it("stops where it was asked to stop", function()
    hs.pasteboard.setContents(nil, "abcd")
    typer.typeClipboard()
    local timer = hs.timer._every[#hs.timer._every]
    timer.fn()
    typer.cancel()
    timer.fn()                       -- a tick that slipped past the stop
    assert.equals("a", typed())
  end)

  it("types nothing when the clipboard is empty", function()
    hs.pasteboard.setContents(nil, "")
    typer.typeClipboard()
    assert.equals(0, #hs.timer._every)
    assert.is_false(typer.status().typing)
  end)

  it("refuses a clipboard past the limit", function()
    local was = typer.maxChars
    typer.maxChars = 10
    hs.pasteboard.setContents(nil, string.rep("x", 11))
    typer.typeClipboard()
    assert.equals(0, #hs.timer._every)
    assert.is_false(typer.status().typing)
    typer.maxChars = was
  end)

  it("releases its hotkeys on dispose", function()
    typer.dispose()
    assert.is_false(typer.status().typing)
    typer.start()                    -- leave the module usable for later specs
  end)
end)


describe("keystroke_typer.buildKeymap", function()
  local base = hs.keycodes.map

  it("maps a character to the key that bears it", function()
    local map = typer.buildKeymap(base, nil)
    assert.same({ key = base.a, mods = {} }, map.a)
    assert.same({ key = base.q, mods = {} }, map.q)
  end)

  it("reaches a capital with shift, with no help from the layout", function()
    local map = typer.buildKeymap(base, nil)
    assert.same({ key = base.a, mods = { "shift" } }, map.A)
  end)

  it("asks the layout for shifted punctuation", function()
    local map = typer.buildKeymap(base, function(code)
      return hs.keycodes.charFor(code, true)
    end)
    assert.same({ key = base["1"], mods = { "shift" } }, map["!"])
    assert.same({ key = base["/"], mods = { "shift" } }, map["?"])
  end)

  it("leaves out key names, which are not characters", function()
    local map = typer.buildKeymap(base, nil)
    assert.is_nil(map.escape)
    assert.is_nil(map["return"])
  end)

  it("has no key for a character this layout cannot produce", function()
    local map = typer.buildKeymap(base, nil)
    assert.is_nil(map["é"])
    assert.is_nil(map["😀"])
  end)
end)

describe("keystroke_typer over a remote desktop", function()
  before_each(function()
    hs.eventtap._sent = {}
    hs.timer._every = {}
  end)

  -- The bug this guards. Every character went out as keycode 0 with the real
  -- character attached as a unicode string. A Windows session over RDP in
  -- scancode mode translates by keycode alone, so it read keycode 0 as
  -- kVK_ANSI_A and typed "A" for the whole clipboard.
  --
  -- The text holds no "a", so any event carrying keycode 0 is the bug rather
  -- than a real press of the A key.
  it("never posts keycode 0 for a character that is not an A", function()
    run("hello world 42!")
    for _, e in ipairs(hs.eventtap._sent) do
      local code = (e.kind == "key") and e.key or e.keycode
      assert.is_not.equals(0, code)
    end
  end)

  it("sends no synthesised text at all for ASCII", function()
    run("Pa$$w0rd! <tab>")
    for _, e in ipairs(hs.eventtap._sent) do
      assert.not_equals("text", e.kind)
    end
  end)

  it("survives being read by keycode alone", function()
    local text = "Hello, World! 42 + 7 = 49; see c:\\temp\\x.log?"
    assert.equals(text, run(text))
  end)

  it("still synthesises what the keyboard has no key for", function()
    run("é")
    local kinds = {}
    for _, e in ipairs(hs.eventtap._sent) do kinds[e.kind] = true end
    assert.is_true(kinds.text)
  end)
end)
