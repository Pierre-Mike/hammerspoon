-- apps/dictation/pronunciation.lua driven through its edges: dictation hands
-- it a take, the scorer answers over HTTP, Space is held and let go, and what
-- comes out is the saved tally, the lesson panel and the keys it holds while
-- open.

_G.hs = require("hs")

local context = require("lib.context")
local pron = require("lib.pronunciation")

-- A scratch directory stands in for ~/.cache/hs-pronunciation.
local TMP = os.tmpname(); os.remove(TMP); os.execute("mkdir -p '" .. TMP .. "'")
local function write(path, data) local f = assert(io.open(path, "wb")); f:write(data); f:close() end
local function exists(path) local f = io.open(path, "rb"); if f then f:close() end; return f ~= nil end
local function ls(dir)
  local out, p = {}, io.popen("ls '" .. dir .. "' 2>/dev/null")
  for l in p:lines() do out[#out + 1] = l end
  p:close()
  return out
end
hs.fs.dir = function(p)
  local names, i = ls(p), 0
  return function() i = i + 1; return names[i] end
end
-- uv is the one tool the scorer needs on disk. It is there on this Mac and not
-- on the Linux CI runner, so the spec says it is installed either way.
local UV = "/opt/homebrew/bin/uv"
hs.fs.attributes = function(p) return (p == UV or exists(p)) and {} or nil end

-- JSON bodies are keys into this table; the state file is kept in memory.
local JSON, saved, seq = {}, nil, 0
hs.json = {
  encode = function(t) seq = seq + 1; local k = "json" .. seq; JSON[k] = t; return k end,
  decode = function(s) if JSON[s] == nil then error("bad json") end; return JSON[s] end,
  read = function() return saved end,
  write = function(t) saved = t; return true end,
}

-- The scorer and the STT server: routes answer at once from `routes`.
local routes, sent
hs.http.asyncGet = function(url, _, cb)
  sent[#sent + 1] = { url = url }
  local r = routes[url:match("https?://[^/]+(/.*)$")]
  if r then cb(r[1], r[2], {}) else cb(0, "", {}) end
end
hs.http.asyncPost = function(url, body, _, cb)
  sent[#sent + 1] = { url = url, body = JSON[body] or body }
  local r = routes[url:match("https?://[^/]+(/.*)$")]
  if not cb then return end
  if r then cb(r[1], r[2], {}) else cb(0, "", {}) end
end
local function posted(path)
  for i = #sent, 1, -1 do if sent[i].url:find(path, 1, true) then return sent[i] end end
end

local tasks
hs.task.new = function(path, cb, args)
  local t = { path = path, cb = cb, args = args or {} }
  function t:start() self.started = true; return self end
  function t:terminate() self.terminated = true; if not self.exited then self.exited = true; self.cb(0, "", "") end; return self end
  function t:setEnvironment(e) self.env = e end
  tasks[#tasks + 1] = t
  return t
end
local function task(path)
  for i = #tasks, 1, -1 do if tasks[i].path == path then return tasks[i] end end
end

local keys
hs.hotkey.bind = function(_, key, pressed, released)
  local h = { key = key, pressed = pressed, released = released }
  function h:delete() self.deleted = true end
  keys[#keys + 1] = h
  return h
end
local function live(key)
  for _, h in ipairs(keys) do if h.key == key and not h.deleted then return h end end
end

local after
hs.timer.doAfter = function(delay, fn)
  local t = { delay = delay, fn = fn }
  function t:stop() self.stopped = true end
  after[#after + 1] = t
  return t
end
local clock = 1000
hs.timer.secondsSinceEpoch = function() return clock end

-- What dictation hands the module: its context, the take in flight and the mic.
local dict
local p, ctx
local function load()
  tasks, keys, after, sent, routes, saved = {}, {}, {}, {}, {}, nil
  hs.settings._v = {}
  os.execute("rm -rf '" .. TMP .. "'/*")
  dict = { micName = "Test Mic", recording = false }
  package.loaded["apps.dictation.pronunciation"] = nil
  ctx = context.new("Dictation")
  p = require("apps.dictation.pronunciation")({
    ctx = ctx,
    isRecording = function() return dict.recording end,
    micName = function() return dict.micName end,
  })
  p.paths.inbox, p.paths.clips, p.paths.attempt = TMP .. "/inbox", TMP .. "/clips", TMP .. "/attempt.wav"
  p.paths.coach = TMP .. "/coach.json"
  routes["/health"] = { 200, hs.json.encode({ ok = true, loaded = true }) }
end

local function sayTake(text)
  local wav = TMP .. "/take-20261030-090000.wav"
  write(wav, "RIFFaudio")
  p.onTake({ text = text, wav = wav })
end

after_each(function() if ctx then ctx:dispose(); ctx = nil end end)

describe("collecting takes", function()
  it("queues an English take's audio and words", function()
    load()
    sayTake("I have three kids at home")
    assert.same({ "take-20261030-090000.txt", "take-20261030-090000.wav" }, ls(TMP .. "/inbox"))
  end)

  it("leaves French alone", function()
    load()
    sayTake("Il a été très sympathique avec moi")
    assert.same({}, ls(TMP .. "/inbox"))
  end)

  it("leaves everything alone when switched off", function()
    load()
    hs.settings._v["dictate.pronunciation.collect"] = false
    sayTake("I have three kids at home")
    assert.same({}, ls(TMP .. "/inbox"))
  end)
end)

describe("checking takes", function()
  local function analysis(flagged)
    return hs.json.encode({ words = {
      { word = "three", flagged = flagged, score = 0.6, expected = "θ ɹ iː", heard = "t ɹ iː",
        errors = { { exp = "θ", got = "t" } } },
      { word = "kids", flagged = false, score = 1 },
    } })
  end

  it("scores a queued take, saves the tally and empties the inbox", function()
    load()
    routes["/analyze"] = { 200, analysis(true) }
    sayTake("I have three kids at home")
    p.drain()
    local req = posted("/analyze").body
    assert.equals("I have three kids at home", req.text)
    assert.equals(TMP .. "/clips", req.clips)
    assert.same({}, ls(TMP .. "/inbox"))
    assert.equals(1, saved.words.three.flags)
  end)

  it("waits while dictation has the mic", function()
    load()
    routes["/analyze"] = { 200, analysis(true) }
    sayTake("I have three kids at home")
    dict.recording = true
    p.drain()
    assert.is_nil(posted("/analyze"))
    assert.equals(2, #ls(TMP .. "/inbox"))
  end)

  it("starts the scorer when it is not running", function()
    load()
    routes["/health"] = nil
    sayTake("I have three kids at home")
    p.drain()
    local sh = task("/bin/sh")
    assert.truthy(sh and sh.started)
    assert.truthy(table.concat(sh.args, " "):find("run --script", 1, true))
  end)

  it("keeps a take the scorer failed on, and gives up after three tries", function()
    load()
    routes["/analyze"] = { 500, hs.json.encode({ error = "boom" }) }
    sayTake("I have three kids at home")
    p.drain(); p.drain()
    assert.equals(2, #ls(TMP .. "/inbox"))
    p.drain()
    assert.same({}, ls(TMP .. "/inbox"))
  end)
end)

describe("a lesson", function()
  local function practise(word)
    p.state.words[word] = { word = word, seen = 2, flags = 2, patterns = { ["θ→t"] = 2 }, clips = {},
                            box = 0, due = 0, expected = "θ ɹ iː", heard = "t ɹ iː" }
  end

  local function attempt(score)
    routes["/score"] = { 200, hs.json.encode({ words = { { word = "three", score = score, heard = "t ɹ iː" } } }) }
    routes["/transcribe"] = { 200, "three" }
    live("space").pressed()
    write(TMP .. "/attempt.wav", "RIFF")
    clock = clock + 1
    live("space").released()
  end

  it("says there is nothing to practise yet", function()
    load()
    p.startLesson()
    assert.is_nil(p.lesson)
  end)

  it("opens the panel, holds its keys and says the word", function()
    load()
    practise("three")
    p.startLesson()
    assert.truthy(p.lesson)
    for _, k in ipairs({ "space", "p", "m", "n", "escape" }) do assert.truthy(live(k), k) end
    local say = task("/usr/bin/say")
    assert.equals("three", say.args[#say.args])
  end)

  it("records on Space and scores the word when it is let go", function()
    load()
    practise("three")
    p.startLesson()
    attempt(0.95)
    local ff = task("/opt/homebrew/bin/ffmpeg")
    assert.truthy(table.concat(ff.args, " "):find(":Test Mic", 1, true))
    assert.equals("three", posted("/score").body.text)
    assert.equals(1, saved.words.three.box, "a first-try pass moves it up a box")
    assert.equals("three", p.lesson.stt)
  end)

  it("grades on the first try only", function()
    load()
    practise("three")
    p.startLesson()
    attempt(0.3)
    attempt(0.95)
    assert.equals(0, saved.words.three.box)
    assert.equals(1, saved.words.three.tries)
  end)

  it("ignores a Space tap too short to be a word", function()
    load()
    practise("three")
    p.startLesson()
    live("space").pressed()
    live("space").released()
    assert.is_nil(posted("/score"))
  end)

  it("gives the keys back and saves when it ends", function()
    load()
    practise("three")
    p.startLesson()
    attempt(0.95)
    live("escape").pressed()
    assert.is_nil(p.lesson)
    assert.is_nil(live("space"))
    assert.truthy(saved.lastLesson)
  end)

  it("never opens while dictation has the mic", function()
    load()
    practise("three")
    dict.recording = true
    p.startLesson()
    assert.is_nil(p.lesson)
  end)
end)

describe("the menu rows", function()
  it("switch learning off and on", function()
    load()
    local row = p.menuRows()[1]
    assert.is_true(row.switch and row.checked)
    row.fn()
    assert.is_false(hs.settings._v["dictate.pronunciation.collect"])
    assert.is_false(p.menuRows()[1].checked)
  end)
end)

describe("switching dictation off", function()
  it("leaves no keys behind", function()
    load()
    p.state.words.three = { word = "three", seen = 2, flags = 2, patterns = {}, clips = {}, box = 0, due = 0 }
    p.startLesson()
    p.stop()
    ctx:dispose(); ctx = nil
    assert.is_nil(live("space"))
  end)
end)
