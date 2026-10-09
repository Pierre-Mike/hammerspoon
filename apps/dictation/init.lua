-- Dictation: hold Fn = record, release = transcribe & type at cursor.
-- Pipeline: ffmpeg → warm STT server (the selected model) → clipboard →
-- apps/keystroke_typer, which types the transcript one keystroke at a time.
--
-- Everything this plugin builds belongs to its context, and two of those things
-- are why it matters here more than anywhere else in apps/. The Fn tap sits in
-- front of every keystroke on the machine, so one left behind means Fn does
-- nothing, for every app, until a reload. And the warm STT server holds :8765
-- and a multi-gigabyte model, so a plugin that could not release it could not
-- be switched off and on again — its own replacement would find the port taken.
--
-- M.dispose() gives back the tap, the server, the ffmpeg child, the overlays,
-- the mic watcher and the Dictate tile, in one call.

local earcon      = require("lib.earcon")
local sttServer   = require("lib.stt_server")
local configFile  = require("lib.config")
local plugins     = require("lib.plugins")
local tfilter     = require("lib.transcript_filter")
local llm         = require("lib.llm_cleanup")
local takes       = require("lib.dictation_takes")
local tapGuard    = require("lib.tap_guard")
local EARCONS_CFG = configFile.EARCONS

local ctx = require("lib.context").new("Dictation")

local DEFAULT_MIC = "MacBook Pro Microphone"  -- selected by NAME; avfoundation indices reshuffle when devices change
local WAV  = "/tmp/hs-dictate.wav"
local RAW  = "/tmp/hs-dictate.raw"   -- headerless s16le PCM, streamed live to the server
local TXT  = "/tmp/hs-dictate.txt"
-- The last takes' audio, so one can be run again through another model.
local TAKES_DIR = os.getenv("HOME") .. "/.cache/hs-dictation/takes"
local FFMPEG   = "/opt/homebrew/bin/ffmpeg"
local PARAKEET = os.getenv("HOME") .. "/.local/bin/parakeet-mlx"
local MODEL_PATH = os.getenv("HOME") .. "/.cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v3/snapshots/ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15"
-- One warm transcription server holds the ONE selected model, so each dictation
-- pays only inference (~0.1–0.2s) instead of a multi-second cold load. The voice
-- agent POSTs to the same port, so it always hears with the same model.
-- parakeet_server.py serves both engines; it runs under the interpreter of the
-- selected model's engine (parakeet-mlx or mlx-audio — see lib/stt_server).
local PARAKEET_PY = os.getenv("HOME") .. "/.local/share/uv/tools/parakeet-mlx/bin/python"
local MLXA_PY     = os.getenv("HOME") .. "/.local/share/uv/tools/mlx-audio/bin/python"
local STT_SERVER  = os.getenv("HOME") .. "/.hammerspoon/parakeet_server.py"
local STT_PORT    = 8765
local STT_BASE    = "http://127.0.0.1:" .. STT_PORT
local STT_URL     = STT_BASE .. "/transcribe"  -- batch: every mlx-audio take, parakeet fallback
local MIN_DURATION = 0.6            -- avfoundation needs ~300ms to start; below this = no audio
local MAX_RECORD   = 90             -- watchdog: auto-stop if a key/button release is ever missed

local M = { recording = false, ffmpegTask = nil, fnDown = false, startedAt = 0, lastResult = nil, cancelled = false, ducked = false, preDuckVolume = nil }
-- Where a take is recorded and kept. On M so a spec can point them at a
-- scratch directory instead of the live files.
M.paths = { WAV = WAV, RAW = RAW, TAKES = TAKES_DIR }
-- "starting" from Fn-down until the first audio bytes land, then "listening".
M.micState = "idle"
-- Optional LM Studio pass over each transcript before it is typed. Off by default.
M.llmCleanup = hs.settings.get("dictate.llmCleanup") == true
-- Pins mlx-audio models to one language ("fr"); nil lets each model decide.
M.language = hs.settings.get("dictate.language")

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

-- ── State listeners ─────────────────────────────────────────────────────────
-- Other apps need to know when the microphone is ours. The voice agent is the
-- first: it shares this Mac's one mic and the same STT server on :8765, so
-- while a take is in flight it must neither hear the dictation nor answer it.
--
-- Registered by name and fanned out in registration order, the way
-- lib/audiowatch handles the one system audio callback. Each handler is wrapped
-- so a listener that throws cannot break a take: dictation is the thing the
-- user is actually doing, and a subscriber is not allowed to cost them a
-- sentence.
M.listeners, M.listenerOrder = {}, {}

local function fire(name, active)
  local ok, err = pcall(M.listeners[name], active)
  if not ok then logf("[state] listener %s failed: %s", name, tostring(err)) end
end

