-- Dictation: hold Fn = record, release = transcribe & paste at cursor.
-- Pipeline: ffmpeg → parakeet-mlx → pbpaste → ⌘V

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
-- mlx-audio runtime for non-streaming engines (Qwen3-ASR). Separate from the
-- parakeet server: it cold-loads per call and has no live-preview streaming.
local MLXA_PY   = os.getenv("HOME") .. "/.local/share/uv/tools/mlx-audio/bin/python"
local QWEN3_OUT = "/tmp/hs-qwen3"
local MIN_DURATION = 0.6            -- avfoundation needs ~300ms to start; below this = no audio
local MAX_RECORD   = 90             -- watchdog: auto-stop if a key/button release is ever missed
local ZELLIJ = os.getenv("HOME") .. "/.cargo/bin/zellij"
local SUPERVISOR_SESSION = "Orchestrator"
local ZELLIJ_ENV = { HOME = os.getenv("HOME"), PATH = "/opt/homebrew/bin:/usr/bin:/bin:/usr/bin:/Users/pierre-mikel/.cargo/bin" }
-- Keepalive: a headless zellij client kept attached to the Orchestrator so that
-- `zellij action write-chars` always has a client to route keystrokes to. zellij
-- 0.44 silently DROPS writes to a session with zero attached clients — which is
-- why sends only worked while the Orchestrator was the session on screen.
local PYTHON3   = "/usr/bin/python3"
local KEEPALIVE = os.getenv("HOME") .. "/.hammerspoon/apps/dictation/zellij_keepalive.py"
local KEEPALIVE_CHECK = 20   -- seconds between "is a client still attached?" re-checks

local M = { recording = false, ffmpegTask = nil, fnDown = false, playDown = false, startedAt = 0, lastResult = nil, cancelled = false, supervisor = false }

-- File logger so we can debug Fn+O routing without staring at the HS console.
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

M.menu = hs.menubar.new()
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
-- Discover every parakeet model cached under the HF hub. The menubar picks one;
-- switching just relaunches the warm server against the chosen snapshot (~3.5s).
local HF_HUB = os.getenv("HOME") .. "/.cache/huggingface/hub"

-- Disk footprint of a cached snapshot ≈ resident memory the model needs once
-- loaded (weights dominate; tokenizer/config are KB). Shown in the menu so a
-- switch makes its RAM cost obvious.
local function humanSize(kb)
  if not kb or kb <= 0 then return "?" end
  local gb = kb / 1048576
  if gb >= 1 then return string.format("%.1f GB", gb) end
  return string.format("%d MB", math.floor(kb / 1024 + 0.5))
end

local function prettyName(id)
  local map = {
    ["parakeet-tdt-0.6b-v3"] = "v3 · multilingual",
    ["parakeet-tdt-0.6b-v2"] = "v2 · English",
    ["parakeet-tdt-1.1b"]    = "1.1b · English (larger)",
    ["Qwen3-ASR-1.7B-4bit"]  = "Qwen3-ASR · multilingual",
  }
  local base = id:match("([^/]+)$") or id
  return map[base] or base
end

-- Returns { {id=, path=, name=, engine=, stream=}, ... } for cached models.
-- engine "parakeet" → warm streaming server (live preview); "qwen3" → mlx-audio
-- batch (transcribe on release, no preview).
local function discoverModels()
  local cmd = 'for d in "' .. HF_HUB .. '"/models--mlx-community--parakeet-* '
    .. '"' .. HF_HUB .. '"/models--mlx-community--Qwen3-ASR*; do '
    .. '[ -d "$d" ] || continue; '
    .. 's=$(ls -d "$d"/snapshots/*/ 2>/dev/null | head -1); '
    .. '[ -e "${s%/}/model.safetensors" ] || continue; '
    .. 'sz=$(du -sL -k "${s%/}" 2>/dev/null | cut -f1); '
    .. 'printf "%s\\t%s\\t%s\\n" "$(basename "$d")" "${s%/}" "${sz:-0}"; '
    .. 'done'
  local out = hs.execute(cmd) or ""
  local models = {}
  for dir, path, kb in out:gmatch("([^\t\n]+)\t([^\t\n]+)\t([^\t\n]+)") do
    local id = dir:gsub("^models%-%-", ""):gsub("%-%-", "/")  -- → mlx-community/…
    local isParakeet = id:find("parakeet", 1, true) ~= nil
    local sizeKB = tonumber(kb) or 0
    models[#models + 1] = {
      id = id, path = path, name = prettyName(id),
      engine = isParakeet and "parakeet" or "qwen3",
      stream = isParakeet,
      sizeKB = sizeKB, sizeStr = humanSize(sizeKB),
    }
  end
  table.sort(models, function(a, b)       -- streaming models first, then v3 before v2
    if a.stream ~= b.stream then return a.stream end
    return a.id > b.id
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
-- model is selected, and kept ready for when you switch back from Qwen3).
local function defaultParakeet()
  for _, m in ipairs(MODELS) do if m.engine == "parakeet" and m.path == MODEL_PATH then return m end end
  for _, m in ipairs(MODELS) do if m.engine == "parakeet" then return m end end
  return { path = MODEL_PATH, name = "v3 · multilingual" }
