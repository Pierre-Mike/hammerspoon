-- The dictation features around a take, driven through apps/dictation's own
-- surface (toggle, the menu, its timers):
--   • the preview says "Starting…" until the mic delivers audio
--   • a silence hallucination is never typed
--   • the transcript is typed at the cursor and stays on the clipboard
--   • the optional LM Studio pass, and its fallbacks to the raw text
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
    if e.kind == "key" then
      local shift = false
      for _, m in ipairs(e.mods or {}) do if m == "shift" then shift = true end end
      out[#out + 1] = KEYTEXT[e.key] or hs.keycodes.charFor(e.key, shift) or "?"
    elseif e.down then
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

local d
local function load(settings)
  tasks, posts, gets, after, taps = {}, {}, {}, {}, {}
  hs.settings._v = settings or {}
  package.loaded["apps.dictation.init"] = nil
  plugins.loaded["keystroke_typer"] = typer
  d = require("apps.dictation.init")
  d.paths = { WAV = TMP .. "/take.wav", RAW = TMP .. "/take.raw", TAKES = TMP .. "/cache/takes" }
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

describe("LM Studio clean-up", function()
  local MODELS = { data = { { id = "qwen", type = "llm", state = "loaded" } } }
  local REPLY = { choices = { { message = { content = "Hello, world." } } } }

  it("is off unless switched on, and never calls LM Studio", function()
    load()
    take()
    assert.equals(0, #gets)
    assert.equals("hello world", d.lastResult)
  end)

  it("types the cleaned text when switched on from the menu", function()
    load()
    menuItem("Clean up with LM Studio").fn()
    assert.is_true(hs.settings._v["dictate.llmCleanup"])
    JSON.models, JSON.reply = MODELS, REPLY
    modelsBody, llmReply = "models", "reply"
    take()
    assert.equals("qwen", JSON.sent.model)
    assert.equals("hello world", JSON.sent.messages[2].content)
    assert.equals("Hello, world.", d.lastResult)
    assert.equals("Hello, world.", pb.text)
  end)

  it("types the raw text when LM Studio is not running", function()
    load({ ["dictate.llmCleanup"] = true })
    take()
    typeOut()
    assert.equals("hello world", d.lastResult)
    assert.equals("hello world", typedText())
  end)

  it("types the raw text on a timeout and ignores a late reply", function()
    load({ ["dictate.llmCleanup"] = true })
    JSON.models = MODELS
    modelsBody, llmReply = "models", "hang"
    take()
    assert.equals(0, #hs.eventtap._sent, "delivered before the clean-up answered")
    fire(4)
    typeOut()
    assert.equals("hello world", typedText())
    assert.equals("hello world", pb.text)
    -- The reply lands after the timeout: nothing more is typed.
    local sent = #hs.eventtap._sent
    JSON.reply = REPLY
    for _, p in ipairs(posts) do
      if p.url:match("/chat/completions$") then p.cb(200, "reply", {}) end
    end
    assert.equals(sent, #hs.eventtap._sent)
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
