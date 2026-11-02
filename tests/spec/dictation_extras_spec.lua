-- The dictation features around a take, driven through apps/dictation's own
-- surface (toggle, the menu, its timers):
--   • the preview says "Starting…" until the mic delivers audio
--   • a silence hallucination is never typed
--   • the transcript is typed at the cursor and stays on the clipboard
--   • the review panel: nothing lands until ↩ pastes it or ⇧↩ types it
--   • the optional Claude clean-up, and its fallbacks to the raw text
--   • the last takes are kept on disk and can be retranscribed
--   • a tap macOS switched off is re-armed, ending a take whose release was lost

_G.hs = require("hs")

local menuFn
local tileDeleted = 0
package.loaded["lib.menuhub"] = {
  item = function(_)
    return {
      setTitle = function() end, setIcon = function() end, setTooltip = function() end,
      setMenu = function(_, fn) menuFn = fn end,
      delete = function() tileDeleted = tileDeleted + 1 end,
    }
  end,
}

hs.audiodevice = {
  defaultOutputDevice = function() return nil end,
  watcher = { setCallback = function() end, start = function() end },
}

-- A scratch directory stands in for /tmp and the takes cache.
local TMP = os.tmpname(); os.remove(TMP); os.execute("mkdir -p '" .. TMP .. "'")
local function write(path, data) local f = assert(io.open(path, "wb")); f:write(data); f:close() end
local function exists(path) local f = io.open(path, "rb"); if f then f:close() end; return f ~= nil end
local function ls(dir)
  local out, p = {}, io.popen("ls '" .. dir .. "' 2>/dev/null")
  for l in p:lines() do out[#out + 1] = l end
  p:close()
  return out
end

hs.fs.mkdir = function(p) os.execute("mkdir -p '" .. p .. "'"); return true end
hs.fs.dir = function(p)
  local names, i = ls(p), 0
  return function() i = i + 1; return names[i] end
end

-- Event taps that can be switched off, like macOS does.
local taps = {}
hs.eventtap.new = function(types, fn)
  local t = { enabled = false, starts = 0, fn = fn, types = types }
  function t:start() self.enabled = true; self.starts = self.starts + 1; return self end
  function t:stop() self.enabled = false; return self end
  function t:isEnabled() return self.enabled end
  taps[#taps + 1] = t
  return t
end
local mods = {}
hs.eventtap.checkKeyboardModifiers = function() return mods end

-- Hotkeys by mods and key, so a spec can press one the way the user would.
local keys = {}
hs.hotkey.bind = function(m, key, pressed)
  local h = { mods = table.concat(m or {}, "+"), key = key, fn = pressed }
  function h:delete() self.deleted = true end
  function h:enable() return self end
  function h:disable() return self end
  keys[#keys + 1] = h
  return h
end
local function liveKey(m, key)
  for i = #keys, 1, -1 do
    local h = keys[i]
    if not h.deleted and h.key == key and h.mods == m then return h end
  end
end
local function press(m, key)
  local h = liveKey(m, key)
  if not h then error("no live hotkey " .. m .. "+" .. key) end
  return h.fn()
end

local wake
hs.caffeinate = { watcher = {
  systemDidWake = 1, screensDidUnlock = 2, systemWillSleep = 3,
  new = function(fn) wake = fn; return { start = function() end, stop = function() end } end,
} }

-- A pasteboard with a changeCount, so the restore can tell our write from the user's.
local pb = { text = "user clipboard", count = 1 }
hs.pasteboard.getContents = function() return pb.text end
hs.pasteboard.setContents = function(s) pb.text = s; pb.count = pb.count + 1 end
hs.pasteboard.changeCount = function() return pb.count end

local after
hs.timer.doAfter = function(delay, fn)
  local t = { delay = delay, fn = fn, stopped = false }
  t.stop = function(self) self.stopped = true end
  after[#after + 1] = t
  return t
end
local function fire(delay)
  for _, t in ipairs(after) do
    if t.delay == delay and not t.stopped and not t.fired then t.fired = true; t.fn() end
  end
end

-- JSON: the spec hands bodies around as keys into this table.
local JSON = {}
hs.json = {
  encode = function(t) JSON["sent"] = t; return "sent" end,
  decode = function(s) if JSON[s] == nil then error("bad json") end; return JSON[s] end,
}

local clock = 1000
hs.timer.secondsSinceEpoch = function() return clock end

local finishBody, posts, gets, llmReply, modelsBody
hs.http.asyncPost = function(url, body, _, cb)
  posts[#posts + 1] = { url = url, body = body, cb = cb }
  if not cb then return end
  if url:match("/finish$") then cb(200, finishBody, {})
  elseif url:match("/transcribe$") then cb(200, "retranscribed words", {})
  elseif url:match("/chat/completions$") then
    if llmReply ~= "hang" then cb(200, llmReply, {}) end
  else cb(200, "", {}) end
end
hs.http.asyncGet = function(url, _, cb)
  gets[#gets + 1] = url
  if url:match("/api/v0/models$") then cb(modelsBody and 200 or 0, modelsBody or "", {})
  elseif cb then cb(200, "", {}) end
end

local SCAN = "models--mlx-community--parakeet-tdt-0.6b-v3\t/hub/v3/snapshots/abc\t1200000\tparakeet parakeet_tdt\n"
hs.execute = function(cmd)
  if cmd:find("HF_HUB", 1, true) then return SCAN, true, "exit", 0 end
  return "", true, "exit", 0
end

local tasks
hs.task.new = function(path, cb, args)
  local t = { path = path, cb = cb, args = args or {}, terminated = false }
  t.start = function(self) self.started = true; return self end
  t.terminate = function(self) self.terminated = true; return self end
  t.setEnvironment = function(self, env) self.env = env end
  tasks[#tasks + 1] = t
  return t
end

-- apps/dictation asks the plugin registry for the typer rather than require()ing
-- it, so the registry is where the spec puts one. Loading it for real is the
-- point: these specs assert on the characters that reach the event tap, which is
-- the only thing that proves a take actually landed somewhere.
local plugins = require("lib.plugins")
local typer = require("apps.keystroke_typer")

-- Replay what was posted as the text an app would end up holding. A key press
-- resolves through the layout, from its keycode and modifiers, never from a
-- character riding on the event — the same rule keystroke_typer_spec reads by.
local KEYTEXT = { ["return"] = "\n", tab = "\t", space = " " }
local function typedText()
  local out = {}
  for _, e in ipairs(hs.eventtap._sent) do
    if not e.down then
      -- a keyup: the same character again
    elseif e.kind == "key" then
      local shift = false
      for _, m in ipairs(e.mods or {}) do if m == "shift" then shift = true end end
      out[#out + 1] = KEYTEXT[e.key] or hs.keycodes.charFor(e.key, shift) or "?"
    else
      out[#out + 1] = e.text
    end
  end
  return table.concat(out)
end

-- One tick per character, plus one for the loop to find nothing left and stop.
-- The typer's repeating timer is the newest one, because it is built the moment
-- the transcript is handed over.
local function typeOut()
  local timer = hs.timer._every[#hs.timer._every]
  for _ = 1, 4000 do
    timer.fn()
    if not typer.status().typing then return end
  end
  error("the typing loop never finished")
end

-- Review is on by default. Most of this file is about a take that types on
-- release, so it is off unless a spec asks for it.
local d
local function load(settings)
  tasks, posts, gets, after, taps, keys = {}, {}, {}, {}, {}, {}
  hs.settings._v = settings or {}
  if hs.settings._v["dictate.review"] == nil then hs.settings._v["dictate.review"] = false end
  package.loaded["apps.dictation.init"] = nil
  plugins.loaded["keystroke_typer"] = typer
  d = require("apps.dictation.init")
  d.paths = { WAV = TMP .. "/take.wav", RAW = TMP .. "/take.raw", TAKES = TMP .. "/cache/takes" }
  -- Pronunciation hears every take; keep what it queues out of ~/.cache.
  local pp = d.pronunciation.paths
  pp.state, pp.inbox, pp.clips = TMP .. "/pron/state.json", TMP .. "/pron/inbox", TMP .. "/pron/clips"
end

local function ffmpegExit()
  for _, t in ipairs(tasks) do
    if t.path:find("ffmpeg", 1, true) and not t.exited then t.exited = true; t.cb(0, "", "") end
  end
end

-- A take long enough to transcribe. The WAV is written while "recording".
-- Typing is left un-drained: a spec that cares about the characters calls
-- typeOut() itself, and one that only cares that nothing was delivered would
-- have no timer to drive.
local function take(wav)
  d.toggle()
  write(d.paths.WAV, wav or "RIFFaudio")
  clock = clock + 3
  d.toggle()
  ffmpegExit()
end

local function menuItem(label, menu)
  for _, it in ipairs(menu or menuFn()) do
    if tostring(it.title):find(label, 1, true) then return it end
  end
  error("no menu row " .. label)
end

before_each(function()
  typer.cancel()
  hs.timer._every = {}
  finishBody, llmReply, modelsBody = "hello world", nil, nil
  pb.text, pb.count = "user clipboard", 1
  mods = {}
  os.execute("rm -rf '" .. TMP .. "'/*")
  hs.eventtap._sent = {}
end)

describe("mic-ready indicator", function()
  it("says Starting until the recorder writes audio, then Listening", function()
    load()
    d.toggle()
    assert.equals("starting", d.micState)
    d.readyTimer.fn()                       -- nothing written yet
    assert.equals("starting", d.micState)
    write(d.paths.RAW, "\0\0\1\0")
    d.readyTimer.fn()
    assert.equals("listening", d.micState)
    assert.is_nil(d.readyTimer)
  end)

  it("a quick tap before audio arrives is still dropped as too short", function()
    load()
    local timer
    d.toggle()
    timer = d.readyTimer
    d.toggle()                              -- same clock: shorter than MIN_DURATION
    assert.is_nil(d.readyTimer)
    assert.equals("idle", d.micState)
    assert.is_false(d.recording)
    assert.equals(0, #hs.eventtap._sent, "a too-short tap delivered something")
    timer.fn()                              -- a stray tick after the stop is harmless
    assert.equals("idle", d.micState)
  end)
end)

describe("transcript clean-up", function()
  it("types nothing when a Whisper-style take is a silence hallucination", function()
    load()
    d.engine = "mlxa"
    finishBody = "Thanks for watching!"
    take()
    assert.equals(0, #hs.eventtap._sent)
    assert.equals("user clipboard", pb.text)
  end)

  it("types a short stock line on Parakeet, where it was really said", function()
    load()
    d.engine = "parakeet"
    finishBody = "Thank you."
    take()
    typeOut()
    assert.equals("Thank you.", d.lastResult)
    assert.equals("Thank you.", typedText())
  end)

  it("collapses a looped sentence before typing it", function()
    load()
    finishBody = "Open the file. Open the file. Open the file."
    take()
    assert.equals("Open the file.", d.lastResult)
  end)
end)

describe("delivering a transcript", function()
  it("types it at the cursor one character at a time", function()
    load()
    take()
    -- Nothing has arrived yet: the first character waits for the first tick.
    assert.equals(0, #hs.eventtap._sent)
    typeOut()
    assert.equals("hello world", typedText())
    -- ⌘V is never sent. The old path opened with it, so a regression that went
    -- back to pasting would show up right here.
    for _, e in ipairs(hs.eventtap._sent) do
      assert.not_equals("v", e.key, "the transcript was pasted, not typed")
    end
  end)

  it("leaves the transcript on the clipboard as the fallback", function()
    load()
    take()
    typeOut()
    assert.equals("hello world", pb.text)
    -- No restore timer, so no amount of waiting takes the text away again.
    fire(0.5)
    assert.equals("hello world", pb.text)
  end)

  it("keeps something the user copied after the take", function()
    load()
    take()
    typeOut()
    hs.pasteboard.setContents("copied after")
    fire(0.5)
    assert.equals("copied after", pb.text)
  end)

  -- The typer is a plugin of its own and can be switched off in the hub. A take
  -- must still reach the user when it is, and must not quietly reload it.
  it("falls back to the clipboard alone when the typer is not loaded", function()
    load()
    plugins.loaded["keystroke_typer"] = nil
    take()
    assert.equals(0, #hs.eventtap._sent)
    assert.equals("hello world", pb.text)
  end)

  -- A take landing while the last one is still going replaces it, rather than
  -- reading as the second press of a toggle and typing nothing at all.
  it("drops a run still in flight and types the newest take", function()
    load()
    take()
    local timer = hs.timer._every[#hs.timer._every]
    timer.fn(); timer.fn()                  -- "he"
    finishBody = "second take"
    take()
    typeOut()
    assert.equals("hesecond take", typedText())
    assert.equals("second take", pb.text)
  end)
end)

-- The rewrites stand in as fakes on d.rewrite: dictation_rewrite_spec covers
-- claude -p, the bar and the timeouts. What matters here is what dictation and
-- the review panel ask of them.
local ta = { runs = {}, bars = {}, hidden = 0, reply = nil }
-- A "hang" reply keeps the rewrite running: ta.finish(result) answers it later,
-- and ta.cancelled counts the calls that were called off.
function ta.run(text, id, done, opts)
  ta.runs[#ta.runs + 1] = { text = text, id = id, opts = opts }
  if ta.reply ~= "hang" then done(ta.reply, ta.reply == nil and "no reply" or nil); return function() end end
  local live = true
  ta.finish = function(result) if live then live = false; done(result, result == nil and "no reply" or nil) end end
  return function() if live then live = false; ta.cancelled = (ta.cancelled or 0) + 1 end end
end
function ta.showBar(text, opts) ta.bars[#ta.bars + 1] = { text = text, opts = opts } end
function ta.hideBar() ta.hidden = ta.hidden + 1 end

local function withActions(settings)
  load(settings)
  ta.runs, ta.bars, ta.hidden, ta.reply = {}, {}, 0, nil
  d.rewrite.run, d.rewrite.showBar, d.rewrite.hideBar = ta.run, ta.showBar, ta.hideBar
end

-- Fn held, then a bare key: the chord tap is the second one built.
local function chord(key)
  local e = {
    getProperty = function() return 0 end,
    getFlags = function() return {} end,
    getKeyCode = function() return hs.keycodes.map[key] end,
  }
  return taps[2].fn(e)
end

describe("Claude clean-up", function()
  it("is off unless switched on, and never runs a rewrite", function()
    withActions()
    take()
    assert.equals(0, #ta.runs)
    assert.equals("hello world", d.lastResult)
  end)

  it("types the cleaned text when switched on from the menu", function()
    withActions()
    menuItem("Clean up with Claude").fn()
    assert.is_true(hs.settings._v["dictate.llmCleanup"])
    ta.reply = "Hello, world."
    take()
    assert.equals("cleanup", ta.runs[1].id)
    assert.equals("hello world", ta.runs[1].text)
    assert.equals(require("lib.text_actions").CLEANUP_TIMEOUT, ta.runs[1].opts.timeout)
    typeOut()
    assert.equals("Hello, world.", d.lastResult)
    assert.equals("Hello, world.", typedText())
    assert.equals("Hello, world.", pb.text)
  end)

  it("types the raw text when the rewrite misses", function()
    withActions({ ["dictate.llmCleanup"] = true })
    take()
    typeOut()
    assert.equals("hello world", typedText())
  end)

  it("waits for the clean-up before typing anything", function()
    withActions({ ["dictate.llmCleanup"] = true })
    ta.reply = "hang"
    take()
    assert.equals(0, #hs.eventtap._sent)
  end)
end)

describe("rewrites bar after a typed take", function()
  it("opens after a take on the typed text, delivering to the clipboard", function()
    withActions()
    take()
    assert.equals(1, #ta.bars)
    assert.equals("hello world", ta.bars[1].text)
    assert.equals("clipboard", ta.bars[1].opts.deliver)
    ta.bars[1].opts.onResult("Hello there.", "improve")
    assert.equals("Hello there.", d.lastResult)
  end)

  it("stays shut when switched off from the menu", function()
    withActions()
    menuItem("Show rewrites after a typed take").fn()
    assert.is_false(hs.settings._v["dictate.textActionsBar"])
    take()
    assert.equals(0, #ta.bars)
  end)

  it("stays shut for a take that heard nothing", function()
    withActions()
    d.engine = "mlxa"
    finishBody = "Thanks for watching!"
    take()
    assert.equals(0, #ta.bars)
  end)

  it("is closed by the next take", function()
    withActions()
    take()
    ta.hidden = 0
    d.toggle()
    assert.equals(1, ta.hidden)
  end)
end)

describe("Fn+R with review off", function()
  local function heldTake()
    d.fnDown = true
    d.toggle(); write(d.paths.WAV, "RIFFaudio")
    assert.is_true(chord("r"))
    clock = clock + 3; d.toggle(); ffmpegExit()
    d.fnDown = false
  end

  it("types nothing and sends the take to the review panel", function()
    withActions()
    heldTake()
    assert.equals(0, #hs.eventtap._sent)
    assert.equals(0, #ta.bars)
    assert.is_true(d.reviewPanel.isOpen())
    assert.equals("hello world", d.reviewPanel.current.draft)
  end)

  it("only holds the take it was pressed in", function()
    withActions()
    heldTake()
    take()
    assert.is_false(d.reviewPanel.isOpen())
    typeOut()
    assert.equals("hello world", typedText())
    assert.equals("clipboard", ta.bars[1].opts.deliver)
  end)
end)

describe("the review panel", function()
  local function reviewing(settings)
    settings = settings or {}
    settings["dictate.review"] = true
    withActions(settings)
  end

  local function pasted()
    for _, e in ipairs(hs.eventtap._sent) do
      if e.key == "v" and e.mods and e.mods[1] == "cmd" then return true end
    end
    return false
  end

  it("is on by default", function()
    load({ ["dictate.review"] = nil })
    hs.settings._v["dictate.review"] = nil
    package.loaded["apps.dictation.init"] = nil
    d = require("apps.dictation.init")
    assert.is_true(d.review)
  end)

  it("types nothing while you speak, and opens on release with the take on the clipboard", function()
    reviewing()
    d.serverDictate = true                  -- live typing would be possible
    d.toggle()
    assert.is_false(d.live.on)
    write(d.paths.WAV, "RIFFaudio"); clock = clock + 3; d.toggle(); ffmpegExit()
    assert.equals(0, #hs.eventtap._sent)
    assert.equals(0, #ta.bars)
    assert.is_true(d.reviewPanel.isOpen())
    assert.equals("hello world", pb.text)
  end)

  it("pastes on ↩ and gives the key back", function()
    reviewing()
    take()
    press("", "return")
    assert.is_false(d.reviewPanel.isOpen())
    fire(0.05)
    assert.is_true(pasted())
    assert.equals("hello world", pb.text)
    assert.equals("hello world", d.lastResult)
    assert.is_nil(liveKey("", "return"))
    assert.is_nil(liveKey("", "escape"))
  end)

  it("types on ⇧↩, one keystroke at a time", function()
    reviewing()
    take()
    press("shift", "return")
    typeOut()
    assert.equals("hello world", typedText())
    assert.is_false(pasted())
  end)

  it("sends nothing on esc and leaves the take on the clipboard", function()
    reviewing()
    take()
    press("", "escape")
    fire(0.05)
    assert.is_false(d.reviewPanel.isOpen())
    assert.equals(0, #hs.eventtap._sent)
    assert.equals("hello world", pb.text)
  end)

  it("rewrites the draft on ⌥1 and brings the words as heard back on ⌥0", function()
    reviewing()
    take()
    ta.reply = "Hello, world."
    press("alt", "1")
    assert.equals("cleanup", ta.runs[1].id)
    assert.equals("hello world", ta.runs[1].text)
    assert.equals("Hello, world.", d.reviewPanel.current.draft)
    assert.equals("Hello, world.", pb.text)
    press("alt", "0")
    assert.equals("hello world", d.reviewPanel.current.draft)
    press("", "return")
    fire(0.05)
    assert.equals("hello world", pb.text)
  end)

  it("keeps the draft when a rewrite fails", function()
    reviewing()
    take()
    press("alt", "2")
    assert.equals("failed", d.reviewPanel.current.mode)
    assert.equals("hello world", d.reviewPanel.current.draft)
    press("", "return")
    fire(0.05)
    assert.is_true(pasted())
  end)

  it("sends nothing while a rewrite runs, then sends the rewrite", function()
    reviewing()
    take()
    ta.reply = "hang"
    press("alt", "1")
    press("", "return")
    press("shift", "return")
    press("alt", "2")
    fire(0.05)
    assert.is_true(d.reviewPanel.isOpen())
    assert.equals(0, #hs.eventtap._sent)
    assert.equals(1, #ta.runs, "a second preset started while the first ran")
    ta.finish("Hello, world.")
    press("", "return")
    fire(0.05)
    assert.is_true(pasted())
    assert.equals("Hello, world.", pb.text)
  end)

  it("waits for the clean-up that runs on its own, too", function()
    reviewing({ ["dictate.llmCleanup"] = true })
    ta.reply = "hang"
    take()
    press("", "return")
    fire(0.05)
    assert.is_true(d.reviewPanel.isOpen())
    assert.is_false(pasted())
  end)

  it("greys out paste, type and the presets while a rewrite runs", function()
    local rv = require("apps.dictation.review")
    local presets = { { id = "cleanup", label = "Clean up" } }
    local off = {}
    for _, b in ipairs(rv.buttons({ original = "a", draft = "a", mode = "working" }, presets)) do
      off[b.id] = b.disabled == true
    end
    assert.same({ paste = true, type = true, original = false, cleanup = true }, off)
  end)

  it("cancels a rewrite still running on ⌥0, and esc still closes it", function()
    reviewing()
    take()
    ta.reply = "hang"
    press("alt", "1")
    press("alt", "0")
    assert.equals(1, ta.cancelled)
    assert.equals("review", d.reviewPanel.current.mode)
    assert.equals("hello world", d.reviewPanel.current.draft)
    press("alt", "1")
    press("", "escape")
    assert.is_false(d.reviewPanel.isOpen())
    assert.equals(2, ta.cancelled)
  end)

  it("runs the clean-up first when that is switched on", function()
    reviewing({ ["dictate.llmCleanup"] = true })
    ta.reply = "Hello, world."
    take()
    assert.equals(0, #hs.eventtap._sent)
    assert.equals("cleanup", ta.runs[1].id)
    assert.equals(require("lib.text_actions").CLEANUP_TIMEOUT, ta.runs[1].opts.timeout)
    press("", "return")
    fire(0.05)
    assert.equals("Hello, world.", pb.text)
    assert.equals("Hello, world.", d.lastResult)
  end)

  it("is closed by the next take, which leaves the last one on the clipboard", function()
    reviewing()
    take()
    d.toggle()
    assert.is_false(d.reviewPanel.isOpen())
    assert.is_nil(liveKey("", "return"))
    assert.equals("hello world", pb.text)
  end)

  it("opens on the selection with ⌘⌥⇧R", function()
    reviewing()
    d.rewrite.grabSelection = function(cb) cb("selected words") end
    press("cmd+alt+shift", "r")
    assert.equals("selected words", d.reviewPanel.current.draft)
  end)

  it("is switched off from the menu, and live typing comes back", function()
    reviewing()
    assert.is_true(menuItem("Type while you speak").disabled)
    menuItem("Review each take").fn()
    assert.is_false(hs.settings._v["dictate.review"])
    take()
    assert.is_false(d.reviewPanel.isOpen())
    typeOut()
    assert.equals("hello world", typedText())
  end)

  it("offers ⌥0 only once the draft is no longer the words as heard", function()
    local rv = require("apps.dictation.review")
    local presets = { { id = "cleanup", label = "Clean up" } }
    local function ids(R)
      local out = {}
      for _, b in ipairs(rv.buttons(R, presets)) do out[#out + 1] = b.id end
      return table.concat(out, " ")
    end
    assert.equals("paste type cleanup", ids({ original = "a", draft = "a" }))
    assert.equals("paste type original cleanup", ids({ original = "a", draft = "A." }))
  end)

  it("never takes focus", function()
    reviewing()
    local made = {}
    local real = hs.canvas.new
    hs.canvas.new = function(f)
      local c = real(f)
      local orig = c.clickActivating
      c.clickActivating = function(self, v) made[#made + 1] = v; if orig then return orig(self, v) end; return self end
      return c
    end
    take()
    hs.canvas.new = real
    assert.is_false(made[#made])
  end)
end)

describe("one tile", function()
  it("carries the rewrites and the pronunciation rows", function()
    load()
    menuItem("Rewrite the selection")
    menuItem("Learn pronunciation from my dictation")
  end)

  it("hands every take to pronunciation", function()
    load()
    local got
    d.pronunciation.onTake = function(t) got = t end
    take("audio")
    assert.equals("hello world", got.text)
  end)
end)

describe("recent takes", function()
  it("keeps each transcribed take's audio and only the newest five", function()
    load()
    for i = 1, 7 do clock = clock + 10; take("audio" .. i) end
    -- Names carry the wall clock to the second; seven takes in one second
    -- share a name, so seed distinct ones as earlier takes would have left.
    for i = 1, 6 do write(d.paths.TAKES .. string.format("/take-20200101-00000%d.wav", i), "old") end
    take("latest")
    local kept = ls(d.paths.TAKES)
    assert.equals(5, #kept)
  end)

  it("does not keep a take cancelled by chord", function()
    load()
    d.toggle()
    write(d.paths.WAV, "audio")
    d.cancelled = true
    clock = clock + 3
    d.toggle()
    ffmpegExit()
    assert.equals(0, #ls(d.paths.TAKES))
  end)

  it("retranscribes a kept take from the menu and copies the result", function()
    load()
    take("audio")
    local name = ls(d.paths.TAKES)[1]
    local sub = menuItem("Retranscribe recent take").menu
    sub[1].fn()
    local last = posts[#posts]
    assert.truthy(last.url:match("/transcribe$"))
    assert.equals(d.paths.TAKES .. "/" .. name, last.body)
    assert.equals("retranscribed words", pb.text)
  end)

  it("says so when no take has been kept", function()
    load()
    local sub = menuItem("Retranscribe recent take").menu
    assert.is_true(sub[1].disabled)
  end)
end)

-- apps/dictation/pronunciation.lua, and any other app, hears each take through
-- onTake: the words the model settled on and the kept WAV, together, once
-- both exist.
describe("take listeners", function()
  it("hands over the transcript and the kept audio once per take", function()
    load()
    local got = {}
    d.onTake("spec", function(t) got[#got + 1] = t end)
    finishBody = "three kids"
    take("audio")
    assert.equals(1, #got)
    assert.equals("three kids", got[1].text)
    assert.equals(d.paths.TAKES .. "/" .. ls(d.paths.TAKES)[1], got[1].wav)
  end)

  it("waits for the audio when the transcript comes first, and the other way round", function()
    load()
    local got = {}
    d.onTake("spec", function(t) got[#got + 1] = t end)
    d.engine, d.stream = "mlxa", false     -- batch: the WAV is kept before it is transcribed
    take("audio")
    assert.equals(1, #got)
    assert.equals("retranscribed words", got[1].text)
  end)

  it("says nothing for a take cancelled by chord", function()
    load()
    local got = 0
    d.onTake("spec", function() got = got + 1 end)
    d.toggle(); write(d.paths.WAV, "audio"); d.cancelled = true
    clock = clock + 3; d.toggle(); ffmpegExit()
    assert.equals(0, got)
  end)

  it("keeps the take going when a listener throws", function()
    load()
    d.onTake("bad", function() error("boom") end)
    take("audio")
    typeOut()
    assert.equals("hello world", typedText())
  end)

  it("stops calling a listener taken off with offTake", function()
    load()
    local got = 0
    d.onTake("spec", function() got = got + 1 end)
    d.offTake("spec")
    take("audio")
    assert.equals(0, got)
  end)
end)

describe("language for batch models", function()
  it("passes a pinned language to the server and restarts it", function()
    load()
    local sub = menuItem("Language").menu
    for _, it in ipairs(sub) do if it.title == "French" then it.fn() end end
    assert.equals("fr", hs.settings._v["dictate.language"])
    for _, t in ipairs(tasks) do
      if t.path == "/bin/sh" and t.args[2] and t.args[2]:find("lsof", 1, true) then t.cb(0, "", "") end
    end
    local server = tasks[#tasks]
    assert.equals("fr", server.env.STT_LANGUAGE)
  end)
end)

describe("event tap watchdog", function()
  it("restarts the Fn tap when macOS has switched it off", function()
    load()
    local flags = taps[1]
    flags.enabled = false
    d.tapTimer.fn()
    assert.is_true(flags.enabled)
    assert.equals(2, flags.starts)
  end)

  it("re-arms on wake from sleep", function()
    load()
    taps[2].enabled = false
    wake(hs.caffeinate.watcher.systemDidWake)
    assert.is_true(taps[2].enabled)
  end)

  it("ends a take whose Fn release was lost while the tap was off", function()
    load()
    d.fnDown = true
    d.toggle()
    clock = clock + 3
    taps[1].enabled = false
    mods = {}                               -- Fn is no longer held
    d.tapTimer.fn()
    assert.is_false(d.recording)
    assert.is_false(d.fnDown)
  end)

  it("leaves a take running when Fn is still held", function()
    load()
    d.fnDown = true
    d.toggle()
    taps[1].enabled = false
    mods = { fn = true }
    d.tapTimer.fn()
    assert.is_true(d.recording)
  end)
end)

-- ── Switching the plugin off ────────────────────────────────────────────────
-- The two that make dictation the worst plugin in apps/ to leave half-running:
-- the Fn tap sees every key on the machine, and the warm server holds :8765
-- plus a multi-gigabyte model. Everything else it registers is checked here
-- alongside them, because the Plugins tile reads dispose() as "it is gone".
describe("dispose", function()
  it("releases the taps, the server, the overlays and the tile", function()
    load()
    local before = tileDeleted
    local server = tasks[#tasks]
    local preview, hide, frame = _G.dictatePreview, _G.dictateHide, _G.dictateFrame
    assert.is_true(taps[1].enabled)
    assert.is_true(taps[2].enabled)
    assert.is_function(preview)
    assert.is_function(require("lib.audiowatch").handlers["dictation"])

    d.dispose()

    -- The tap: an abandoned one swallows Fn for every app until a reload.
    assert.is_false(taps[1].enabled)
    assert.is_false(taps[2].enabled)
    -- The warm server: its port and its model have to come back, or the plugin
    -- cannot be switched on again.
    assert.is_true(server.terminated)
    assert.equals(before + 1, tileDeleted)
    -- Gone, not necessarily nil: the context puts back whatever held the name
    -- before, which in this spec is an earlier load of this same module. What
    -- matters is that `hs -c 'dictatePreview(…)'` no longer reaches this one.
    assert.are_not.equal(preview, _G.dictatePreview)
    assert.are_not.equal(hide, _G.dictateHide)
    assert.are_not.equal(frame, _G.dictateFrame)
    -- The mic watcher is one slot in a shared registry, so leaving it behind
    -- would keep telling a disposed plugin about every device change.
    assert.is_nil(require("lib.audiowatch").handlers["dictation"])
  end)

  it("ends a take that is still running", function()
    load()
    d.toggle()
    assert.is_true(d.recording)
    local ffmpeg
    for _, t in ipairs(tasks) do if t.path:find("ffmpeg", 1, true) then ffmpeg = t end end

    d.dispose()

    -- The mic is the thing the user would notice: a capture left running keeps
    -- the orange indicator on with nothing recording.
    assert.is_false(d.recording)
    assert.is_true(ffmpeg.terminated)
    assert.equals("idle", d.micState)
  end)

  it("stops the tap watchdog, which would otherwise re-arm the taps", function()
    load()
    local stopped = false
    d.tapTimer.stop = function() stopped = true end

    d.dispose()

    -- This is how a disposed plugin comes back to life: the tap watchdog ticks
    -- two seconds later, finds its tap off, and starts it again. Which is the
    -- right thing to do while the plugin is running and exactly wrong after.
    assert.is_true(stopped)
  end)
end)