end

local _sel = initModel()
M.engine     = _sel.engine            -- "parakeet" | "qwen3"
M.stream     = _sel.stream            -- live preview?
M.selectedId = _sel.id                -- for the menu checkmark
M.modelName  = _sel.name
M.modelSize  = _sel.sizeStr           -- resident-memory footprint (e.g. "2.3 GB")
M.modelRepo  = _sel.id                -- mlx-audio --model arg (qwen3)
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

-- ── Orchestrator keepalive ───────────────────────────────────────────────────
-- Hold a headless zellij client attached to the Orchestrator at all times so
-- write-chars/write below always have a client to land on. zellij_keepalive.py
-- attaches an OVERSIZED client; zellij sizes a shared session to its smallest
-- client, so it never shrinks the user's own view. Self-healing: hs.task's exit
-- callback clears the handle and the periodic watchdog (see init) respawns it,
-- e.g. after the Orchestrator session is restarted.
local function keepaliveRunning()
  return M.keepalive ~= nil and M.keepalive:isRunning()
end

local function ensureSupervisorClient()
  if keepaliveRunning() then return end
  M.keepalive = hs.task.new(PYTHON3, function(code, _, err)
    if code ~= 0 and err and err ~= "" then
      logf("[keepalive] exited code=%d err=%s", code, tostring(err))
    end
    M.keepalive = nil
  end, { KEEPALIVE, SUPERVISOR_SESSION })
  M.keepalive:setEnvironment(ZELLIJ_ENV)
  M.keepalive:start()
  logf("[keepalive] launched client for %s", SUPERVISOR_SESSION)
end

