-- Central config: all paths, URLs, and tunables in one place.

local HOME = os.getenv("HOME")

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
  SUPERVISOR_SESSION  = "Orchestrator",

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
  --   SENT  — transcript written into the Orchestrator zellij pane ("delivered")
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
    SENT    = "Submarine",  -- distinct, deeper — "delivered to Orchestrator"
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
