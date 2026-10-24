-- apps/karaoke driven through its edges: media-control lines go in on the
-- stream, LRCLIB answers come back through hs.http, and what comes out is the
-- island on screen and the text on it.

_G.hs = require("hs")

local tile = { title = nil, deleted = false }
package.loaded["lib.menuhub"] = {
  item = function(_)
    return {
      setTitle = function(_, t) tile.title = t end, setMenu = function(_, fn) tile.menu = fn end,
      setTooltip = function() end, delete = function() tile.deleted = true end,
    }
  end,
}

local MEDIA_CONTROL = "/opt/homebrew/bin/media-control"

local clock = 1000
hs.timer.secondsSinceEpoch = function() return clock end

-- The frame ticker: a spec calls tick() to draw one frame, if it is running.
local every
hs.timer.doEvery = function(_, fn)
  local t = { fn = fn, on = true }
  function t:stop() self.on = false; return self end
  function t:start() self.on = true; return self end
  function t:running() return self.on end
  every[#every + 1] = t
  return t
end
local function tick()
  for _, t in ipairs(every) do if t.on then t.fn() end end
end

-- One-shot timers that fire only when the spec says so.
local after
hs.timer.doAfter = function(_, fn)
  local t = { fn = fn }
  function t:stop() self.stopped = true end
  after[#after + 1] = t
  return t
end

-- The stream task: feed(text) is what media-control would print.
local tasks
hs.task.new = function(path, cb, stream, args)
  local t = { path = path, cb = cb, stream = stream, args = args, terminated = false }
  function t:start() self.started = true; return self end
  function t:terminate() self.terminated = true; return self end
  function t.feed(text) stream(t, text, "") end
  tasks[#tasks + 1] = t
  return t
end
local function feed(text) tasks[#tasks].feed(text) end

-- JSON bodies are keys into this table, as in the other plugin specs.
local JSON = {}
hs.json = {
  encode = function(_) return "{}" end,
  decode = function(s) if JSON[s] == nil then error("bad json") end; return JSON[s] end,
}

-- LRCLIB: every request is held until the spec answers it.
local requests
hs.http.asyncGet = function(url, headers, cb)
  requests[#requests + 1] = { url = url, headers = headers, answer = function(status, key) cb(status, key, {}) end }
end
local function lastUrl() return requests[#requests].url end

-- Answer every request the plugin makes, the newest first, until it stops
-- asking. `pick(req)` returns the status and body for each.
local function drain(pick)
  local answered = 0
  while answered < #requests do
    answered = #requests
    requests[answered].answer(pick(requests[answered]))
  end
end

-- Canvases: elements by index, the way hs.canvas exposes them.
local canvases
hs.canvas.new = function(frame)
  local c = { frame0 = frame, visible = false, deleted = false }
  function c:level() return self end
  function c:behavior() return self end
  function c:show() self.visible = true; return self end
  function c:hide() self.visible = false; return self end
  function c:delete() self.deleted = true end
  function c:minimumTextSize(_, text) return { w = #text * 10, h = 20 } end
  canvases[#canvases + 1] = c
  return c
end
local function island()
  for i = #canvases, 1, -1 do
    local c = canvases[i]
    if not c.deleted and c[1] and c[1].type == "rectangle" then return c end
  end
end

local function screen(name, full, frame)
  return { name = function() return name end, fullFrame = function() return full end,
           frame = function() return frame end }
end
local MAIN = screen("NB34C", { x = 0, y = 0, w = 3440, h = 1440 }, { x = 0, y = 30, w = 3440, h = 1410 })
local BUILTIN = screen("Built-in Retina Display", { x = -1728, y = 275, w = 1728, h = 1117 },
                       { x = -1728, y = 308, w = 1728, h = 1084 })
hs.screen.primaryScreen = function() return MAIN end
hs.screen.allScreens = function() return { MAIN, BUILTIN } end

-- What media-control printed for a YouTube video in Safari.
local function youtube(over)
  local p = {
    playbackRate = 1, timestampEpochMicros = 1000 * 1e6, album = "",
    elapsedTimeMicros = 0, playing = true, bundleIdentifier = "com.apple.WebKit.GPU",
    parentApplicationBundleIdentifier = "com.apple.Safari",
    title = "Rilès - Una Vez Más (Que será, será) (Prod. Rilès)", artist = "Rilès",
    durationMicros = 256281000,
  }
  for k, v in pairs(over or {}) do p[k] = v end
  return { type = "data", diff = false, payload = p }
end
JSON.play  = youtube()
JSON.pause = youtube({ playing = false, playbackRate = 0, elapsedTimeMicros = 20 * 1e6,
                       timestampEpochMicros = 1020 * 1e6 })
JSON.empty = { type = "data", diff = false, payload = {} }
JSON.other = youtube({ title = "Some Song", artist = "Someone" })

JSON.lyrics = { id = 1, duration = 256, instrumental = false,
                syncedLyrics = "[00:14.30] History repeats itself\n[00:17.54] With the blood and with the hate" }
JSON.plain  = { id = 2, duration = 256, instrumental = false, plainLyrics = "no stamps" }
JSON.found  = { { id = 3, duration = 257, syncedLyrics = "[00:01.00] Found by search" } }
JSON.nohits = {}

local karaoke

local function load()
  package.loaded["apps.karaoke"] = nil
  karaoke = require("apps.karaoke")
  return karaoke
end

describe("apps/karaoke", function()
  before_each(function()
    clock = 1000
    every, after, tasks, requests, canvases = {}, {}, {}, {}, {}
    hs.settings._v = {}
    hs.fs._files = { [MEDIA_CONTROL] = { mode = "file" } }
    tile.title, tile.deleted, tile.menu = nil, false, nil
  end)

  after_each(function() if karaoke then karaoke.dispose(); karaoke = nil end end)

  it("streams from media-control without diffs or artwork", function()
    load()
    assert.equals(MEDIA_CONTROL, tasks[1].path)
    assert.same({ "stream", "--no-diff", "--no-artwork", "--micros" }, tasks[1].args)
    assert.is_true(tasks[1].started)
  end)

  it("asks LRCLIB for the song inside a YouTube title, not the title itself", function()
    load()
    feed("play\n")
    assert.equals(1, #requests)
    assert.equals(
      "https://lrclib.net/api/get?artist_name=Ril%C3%A8s&track_name=Una%20Vez%20M%C3%A1s%20%28Que%20ser%C3%A1%2C%20ser%C3%A1%29&duration=256",
      lastUrl())
    assert.truthy(requests[1].headers["User-Agent"]:find("hammerspoon", 1, true))
  end)

  it("reads a line that arrives in two pieces", function()
    load()
    feed("pl")
    assert.equals(0, #requests)
    feed("ay\n")
    assert.equals(1, #requests)
  end)

  it("names the song while it looks, then sings along", function()
    load()
    feed("play\n")
    local c = island()
    assert.is_true(c.visible)
    assert.equals("Rilès - Una Vez Más (Que será, será) (Prod. Rilès) · Rilès", c[2].text)
    assert.equals("Looking up lyrics…", c[6].text)

    requests[1].answer(200, "lyrics")
    clock = 1015   -- 15 s in: the first line is being sung
    tick()
    c = island()
    assert.equals("History repeats itself", c[2].text)
    assert.equals("History repeats itself", c[4].text)
    assert.equals("With the blood and with the hate", c[6].text)
    -- The lit copy is clipped part of the way across.
    local clip = c[3].frame
    assert.is_true(clip.w > 0 and clip.w < #"History repeats itself" * 10)
  end)

  it("searches when the exact match has no timestamps", function()
    load()
    feed("play\n")
    requests[1].answer(200, "plain")
    assert.truthy(lastUrl():find("/api/search?track_name=Una%20Vez%20M%C3%A1s&artist_name=Ril%C3%A8s", 1, true))
    requests[2].answer(200, "found")
    clock = 1002
    tick()
    assert.equals("Found by search", island()[2].text)
  end)

  it("ends on a free-text search when nothing else matched", function()
    load()
    feed("play\n")
    drain(function(r)
      if r.url:find("/search?q=", 1, true) then return 200, "found" end
      if r.url:find("/search?", 1, true) then return 200, "nohits" end
      return 404, "nohits"
    end)
    assert.truthy(lastUrl():find("/api/search?q=", 1, true))
    clock = 1002
    tick()
    assert.equals("Found by search", island()[2].text)
  end)

  it("asks again, waiting longer each time, while LRCLIB is busy", function()
    load()
    feed("play\n")
    requests[1].answer(503, "nohits")
    assert.equals(1, #requests)
    after[#after].fn()
    assert.equals(2, #requests)
    assert.equals(requests[1].url, requests[2].url)
  end)

  it("says so when there are no lyrics, then gets out of the way", function()
    load()
    feed("play\n")
    drain(function(r)
      if r.url:find("/search", 1, true) then return 200, "nohits" end
      return 404, "nohits"
    end)
    assert.equals("No synced lyrics for this one", island()[6].text)
    clock = clock + 6
    tick()
    assert.is_false(island().visible)
  end)

  it("tells a busy LRCLIB from a missing song, and asks again later", function()
    load()
    feed("play\n")
    -- Every request busy on every try: run each backoff timer as it is armed.
    for _ = 1, 100 do
      local r = requests[#requests]
      if r.done then break end
      r.done = true
      r.answer(503, "nohits")
      if karaoke.lyrics.kind == "error" then break end
      local t = after[#after]
      if t and not t.ran then t.ran = true; t.fn() end
    end
    assert.equals("error", karaoke.lyrics.kind)
    assert.equals("LRCLIB is busy, trying again soon", island()[6].text)
    assert.is_nil(karaoke.cache[karaoke.np.key])
    -- The retry of the whole lookup is armed and asks from the top.
    local n = #requests
    after[#after].fn()
    assert.equals(n + 1, #requests)
    assert.equals(requests[1].url, lastUrl())
  end)

  it("hides a few seconds after a pause and comes back on play", function()
    load()
    feed("play\n")
    requests[1].answer(200, "lyrics")
    clock = 1020
    feed("pause\n")
    tick()
    assert.is_true(island().visible)
    clock = 1024
    tick()
    assert.is_false(island().visible)
    JSON.resume = youtube({ elapsedTimeMicros = 20 * 1e6, timestampEpochMicros = 1030 * 1e6 })
    clock = 1030
    feed("resume\n")
    assert.is_true(island().visible)
  end)

  it("does not look a song up twice", function()
    load()
    feed("play\n")
    requests[1].answer(200, "lyrics")
    feed("other\n")
    local n = #requests
    feed("play\n")
    assert.equals(n, #requests)
    assert.equals("Rilès - Una Vez Más (Que será, será) (Prod. Rilès)", karaoke.np.title)
  end)

  it("drops an answer for a song that is no longer playing", function()
    load()
    feed("play\n")
    feed("other\n")
    requests[1].answer(200, "lyrics")
    assert.equals("Some Song", karaoke.np.title)
    assert.equals("loading", karaoke.lyrics.kind)
  end)

  it("hides when nothing is playing", function()
    load()
    feed("play\n")
    feed("empty\n")
    assert.is_nil(karaoke.np)
    assert.is_false(island().visible)
  end)

  it("moves the lyrics with the timing nudge", function()
    load()
    feed("play\n")
    requests[1].answer(200, "lyrics")
    clock = 1017   -- 17.0 s: still the first line
    tick()
    assert.equals("History repeats itself", island()[2].text)
    karaoke.nudge(0.5)   -- a second sooner: 18.0 s, past the 17.54 s stamp
    karaoke.nudge(0.5)
    tick()
    assert.equals("With the blood and with the hate", island()[2].text)
    karaoke.nudge(nil)
    tick()
    assert.equals("History repeats itself", island()[2].text)
  end)

  it("switches off from the hub and stays off", function()
    load()
    feed("play\n")
    karaoke.toggle()
    assert.is_false(island().visible)
    assert.equals("🎤💤", tile.title)
    assert.is_false(hs.settings._v["karaoke.enabled"])
  end)

  it("sits under the notch on the built-in screen", function()
    hs.settings._v["karaoke.screen"] = "builtin"
    load()
    feed("play\n")
    local c = island()
    assert.equals(275, c.frame0.y)
    assert.equals(33 + 4, c[2].frame.y)   -- below the 33 pt menu bar
  end)

  it("falls back to AppleScript without media-control", function()
    hs.fs._files = {}
    hs.spotify = {
      isRunning = function() return true end, isPlaying = function() return true end,
      getCurrentTrack = function() return "Hello" end, getCurrentArtist = function() return "Adele" end,
      getCurrentAlbum = function() return "25" end, getDuration = function() return 295 end,
      getPosition = function() return 12 end,
    }
    load()
    assert.equals(0, #tasks)
    assert.equals("AppleScript", karaoke.source)
    for _, t in ipairs(every) do if t.on then t.fn() end end
    assert.equals("Hello", karaoke.np.title)
    assert.equals("https://lrclib.net/api/get?artist_name=Adele&track_name=Hello&duration=295", lastUrl())
    hs.spotify = nil
  end)

  it("takes everything back on dispose", function()
    load()
    feed("play\n")
    local c = island()
    local stream = tasks[1]
    karaoke.dispose()
    karaoke = nil
    assert.is_true(stream.terminated)
    assert.is_true(c.deleted)
    assert.is_true(tile.deleted)
    -- An answer that lands after dispose draws nothing.
    local before = #canvases
    requests[1].answer(200, "lyrics")
    assert.equals(before, #canvases)
  end)
end)