-- Write the transcript straight into the Orchestrator zellij pane, then Enter.
-- Skips the event queue: text appears in the Claude Code prompt and submits.
local function sendToSupervisor(text)
  if not text or text == "" then return end
  -- Final guard: make sure a client is attached before we write (idempotent —
  -- a no-op when the keepalive is already up, which it normally is).
  ensureSupervisorClient()
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return end

  local writeTask = hs.task.new(ZELLIJ,
    function(code, _, err)
      if code ~= 0 then
        logf("[supervisor] zellij write-chars exit=%d err=%s", code, tostring(err))
        notify("zellij write-chars failed", 2.4)
        return
      end
      local enterTask = hs.task.new(ZELLIJ,
        function(c2, _, e2)
          if c2 ~= 0 then
            logf("[supervisor] zellij write 13 exit=%d err=%s", c2, tostring(e2))
          end
        end,
        {"--session", SUPERVISOR_SESSION, "action", "write", "13"})
      enterTask:setEnvironment(ZELLIJ_ENV)
      enterTask:start()
    end,
    {"--session", SUPERVISOR_SESSION, "action", "write-chars", text})
  writeTask:setEnvironment(ZELLIJ_ENV)
  writeTask:start()

  logf("[supervisor] voice → zellij len=%d preview=%q", #text, text:sub(1, 60))
  local preview = text:sub(1, 60); if #text > 60 then preview = preview .. "…" end
  notify("→ Orchestrator (voice): " .. preview, 1.8)
end

-- Shared tail: reset UI, then paste or route to the Orchestrator.
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
    logf("[dictate] route: %s", M.supervisor and "supervisor" or "paste")
    if M.supervisor then
      M.supervisor = false
      sendToSupervisor(out)
    else
      paste(out)
    end
  else
    M.supervisor = false
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

-- Batch path for non-streaming engines (Qwen3-ASR via mlx-audio). No live
-- preview: the finished WAV is transcribed after release. No --language flag, so
-- the model auto-detects (English/French). Cold-loads the model each call.
local function transcribeQwen3()
  os.remove(QWEN3_OUT .. ".txt")
  logf("[dictate] qwen3 batch transcribe (%s)", M.modelRepo)
  local t = hs.task.new(MLXA_PY, function(code, _, err)
    if code ~= 0 and err and err ~= "" then logf("[dictate] qwen3 stderr: %s", err) end
    finishTranscript(readFile(QWEN3_OUT .. ".txt"))
  end, {"-m", "mlx_audio.stt.generate", "--model", M.modelRepo,
        "--audio", WAV, "--output-path", QWEN3_OUT, "--format", "txt"})
  t:setEnvironment({ HOME = os.getenv("HOME"), PATH = "/opt/homebrew/bin:/usr/bin:/bin" })
  t:start()
end

-- Forward decl so startRecording's watchdog can call stopRecording (defined below).
local stopRecording

local function startRecording()
  os.remove(WAV); os.remove(RAW)
  -- Pre-warm the Orchestrator client: if the keepalive is down (e.g. the session
  -- was just restarted), relaunch it now so a client is attached by the time this
  -- recording finishes and (maybe) routes to the Orchestrator. Idempotent.
  ensureSupervisorClient()
  M.recording = true
  M.qwenFinish = false
  M.startedAt = hs.timer.secondsSinceEpoch()
  setIcon("●")
  hideLivePreview()
  showLivePreview(nil)   -- "Listening…" (stays put for batch engines: no partials)
  duckNoise()
  logf("[dictate] recording start (mic=%q, engine=%s)", M.micName, M.engine)
  -- Two outputs from one capture: WAV for batch transcription (CLI / Qwen3),
  -- plus a headerless s16le PCM file the parakeet server tails live.
  M.ffmpegTask = hs.task.new(FFMPEG, function(code, _, err)
    logf("[dictate] ffmpeg exit=%d", code)
    if code ~= 0 and err and err ~= "" then logf("[dictate] ffmpeg stderr: %s", err) end
    -- Non-streaming engine: WAV is finalized now, so kick off the batch transcribe.
    if M.qwenFinish then M.qwenFinish = false; transcribeQwen3() end
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
  if M.watchdog then M.watchdog:stop(); M.watchdog = nil end
  local dur = hs.timer.secondsSinceEpoch() - M.startedAt
  -- For batch engines, flag the finish BEFORE terminating ffmpeg so its exit
  -- callback (which fires once the WAV is finalized) runs transcribeQwen3.
  M.qwenFinish = (not M.stream) and (not M.cancelled) and (dur >= MIN_DURATION)
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
  -- Batch engine: handled by the ffmpeg exit callback (M.qwenFinish) once WAV is finalized.
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

-- Reap a keepalive client orphaned by a previous HS session, then start a fresh
-- one. The watchdog re-checks every KEEPALIVE_CHECK seconds and respawns it if
-- the client ever drops (Orchestrator restarted, session killed, etc.), so a
-- client is essentially always attached and sends never silently vanish.
local killStaleKeepalive = hs.task.new("/bin/sh", function() ensureSupervisorClient() end,
  {"-c", "pkill -f zellij_keepalive[.]py 2>/dev/null; true"})
killStaleKeepalive:start()
M.keepaliveTimer = hs.timer.doEvery(KEEPALIVE_CHECK, ensureSupervisorClient)

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
-- 5-cell bar scaled to the largest cached model, so relative RAM cost is
-- legible at a glance (█ = filled, ░ = empty).
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
  local items = { { title = "Speech model · RAM footprint", disabled = true } }
  for _, m in ipairs(MODELS) do
    local icon = m.stream and "🟢" or "🟡"
    items[#items + 1] = { title = string.format("%s  %s   %s  %s",
                            icon, m.name, sizeBar(m.sizeKB, maxKB), m.sizeStr),
                          checked = (m.id == M.selectedId),
                          fn = function() setModel(m) end }
  end
  items[#items + 1] = { title = "-" }
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
    -- AirPods/MFB is the headset's talk-to-Orchestrator button: route via
    -- zellij write-chars (focus-independent), not paste-at-cursor.
    if not M.recording then M.supervisor = true; startRecording() end
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
--   Fn+A  send this recording's transcript to the Orchestrator zellij session (instead of paste)
M.keyWatcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
  if not M.fnDown then return false end
  local kc = e:getKeyCode()
  if kc == hs.keycodes.map["c"] then
    M.cancelled = true
    recallLast()
    return true
  end
  if kc == hs.keycodes.map["a"] then
    M.supervisor = true
    logf("[chord] Fn+A — Orchestrator mode armed")
    notify("→ Orchestrator mode (release Fn to send)", 1.6)
    return true
  end
  return false
end)
M.keyWatcher:start()

-- Keep the mic list fresh even without opening the menu: a headset that
-- (dis)connects after launch retriggers discovery, and if the *selected* mic
-- disappears we say so instead of silently recording nothing.
hs.audiodevice.watcher.setCallback(function()
  MICS = discoverMics()
  local present = false
  for _, m in ipairs(MICS) do if m.name == M.micName then present = true; break end end
  if not present then
    logf("[mic] selected %q disconnected", tostring(M.micName))
    notify("Mic '" .. tostring(M.micName) .. "' disconnected — pick another", 2.8)
  end
end)
hs.audiodevice.watcher.start()

-- Public API for other apps (e.g. volume_tap) to drive voice → Orchestrator.
M.isRecording = function() return M.recording end
-- Start a recording already routed to the Orchestrator (no Fn / no paste).
M.startSupervisorVoice = function()
  if M.recording then return false end
  M.supervisor = true
  startRecording()
  return true
end
-- Stop the current recording; finishTranscript routes per M.supervisor.
M.stopVoice = function()
  if not M.recording then return false end
  stopRecording()
  return true
end

notify("Dictate ready · hold Fn or MFB · Fn+C recall · Fn+A → " .. SUPERVISOR_SESSION, 2.0)
logf("[dictate] init complete")

return M
