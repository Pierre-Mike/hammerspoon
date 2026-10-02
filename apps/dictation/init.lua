-- Dictation: hold Fn = record, release = transcribe & paste at cursor.
-- Pipeline: ffmpeg → parakeet-mlx → pbpaste → ⌘V

local earcon      = require("lib.earcon")
local configFile  = require("lib.config")
local EARCONS_CFG = configFile.EARCONS

local DEFAULT_MIC = "MacBook Pro Microphone"  -- selected by NAME; avfoundation indices reshuffle when devices change
local WAV  = "/tmp/hs-dictate.wav"
local RAW  = "/tmp/hs-dictate.raw"   -- headerless s16le PCM, streamed live to the server
local TXT  = "/tmp/hs-dictate.txt"
local FFMPEG   = "/opt/homebrew/bin/ffmpeg"
local PARAKEET = os.getenv("HOME") .. "/.local/bin/parakeet-mlx"
local MODEL_PATH = os.getenv("HOME") .. "/.cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v3/snapshots/ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15"
-- Warm transcription server: model stays resident, so each dictation pays only
-- ~0.2s inference instead of the ~2s cold-start of the parakeet-mlx CLI.
local PARAKEET_PY     = os.getenv("HOME") .. "/.local/share/uv/tools/parakeet-mlx/bin/python"
local PARAKEET_SERVER = os.getenv("HOME") .. "/.hammerspoon/parakeet_server.py"
local PARAKEET_BASE   = "http://127.0.0.1:8765"
local PARAKEET_URL    = PARAKEET_BASE .. "/transcribe"  -- batch (fallback only)
-- mlx-audio runtime: the batch backend behind every non-streaming model
-- (Qwen3-ASR, Whisper, Granite, Cohere Transcribe, Mega-ASR — see ENGINES).
-- Separate from the parakeet server: it cold-loads per call, one model at a
-- time, and has no live-preview streaming.
local MLXA_PY   = os.getenv("HOME") .. "/.local/share/uv/tools/mlx-audio/bin/python"
local BATCH_OUT = "/tmp/hs-stt-batch"
local MIN_DURATION = 0.6            -- avfoundation needs ~300ms to start; below this = no audio
local MAX_RECORD   = 90             -- watchdog: auto-stop if a key/button release is ever missed

local M = { recording = false, ffmpegTask = nil, fnDown = false, playDown = false, startedAt = 0, lastResult = nil, cancelled = false }

-- File logger so we can debug dictation without staring at the HS console.
local LOG = "/tmp/hs-dictate.log"
local function logf(fmt, ...)
  local line = string.format(fmt, ...)
  local f = io.open(LOG, "a")
  if f then
    f:write(os.date("%H:%M:%S "), line, "\n")
    f:close()
  end
  print(line)
end

-- Earcon player: hs.sound is non-blocking, so calling this from startRecording
-- does NOT delay ffmpeg spawn. Failures are swallowed on purpose — a missing
-- .aiff must never break the dictation path. Sounds are cached after first load
-- so subsequent triggers are effectively free.
local _earconCache = {}
local function _loadSystemSound(name)
  if _earconCache[name] ~= nil then return _earconCache[name] or nil end
  local ok, snd = pcall(hs.sound.getByName, name)
  if not ok or not snd then
    -- Fall back to /System/Library/Sounds/<name>.aiff — hs.sound.getByName
    -- occasionally misses freshly-registered sounds.
    local path = "/System/Library/Sounds/" .. name .. ".aiff"
    ok, snd = pcall(hs.sound.soundFromFile, path)
    if not ok then snd = nil end
  end
  _earconCache[name] = snd or false
  return snd or nil
end
local function _loadFileSound(path)
  if _earconCache[path] ~= nil then return _earconCache[path] or nil end
  local ok, snd = pcall(hs.sound.soundFromFile, path)
  if not ok then snd = nil end
  _earconCache[path] = snd or false
  return snd or nil
end
local _earconPlayer = {
  system = function(name, volume)
    local snd = _loadSystemSound(name); if not snd then return end
    pcall(function() snd:volume(volume); snd:stop(); snd:play() end)
  end,
  file = function(path, volume)
    local snd = _loadFileSound(path); if not snd then return end
    pcall(function() snd:volume(volume); snd:stop(); snd:play() end)
  end,
}
-- kind: "start" (mic just began), "stop" (recording ended, transcribing).
local function playEarcon(kind)
  local ok, err = pcall(earcon.play, EARCONS_CFG, kind, _earconPlayer)
  if not ok then logf("[earcon] play(%s) failed: %s", tostring(kind), tostring(err)) end
end

M.menu = require("lib.menuhub").item("Dictation")
-- Native template image (monochrome, auto-tints to the menubar colour).
local ICON_MIC = hs.image.imageFromName("NSTouchBarAudioInputTemplate")
local function setIcon(s)
  if s == "○" then          -- idle: microphone glyph
    if ICON_MIC then M.menu:setTitle(""); M.menu:setIcon(ICON_MIC)
    else M.menu:setIcon(nil); M.menu:setTitle("🎤") end
  elseif s == "●" then      -- recording
    M.menu:setIcon(nil); M.menu:setTitle("🔴")
  elseif s == "…" then      -- transcribing
    M.menu:setIcon(nil); M.menu:setTitle("⏳")
  else
    M.menu:setIcon(nil); M.menu:setTitle(s)
  end
