-- Pure rules behind the one warm speech-to-text server — no hs.* dependency.
--
-- apps/dictation runs exactly one server (parakeet_server.py on :8765) and it
-- holds exactly one model: whichever the Dictate menu has selected. The voice
-- agent POSTs to the same server, so it always transcribes with that model too.
-- This module answers the two questions a switch asks: which backend runs a
-- model, and how to launch the server for it.

local M = {}

-- config.json model_type → engine. "parakeet" is synthesised by the hub scan in
-- apps/dictation for any NeMo-target config; every other key is an mlx-audio STT
-- architecture (one directory each under mlx_audio/stt/models/). A cached model
-- whose type is absent here is skipped rather than guessed at, which is also
-- what keeps the non-speech models in the same cache — LLMs, pocket-tts — out of
-- the menu.
M.ENGINES = {
  parakeet           = "parakeet",
  qwen3_asr          = "mlxa",
  mega_asr           = "mlxa",
  cohere_asr         = "mlxa",
  granite_speech     = "mlxa",
  granite_speech_nar = "mlxa",
  whisper            = "mlxa",
  glm                = "mlxa",
  glmasr             = "mlxa",
  voxtral            = "mlxa",
  voxtral_realtime   = "mlxa",
  nemotron_asr       = "mlxa",
  fun_asr_nano       = "mlxa",
  fireredasr2        = "mlxa",
  sensevoice         = "mlxa",
  canary             = "mlxa",
  moonshine          = "mlxa",
  vibevoice          = "mlxa",
}

-- `types` is the space-separated list of model_type values found in one
-- snapshot's config.json, in file order. Nested encoder configs carry their own
-- model_type, so the first type ENGINES knows decides — a nested
-- `qwen3_asr_audio_encoder` can never pick a backend.
function M.engineFor(types)
  for t in tostring(types or ""):gmatch("%S+") do
    if M.ENGINES[t] then return M.ENGINES[t] end
  end
  return nil
end

-- How the server is started for model `m` (an entry from the menu's model list:
-- { id, path, engine }). `rt` names the runtime: { parakeetPy, mlxaPy, server,
-- home, port }. Each engine needs its own interpreter, since parakeet-mlx and
-- mlx-audio live in separate uv tool environments.
--
-- Returns { python, args, env, streams } or nil, reason.
function M.launch(m, rt)
  if type(m) ~= "table" then return nil, "no model selected" end
  local env = {
    HOME = rt.home,
    PATH = "/opt/homebrew/bin:/usr/bin:/bin",
    STT_ENGINE = m.engine,
    STT_MODEL_ID = m.id,
    STT_PORT = tostring(rt.port),
    -- Every model in the menu is already in the hub cache; offline mode keeps a
    -- launch from waiting on the network to confirm it.
    HF_HUB_OFFLINE = "1",
  }
  local python
  if m.engine == "parakeet" then
    if not m.path then return nil, "parakeet model " .. tostring(m.id) .. " has no snapshot path" end
    python, env.STT_MODEL = rt.parakeetPy, m.path
  elseif m.engine == "mlxa" then
    -- By repo id, not snapshot path: mlx-audio reads part of the architecture
    -- off the repo name, and a snapshot directory is only a commit hash.
    if not m.id then return nil, "mlx-audio model has no repo id" end
    python, env.STT_MODEL = rt.mlxaPy, m.id
  else
    return nil, "unknown engine " .. tostring(m.engine) .. " for " .. tostring(m.id)
  end
  return { python = python, args = { rt.server }, env = env, streams = (m.engine == "parakeet") }
end

-- Shell command that frees `port` and returns only once nothing holds it, so
-- the old model's memory is released before the new one starts loading. Gives up
-- after ~5s and always exits 0, so the caller's launch callback still runs.
function M.freePortCommand(port)
  local p = tostring(port)
  return "/usr/sbin/lsof -ti :" .. p .. " | xargs kill -9 2>/dev/null; "
      .. "i=0; while /usr/sbin/lsof -ti :" .. p .. " >/dev/null 2>&1 && [ $i -lt 50 ]; "
      .. "do sleep 0.1; i=$((i+1)); done; true"
end

return M
