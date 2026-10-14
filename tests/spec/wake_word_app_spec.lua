-- The wake word is the one plugin that holds the microphone open with no call
-- in progress, so what starts it, what stops it, and what it is allowed to do
-- while something else is listening are all worth pinning down. lib/wake_word
-- has the rules; this is the wiring around them: the capture, the tick, and the
-- three HTTP calls it makes at the voice agent's daemon.

_G.hs = require("hs")

local context = require("lib.context")
local ww = require("lib.wake_word")

local hub = { made = {}, deleted = {} }
package.loaded["lib.menuhub"] = {
  item = function(name)
    hub.made[#hub.made + 1] = name
    return {
      setTitle = function() end, setTooltip = function() end, setMenu = function() end,
      delete = function() hub.deleted[#hub.deleted + 1] = name end,
    }
  end,
}

local tasks
hs.task.new = function(path, cb, args)
  local t = { path = path, cb = cb, args = args or {}, terminated = false }
  t.start = function(self) self.started = true; return self end
  t.terminate = function(self) self.terminated = true; return self end
  t.isRunning = function(self) return self.started and not self.terminated end
  tasks[#tasks + 1] = t
  return t
end

-- Every request, and what each route answers. A spec changes `routes` to put
-- the daemon or the STT server in the state it wants.
local requests, routes
local function route(url)
  for suffix, answer in pairs(routes) do
    if url:sub(-#suffix) == suffix then return answer end
  end
  return { 0, "" }
end
hs.http.asyncGet = function(url, _, cb)
  requests[#requests + 1] = { url = url }
  local a = route(url)
  cb(a[1], a[2], {})
end
hs.http.asyncPost = function(url, body, _, cb)
  requests[#requests + 1] = { url = url, body = body }
  local a = route(url)
  cb(a[1], type(a[2]) == "function" and a[2](body) or a[2], {})
end
local function sent(suffix)
  local out = {}
  for _, r in ipairs(requests) do
    if r.url:sub(-#suffix) == suffix then out[#out + 1] = r end
  end
  return out
end

-- The real encoder is hs.json; the stock mock answers "{}", which would hide
-- what /heard was given.
hs.json.encode = function(t) return string.format('{"text": %q}', t.text) end

-- Stand-ins for the two neighbours. Only what the wake word reads is modelled:
-- the agent's state and refresh, and dictation's microphone and recording flag.
local agent, dictation

-- Starting the capture deletes the old file, and the live one under /tmp is in
-- use by the Hammerspoon actually running on this Mac. The plugin takes its
-- paths from the lib when it loads, so the lib is pointed elsewhere first.
local live = { RAW = ww.RAW, WAV = ww.WAV, PREROLL_WAV = ww.PREROLL_WAV }
local function useScratch()
  ww.RAW, ww.WAV, ww.PREROLL_WAV = os.tmpname(), os.tmpname(), os.tmpname()
end
local function restoreLive()
  for _, path in ipairs({ ww.RAW, ww.WAV, ww.PREROLL_WAV }) do os.remove(path) end
  ww.RAW, ww.WAV, ww.PREROLL_WAV = live.RAW, live.WAV, live.PREROLL_WAV
end

local app
local function load(settings, opts)
  opts = opts or {}
  tasks, requests = {}, {}
  hub.made, hub.deleted = {}, {}
  hs.timer._every = {}
  routes = {
    ["/status"] = { 200, '{"running": false, "agent": "up"}' },
    ["/start"]  = { 200, '{"running": true, "agent": "up"}' },
    ["/heard"]  = { 200, '{"ok": true}' },
    ["/transcribe"] = { 200, "" },
  }
  agent = { state = "idle", refreshed = 0 }
  agent.refresh = function() agent.refreshed = agent.refreshed + 1 end
  dictation = { micName = "MacBook Pro Microphone", recording = false }
  dictation.isRecording = function() return dictation.recording end
  package.loaded["apps.voice_agent"] = agent
  if opts.noAgent then package.loaded["apps.voice_agent"] = nil end
  package.loaded["apps.dictation"] = dictation
  context.resetAtExit()
  hs.fs._files["/opt/homebrew/bin/ffmpeg"] = { mode = "file" }
  hs.settings._v = settings or {}
  useScratch()
  package.loaded["apps.wake_word"] = nil
  app = require("apps.wake_word")
  assert.equals(ww.RAW, app.paths.raw)
  return app
end

local function capture()
  local found
  for _, t in ipairs(tasks) do
    if t.path:find("ffmpeg", 1, true) and not t.terminated then found = t end
  end
  return found
end

-- What ffmpeg would have written: `seconds` of a tone loud enough to clear the
-- silence floor.
local function speak(seconds)
  local f = assert(io.open(app.paths.raw, "wb"))
  f:write(string.rep(string.pack("<i2", 3000), math.floor(seconds * ww.RATE)))
  f:close()
end

local function tick() app.timer.fn() end

describe("wake_word app", function()
  after_each(function()
    if app and app.dispose then app.dispose() end
    package.loaded["apps.voice_agent"] = nil
    package.loaded["apps.dictation"] = nil
    context.resetAtExit()
    restoreLive()
  end)

  it("listens by default, on dictation's microphone", function()
    load()
    assert.is_true(app.enabled())
    local ff = capture()
    assert.truthy(ff)
    assert.is_true(ff.started)
    local args = table.concat(ff.args, " ")
    assert.truthy(args:find("avfoundation", 1, true))
    assert.truthy(args:find(":MacBook Pro Microphone", 1, true))
    assert.same({ "Wake word" }, hub.made)
  end)

  -- The key is the one the switch had in the voice agent's tile, so a user who
  -- switched it off there finds it still off here.
  it("stays quiet when it was switched off", function()
    load({ ["voice_agent.wakeWord"] = false })
    assert.is_false(app.enabled())
    assert.is_nil(capture())
    tick()
    assert.same({}, requests)
  end)

  -- Switching it off must close the microphone, not just stop transcribing:
  -- leaving ffmpeg on an input the user has just said no to is the one thing
  -- this toggle has to get right.
  it("opens and closes the microphone with the menu entry", function()
    load()
    local first = capture()
    app.set(false)
    assert.is_true(first.terminated)
    assert.is_nil(app.capture)
    assert.is_false(hs.settings._v["voice_agent.wakeWord"])

    app.set(true)
    assert.truthy(app.capture)
    assert.is_false(app.capture.terminated)
  end)

  it("gives the microphone, the tick and the tile back when switched off", function()
    load()
    local ff = capture()
    local stopped = false
    app.timer.stop = function() stopped = true end
    app.dispose()
    assert.is_true(ff.terminated)
    assert.is_true(stopped)
    assert.is_nil(app.capture)
    assert.same({ "Wake word" }, hub.deleted)
  end)

  -- With no supervisor there is nobody to show the call or end it, so the
  -- microphone stays closed until the voice agent plugin is back.
  it("keeps the microphone closed while the voice agent plugin is not loaded", function()
    load(nil, { noAgent = true })
    assert.is_nil(capture())
    tick()
    assert.is_nil(capture())
    assert.same({}, requests)

    package.loaded["apps.voice_agent"] = agent
    tick()
    assert.truthy(capture())
  end)

  it("closes the microphone when the voice agent plugin goes away", function()
    load()
    local ff = capture()
    package.loaded["apps.voice_agent"] = nil
    tick()
    assert.is_true(ff.terminated)
    assert.is_nil(app.capture)
  end)

  it("asks the daemon, not the plugin, whether a call is open", function()
    load()
    tick()
    assert.equals(1, #sent("127.0.0.1:8792/status"))
  end)

  it("starts a call when it hears the word, then hands over the sentence", function()
    load()
    routes["/transcribe"] = { 200, "Please read me the weather, Codec." }
    speak(3)
    tick()

    -- Twice: the window that heard the word, then the longer preroll clip read
    -- once /start answered.
    local stt = sent(":8765/transcribe")
    assert.equals(2, #stt)
    assert.equals(app.paths.wav, stt[1].body)
    assert.equals(app.paths.preroll, stt[2].body)
    local starts = sent(":8792/start")
    assert.equals(1, #starts)
    -- The agent's menu bar did not see that /start go by.
    assert.equals(1, agent.refreshed)
    local heard = sent(":8792/heard")
    assert.equals(1, #heard)
    assert.truthy(heard[1].body:find("Please read me the weather, Codec.", 1, true))
  end)

  it("does not start a second call on the same word", function()
    load()
    routes["/transcribe"] = { 200, "Codec." }
    speak(3)
    tick()
    -- The call it just started is live now, by the /start answer.
    routes["/status"] = { 200, '{"running": false, "agent": "up"}' }
    app.polled = "idle"
    tick()
    assert.equals(1, #sent(":8792/start"))
  end)

  it("hands over nothing when the word was all there was", function()
    load()
    routes["/transcribe"] = { 200, "Codec." }
    speak(3)
    tick()
    assert.equals(1, #sent(":8792/start"))
    assert.equals(0, #sent(":8792/heard"))
  end)

  -- Otherwise dictating the word "codec" into a text field opens a call.
  it("transcribes nothing while dictation has the microphone", function()
    load()
    routes["/transcribe"] = { 200, "Codec." }
    dictation.recording = true
    speak(3)
    tick()
    assert.equals(0, #sent("/transcribe"))
    assert.equals(0, #sent("/start"))
  end)

  -- ⌃⌥⌘V goes through the plugin, which knows the call is open before this
  -- app's own poll does.
  it("transcribes nothing during a call the plugin started", function()
    load()
    agent.state = "live"
    speak(3)
    tick()
    assert.equals(0, #sent("/transcribe"))
  end)

  it("transcribes nothing while the daemon is down", function()
    load()
    routes["/status"] = { 0, "" }
    speak(3)
    tick()
    assert.equals(0, #sent("/transcribe"))
  end)

  -- The window at the moment a call closes is that call: a "codec" said in it
  -- must not reopen it.
  it("waits for the window to refill after a call closes", function()
    load()
    routes["/status"] = { 200, '{"running": true}' }
    speak(3)
    tick()
    tick()
    routes["/status"] = { 200, '{"running": false}' }
    -- The tick that sees the call gone, and the next one: both are inside the
    -- settle window, and the capture is loud enough to be sent otherwise.
    tick()
    tick()
    assert.equals(0, #sent("/transcribe"))
  end)

  it("sends nothing to the STT server from a quiet room", function()
    load()
    local f = assert(io.open(app.paths.raw, "wb"))
    f:write(string.rep("\0\0", 3 * ww.RATE))
    f:close()
    tick()
    assert.equals(0, #sent("/transcribe"))
  end)
end)