end
setIcon("○")

-- ── Model selection ─────────────────────────────────────────────────────────
-- Every speech model cached under the HF hub is offered in the menubar. One
-- appears the moment its snapshot is fully on disk (`hf download <repo>`) and
-- goes when the cache directory goes — gaining or losing a model is a download,
-- not an edit here.
--
-- Which backend runs a model is read off the model's own config.json, never its
-- name:
--   • a NeMo `target` (the parakeet family) → parakeet-mlx, the only backend
--     that streams, so these are the only models with a live preview
--   • a `model_type` mlx-audio implements → mlx-audio's batch CLI, which
--     cold-loads per call and returns the text on release
local HF_HUB = os.getenv("HOME") .. "/.cache/huggingface/hub"

-- config.json model_type → backend. "parakeet" is synthesised by the scan below
-- for any NeMo-target config; every other key is an mlx-audio STT architecture
-- (one directory each under mlx_audio/stt/models/). A cached model whose type is
-- absent here is skipped rather than guessed at, which is also what keeps the
-- non-speech models in the same cache — LLMs, pocket-tts — out of the menu.
local ENGINES = {
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

-- Label and accuracy for the models worth naming. `wer` is measured HERE, on
-- this machine, against the exact quantised snapshot the menu loads: 73
-- LibriSpeech test-clean clips, 481s of audio, 1169 reference words, each clip
-- transcribed on its own the way a dictation is. Published leaderboard figures
-- describe the full-precision originals, and the gap is not small — the 4-bit
-- Qwen3-ASR build measures 3.93 where the original leads the leaderboard at
-- 4.31 avg, so a quantised snapshot has to be measured, not assumed.
--
-- What the number does not cover: clean read speech only. A model that is
-- mediocre here can still be the one that survives a noisy room, and Whisper in
-- particular is built for messy input this corpus never presents.
--
-- A cached model absent from this table still appears, under its bare repo name
-- and with no number, because a guessed WER would be worse than none.
local CATALOG = {
  ["mlx-community/parakeet-tdt-0.6b-v2"]               = { name = "parakeet v2 · English",        wer = 2.74 },
  ["mlx-community/parakeet-tdt-0.6b-v3"]               = { name = "parakeet v3 · 25 langs",       wer = 3.17 },
  ["mlx-community/parakeet-tdt-1.1b"]                  = { name = "parakeet 1.1b · English"                  },
  ["lyzgeorge/cohere-transcribe-03-2026-mlx-4bit"]     = { name = "Cohere Transcribe · 14 langs", wer = 1.97 },
  ["mlx-community/granite-speech-4.1-2b-nar-mlx-5bit"] = { name = "Granite 4.1 NAR · 5 langs",    wer = 2.57 },
  ["mlx-community/Qwen3-ASR-1.7B-4bit"]                = { name = "Qwen3-ASR 1.7B · 52 langs",    wer = 3.93 },
  -- Whisper earns its place on robustness and 99 languages, not on this corpus:
  -- it is both the least accurate and, at 68s for 481s of audio, six times
  -- slower than parakeet. Reach for it when the audio is messy, not by default.
  ["mlx-community/whisper-large-v3-asr-8bit"]          = { name = "Whisper large-v3 · 99 langs",  wer = 7.36 },
  -- Qwen3-ASR with a quality router in front: on noisy or far-field audio a LoRA
  -- path cuts WER by roughly a fifth (7.53 vs 9.31 on NOIZEUS), on clean speech
  -- it is plain Qwen3-ASR. CAUTION: mlx-audio 0.5.7 raises a broadcast_shapes
  -- error on anything past ~30s, and MAX_RECORD allows 90, so a long dictation
  -- on this model comes back empty. Short takes only until that is fixed.
  ["mlx-community/Mega-ASR-bf16"]                      = { name = "Mega-ASR · noisy, ≤30s",       wer = 3.76 },
}

-- Disk footprint of a cached snapshot ≈ resident memory the model needs once
-- loaded (weights dominate; tokenizer/config are KB). Shown in the menu so a
-- switch makes its RAM cost obvious.
local function humanSize(kb)
  if not kb or kb <= 0 then return "?" end
  local gb = kb / 1048576
  if gb >= 1 then return string.format("%.1f GB", gb) end
  return string.format("%d MB", math.floor(kb / 1024 + 0.5))
end

-- One pass over the hub. Per snapshot it emits every model_type in the config —
-- there are usually several, since nested encoder configs carry their own — plus
-- a "parakeet" marker for NeMo configs. Lua then takes the first type ENGINES
-- recognises, so a nested `qwen3_asr_audio_encoder` can never decide a backend.
-- A repo with `.incomplete` blobs is a download still in flight: listing it would
-- put a model in the menu that fails the moment it is picked.
local HUB_SCAN = [==[
for d in "$HF_HUB"/models--*; do
  [ -d "$d" ] || continue
  ls "$d"/blobs/*.incomplete >/dev/null 2>&1 && continue
  s=$(ls -d "$d"/snapshots/*/ 2>/dev/null | head -1); [ -n "$s" ] || continue; s=${s%/}
  [ -f "$s/config.json" ] || continue
  [ -e "$s/model.safetensors" ] || [ -e "$s/model.safetensors.index.json" ] || continue
  ty=$(grep -o '"model_type"[^,}]*' "$s/config.json" | grep -o '"[A-Za-z0-9_]*"$' | tr -d '"' | tr '\n' ' ')
  grep -q 'nemo\.collections\.asr\.models' "$s/config.json" && ty="parakeet $ty"
  printf '%s\t%s\t%s\t%s\n' "$(basename "$d")" "$s" "$(du -sL -k "$s" 2>/dev/null | cut -f1)" "$ty"
done
]==]