-- Registering under a name that is already taken replaces that handler rather
-- than stacking a second one, so a Hammerspoon reload cannot double up.
--
-- The immediate call is wrapped like every other one: apps/voice_agent
-- subscribes at load time, and a POST that throws there would otherwise abort
-- the require and take the rest of that app's wiring with it.
function M.onState(name, fn)
  if not M.listeners[name] then M.listenerOrder[#M.listenerOrder + 1] = name end
  M.listeners[name] = fn
  fire(name, M.recording)   -- a late subscriber starts in sync
end

-- Unsubscribe. apps/voice_agent calls this when its own context comes apart:
-- a listener left registered would keep POSTing holds at a daemon that is no
-- longer being supervised, and keep the agent deaf with nothing to release it.
function M.offState(name)
  if not M.listeners[name] then return end
  M.listeners[name] = nil
  for i, n in ipairs(M.listenerOrder) do
    if n == name then table.remove(M.listenerOrder, i); break end
  end
end

-- The one place M.recording is written. `active` is true from the first frame
-- of capture until the transcript is delivered or the take is dropped, because
-- that whole window is when the mic, the STT server and the cursor are ours —
-- not just the capture. Writing the same value again fires nothing.
local function setRecording(active)
  if M.recording == active then return end
  M.recording = active
  for _, name in ipairs(M.listenerOrder) do fire(name, active) end
end

-- Earcon player: hs.sound is non-blocking, so calling this from startRecording
-- does NOT delay ffmpeg spawn. Failures are swallowed on purpose — a missing
-- .aiff must never break the dictation path. Sounds are cached after first load
-- so subsequent triggers are effectively free.
-- Each cached sound is one context effect, so disposing mid-cue stops it. A
-- sound that will not load is cached as `false` so a missing .aiff is looked
-- for once rather than on every take.
local _earconCache = {}
local function _loadSound(key, fallback)
  if _earconCache[key] ~= nil then return _earconCache[key] or nil end
  local snd = ctx:sound(key)
  -- /System/Library/Sounds/<name>.aiff: hs.sound.getByName occasionally misses
  -- a freshly-registered system sound, and the file is there either way.
  if not snd and fallback then snd = ctx:sound(fallback) end
  _earconCache[key] = snd or false
  return snd or nil
end
local _earconPlayer = {
  system = function(name, volume)
    local snd = _loadSound(name, "/System/Library/Sounds/" .. name .. ".aiff")
    if not snd then return end
    pcall(function() snd:volume(volume); snd:stop(); snd:play() end)
  end,
  file = function(path, volume)
    local snd = _loadSound(path); if not snd then return end
    pcall(function() snd:volume(volume); snd:stop(); snd:play() end)
  end,
}
-- kind: "start" (mic just began), "stop" (recording ended, transcribing).
local function playEarcon(kind)
  local ok, err = pcall(earcon.play, EARCONS_CFG, kind, _earconPlayer)
  if not ok then logf("[earcon] play(%s) failed: %s", tostring(kind), tostring(err)) end
end

M.menu = ctx:tile("Dictation")
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
-- Whichever model is selected is the only one loaded: the warm server is
-- relaunched with it on every switch, the old process killed first so its
-- memory is back before the new model loads. Which backend runs a model is read
-- off the model's own config.json, never its name (table in lib/stt_server):
--   • a NeMo `target` (the parakeet family) → parakeet-mlx, the only backend
--     that streams, so these are the only models with a live preview
--   • a `model_type` mlx-audio implements → mlx-audio, loaded once in the same
--     server and transcribing the whole WAV on release
local HF_HUB = os.getenv("HOME") .. "/.cache/huggingface/hub"

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
-- a "parakeet" marker for NeMo configs. sttServer.engineFor then takes the first
-- type it recognises, so a nested `qwen3_asr_audio_encoder` can never decide a backend.
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
    local engine = sttServer.engineFor(types)
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

-- The warm server runs the selected model and nothing else — M.serverModel is
-- always the same entry as the selection, set again on every switch.
local _sel = initModel()
M.engine      = _sel.engine           -- "parakeet" (streams) | "mlxa" (batch)
M.stream      = _sel.stream           -- live preview?
M.selectedId  = _sel.id               -- for the menu checkmark
M.modelName   = _sel.name
M.modelSize   = _sel.sizeStr          -- resident-memory footprint (e.g. "2.3 GB")
M.serverModel = _sel                  -- what parakeet_server.py loads
M.menu:setTooltip("Dictate · " .. M.modelName .. " · " .. (M.modelSize or "?") .. " · mic: " .. (M.micName or "?"))

-- Floating HUD at screen center
local function showHUD(label, dotColor)
  local f = hs.screen.mainScreen():frame()
  local w, h = 260, 70
  local x = f.x + (f.w - w) / 2
  local y = f.y + (f.h - h) / 2
  -- Named, so asking for it again takes the previous one down: three of these
  -- are drawn per take and a stack of them would float over every space.
  M.hud, M.hudRelease = ctx:canvas("hud", {x = x, y = y, w = w, h = h})
  M.hud:behavior({"canJoinAllSpaces", "stationary"})
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
  if M.hudRelease then M.hudRelease() end
  M.hud, M.hudRelease = nil, nil
end

-- Single centered notification that always replaces the previous one.
-- Avoids hs.alert.show's bottom-stacked behavior so the user sees one message at a time.
local function notify(text, seconds)
  if M.notifyTimer then M.notifyTimer(); M.notifyTimer = nil end
  local f = hs.screen.mainScreen():frame()
  local w, h = 420, 56
  local x = f.x + (f.w - w) / 2
  local y = f.y + (f.h - h) / 2
  -- The name is what makes this replace rather than stack: one message on
  -- screen at a time is the whole point of not using hs.alert here.
  M.notify, M.notifyRelease = ctx:canvas("notify", {x = x, y = y, w = w, h = h})
  M.notify:behavior({"canJoinAllSpaces", "stationary"})
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
  -- Held as the context's release, so the cancel above stops the timer and
  -- hands the effect back in one call.
  local _, stop = ctx:after(seconds or 1.6, function()
    if M.notifyRelease then M.notifyRelease() end
    M.notify, M.notifyRelease, M.notifyTimer = nil, nil, nil
  end)
  M.notifyTimer = stop
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
    M.preview, M.previewRelease = ctx:canvas("preview", { x = x, y = y, w = w, h = h })
    M.preview:behavior({ "canJoinAllSpaces", "stationary" })
    M.preview:level(hs.canvas.windowLevels.overlay)
  else
    M.preview:frame({ x = x, y = y, w = w, h = h })
  end
  M.preview:replaceElements(
    { type = "rectangle", action = "fill",
      fillColor = { red = 0, green = 0, blue = 0, alpha = 0.85 },
      roundedRectRadii = { xRadius = 16, yRadius = 16 } },
    -- Amber until the mic delivers audio, red once it is really recording.
    { type = "circle", action = "fill",
      fillColor = (M.micState == "starting") and COLOR_PROC or COLOR_REC,
      center = { x = 30, y = 30 }, radius = 9 },
    { type = "text",
      text = shown and previewStyled(shown) or ((M.micState == "starting") and "Starting…" or "Listening…"),
      textColor = COLOR_SETTLED, textSize = PREVIEW_SIZE,
      frame = { x = PREVIEW_PAD, y = PREVIEW_TOP, w = innerW, h = h - PREVIEW_TOP - 8 } }
  )
  M.preview:show()
end

local function hideLivePreview()
  if M.previewPoll then M.previewPoll() end
  M.previewTimer, M.previewPoll = nil, nil
  if M.previewRelease then M.previewRelease() end
  M.preview, M.previewRelease = nil, nil
end

-- Debug handles so the preview can be driven from `hs -c` without a mic.
-- Through the context, so switching the plugin off takes the names back
-- instead of leaving three commands that answer and no longer work.
ctx:global("dictatePreview", showLivePreview)
ctx:global("dictateHide", hideLivePreview)
ctx:global("dictateFrame", function()
  if not M.preview then return "nil" end
  local fr = M.preview:frame()
  return string.format("x=%d y=%d w=%d h=%d", fr.x, fr.y, fr.w, fr.h)
end)

local function readFile(p)
  local f = io.open(p, "r"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

local function fileSize(p)
  local f = io.open(p, "rb"); if not f then return 0 end
  local n = f:seek("end"); f:close(); return n or 0
end

-- Put the transcript at the cursor as real keystrokes, and leave it on the
-- clipboard behind them.
--
-- ⌘V used to do this, and it failed silently in exactly the places dictation
-- earns its keep: a terminal in bracketed-paste mode, a remote desktop or
-- Citrix session, a kiosk form that only listens for keydown, anything that
-- strips a paste for "security". The key went out, nothing arrived, and half a
-- second later the clipboard was handed back — so the take was gone with no
-- error anywhere to say so. apps/keystroke_typer sends each character as its own
-- key event on the system event tap, which those same apps cannot tell from a
-- person at the keyboard, and the text appearing as it types is its own receipt.
--
-- The clipboard is not restored afterwards. It holds the transcript until the
-- user copies something else, so ⌘V is there when typing is the wrong answer —
-- a field that rejects synthetic events, or a take typed into the wrong window.
local function deliver(text)
  if not text or text == "" then return end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return end
  hs.pasteboard.setContents(text)

  -- Asked of the registry rather than require()d. plugins.unload clears
  -- package.loaded, so a plain require would re-run apps/keystroke_typer and
  -- bring back a plugin the user switched off in the hub — once per take.
  local typer = plugins.loaded["keystroke_typer"]
  if type(typer) ~= "table" or type(typer.type) ~= "function" then
    logf("[dictate] keystroke typer not loaded — transcript is on the clipboard")
    notify("copied — ⌘V to paste", 1.8)
    return
  end
  -- replace: a run still going belongs to the previous take, and the newest one
  -- is what the user is waiting for. quiet: the HUD already said its piece.
  typer.type(text, { replace = true, quiet = true })
end

-- Duck system audio while the mic is open; unduckNoise puts it back. One duck,
-- one restore — M.ducked is what keeps them paired. Without it a second duck
-- would save the already-ducked 30 as the "original" volume, and from then on
-- every restore would hand back 30 instead of what the user was listening at.
local DUCK_LEVEL = 30
local function duckNoise()
  if M.ducked then logf("[duck] already ducked — keeping saved volume"); return end
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev then logf("[duck] no output device"); return end
  local vol = dev:volume()
  if not vol then logf("[duck] output device reports no volume"); return end
  M.preDuckVolume, M.ducked = vol, true
  dev:setVolume(DUCK_LEVEL)
  logf("[duck] volume %.1f → %d", vol, DUCK_LEVEL)
end

-- The single restore point. Every exit from a take routes here — transcript
-- delivered, chord cancel, tap too short, transcription error — so calling it is
-- always safe and never double-restores. State is cleared before the device
-- call so a failing setVolume cannot strand us ducked forever.
local function unduckNoise()
  if not M.ducked then return end
  local vol = M.preDuckVolume
  M.ducked, M.preDuckVolume = false, nil
  local dev = hs.audiodevice.defaultOutputDevice()
  if not dev then logf("[duck] no output device to restore to"); return end
  dev:setVolume(vol)
  logf("[duck] restored %.1f", vol)
end

-- Optional clean-up through LM Studio's OpenAI-compatible server. Calls
-- done(text) exactly once: with the cleaned text, or with the raw text on any
-- miss — LM Studio down, no model loaded, a bad reply, or no answer within
-- llm.TIMEOUT seconds. A reply that lands after the timeout is ignored.
local function polish(text, done)
  local finished = false
  local function finish(result, why)
    if finished then return end
    finished = true
    if M.polishTimer then M.polishTimer(); M.polishTimer = nil end
    if why then logf("[llm] %s; typing the raw transcript", why) end
    if not M.recording then hideHUD() end
    done(result or text)
  end
  showHUD("Cleaning up…", COLOR_PROC)
  local _, stopPolish = ctx:after(llm.TIMEOUT, function()
    M.polishTimer = nil
    finish(nil, "no reply in " .. llm.TIMEOUT .. "s")
  end)
  M.polishTimer = stopPolish
  hs.http.asyncGet(llm.BASE .. "/api/v0/models", nil, function(status, body, _)
    if finished then return end
    local ok, decoded = pcall(hs.json.decode, body or "")
    local model = (status == 200 and ok) and llm.pickModel(decoded) or nil
    if not model then return finish(nil, "no LM Studio model loaded (status " .. tostring(status) .. ")") end
    hs.http.asyncPost(llm.BASE .. "/v1/chat/completions", hs.json.encode(llm.request(text, model)),
      { ["Content-Type"] = "application/json" },
      function(st, b, _)
        if finished then return end
        local ok2, dec = pcall(hs.json.decode, b or "")
        local cleaned = (st == 200 and ok2) and llm.parse(dec, text) or nil
        if not cleaned then return finish(nil, "unusable reply from " .. model .. " (status " .. tostring(st) .. ")") end
        logf("[llm] %s: %d → %d chars", model, #text, #cleaned)
        finish(cleaned)
      end)
  end)
end

-- Shared tail: reset UI, clean the transcript, then type it at the cursor.
local function finishTranscript(out)
  setIcon("○"); hideHUD(); hideLivePreview(); setRecording(false)
  unduckNoise()
  logf("[dictate] result: %s", tostring(out))
  if not out or out == "" then
    notify("no transcription (see console)", 1.6)
    return
  end
  -- Stock subtitle lines that stand for silence (Whisper-style batch models
  -- only; Parakeet doesn't invent them), and a sentence looped on trailing
  -- silence (lib/transcript_filter).
  local text = tfilter.clean(out, { stockLines = M.engine ~= "parakeet" })
  if text == "" then
    logf("[dictate] dropped as a silence hallucination: %q", out)
    notify("nothing heard", 1.4)
    return
  end
  M.lastResult = text
  if not M.llmCleanup then deliver(text); return end
  polish(text, function(final)
    M.lastResult = final
    deliver(final)
  end)
end

-- Cold fallback for parakeet models only: spawn the parakeet-mlx CLI on the same
-- snapshot when the warm server misses (not up yet, mid-restart, error).
local function transcribeCLI()
  os.remove(TXT); os.remove("/private/tmp/hs-dictate.txt")
  local task, done
  task, done = ctx:task(PARAKEET,
    function(exitCode, stdOut, stdErr)
      done()
      logf("[dictate] parakeet(CLI) exit=%d", exitCode)
      if stdErr and stdErr ~= "" then logf("[dictate] stderr: %s", stdErr) end
      finishTranscript(readFile(TXT) or readFile("/private/tmp/hs-dictate.txt"))
    end,
    {"--model", M.serverModel.path, "--output-dir", "/tmp", "--output-format", "txt", M.paths.WAV}
  )
  task:setEnvironment({ HOME = os.getenv("HOME"), PATH = "/opt/homebrew/bin:/usr/bin:/bin" })
  task:start()
end

-- Batch path: POST the finished WAV's path to the warm server, which holds the
-- selected model whatever its engine. This is every take on an mlx-audio model
-- (no live preview: transcribed after release; the language is the model's
-- own default unless pinned in the menu) and the fallback for a parakeet stream that missed. On a miss
-- a parakeet model falls back to its CLI; an mlx-audio model reports the error
-- rather than cold-loading a second copy of itself.
local function transcribe()
  setIcon("…")
  showHUD("Transcribing…", COLOR_PROC)
  hs.http.asyncPost(STT_URL, M.paths.WAV, { ["Content-Type"] = "text/plain" },
    function(status, body, _)
      if status == 200 and body and body ~= "" and not body:match("^__ERROR__") then
        logf("[dictate] server ok len=%d", #body)
        finishTranscript(body)
      elseif M.engine == "parakeet" then
        logf("[dictate] server miss (status=%s), CLI fallback", tostring(status))
        transcribeCLI()
      else
        logf("[dictate] server miss (status=%s) on %s: %s", tostring(status), M.modelName, tostring(body))
        finishTranscript(nil)
      end
    end)
end

-- ── Recent takes ────────────────────────────────────────────────────────────
-- Every take that reaches transcription is copied into TAKES, newest takes.KEEP
-- kept, so the menu can run one again through another model.
local function takeNames()
  local names = {}
  pcall(function()
    for f in hs.fs.dir(M.paths.TAKES) do names[#names + 1] = f end
  end)
  return names
end

local function saveTake()
  local data = readFile(M.paths.WAV)
  if not data or data == "" then logf("[takes] no WAV to keep"); return end
  if hs.fs.mkdir then
    pcall(hs.fs.mkdir, M.paths.TAKES:match("^(.*)/[^/]+$"))
    pcall(hs.fs.mkdir, M.paths.TAKES)
  end
  local name = takes.name(os.time())
  local f = io.open(M.paths.TAKES .. "/" .. name, "wb")
  if not f then logf("[takes] cannot write %s", M.paths.TAKES); return end
  f:write(data); f:close()
  local _, remove = takes.prune(takeNames(), takes.KEEP)
  for _, old in ipairs(remove) do os.remove(M.paths.TAKES .. "/" .. old) end
  logf("[takes] kept %s (%d bytes), rotated out %d", name, #data, #remove)
end

-- ── Mic-ready indicator ─────────────────────────────────────────────────────
-- avfoundation takes ~300ms to open the mic, and words spoken before that are
-- lost. The preview says "Starting…" (amber dot) from Fn-down and turns to
-- "Listening…" (red dot) only once ffmpeg has written audio bytes.
local MIC_POLL = 0.05

local function stopReadyPoll()
  if M.readyRelease then M.readyRelease() end
  M.readyTimer, M.readyRelease = nil, nil
end

local function startReadyPoll()
  stopReadyPoll()
  M.micState = "starting"
  M.readyTimer, M.readyRelease = ctx:timer(MIC_POLL, function()
    if not M.recording then stopReadyPoll(); return end
    if fileSize(M.paths.RAW) > 0 then
      stopReadyPoll()
      M.micState = "listening"
      logf("[dictate] mic live after %.2fs", hs.timer.secondsSinceEpoch() - M.startedAt)
      showLivePreview(M.lastPartial)
    end
  end)
end

-- Forward decl so startRecording's watchdog can call stopRecording (defined below).
local stopRecording

local function startRecording()
  -- Fire the "listening" cue FIRST so it lands before ffmpeg spins up. hs.sound
  -- is non-blocking, so this adds no measurable latency to mic capture.
  playEarcon("start")
  os.remove(M.paths.WAV); os.remove(M.paths.RAW)
  setRecording(true)
  M.batchFinish = false
  M.keepTake = false
  M.lastPartial = nil
  M.startedAt = hs.timer.secondsSinceEpoch()
  setIcon("●")
  hideLivePreview()
  startReadyPoll()
  showLivePreview(nil)   -- "Starting…" until audio arrives, then "Listening…"
  duckNoise()
  logf("[dictate] recording start (mic=%q, engine=%s)", M.micName, M.engine)
  -- Two outputs from one capture: WAV for batch transcription (server /transcribe),
  -- plus a headerless s16le PCM file the server tails live (parakeet models).
  local ffmpeg, stopFfmpeg
  ffmpeg, stopFfmpeg = ctx:task(FFMPEG, function(code, _, err)
    stopFfmpeg()
    if M.ffmpegTask == ffmpeg then M.ffmpegTask, M.ffmpegRelease = nil, nil end
    logf("[dictate] ffmpeg exit=%d", code)
    if code ~= 0 and err and err ~= "" then logf("[dictate] ffmpeg stderr: %s", err) end
    -- The WAV is finalized now: keep a copy before anything reads or replaces it.
    if M.keepTake then M.keepTake = false; saveTake() end
    -- Non-streaming engine: WAV is finalized now, so kick off the batch transcribe.
    if M.batchFinish then M.batchFinish = false; transcribe() end
  end,
    {"-y", "-f", "avfoundation", "-i", ":" .. M.micName,
     "-ar", "16000", "-ac", "1", M.paths.WAV,
     "-ar", "16000", "-ac", "1", "-f", "s16le", "-flush_packets", "1", M.paths.RAW})
  M.ffmpegTask, M.ffmpegRelease = ffmpeg, stopFfmpeg
  M.ffmpegTask:start()
  -- Watchdog: never hold the mic open forever if a release event is missed
  -- (e.g. a spurious headset PLAY press, or a swallowed Fn key-up).
  if M.watchdog then M.watchdog() end
  local _, stopWatchdog = ctx:after(MAX_RECORD, function()
    M.watchdog = nil
    if M.recording then
      logf("[dictate] watchdog fired after %ds — auto-stopping (missed release?)", MAX_RECORD)
      notify("recording auto-stopped after " .. MAX_RECORD .. "s", 2.2)
      stopRecording()
    end
  end)
  M.watchdog = stopWatchdog
  if M.stream then
    -- Begin streaming this recording into the warm model as it's captured.
    hs.http.asyncPost(STT_BASE .. "/start", M.paths.RAW, {}, function(status, _, _)
      if status ~= 200 then logf("[dictate] /start status=%s (will batch-fallback)", tostring(status)) end
    end)
    -- Poll the live hypothesis and show it growing in the preview panel.
    M.previewTimer, M.previewPoll = ctx:timer(0.2, function()
      hs.http.asyncGet(STT_BASE .. "/partial", nil, function(status, body, _)
        if M.recording and status == 200 and body and body ~= "" then
          M.lastPartial = body
          showLivePreview(body)
        end
      end)
    end)
  end
end

local function cancelStream()
  hs.http.asyncPost(STT_BASE .. "/cancel", "", {}, function() end)
end

function stopRecording()
  -- Fire the "captured" cue immediately on release, before terminating ffmpeg
  -- or dispatching transcription. Distinguishable from the start cue by ear.
  playEarcon("stop")
  if M.watchdog then M.watchdog(); M.watchdog = nil end
  local dur = hs.timer.secondsSinceEpoch() - M.startedAt
  -- For batch engines, flag the finish BEFORE terminating ffmpeg so its exit
  -- callback (which fires once the WAV is finalized) runs transcribe().
  M.batchFinish = (not M.stream) and (not M.cancelled) and (dur >= MIN_DURATION)
  M.keepTake = (not M.cancelled) and (dur >= MIN_DURATION)
  stopReadyPoll()
  M.micState = "idle"
  -- Through the release: it terminates ffmpeg AND stops the context holding a
  -- handle to a capture that is over.
  if M.ffmpegRelease then M.ffmpegRelease() end
  M.ffmpegTask, M.ffmpegRelease = nil, nil
  if M.previewPoll then M.previewPoll() end
  M.previewTimer, M.previewPoll = nil, nil
  if M.cancelled then
    logf("[dictate] cancelled by chord")
    M.cancelled = false; setIcon("○"); hideHUD(); hideLivePreview(); setRecording(false); unduckNoise()
    if M.stream then cancelStream() end
    return
  end
  if dur < MIN_DURATION then
    logf("[dictate] tap too short (%.2fs), ignored", dur)
    setIcon("○"); hideHUD(); hideLivePreview(); setRecording(false); unduckNoise()
    if M.stream then cancelStream() end
    return
  end
  setIcon("…"); showHUD("Transcribing…", COLOR_PROC)
  if M.stream then
    -- ffmpeg already got SIGTERM; tell the server to drain the last audio and
    -- return the transcript. The model has consumed this clip live, so only the
    -- final <1s remains. Fall back to batch (server, then CLI) on miss.
    hs.http.asyncPost(STT_BASE .. "/finish", "", {}, function(status, body, _)
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

-- Launch the warm server on M.serverModel, under that engine's interpreter. The
-- exit callback only clears M.serverTask if it is still this task: a killed
-- server reports its exit after its replacement has already started.
local function launchServer()
  local m = M.serverModel
  local l, why = sttServer.launch(m, {
    parakeetPy = PARAKEET_PY, mlxaPy = MLXA_PY, server = STT_SERVER,
    home = os.getenv("HOME"), port = STT_PORT, language = M.language,
  })
  if not l then
    logf("[server] cannot launch: %s", tostring(why))
    notify("STT server not started: " .. tostring(why), 2.8)
    return
  end
  local task, done
  task, done = ctx:task(l.python,
    function(code, _, err)
      logf("[server] exited code=%d err=%s", code, tostring(err))
      done()
      if M.serverTask == task then M.serverTask, M.serverRelease = nil, nil end
    end,
    l.args)
  task:setEnvironment(l.env)
  task:start()
  M.serverTask, M.serverRelease = task, done
  logf("[server] launching warm %s server (%s)", m.engine, m.name or m.id or "?")
end

-- (Re)launch the warm server on M.serverModel. Kills whatever holds :8765 and
-- waits for the port to free before launching, so the previous model's memory
-- is released before the next one loads: never two models resident at once.
-- Also how startup gets rid of a server left over from before a reload.
local function restartServer()
  -- The release terminates the old server and stops the context holding it, so
  -- a model switched five times does not leave five dead handles behind.
  if M.serverRelease then M.serverRelease() end
  M.serverTask, M.serverRelease = nil, nil
  local k, done
  k, done = ctx:task("/bin/sh", function() done(); launchServer() end,
    {"-c", sttServer.freePortCommand(STT_PORT)})
  k:start()
end

restartServer()   -- after a reload: the saved selection, not a default parakeet

-- Reap an orphaned capture: if HS reloads or crashes while recording, its child
-- ffmpeg is reparented to launchd and keeps holding the mic (avfoundation :1)
-- open forever — the persistent orange mic indicator with nothing recording.
-- The WAV path is a unique signature, so this only ever hits our own ffmpeg.
local killStaleFfmpeg = ctx:task("/bin/sh", nil,
  {"-c", "pkill -f 'ffmpeg .*hs-dictate[.]wav' 2>/dev/null; true"})
killStaleFfmpeg:start()

-- Every switch restarts the server on the new model, whatever its engine: the
-- old model is unloaded with its process, and dictation and the voice agent
-- both move to the new one together.
local function setModel(m)
  if M.recording then notify("stop recording before switching model", 1.8); return end
  if m.id == M.selectedId then return end
  M.engine, M.stream, M.selectedId = m.engine, m.stream, m.id
  M.modelName, M.modelSize = m.name, m.sizeStr
  M.serverModel = m
  hs.settings.set("dictate.modelId", m.id)
  M.menu:setTooltip("Dictate · " .. M.modelName .. " · " .. (M.modelSize or "?"))
  logf("[model] switch → %s (engine=%s, %s)", m.name, m.engine, m.sizeStr or "?")
  local sz = " · " .. (m.sizeStr or "?") .. " RAM"
  local kind = m.stream and "" or " · batch (no live preview)"
  notify("Model: " .. m.name .. sz .. kind .. " — loading…", 2.8)
  restartServer()
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

-- Language for mlx-audio models. "Auto" leaves it to the model (Whisper detects
-- it per take); parakeet ignores it. A change restarts the server, because the
-- language is fixed when the model loads.
local LANGUAGES = { { code = nil, name = "Auto" }, { code = "en", name = "English" }, { code = "fr", name = "French" } }

local function setLanguage(code)
  if M.recording then notify("stop recording before switching language", 1.8); return end
  if code == M.language then return end
  M.language = code
  hs.settings.set("dictate.language", code)
  logf("[lang] → %s", tostring(code or "auto"))
  notify("Language: " .. (code or "auto") .. " — reloading model…", 2.2)
  restartServer()
end

local function setLlmCleanup(on)
  M.llmCleanup = on and true or false
  hs.settings.set("dictate.llmCleanup", M.llmCleanup)
  logf("[llm] clean-up %s", M.llmCleanup and "on" or "off")
end

-- Run a kept take through whatever model is loaded now, and put the result on
-- the clipboard rather than typing it: the cursor has moved on since.
local function retranscribe(name)
  local path = M.paths.TAKES .. "/" .. name
  logf("[takes] retranscribe %s with %s", name, tostring(M.modelName))
  notify("Retranscribing with " .. tostring(M.modelName) .. "…", 1.6)
  hs.http.asyncPost(STT_URL, path, { ["Content-Type"] = "text/plain" }, function(status, body, _)
    if status ~= 200 or not body or body:match("^__ERROR__") then
      logf("[takes] retranscribe miss (status=%s): %s", tostring(status), tostring(body))
      notify("retranscribe failed (see console)", 2.0)
      return
    end
    local text = tfilter.clean(body, { stockLines = M.engine ~= "parakeet" })
    if text == "" then notify("nothing heard in that take", 1.6); return end
    M.lastResult = text
    hs.pasteboard.setContents(text)
    local preview = text:sub(1, 60)
    if #text > 60 then preview = preview .. "…" end
    notify("copied: " .. preview, 2.0)
  end)
end

local function takesMenu()
  local kept = takes.prune(takeNames(), takes.KEEP)
  if #kept == 0 then return { { title = "No takes kept yet", disabled = true } } end
  local items = {}
  for _, name in ipairs(kept) do
    items[#items + 1] = { title = takes.label(name), fn = function() retranscribe(name) end }
  end
  return items
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
  local langItems = {}
  for _, l in ipairs(LANGUAGES) do
    langItems[#langItems + 1] = { title = l.name, checked = (l.code == M.language),
      fn = function() setLanguage(l.code) end }
  end
  items[#items + 1] = { title = "Language (batch models): " .. (M.language or "auto"), menu = langItems }
  items[#items + 1] = { title = "Clean up with LM Studio", switch = true, checked = M.llmCleanup,
    fn = function() setLlmCleanup(not M.llmCleanup) end }
  items[#items + 1] = { title = "Retranscribe recent take", menu = takesMenu() }
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

-- Watch Fn modifier flag transitions. Through the context, because this tap
-- sees every key on the machine: one left running after the plugin is gone
-- swallows Fn for every app until a reload.
M.flagWatcher = ctx:eventtap(hs.eventtap.event.types.flagsChanged, function(e)
  local flags = e:getFlags()
  local nowDown = flags.fn == true
  if nowDown ~= M.fnDown then
    M.fnDown = nowDown
    if nowDown then startRecording() else stopRecording() end
  end
  return false
end)

-- Chord detection while holding Fn:
--   Fn+C  cancel current recording and recall last
--   Fn+S  speak the current selection through the TTS queue (no dictation)

M.keyWatcher = ctx:eventtap(hs.eventtap.event.types.keyDown, function(e)
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

-- Tap watchdog. macOS switches a global event tap off without notice — after
-- sleep, when a callback runs slow under load, or while secure input is on —
-- and Fn then does nothing until a reload. Check every TAP_CHECK seconds and on
-- wake, restart whichever tap is off (lib/tap_guard), and if Fn's release was
-- lost while it was off, end the take the user already let go of.
local TAP_CHECK = 2

local function rearmTaps(why)
  local names = tapGuard.rearm({ flags = M.flagWatcher, keys = M.keyWatcher })
  if #names == 0 then return end
  logf("[tap] re-armed %s (%s)", table.concat(names, ", "), why)
  local ok, mods = pcall(hs.eventtap.checkKeyboardModifiers)
  if ok and tapGuard.missedRelease(M.fnDown, mods) then
    logf("[tap] Fn was released while the tap was off; ending the take")
    M.fnDown = false
    if M.recording then stopRecording() end
  end
end
M.rearmTaps = rearmTaps

M.tapTimer = ctx:timer(TAP_CHECK, function() rearmTaps("check") end)

-- The `if hs.caffeinate` guard that used to wrap this is gone: ctx:watcher
-- hands back nothing on a machine (or in a spec) that has no such watcher, so
-- the plugin asks for the one it wants and carries on either way. The event
-- constants are read inside the handler, which only ever runs where there was
-- a watcher to read them off.
M.wakeWatcher = ctx:watcher("caffeinate", function(event)
  local W = hs.caffeinate.watcher
  if event == W.systemDidWake or event == W.screensDidUnlock then rearmTaps("wake") end
end)

-- Keep the mic list fresh even without opening the menu: a headset that
-- (dis)connects after launch retriggers discovery, and if the *selected* mic
-- disappears we say so instead of silently recording nothing.
-- Through ctx:watcher("audio", …), which is lib/audiowatch: the system watcher
-- has room for one callback only, so apps register by name and the registry
-- fans it out. The name is what dispose gives back.
ctx:watcher("audio", "dictation", function()
  MICS = discoverMics()
  local present = false
  for _, m in ipairs(MICS) do if m.name == M.micName then present = true; break end end
  if not present then
    logf("[mic] selected %q disconnected", tostring(M.micName))
    notify("Mic '" .. tostring(M.micName) .. "' disconnected — pick another", 2.8)
  end
end)

M.isRecording = function() return M.recording end
-- Start or stop a take from something other than Fn (e.g. a Shokz chord). The
-- transcript types at the cursor, the same as a Fn take.
M.toggle = function()
  if M.recording then stopRecording() else startRecording() end
end

notify("Dictate ready · hold Fn or MFB · Fn+C recall · Fn+S speak selection", 2.0)
logf("[dictate] init complete")

-- Switch the plugin off: the Fn tap, the warm server and its model, any capture
-- in flight, the overlays, the mic watcher, the debug globals and the tile.
-- Hammerspoon's own volume is put back first, because a plugin disposed mid-take
-- would otherwise leave the user's output ducked at 30 with nothing left that
-- knows what it was.
function M.dispose()
  if M.recording then M.cancelled = true; stopRecording() end
  unduckNoise()
  ctx:dispose()
  M.listeners, M.listenerOrder = {}, {}
  _earconCache = {}
end

return M
