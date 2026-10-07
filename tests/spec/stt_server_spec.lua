-- lib/stt_server decides how the one warm speech server is launched for the
-- model picked in the Dictate menu. Pure, so no hs mock is needed.
local stt = require("lib.stt_server")

local RT = {
  parakeetPy = "/py/parakeet",
  mlxaPy     = "/py/mlx-audio",
  server     = "/hs/parakeet_server.py",
  home       = "/Users/me",
  port       = 8765,
}

local PARAKEET = {
  id = "mlx-community/parakeet-tdt-0.6b-v3", engine = "parakeet",
  path = "/hub/models--mlx-community--parakeet-tdt-0.6b-v3/snapshots/abc",
}
local COHERE = {
  id = "lyzgeorge/cohere-transcribe-03-2026-mlx-4bit", engine = "mlxa",
  path = "/hub/models--lyzgeorge--cohere-transcribe-03-2026-mlx-4bit/snapshots/def",
}

describe("stt_server.engineFor", function()
  it("reads the parakeet marker the hub scan adds for NeMo configs", function()
    assert.equals("parakeet", stt.engineFor("parakeet parakeet_tdt"))
  end)

  it("maps an mlx-audio architecture to the mlx-audio engine", function()
    assert.equals("mlxa", stt.engineFor("cohere_asr"))
    assert.equals("mlxa", stt.engineFor("whisper"))
  end)

  -- Nested encoder configs carry their own model_type; the first known one wins.
  it("skips unknown nested types and takes the first it knows", function()
    assert.equals("mlxa", stt.engineFor("qwen3_asr_audio_encoder qwen3_asr"))
  end)

  it("returns nil for non-speech models so they stay out of the menu", function()
    assert.is_nil(stt.engineFor("llama"))
    assert.is_nil(stt.engineFor(""))
    assert.is_nil(stt.engineFor(nil))
  end)
end)

describe("stt_server.launch", function()
  it("runs a parakeet model under parakeet-mlx's python, from its snapshot", function()
    local l = assert(stt.launch(PARAKEET, RT))
    assert.equals("/py/parakeet", l.python)
    assert.same({ "/hs/parakeet_server.py" }, l.args)
    assert.equals("parakeet", l.env.STT_ENGINE)
    assert.equals(PARAKEET.path, l.env.STT_MODEL)
    assert.equals(PARAKEET.id, l.env.STT_MODEL_ID)
    assert.equals("8765", l.env.STT_PORT)
    assert.is_true(l.streams)
  end)

  -- mlx-audio guesses the architecture partly from the repo name, which a
  -- snapshot hash does not carry, so it gets the repo id and loads offline.
  it("runs an mlx-audio model under mlx-audio's python, by repo id, offline", function()
    local l = assert(stt.launch(COHERE, RT))
    assert.equals("/py/mlx-audio", l.python)
    assert.equals("mlxa", l.env.STT_ENGINE)
    assert.equals(COHERE.id, l.env.STT_MODEL)
    assert.equals("1", l.env.HF_HUB_OFFLINE)
    assert.is_false(l.streams)
  end)

  it("passes HOME and a PATH with Homebrew's ffmpeg on it", function()
    local l = assert(stt.launch(COHERE, RT))
    assert.equals("/Users/me", l.env.HOME)
    assert.truthy(l.env.PATH:find("/opt/homebrew/bin", 1, true))
  end)

  it("refuses a model with no engine instead of guessing an interpreter", function()
    local l, err = stt.launch({ id = "x/y", engine = "nope", path = "/p" }, RT)
    assert.is_nil(l)
    assert.truthy(err:find("nope", 1, true))
  end)

  it("refuses a parakeet entry with no snapshot path", function()
    local l, err = stt.launch({ id = "x/y", engine = "parakeet" }, RT)
    assert.is_nil(l)
    assert.truthy(err)
  end)

  it("refuses a missing model", function()
    assert.is_nil((stt.launch(nil, RT)))
  end)
end)

describe("stt_server.freePortCommand", function()
  local cmd = stt.freePortCommand(8765)

  it("kills whatever holds the port", function()
    assert.truthy(cmd:find("lsof -ti :8765", 1, true))
    assert.truthy(cmd:find("kill -9", 1, true))
  end)

  -- The old model has to be gone before the new one loads, or both sit in
  -- memory at once: the wait is what makes "one model at a time" true.
  it("waits for the port to come free before returning", function()
    assert.truthy(cmd:find("while", 1, true))
  end)

  it("always exits 0 so the launch callback runs", function()
    assert.truthy(cmd:match("true$"))
  end)
end)