-- Returns { {id=, path=, name=, wer=, engine=, stream=, sizeKB=, sizeStr=}, … }
-- for every cached model whose config names a backend we can run.
local function discoverModels()
  local out = hs.execute('HF_HUB="' .. HF_HUB .. '"\n' .. HUB_SCAN) or ""
  local models = {}
  for dir, path, kb, types in out:gmatch("([^\t\n]+)\t([^\t\n]+)\t([^\t\n]+)\t([^\n]*)") do
    local engine
    for t in types:gmatch("%S+") do engine = engine or ENGINES[t] end
    if engine then
      local id = dir:gsub("^models%-%-", ""):gsub("%-%-", "/")   -- → mlx-community/…
      local meta = CATALOG[id] or {}
      local sizeKB = tonumber(kb) or 0
      models[#models + 1] = {
        id = id, path = path,
        name = meta.name or (id:match("([^/]+)$") or id),
        wer = meta.wer,
        engine = engine, stream = (engine == "parakeet"),
        sizeKB = sizeKB, sizeStr = humanSize(sizeKB),
      }
    end
  end
  -- Streaming models first — they are the only ones that show a live preview, so
  -- they are a different kind of choice, not just a more accurate one. Within a
  -- group, most accurate first; ties and unranked models fall back to the id so
  -- the menu order never shifts between reloads.
  table.sort(models, function(a, b)
    if a.stream ~= b.stream then return a.stream end
    if (a.wer or 99) ~= (b.wer or 99) then return (a.wer or 99) < (b.wer or 99) end
    return a.id < b.id
  end)
  return models
end

local MODELS = discoverModels()

