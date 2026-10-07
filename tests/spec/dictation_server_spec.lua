-- One model, one server. These specs drive apps/dictation through what the user
-- touches — reload, the Dictate menu, a take — and assert on the processes it
-- spawns and the requests it sends:
--   • startup launches the server on the SAVED model, whatever its engine
--   • picking a model kills the old server, then launches one on the new model
--   • a take on an mlx-audio model goes to the server's /transcribe and never
--     spawns a cold mlx-audio process beside it

_G.hs = require("hs")

local HOME = os.getenv("HOME")
local PARAKEET_PY = HOME .. "/.local/share/uv/tools/parakeet-mlx/bin/python"
local MLXA_PY     = HOME .. "/.local/share/uv/tools/mlx-audio/bin/python"

-- Menubar stub that keeps the menu builder, so a spec can click a model row.
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

-- The hub scan sees two cached models, one per engine.
local V3_PATH = "/hub/models--mlx-community--parakeet-tdt-0.6b-v3/snapshots/abc"
local SCAN = table.concat({
  "models--mlx-community--parakeet-tdt-0.6b-v3\t" .. V3_PATH .. "\t1200000\tparakeet parakeet_tdt",
  "models--lyzgeorge--cohere-transcribe-03-2026-mlx-4bit\t/hub/cohere/snapshots/def\t1500000\tcohere_asr",
}, "\n") .. "\n"
hs.execute = function(cmd)
  if cmd:find("HF_HUB", 1, true) then return SCAN, true, "exit", 0 end
  return "", true, "exit", 0
end

-- Every spawned process, in order, with what it was started with.
local tasks
hs.task.new = function(path, cb, args)
  local t = { path = path, cb = cb, args = args or {}, started = false, terminated = false }
  t.start = function(self) self.started = true; return self end
  t.terminate = function(self) self.terminated = true end
  t.setEnvironment = function(self, env) self.env = env end
  tasks[#tasks + 1] = t
  return t
end

local posts
hs.http.asyncPost = function(url, body, _, cb)
  posts[#posts + 1] = { url = url, body = body }
  if cb then
    if url:match("/transcribe$") then cb(200, "bonjour", {}) else cb(200, "", {}) end
  end
end

local clock = 1000
hs.timer.secondsSinceEpoch = function() return clock end

local function servers()
  local out = {}
  for _, t in ipairs(tasks) do
    if t.path == PARAKEET_PY or t.path == MLXA_PY then out[#out + 1] = t end
  end
  return out
end

-- The port-freeing shell runs first; its exit is what launches the server.
local function runPortKill()
  for _, t in ipairs(tasks) do
    if t.path == "/bin/sh" and t.args[2] and t.args[2]:find("lsof", 1, true) and not t.ran then
      t.ran = true
      t.cb(0, "", "")
    end
  end
end

local function load(savedId)
  tasks, posts = {}, {}
  hs.settings._v = { ["dictate.modelId"] = savedId }
  package.loaded["apps.dictation.init"] = nil
  local d = require("apps.dictation.init")
  runPortKill()
  return d
end

local function clickModel(label)
  for _, item in ipairs(menuFn()) do
    if item.fn and item.title:find(label, 1, true) then item.fn(); return end
  end
  error("no menu row for " .. label)
end

describe("dictation STT server", function()
  it("starts on the saved parakeet model, under parakeet-mlx's python", function()
    load("mlx-community/parakeet-tdt-0.6b-v3")
    local s = servers()
    assert.equals(1, #s)
    assert.equals(PARAKEET_PY, s[1].path)
    assert.equals("parakeet", s[1].env.STT_ENGINE)
    assert.equals(V3_PATH, s[1].env.STT_MODEL)
  end)

  it("starts on a saved mlx-audio model instead of a default parakeet one", function()
    load("lyzgeorge/cohere-transcribe-03-2026-mlx-4bit")
    local s = servers()
    assert.equals(1, #s, "a second model was loaded beside the selected one")
    assert.equals(MLXA_PY, s[1].path)
    assert.equals("mlxa", s[1].env.STT_ENGINE)
    assert.equals("lyzgeorge/cohere-transcribe-03-2026-mlx-4bit", s[1].env.STT_MODEL)
  end)

  it("restarts the server on the model picked in the menu, killing the old one first", function()
    load("mlx-community/parakeet-tdt-0.6b-v3")
    local old = servers()[1]
    clickModel("Cohere Transcribe")
    assert.is_true(old.terminated)
    assert.equals(1, #servers(), "new server launched before the port was freed")
    runPortKill()
    local s = servers()
    assert.equals(2, #s)
    assert.equals(MLXA_PY, s[2].path)
    assert.equals("lyzgeorge/cohere-transcribe-03-2026-mlx-4bit", s[2].env.STT_MODEL)
  end)

  it("transcribes an mlx-audio take through the warm server, with no cold process", function()
    local d = load("lyzgeorge/cohere-transcribe-03-2026-mlx-4bit")
    d.toggle()
    clock = clock + 3
    d.toggle()
    -- ffmpeg's exit is what says the WAV is finished.
    for _, t in ipairs(tasks) do
      if t.path:find("ffmpeg", 1, true) then t.cb(0, "", "") end
    end
    local transcribes = 0
    for _, p in ipairs(posts) do
      if p.url:match("/transcribe$") then transcribes = transcribes + 1; assert.equals("/tmp/hs-dictate.wav", p.body) end
      assert.is_nil(p.url:match("/start$"), "a batch model was asked to stream")
    end
    assert.equals(1, transcribes)
    for _, t in ipairs(tasks) do
      for _, a in ipairs(t.args) do
        assert.is_nil(tostring(a):find("mlx_audio.stt.generate", 1, true), "spawned a cold mlx-audio process")
      end
    end
    assert.equals("bonjour", d.lastResult)
  end)
end)
