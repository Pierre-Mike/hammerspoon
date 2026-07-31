-- Central config: all paths, URLs, and tunables in one place.

local HOME = os.getenv("HOME")

-- ── Voice routing targets ───────────────────────────────────────────────────
-- A dictated transcript either pastes at the cursor (default) or is written
-- into a supervisor's zellij pane. Every routable supervisor lives in the
-- VOICE_TARGETS table below — this is the ONLY place a session name is spelled,
-- so retargeting is a one-line edit and no module keeps its own copy.
--
-- SAFETY — why firstmate gets its own session:
--   firstmate runs one zellij TAB PER CREWMATE TASK inside a single shared
--   session (default name "firstmate", overridable with FM_ZELLIJ_SESSION).
--   `zellij --session <name> action write-chars` delivers to whichever pane is
--   FOCUSED in that session, not to a pane we name. So if we ever targeted the
--   shared session, a dictated sentence would land in whatever crewmate tab
--   happened to be focused — feeding speech meant for the captain straight into
--   a worker's prompt.
--   The assumption baked in here: the firstmate PRIMARY (captain) runs in its
--   own dedicated session, FIRSTMATE_PRIMARY_SESSION, whose only pane is the
--   primary. The shared session is treated as crewmates-only and is listed in
--   FIRSTMATE_CREW_SESSIONS, which lib/voice_targets.lua refuses to route to.
local FIRSTMATE_PRIMARY_SESSION = "firstmate-primary"
local FIRSTMATE_CREW_SESSIONS   = { "firstmate" }   -- never a voice destination
do
  local envCrew = os.getenv("FM_ZELLIJ_SESSION")
  if envCrew and envCrew ~= "" then
    FIRSTMATE_CREW_SESSIONS[#FIRSTMATE_CREW_SESSIONS + 1] = envCrew
  end
end

return {
  AUDIO_DEVICE        = "1",
  WAV                 = "/tmp/hs-dictate.wav",
  RAW                 = "/tmp/hs-dictate.raw",
  TXT                 = "/tmp/hs-dictate.txt",
  LOG                 = "/tmp/hs-dictate.log",
  MIN_DURATION        = 0.6,

  FFMPEG              = "/opt/homebrew/bin/ffmpeg",
  ZELLIJ              = "/opt/homebrew/bin/zellij",
  ZELLIJ_SOCKET_DIR   = "/var/z",

  -- Routable supervisors, keyed by route name. Resolve these through
  -- lib/voice_targets.lua — it enforces the crewmate-session guard above.
  --   session — zellij session `write-chars` is aimed at
  --   label   — human name used in HUD/notify text and the ready banner
  --   chord   — letter that, held with Fn, arms this route for the current take
  -- "c" is reserved by apps/dictation for cancel-and-recall; voice_targets
  -- .conflicts() fails the config if a target ever claims it.
  VOICE_TARGETS = {
    orchestrator = { session = "Orchestrator",              label = "Orchestrator", chord = "a" },
    firstmate    = { session = FIRSTMATE_PRIMARY_SESSION,   label = "firstmate",    chord = "p" },
  },
  -- Route used when something asks for "the supervisor" without naming one
  -- (headset MFB, apps/volume_tap, dictate.startSupervisorVoice()).
  VOICE_TARGET_DEFAULT      = "orchestrator",
  FIRSTMATE_PRIMARY_SESSION = FIRSTMATE_PRIMARY_SESSION,
  FIRSTMATE_CREW_SESSIONS   = FIRSTMATE_CREW_SESSIONS,

  PARAKEET            = HOME .. "/.local/bin/parakeet-mlx",
  PARAKEET_PY         = HOME .. "/.local/share/uv/tools/parakeet-mlx/bin/python",
  PARAKEET_SERVER     = HOME .. "/.hammerspoon/parakeet_server.py",
  MODEL_PATH          = HOME .. "/.cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v3/snapshots/ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15",
  PARAKEET_BASE       = "http://127.0.0.1:8765",

  -- TTS service (apps/tts.lua): a spoken-text queue any app can post to.
  TTS_PORT            = 8790,                       -- hs.httpserver intake other apps POST to
  POCKET_TTS_PORT     = 8791,                       -- internal pocket-tts synth backend
  POCKET_TTS_BASE     = "http://127.0.0.1:8791",
  POCKET_TTS_SERVER   = HOME .. "/.hammerspoon/pocket_tts_server.py",
  POCKET_TTS_PY       = HOME .. "/.hammerspoon/.venv-tts/bin/python",   -- venv with pocket-tts installed
  TTS_VOICE           = "alba",                     -- default pocket-tts voice
  TTS_LANGUAGE        = "english",
  AFPLAY              = "/usr/bin/afplay",
  -- Named voice profiles: map a "kind of work" to a voice so different callers
  -- get different voices. A /speak request may pass a profile key OR any raw
  -- pocket-tts voice name (26 built-ins e.g. alba, marius, vera, george, eve,
  -- jane, michael, paul) OR a path/hf:// URL to clone. Edit freely.
  TTS_PROFILES        = {
    default = "alba",     -- general / fallback
    alerts  = "marius",   -- notifications, warnings
    code    = "george",   -- build/test/CI output narration
    reading = "vera",     -- long-form reading
    system  = "michael",  -- status / system messages
  },

  DUCK_LEVEL          = 0.50,

  -- Audible pipeline cues. Three distinguishable earcons so a headset-only
  -- operator can tell state by ear:
  --   START — mic capture just began ("listening")
  --   STOP  — recording ended, transcription dispatched ("processing")
  --   SENT  — transcript written into a supervisor's zellij pane ("delivered")
  -- Kept LOCAL (hs.sound) so it is instant and does not queue behind the
  -- /speak TTS service on 8790.
  --
  -- Each slot accepts either:
  --   • a bare macOS system-sound name (e.g. "Tink", "Pop", "Morse")
  --     — anything under /System/Library/Sounds/*.aiff
  --   • an absolute path to a short .wav / .aiff / .caf on disk
  --
  -- VOLUME is 0.0–1.0 (applied to the hs.sound before play).
  -- Set enabled = false to silence all three; set an individual slot to nil
  -- or "" to silence just that step.
  EARCONS = {
    enabled = true,
    START   = "Tink",       -- high, short — "listening now"
    STOP    = "Pop",        -- subtler, lower — "captured, transcribing"
    SENT    = "Submarine",  -- distinct, deeper — "delivered to the supervisor"
    VOLUME  = 0.45,
  },

  PREVIEW = {
    FONT_SIZE         = 28,
    PAD               = 24,
    TOP               = 50,
    MAX_SCREEN_RATIO  = 0.7,
    CHARS_PER_UNIT    = 0.52,
    LINE_HEIGHT_RATIO = 1.32,
    BOTTOM_OFFSET     = 120,
  },
}