-- ── Microphone selection ────────────────────────────────────────────────────
-- avfoundation device indices reshuffle whenever an input is added/removed, so
-- we pick the mic by NAME and pass the name straight to ffmpeg (it matches).
-- The menubar lists every current input; the choice persists in hs.settings.
local function discoverMics()
  local out = hs.execute(FFMPEG .. " -f avfoundation -list_devices true -i '' 2>&1") or ""
  local mics, inAudio = {}, false
  for line in out:gmatch("[^\n]+") do
    if line:find("audio devices:", 1, true) then
      inAudio = true
    elseif line:find("video devices:", 1, true) then
      inAudio = false
    elseif inAudio then
      local idx, name = line:match("%]%s*%[(%d+)%]%s+(.+)$")
      if idx and name then
        mics[#mics + 1] = { index = idx, name = (name:gsub("%s+$", "")) }
      end
    end
  end
  return mics
end

local MICS = discoverMics()

-- Persisted mic (by name). If it's not currently connected we keep the name
-- anyway, so it just works again once the device reappears.
local function initMic()
  local saved = hs.settings.get("dictate.audioDevice")
  if saved and saved ~= "" then return saved end
  for _, m in ipairs(MICS) do if m.name == DEFAULT_MIC then return m.name end end
  return (MICS[1] and MICS[1].name) or DEFAULT_MIC
end
M.micName = initMic()

-- Restore the persisted choice, else default to MODEL_PATH (v3).
local function initModel()
  local savedId = hs.settings.get("dictate.modelId")
  for _, m in ipairs(MODELS) do if m.id == savedId then return m end end
  for _, m in ipairs(MODELS) do if m.path == MODEL_PATH then return m end end
  return MODELS[1] or { id = "default", path = MODEL_PATH, name = "default", engine = "parakeet", stream = true }
end

-- The warm parakeet server always runs a *parakeet* model (used when a streaming
-- model is selected, and kept ready for when you switch back from a batch one).
local function defaultParakeet()
  for _, m in ipairs(MODELS) do if m.engine == "parakeet" and m.path == MODEL_PATH then return m end end
  for _, m in ipairs(MODELS) do if m.engine == "parakeet" then return m end end
  return { path = MODEL_PATH, name = "v3 · multilingual" }
end

local _sel = initModel()
M.engine     = _sel.engine            -- "parakeet" (streams) | "mlxa" (batch)
M.stream     = _sel.stream            -- live preview?
M.selectedId = _sel.id                -- for the menu checkmark
M.modelName  = _sel.name
M.modelSize  = _sel.sizeStr           -- resident-memory footprint (e.g. "2.3 GB")
M.modelRepo  = _sel.id                -- mlx-audio --model arg (batch engine)
if _sel.engine == "parakeet" then
  M.serverModelPath, M.serverModelName = _sel.path, _sel.name
else
  local p = defaultParakeet()
  M.serverModelPath, M.serverModelName = p.path, p.name
end
M.menu:setTooltip("Dictate · " .. M.modelName .. " · " .. (M.modelSize or "?") .. " · mic: " .. (M.micName or "?"))

-- Floating HUD at screen center
local function showHUD(label, dotColor)
  if M.hud then M.hud:delete(); M.hud = nil end
  local f = hs.screen.mainScreen():frame()
  local w, h = 260, 70
  local x = f.x + (f.w - w) / 2
  local y = f.y + (f.h - h) / 2
  M.hud = hs.canvas.new({x = x, y = y, w = w, h = h}):behavior({"canJoinAllSpaces", "stationary"})
  M.hud:level(hs.canvas.windowLevels.overlay)
  M.hud:appendElements(
    { type = "rectangle", action = "fill",
      fillColor = { red = 0, green = 0, blue = 0, alpha = 0.82 },
      roundedRectRadii = { xRadius = 14, yRadius = 14 } },
    { type = "circle", action = "fill",
      fillColor = dotColor,
      center = { x = 32, y = 35 }, radius = 11 },
    { type = "text", text = label,
      textColor = { white = 1, alpha = 1 },
      textSize = 20, textAlignment = "left",
      frame = { x = 60, y = 22, w = 190, h = 30 } }
  )
  M.hud:show()
end

local function hideHUD()
  if M.hud then M.hud:delete(); M.hud = nil end
end

-- Single centered notification that always replaces the previous one.
-- Avoids hs.alert.show's bottom-stacked behavior so the user sees one message at a time.
local function notify(text, seconds)
  if M.notify then M.notify:delete(); M.notify = nil end
  if M.notifyTimer then M.notifyTimer:stop(); M.notifyTimer = nil end
  local f = hs.screen.mainScreen():frame()
  local w, h = 420, 56
  local x = f.x + (f.w - w) / 2
  local y = f.y + (f.h - h) / 2
  M.notify = hs.canvas.new({x = x, y = y, w = w, h = h}):behavior({"canJoinAllSpaces", "stationary"})
  M.notify:level(hs.canvas.windowLevels.overlay)
  M.notify:appendElements(
    { type = "rectangle", action = "fill",
      fillColor = { red = 0, green = 0, blue = 0, alpha = 0.85 },
      roundedRectRadii = { xRadius = 12, yRadius = 12 } },
    { type = "text", text = text,
      textColor = { white = 1, alpha = 1 },
      textSize = 18, textAlignment = "center",
      frame = { x = 12, y = 16, w = w - 24, h = h - 24 } }
  )
  M.notify:show()
  M.notifyTimer = hs.timer.doAfter(seconds or 1.6, function()
    if M.notify then M.notify:delete(); M.notify = nil end
    M.notifyTimer = nil
  end)
end

local COLOR_REC  = { red = 1.0, green = 0.25, blue = 0.25, alpha = 1 }
local COLOR_PROC = { red = 1.0, green = 0.75, blue = 0.20, alpha = 1 }
local COLOR_SETTLED = { white = 0.92, alpha = 1 }            -- earlier words (settling)
local COLOR_DRAFT   = { red = 1.0, green = 0.78, blue = 0.25, alpha = 1 }  -- volatile tail

-- Live dictation preview. Every word stays provisional until you release (this
-- model commits nothing mid-stream), so the trailing word — the one most likely
-- to still change — is shown amber over the dimmer, more-settled text.
local PREVIEW_SIZE = 28        -- font point size for the live text
local PREVIEW_PAD  = 24        -- inner horizontal/vertical padding
local PREVIEW_TOP  = 50        -- text top offset (leaves room for the rec dot)

local function previewStyled(text)
  local ok, st = pcall(function()
    local s = hs.styledtext.new(text, { font = { size = PREVIEW_SIZE }, color = COLOR_SETTLED })
    local i = text:find("%S+$")   -- byte index where the trailing word starts
    if i then s = s:setStyle({ color = COLOR_DRAFT }, i, #text) end
    return s
  end)
  if ok then return st else return text end
end

-- The panel auto-sizes to the text and is anchored at the bottom, so it grows
-- upward as you speak. Past a screen-height cap it shows the tail (newest words).
local function showLivePreview(text)
  local f = hs.screen.mainScreen():frame()
  local w = math.min(1000, math.floor(f.w * 0.72))
  local innerW = w - 2 * PREVIEW_PAD
  local lineH = math.floor(PREVIEW_SIZE * 1.32)
  local cpl = math.max(8, math.floor(innerW / (PREVIEW_SIZE * 0.52)))  -- ~chars/line
  local maxH = math.floor(f.h * 0.7)
  local maxLines = math.max(1, math.floor((maxH - PREVIEW_TOP - PREVIEW_PAD) / lineH))

  local shown = (text and text ~= "") and text or nil
  if shown then
    -- Keep only the tail that fits, so the words being spoken stay on screen.
    local maxChars = maxLines * cpl
    if #shown > maxChars then shown = "…" .. shown:sub(#shown - maxChars + 2) end
  end

  -- Count wrapped lines for the (possibly trimmed) text to size the panel.
  local lines = 1
  if shown then
    local seg = 0
    for i = 1, #shown do
      local c = shown:sub(i, i)
      if c == "\n" then lines = lines + 1; seg = 0
      else seg = seg + 1; if seg >= cpl then lines = lines + 1; seg = 0 end end
    end
  end
  local h = math.min(maxH, PREVIEW_TOP + lines * lineH + PREVIEW_PAD)
  h = math.max(h, PREVIEW_TOP + lineH + PREVIEW_PAD)   -- at least one line
  local x = f.x + (f.w - w) / 2
  local y = f.y + f.h - h - 120                         -- bottom edge stays fixed

  if not M.preview then
    M.preview = hs.canvas.new({ x = x, y = y, w = w, h = h })
      :behavior({ "canJoinAllSpaces", "stationary" })
    M.preview:level(hs.canvas.windowLevels.overlay)
  else
    M.preview:frame({ x = x, y = y, w = w, h = h })
  end
  M.preview:replaceElements(
    { type = "rectangle", action = "fill",
      fillColor = { red = 0, green = 0, blue = 0, alpha = 0.85 },
      roundedRectRadii = { xRadius = 16, yRadius = 16 } },
    { type = "circle", action = "fill", fillColor = COLOR_REC,
      center = { x = 30, y = 30 }, radius = 9 },
    { type = "text",
      text = shown and previewStyled(shown) or "Listening…",
      textColor = COLOR_SETTLED, textSize = PREVIEW_SIZE,
      frame = { x = PREVIEW_PAD, y = PREVIEW_TOP, w = innerW, h = h - PREVIEW_TOP - 8 } }
  )
  M.preview:show()
end

local function hideLivePreview()
  if M.previewTimer then M.previewTimer:stop(); M.previewTimer = nil end
  if M.preview then M.preview:delete(); M.preview = nil end
end

-- Debug handles so the preview can be driven from `hs -c` without a mic.
_G.dictatePreview = showLivePreview
_G.dictateHide = hideLivePreview
_G.dictateFrame = function()
  if not M.preview then return "nil" end
  local fr = M.preview:frame()
  return string.format("x=%d y=%d w=%d h=%d", fr.x, fr.y, fr.w, fr.h)
end

local function readFile(p)
  local f = io.open(p, "r"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function paste(text)
  if not text or text == "" then return end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return end
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({"cmd"}, "v", 0)
end

-- Shared tail: reset UI, then paste at the cursor.
local function finishTranscript(out)
  setIcon("○"); hideHUD(); hideLivePreview(); M.recording = false
  -- Restore system volume after recording.
  local dev = hs.audiodevice.defaultOutputDevice()
  if dev and M.preDuckVolume then
    dev:setVolume(M.preDuckVolume)
    logf("[duck] restored %.1f", M.preDuckVolume)
    M.preDuckVolume = nil
  end
  logf("[dictate] result: %s", tostring(out))
  if out and out ~= "" then
    out = out:gsub("^%s+", ""):gsub("%s+$", "")
    M.lastResult = out
    paste(out)
  else
    notify("no transcription (see console)", 1.6)
  end
end

-- Cold fallback: spawn the parakeet-mlx CLI (used only if the warm server is down).
local function transcribeCLI()
  os.remove(TXT); os.remove("/private/tmp/hs-dictate.txt")
  local task = hs.task.new(PARAKEET,
    function(exitCode, stdOut, stdErr)
      logf("[dictate] parakeet(CLI) exit=%d", exitCode)
      if stdErr and stdErr ~= "" then logf("[dictate] stderr: %s", stdErr) end
      finishTranscript(readFile(TXT) or readFile("/private/tmp/hs-dictate.txt"))
    end,
    {"--model", M.serverModelPath, "--output-dir", "/tmp", "--output-format", "txt", WAV}
  )
  task:setEnvironment({ HOME = os.getenv("HOME"), PATH = "/opt/homebrew/bin:/usr/bin:/bin" })
  task:start()
end

-- Warm path: POST the wav path to the resident server; fall back to the CLI on
-- any miss (server not up yet, connection refused, transcription error).
local function transcribe()
  setIcon("…")
  showHUD("Transcribing…", COLOR_PROC)
  hs.http.asyncPost(PARAKEET_URL, WAV, { ["Content-Type"] = "text/plain" },
    function(status, body, _)
      if status == 200 and body and body ~= "" and not body:match("^__ERROR__") then
        logf("[dictate] server ok len=%d", #body)
        finishTranscript(body)
      else
        logf("[dictate] server miss (status=%s), CLI fallback", tostring(status))
        transcribeCLI()
      end
    end)
end

-- Duck system audio on recording start; stored on M so finishTranscript can restore.
local DUCK_LEVEL = 30
local function duckNoise()
  local dev = hs.audiodevice.defaultOutputDevice()
  if dev then
    M.preDuckVolume = dev:volume()
    dev:setVolume(DUCK_LEVEL)
    logf("[duck] volume %.1f → %d", M.preDuckVolume, DUCK_LEVEL)
  else
    logf("[duck] no output device")
  end
end

local function unduckNoise()
  local dev = hs.audiodevice.defaultOutputDevice()
  if dev and M.preDuckVolume then
    dev:setVolume(M.preDuckVolume)
    logf("[duck] restored %.1f", M.preDuckVolume)
    M.preDuckVolume = nil
  end
end

-- Batch path for every non-streaming model, run through mlx-audio. No live
-- preview: the finished WAV is transcribed after release. No --language flag, so
-- the model auto-detects (English/French). Cold-loads the model each call, which
-- is why these entries cost seconds where a warm parakeet costs ~0.2s.
local function transcribeBatch()
  os.remove(BATCH_OUT .. ".txt")
  logf("[dictate] batch transcribe (%s)", M.modelRepo)
  local t = hs.task.new(MLXA_PY, function(code, _, err)
    if code ~= 0 and err and err ~= "" then logf("[dictate] batch stderr: %s", err) end
    finishTranscript(readFile(BATCH_OUT .. ".txt"))
  end, {"-m", "mlx_audio.stt.generate", "--model", M.modelRepo,
        "--audio", WAV, "--output-path", BATCH_OUT, "--format", "txt"})
  t:setEnvironment({ HOME = os.getenv("HOME"), PATH = "/opt/homebrew/bin:/usr/bin:/bin" })
  t:start()
end

-- Forward decl so startRecording's watchdog can call stopRecording (defined below).
local stopRecording

local function startRecording()
  -- Fire the "listening" cue FIRST so it lands before ffmpeg spins up. hs.sound
  -- is non-blocking, so this adds no measurable latency to mic capture.
  playEarcon("start")
  os.remove(WAV); os.remove(RAW)
  M.recording = true
  M.batchFinish = false
  M.startedAt = hs.timer.secondsSinceEpoch()
  setIcon("●")
  hideLivePreview()
  showLivePreview(nil)   -- "Listening…" (stays put for batch engines: no partials)
  duckNoise()
  logf("[dictate] recording start (mic=%q, engine=%s)", M.micName, M.engine)
  -- Two outputs from one capture: WAV for batch transcription (CLI / mlx-audio),
  -- plus a headerless s16le PCM file the parakeet server tails live.
  M.ffmpegTask = hs.task.new(FFMPEG, function(code, _, err)
    logf("[dictate] ffmpeg exit=%d", code)
    if code ~= 0 and err and err ~= "" then logf("[dictate] ffmpeg stderr: %s", err) end
    -- Non-streaming engine: WAV is finalized now, so kick off the batch transcribe.
    if M.batchFinish then M.batchFinish = false; transcribeBatch() end
  end,
    {"-y", "-f", "avfoundation", "-i", ":" .. M.micName,
     "-ar", "16000", "-ac", "1", WAV,
     "-ar", "16000", "-ac", "1", "-f", "s16le", "-flush_packets", "1", RAW})
  M.ffmpegTask:start()
  -- Watchdog: never hold the mic open forever if a release event is missed
  -- (e.g. a spurious headset PLAY press, or a swallowed Fn key-up).
  if M.watchdog then M.watchdog:stop() end
  M.watchdog = hs.timer.doAfter(MAX_RECORD, function()
    M.watchdog = nil
    if M.recording then
      logf("[dictate] watchdog fired after %ds — auto-stopping (missed release?)", MAX_RECORD)
      notify("recording auto-stopped after " .. MAX_RECORD .. "s", 2.2)
      stopRecording()
    end
  end)
  if M.stream then
    -- Begin streaming this recording into the warm model as it's captured.
    hs.http.asyncPost(PARAKEET_BASE .. "/start", RAW, {}, function(status, _, _)
      if status ~= 200 then logf("[dictate] /start status=%s (will batch-fallback)", tostring(status)) end
    end)
    -- Poll the live hypothesis and show it growing in the preview panel.
    M.previewTimer = hs.timer.new(0.2, function()
      hs.http.asyncGet(PARAKEET_BASE .. "/partial", nil, function(status, body, _)
        if M.recording and status == 200 and body and body ~= "" then
          showLivePreview(body)
        end
      end)
    end)
    M.previewTimer:start()
  end
end

local function cancelStream()
  hs.http.asyncPost(PARAKEET_BASE .. "/cancel", "", {}, function() end)
end

function stopRecording()
  -- Fire the "captured" cue immediately on release, before terminating ffmpeg
  -- or dispatching transcription. Distinguishable from the start cue by ear.
  playEarcon("stop")
  if M.watchdog then M.watchdog:stop(); M.watchdog = nil end
  local dur = hs.timer.secondsSinceEpoch() - M.startedAt
  -- For batch engines, flag the finish BEFORE terminating ffmpeg so its exit
  -- callback (which fires once the WAV is finalized) runs transcribeBatch.
  M.batchFinish = (not M.stream) and (not M.cancelled) and (dur >= MIN_DURATION)
  if M.ffmpegTask then M.ffmpegTask:terminate(); M.ffmpegTask = nil end
  if M.previewTimer then M.previewTimer:stop(); M.previewTimer = nil end
  if M.cancelled then
    logf("[dictate] cancelled by chord")
    M.cancelled = false; setIcon("○"); hideHUD(); hideLivePreview(); M.recording = false; unduckNoise()
    if M.stream then cancelStream() end
    return
  end
  if dur < MIN_DURATION then
    logf("[dictate] tap too short (%.2fs), ignored", dur)
    setIcon("○"); hideHUD(); hideLivePreview(); M.recording = false; unduckNoise()
    if M.stream then cancelStream() end
    return
  end
  setIcon("…"); showHUD("Transcribing…", COLOR_PROC)
  if M.stream then
    -- ffmpeg already got SIGTERM; tell the server to drain the last audio and
    -- return the transcript. The model has consumed this clip live, so only the
    -- final <1s remains. Fall back to batch (server, then CLI) on miss.
    hs.http.asyncPost(PARAKEET_BASE .. "/finish", "", {}, function(status, body, _)
      if status == 200 and body and body ~= "" and not body:match("^__ERROR__") then
        logf("[dictate] stream finish len=%d", #body)
        finishTranscript(body)
      else
        logf("[dictate] stream finish miss (status=%s), batch fallback", tostring(status))
        transcribe()
      end
    end)
  end
  -- Batch engine: handled by the ffmpeg exit callback (M.batchFinish) once WAV is finalized.
end

-- Kill any stale process on port 8765, then launch the warm parakeet server.
local function launchServer()
  M.serverTask = hs.task.new(PARAKEET_PY,
    function(code, _, err)
      logf("[server] exited code=%d err=%s", code, tostring(err))
      M.serverTask = nil
    end,
    { PARAKEET_SERVER })
  M.serverTask:setEnvironment({
    HOME = os.getenv("HOME"),
    PATH = "/opt/homebrew/bin:/usr/bin:/bin",
    PARAKEET_MODEL_PATH = M.serverModelPath,
  })
  M.serverTask:start()
  logf("[server] launching warm parakeet server (%s)", M.serverModelName or "?")
end

local killStale = hs.task.new("/bin/sh", function() launchServer() end,
  {"-c", "lsof -ti :8765 | xargs kill -9 2>/dev/null; true"})
killStale:start()

-- Reap an orphaned capture: if HS reloads or crashes while recording, its child
-- ffmpeg is reparented to launchd and keeps holding the mic (avfoundation :1)
-- open forever — the persistent orange mic indicator with nothing recording.
-- The WAV path is a unique signature, so this only ever hits our own ffmpeg.
local killStaleFfmpeg = hs.task.new("/bin/sh", nil,
  {"-c", "pkill -f 'ffmpeg .*hs-dictate[.]wav' 2>/dev/null; true"})
killStaleFfmpeg:start()

-- Relaunch the warm server against M.serverModelPath. Frees :8765 first so the new
-- model loads cleanly into a fresh process (the previous worker held the GPU).
local function restartServer()
  if M.serverTask then M.serverTask:terminate(); M.serverTask = nil end
  local k = hs.task.new("/bin/sh", function() launchServer() end,
    {"-c", "lsof -ti :8765 | xargs kill -9 2>/dev/null; true"})
  k:start()
end

local function setModel(m)
  if M.recording then notify("stop recording before switching model", 1.8); return end
  if m.id == M.selectedId then return end
  M.engine, M.stream, M.selectedId = m.engine, m.stream, m.id
  M.modelName, M.modelRepo, M.modelSize = m.name, m.id, m.sizeStr
  hs.settings.set("dictate.modelId", m.id)
  M.menu:setTooltip("Dictate · " .. M.modelName .. " · " .. (M.modelSize or "?"))
  logf("[model] switch → %s (engine=%s, %s)", m.name, m.engine, m.sizeStr or "?")
  local sz = " · " .. (m.sizeStr or "?") .. " RAM"
  if m.engine == "parakeet" then
    if m.path ~= M.serverModelPath then
      M.serverModelPath, M.serverModelName = m.path, m.name
      notify("Model: " .. m.name .. sz .. " — reloading…", 2.4)
      restartServer()
    else
      notify("Model: " .. m.name .. sz, 1.6)   -- server already on this model
    end
  else
    -- Batch engine: nothing to reload; the parakeet server stays warm for switch-back.
    notify("Model: " .. m.name .. sz .. " · batch (no live preview)", 2.8)
  end
end

-- Dynamic menu: rebuilt each open so the active model keeps its checkmark.
-- 🟢 = streaming parakeet (live preview) · 🟡 = batch engine (transcribe on release).
-- Each row carries the two numbers a switch actually trades off: published
-- English WER and RAM. The 5-cell bar scales to the largest cached model, so the
-- relative memory cost is legible at a glance (█ = filled, ░ = empty).
local function sizeBar(kb, maxKB)
  if not kb or kb <= 0 or not maxKB or maxKB <= 0 then return "" end
  local cells = 5
  local filled = math.max(1, math.min(cells, math.floor((kb / maxKB) * cells + 0.5)))
  return string.rep("█", filled) .. string.rep("░", cells - filled)
end

local function setMic(name)
  if M.recording then notify("stop recording before switching mic", 1.8); return end
  M.micName = name
  hs.settings.set("dictate.audioDevice", name)
  M.menu:setTooltip("Dictate · " .. (M.modelName or "?") .. " · mic: " .. name)
  logf("[mic] switch → %q", name)
  notify("Mic: " .. name, 1.6)
end

local function buildMenu()
  MICS = discoverMics()   -- refresh so the picker reflects currently-connected inputs
  local maxKB = 0
  for _, m in ipairs(MODELS) do if m.sizeKB and m.sizeKB > maxKB then maxKB = m.sizeKB end end
  local items = { { title = "Speech model · English WER · RAM footprint", disabled = true } }
  for _, m in ipairs(MODELS) do
    local icon = m.stream and "🟢" or "🟡"
    local wer  = m.wer and string.format("%.2f", m.wer) or "  — "
    items[#items + 1] = { title = string.format("%s  %s   %s   %s  %s",
                            icon, m.name, wer, sizeBar(m.sizeKB, maxKB), m.sizeStr),
                          checked = (m.id == M.selectedId),
                          fn = function() setModel(m) end }
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "WER: measured on LibriSpeech test-clean, lower is better", disabled = true }
  items[#items + 1] = { title = "█ RAM resident   🟢 live preview   🟡 batch (on release)", disabled = true }
  items[#items + 1] = { title = "-" }
  -- Microphone picker: select by name so it survives avfoundation reshuffles.
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Microphone", disabled = true }
  local micSeen = false
  for _, mic in ipairs(MICS) do
    if mic.name == M.micName then micSeen = true end
    items[#items + 1] = { title = mic.name,
      checked = (mic.name == M.micName),
      fn = function() setMic(mic.name) end }
  end
  if not micSeen and M.micName then
    items[#items + 1] = { title = M.micName .. "  (disconnected)", checked = true, disabled = true }
  end
  items[#items + 1] = { title = "Rescan microphones",
    fn = function() MICS = discoverMics(); notify("Rescanned mics (" .. #MICS .. ")", 1.6) end }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Restart server",
    fn = function() notify("Restarting STT server…", 1.6); restartServer() end }
  return items
end
M.menu:setMenu(buildMenu)

local function recallLast()
  if not M.lastResult or M.lastResult == "" then
    notify("no last transcription", 1.4); return
  end
  hs.pasteboard.setContents(M.lastResult)
  local preview = M.lastResult:sub(1, 60)
  if #M.lastResult > 60 then preview = preview .. "…" end
  notify("copied: " .. preview, 1.6)
end

-- Watch Fn modifier flag transitions
M.flagWatcher = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(e)
  local flags = e:getFlags()
  local nowDown = flags.fn == true
  if nowDown ~= M.fnDown then
    M.fnDown = nowDown
    if nowDown then startRecording() else stopRecording() end
  end
  return false
end)
M.flagWatcher:start()

-- Headset MFB → Play/Pause (Logi Tune: Single Press → Play/Pause).
-- Same hold-to-record semantics as Fn. Swallows the event so it doesn't
-- toggle Music/Spotify. Auto-repeats are ignored via the playDown guard.
M.playWatcher = hs.eventtap.new({hs.eventtap.event.types.systemDefined}, function(e)
  local d = e:systemKey()
  if not d or d.key ~= "PLAY" then return false end
  if d.down and not M.playDown then
    M.playDown = true
    if not M.recording then startRecording() end
    return true
  elseif d.down == false and M.playDown then
    M.playDown = false
    if M.recording then stopRecording() end
    return true
  end
  return false
end)
M.playWatcher:start()

-- Chord detection while holding Fn:
--   Fn+C  cancel current recording and recall last
--   Fn+S  speak the current selection through the TTS queue (no dictation)

M.keyWatcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
  if not M.fnDown then return false end
  -- Bare Fn+<key> only. Without this guard the synthetic ⌘C that Fn+S fires to
  -- grab the selection comes straight back through this tap as Fn+C, cancelling
  -- the chord that just sent it — and Fn+⌘C would never reach the focused app.
  local f = e:getFlags()
  if f.cmd or f.alt or f.ctrl or f.shift then return false end
  local kc = e:getKeyCode()
  if kc == hs.keycodes.map["c"] then
    M.cancelled = true
    recallLast()
    return true
  end
  if kc == hs.keycodes.map["s"] then
    -- Reading out, not dictating in. Fn-down already opened the mic, so mark the
    -- capture cancelled (release drops the clip and unducks) and hand off to the
    -- TTS queue. Required lazily: init.lua loads dictation before apps.tts.
    M.cancelled = true
    logf("[chord] Fn+S — speak selection")
    local ok, tts = pcall(require, "apps.tts")
    if ok and type(tts) == "table" and tts.speakSelection then
      tts.speakSelection()
    else
      logf("[chord] Fn+S — apps.tts unavailable: %s", tostring(tts))
      notify("TTS service not loaded", 1.8)
    end
    return true
  end
  return false
end)
M.keyWatcher:start()

-- Keep the mic list fresh even without opening the menu: a headset that
-- (dis)connects after launch retriggers discovery, and if the *selected* mic
-- disappears we say so instead of silently recording nothing.
-- Through lib/audiowatch: the system watcher has room for one callback only.
require("lib.audiowatch").on("dictation", function()
  MICS = discoverMics()
  local present = false
  for _, m in ipairs(MICS) do if m.name == M.micName then present = true; break end end
  if not present then
    logf("[mic] selected %q disconnected", tostring(M.micName))
    notify("Mic '" .. tostring(M.micName) .. "' disconnected — pick another", 2.8)
  end
end)

M.isRecording = function() return M.recording end

notify("Dictate ready · hold Fn or MFB · Fn+C recall · Fn+S speak selection", 2.0)
logf("[dictate] init complete")

return M
