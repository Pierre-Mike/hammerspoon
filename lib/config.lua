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

  -- A second instance of the same server, running the French model.
  --
  -- One pocket-tts process holds exactly one model, and the model decides the
  -- phonetics — not the voice name. Reading French through the English model gets
  -- every word right and every sound wrong, and no choice of voice fixes it. So
  -- French gets its own process. Notifications (apps/tts.lua) keep using the
  -- English one on 8791; the voice agent sends French replies to 8793.
  --
  -- "french_24l" is the only French identifier pocket-tts accepts: load_model
  -- rejects "french" outright and says so. It is a 24-layer model where English
  -- is 6, which costs 672 MB on disk, ~2.4 GB resident, and roughly 3.7x the
  -- synthesis time (still faster than real time: ~1.3s for a 7-word sentence).
  --
  -- Each instance needs its OWN output directory. The server rotates through
  -- /tmp/hs-tts-0..7.wav, and two processes sharing that set overwrite each
  -- other's audio: a French reply came back as an English notification clip
  -- during testing, because the other server had reused the slot between the
  -- write and the read.
  POCKET_TTS_OUT      = "/tmp",
  POCKET_TTS_FR_PORT  = 8793,
  POCKET_TTS_FR_BASE  = "http://127.0.0.1:8793",
  POCKET_TTS_FR_OUT   = "/tmp/pocket-tts-fr",
  TTS_LANGUAGE_FR     = "french_24l",
  TTS_VOICE_FR        = "estelle",                  -- pocket-tts' own French default
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

  -- Fn+S — speak whatever is selected. macOS has no "read the selection" API, so
  -- the chord copies it (⌘C), reads the pasteboard, then puts the clipboard back.
  --   PROFILE  voice for read-aloud text (a TTS_PROFILES key or a raw voice name)
  --   POLL     how often to check whether the copy landed
  --   TIMEOUT  give up after this long and treat it as "nothing selected"
  TTS_SELECTION       = {
    PROFILE = "reading",
    POLL    = 0.03,
    TIMEOUT = 0.45,
  },

  DUCK_LEVEL          = 0.50,

  -- Audible pipeline cues. Two distinguishable earcons so a headset-only
  -- operator can tell state by ear:
  --   START — mic capture just began ("listening")
  --   STOP  — recording ended, transcription dispatched ("processing")
  -- Kept LOCAL (hs.sound) so it is instant and does not queue behind the
  -- /speak TTS service on 8790.
  --
  -- Each slot accepts either:
  --   • a bare macOS system-sound name (e.g. "Tink", "Pop", "Morse")
  --     — anything under /System/Library/Sounds/*.aiff
  --   • an absolute path to a short .wav / .aiff / .caf on disk
  --
  -- VOLUME is 0.0–1.0 (applied to the hs.sound before play).
  -- Set enabled = false to silence both; set an individual slot to nil
  -- or "" to silence just that step.
  EARCONS = {
    enabled = true,
    START   = "Tink",       -- high, short — "listening now"
    STOP    = "Pop",        -- subtler, lower — "captured, transcribing"
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
