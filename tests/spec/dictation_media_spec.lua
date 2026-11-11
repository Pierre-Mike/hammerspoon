-- Pausing media is the same two-call protocol as ducking: pauseMedia() on
-- record, resumeMedia() on every exit from the take. The difference is that it
-- asks first. The media key only toggles, so pressing it with nothing playing
-- would start the last video the user watched, in the middle of their sentence.
-- These specs drive apps/dictation through toggle() and assert on the
-- media-control commands it runs.

_G.hs = require("hs")

package.loaded["lib.menuhub"] = {
  item = function(_)
    return {
      setTitle = function() end, setIcon = function() end,
      setMenu = function() end, setTooltip = function() end,
      delete = function() end,
    }
  end,
}

-- Mirrors MEDIA_CONTROL in apps/dictation/init.lua.
local MEDIA_CONTROL = "/opt/homebrew/bin/media-control"
local PLAYING, PAUSED = '{"playing":true,"title":"a video"}', '{"playing":false}'

-- Every media-control run, as "get", "pause" or "play". A `get` waits in
-- `pending` until the spec answers it, the way the real process answers a
-- moment after the mic opens.
local ran, pending = {}, {}
hs.task.new = function(path, cb, args)
  local t = { start = function() end, terminate = function() end, setEnvironment = function() end }
  if path == MEDIA_CONTROL then
    ran[#ran + 1] = args[1]
    if args[1] == "get" then pending[#pending + 1] = cb end
  end
  return t
end

local function answer(body)
  local cb = table.remove(pending, 1)
  cb(0, body, "")
end

hs.json.decode = function(s)
  if s == PLAYING then return { playing = true, title = "a video" } end
  if s == PAUSED then return { playing = false } end
  return {}
end

hs.audiodevice = {
  defaultOutputDevice = function() return nil end,
  watcher = { setCallback = function() end, start = function() end },
}

local clock = 1000
hs.timer.secondsSinceEpoch = function() return clock end

hs.http.asyncPost = function(url, _, _, cb)
  if not cb then return end
  if tostring(url):match("/finish$") then cb(200, "hello world", {}) else cb(200, "", {}) end
end

local d = require("apps.dictation.init")

before_each(function()
  ran, pending = {}, {}
  clock = clock + 100
  hs.fs._files[MEDIA_CONTROL] = { mode = "file" }
  d.pauseMedia, d.mediaPaused = true, false
  d.recording, d.cancelled = false, false
end)

describe("dictation pausing media", function()
  it("pauses what is playing and plays it again after the transcript", function()
    d.toggle()
    answer(PLAYING)
    assert.same({ "get", "pause" }, ran)
    assert.is_true(d.mediaPaused)

    clock = clock + 3
    d.toggle()
    assert.same({ "get", "pause", "play" }, ran)
    assert.is_false(d.mediaPaused)
  end)

  it("leaves paused media alone", function()
    d.toggle()
    answer(PAUSED)
    clock = clock + 3
    d.toggle()
    assert.same({ "get" }, ran)
  end)

  it("leaves media alone when nothing has ever played", function()
    d.toggle()
    answer("null")
    clock = clock + 3
    d.toggle()
    assert.same({ "get" }, ran)
  end)

  -- The answer to `get` lands after the release. Pausing then would leave the
  -- video stopped with no take left to start it again.
  it("does not pause for a take that ended before the answer came", function()
    d.toggle()
    d.toggle()
    answer(PLAYING)
    assert.same({ "get" }, ran)
    assert.is_false(d.mediaPaused)
  end)

  it("plays again after a take cancelled by chord", function()
    d.toggle()
    answer(PLAYING)
    d.cancelled = true
    clock = clock + 3
    d.toggle()
    assert.same({ "get", "pause", "play" }, ran)
  end)

  it("plays again after a tap too short to transcribe", function()
    d.toggle()
    answer(PLAYING)
    d.toggle()
    assert.same({ "get", "pause", "play" }, ran)
  end)

  it("does not play twice for one pause", function()
    d.toggle()
    answer(PLAYING)
    clock = clock + 3
    d.toggle()
    d.toggle(); d.toggle()   -- stray press and release
    answer(PAUSED)
    assert.same({ "get", "pause", "play", "get" }, ran)
  end)

  it("runs nothing with the switch off", function()
    d.pauseMedia = false
    d.toggle()
    clock = clock + 3
    d.toggle()
    assert.same({}, ran)
  end)

  it("runs nothing when media-control is not installed", function()
    hs.fs._files[MEDIA_CONTROL] = nil
    d.toggle()
    clock = clock + 3
    d.toggle()
    assert.same({}, ran)
  end)

  -- Last, because nothing works after it. dispose() then stops every process
  -- the plugin started, so `play` must not be one of them.
  it("plays again when the plugin is switched off mid-take", function()
    d.toggle()
    answer(PLAYING)
    d.dispose()
    assert.same({ "get", "pause", "play" }, ran)
  end)
end)
