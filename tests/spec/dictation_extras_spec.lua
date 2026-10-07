-- The dictation features around a take, driven through apps/dictation's own
-- surface (toggle, the menu, its timers):
--   • the preview says "Starting…" until the mic delivers audio
--   • a silence hallucination never pastes
--   • the user's clipboard comes back after the paste
--   • the optional LM Studio pass, and its fallbacks to the raw text
--   • the last takes are kept on disk and can be retranscribed
--   • a tap macOS switched off is re-armed, ending a take whose release was lost

_G.hs = require("hs")

local menuFn
package.loaded["lib.menuhub"] = {
  item = function(_)
    return {
      setTitle = function() end, setIcon = function() end, setTooltip = function() end,
      setMenu = function(_, fn) menuFn = fn end,
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
  local t = { path = path, cb = cb, args = args or {} }
  t.start = function(self) return self end
  t.terminate = function() end
  t.setEnvironment = function(self, env) self.env = env end
  tasks[#tasks + 1] = t
  return t
end

local d
local function load(settings)
  tasks, posts, gets, after, taps = {}, {}, {}, {}, {}
  hs.settings._v = settings or {}
  package.loaded["apps.dictation.init"] = nil
  d = require("apps.dictation.init")
  d.paths = { WAV = TMP .. "/take.wav", RAW = TMP .. "/take.raw", TAKES = TMP .. "/cache/takes" }
end

local function ffmpegExit()
  for _, t in ipairs(tasks) do
    if t.path:find("ffmpeg", 1, true) and not t.exited then t.exited = true; t.cb(0, "", "") end
  end
end

-- A take long enough to transcribe. The WAV is written while "recording".
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
    assert.equals(0, #hs.eventtap._sent, "a too-short tap pasted something")
    timer.fn()                              -- a stray tick after the stop is harmless
    assert.equals("idle", d.micState)
  end)
end)

describe("transcript clean-up", function()
  it("pastes nothing when a Whisper-style take is a silence hallucination", function()
    load()
    d.engine = "mlxa"
    finishBody = "Thanks for watching!"
    take()
    assert.equals(0, #hs.eventtap._sent)
    assert.equals("user clipboard", pb.text)
  end)

  it("pastes a short stock line on Parakeet, where it was really said", function()
    load()
    d.engine = "parakeet"
    finishBody = "Thank you."
    take()
    assert.equals("Thank you.", d.lastResult)
    assert.is_true(#hs.eventtap._sent > 0)
  end)

  it("collapses a looped sentence before pasting", function()
    load()
    finishBody = "Open the file. Open the file. Open the file."
    take()
    assert.equals("Open the file.", d.lastResult)
  end)
end)

describe("clipboard after a paste", function()
  it("pastes with ⌘V and puts the user's clipboard back afterwards", function()
    load()
    take()
    assert.equals("v", hs.eventtap._sent[1].key)
    assert.equals("hello world", pb.text)   -- still there while the app reads it
    fire(0.5)
    assert.equals("user clipboard", pb.text)
  end)

  it("keeps something the user copied in the meantime", function()
    load()
    take()
    hs.pasteboard.setContents("copied after")
    fire(0.5)
    assert.equals("copied after", pb.text)
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

  it("pastes the cleaned text when switched on from the menu", function()
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

  it("pastes the raw text when LM Studio is not running", function()
    load({ ["dictate.llmCleanup"] = true })
    take()
    assert.equals("hello world", d.lastResult)
    assert.equals("v", hs.eventtap._sent[1].key)
  end)

  it("pastes the raw text on a timeout and ignores a late reply", function()
    load({ ["dictate.llmCleanup"] = true })
    JSON.models = MODELS
    modelsBody, llmReply = "models", "hang"
    take()
    assert.equals(0, #hs.eventtap._sent, "pasted before the clean-up answered")
    fire(4)
    assert.equals(1, #hs.eventtap._sent)
    assert.equals("hello world", pb.text)
    -- The reply lands after the timeout: nothing more is pasted.
    JSON.reply = REPLY
    for _, p in ipairs(posts) do
      if p.url:match("/chat/completions$") then p.cb(200, "reply", {}) end
    end
    assert.equals(1, #hs.eventtap._sent)
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
