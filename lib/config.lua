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

  DUCK_LEVEL          = 0.50,

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
