-- Central config: all paths, URLs, and tunables in one place.

local HOME = os.getenv("HOME")

-- ── Voice routing targets ───────────────────────────────────────────────────
-- A dictated transcript either pastes at the cursor (default) or is written
-- into a supervisor's zellij pane. Every routable supervisor lives in the
-- VOICE_TARGETS table below — this is the ONLY place a session name is spelled,
-- so retargeting is a one-line edit and no module keeps its own copy.
--
-- Each target names its TRANSPORT (which multiplexer owns the pane), because
-- firstmate runs a HYBRID: the captain/primary sits in a **tmux** pane while
-- crewmate tasks spawn as **zellij** tabs. That isn't a preference — firstmate's
-- away-mode supervisor daemon refuses at startup for any supervisor backend
-- other than tmux or herdr (bin/fm-supervise-daemon.sh, docs/configuration.md
-- "Away-mode supervisor backend"), and it resolves the supervisor pane's backend
-- independently of the runtime backend that spawns crewmates. So voice-in has to
-- speak tmux to reach the captain, and zellij only for the Orchestrator.
--
-- SAFETY — never deliver into a crewmate pane:
--   Both transports address "wherever the target resolves to", so an ambient or
--   under-specified target can land dictation in a worker's prompt.
--   • tmux (firstmate primary): the target must name session AND window (and
--     ideally pane) explicitly. A bare "firstmate" would go to that session's
--     CURRENT window — ambient, and therefore refused. Crewmates are zellij
--     tabs, so a tmux target cannot reach one at all; the explicit target is
--     what stops delivery reaching the wrong tmux pane.
--   • zellij (Orchestrator): without an explicit --pane-id, `zellij --session
--     <name> action …` delivers to whichever pane is FOCUSED. firstmate's
--     crewmates live in one shared session (default "firstmate", overridable
--     with FM_ZELLIJ_SESSION), so any zellij-transport route pointing there is
--     refused outright — see FIRSTMATE_CREW_SESSIONS.
--   lib/voice_targets.lua enforces both, and refuses rather than guessing.
--
-- The tmux target for the captain. Single named constant: change it here when
-- the session/window naming settles. Explicit down to the pane — firstmate's own
-- default supervisor target is the window-level "firstmate:0"
-- (FM_SUPERVISOR_TARGET_DEFAULT), and this pins the pane too so a split in that
-- window cannot silently take delivery.
local FIRSTMATE_PRIMARY_TMUX_TARGET = "firstmate:0.0"

-- zellij sessions holding firstmate crewmate tabs — never a voice destination.
local FIRSTMATE_CREW_SESSIONS = { "firstmate" }
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

  -- Per-transport CLI: which binary drives each multiplexer, and the environment
  -- its task runs with. Adding a transport here plus a dispatch entry in
  -- lib/voice_targets.TRANSPORTS is all a third multiplexer needs.
  -- NOTE the zellij binary is the ~/.cargo one, not the ZELLIJ path above —
  -- that is the path apps/dictation has always used and the one that works.
  VOICE_TRANSPORTS = {
    zellij = {
      bin = HOME .. "/.cargo/bin/zellij",
      env = { HOME = HOME, PATH = "/opt/homebrew/bin:/usr/bin:/bin:" .. HOME .. "/.cargo/bin" },
    },
    tmux = {
      bin = "/opt/homebrew/bin/tmux",
      env = { HOME = HOME, PATH = "/opt/homebrew/bin:/usr/bin:/bin" },
    },
  },

  -- Routable supervisors, keyed by route name. Resolve these through
  -- lib/voice_targets.lua — it enforces the per-transport target guards above.
  --   transport — "zellij" or "tmux"; decides which CLI and argv shape is used
  --   session   — zellij transport: the session to deliver into
  --   target    — tmux transport: explicit "session:window[.pane]" target
  --   label     — human name used in HUD/notify text and the ready banner
  --   chord     — letter that, held with Fn, arms this route for the current take
  -- zellij transport only:
  --   input     — "paste" (bracketed paste, `action paste`) or "write-chars"
  --   submit    — "enter" (`action send-keys Enter`) or "write13" (`action write 13`)
  --   paneId    — OPTIONAL pane id (e.g. "terminal_3"); when set every action
  --               carries --pane-id so delivery ignores which pane is focused.
  --
  -- The tmux transport always types with `send-keys -l` and submits with
  -- `send-keys Enter` — the same pair firstmate itself uses for tmux panes
  -- (bin/fm-tmux-lib.sh), so voice-in speaks to the captain exactly the way
  -- firstmate's own away-mode daemon does.
  --
  -- Orchestrator deliberately stays on zellij write-chars + write 13, the exact
  -- pair it has always used, so this addition changes no working live path.
  --
  -- "c" is reserved by apps/dictation for cancel-and-recall; voice_targets
  -- .conflicts() fails the config if a target ever claims it.
  VOICE_TARGETS = {
    orchestrator = { transport = "zellij", session = "Orchestrator", label = "Orchestrator",
                     chord = "a", input = "write-chars", submit = "write13" },
    firstmate    = { transport = "tmux", target = FIRSTMATE_PRIMARY_TMUX_TARGET,
                     label = "firstmate", chord = "p" },
  },
  -- Route used when something asks for "the supervisor" without naming one
  -- (headset MFB, apps/volume_tap, dictate.startSupervisorVoice()).
  VOICE_TARGET_DEFAULT            = "orchestrator",
  FIRSTMATE_PRIMARY_TMUX_TARGET   = FIRSTMATE_PRIMARY_TMUX_TARGET,
  FIRSTMATE_CREW_SESSIONS         = FIRSTMATE_CREW_SESSIONS,

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
