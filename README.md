# Hammerspoon config

My [Hammerspoon](https://www.hammerspoon.org/) setup — menu-bar tools for dictation,
ambient noise, voice control, and a face-touch deterrent. This repo is the source of
truth; `~/.hammerspoon` is a symlink to it.

## Install

```sh
git clone https://github.com/Pierre-Mike/hammerspoon.git ~/Github/hammerspoon
ln -s ~/Github/hammerspoon ~/.hammerspoon
# then reload Hammerspoon:  hs -c 'hs.reload()'
```

`init.lua` requires each app under `apps/`:

| App | What it does |
|-----|--------------|
| `apps/dictation` | Hold **Fn** (or headset MFB) to record; release to transcribe with [parakeet-mlx](https://github.com/senstella/parakeet-mlx) and paste at the cursor. A warm server (`parakeet_server.py`, port 8765) keeps the model resident for live-preview streaming. `Fn+A` routes the transcript into the zellij `Orchestrator` session and `Fn+P` into the firstmate primary's tmux pane instead of pasting — see [Voice routing targets](#voice-routing-targets). `Fn+C` cancels & recalls the last result. Menu-bar picker switches speech models. |
| `apps/brown_noise` | Menu-bar noise machine: play/stop, volume, and color (white/pink/brown/blue/violet). |
| `apps/volume_tap` | Voice control for the default supervisor (Orchestrator) via volume-key taps. |
| `apps/noseguard` | Nose-touch deterrent — a headless Python daemon (`noseguard.py`) watches the camera via AVFoundation + Apple Vision and disrupts you when a fingertip rests on your nose. Only the nose landmarks count, the contact radius scales to your interpupillary distance rather than the frame, and contact has to hold still for half a second — so beards, eating, and hands merely raised near the face don't fire. Geometry and debounce live in `nose_geom.py` (pure, unit-tested). |
| `apps/tts` | Spoken-text queue any app can post to. Text arrives over HTTP (`POST :8790/speak`), the `hs -c 'speak("…")'` CLI, or a `hammerspoon://speak?text=…` URL; a FIFO queue plays chunks serially so nothing talks over itself. Long text is split into sentences so playback starts on the first one. Voice comes from a warm [Kyutai pocket-tts](https://github.com/kyutai-labs/pocket-tts) server (`pocket_tts_server.py`, port 8791) kept resident on CPU. Menu-bar item shows queue depth + Stop. |

## Voice routing targets

A dictated transcript either pastes at the cursor (plain **Fn**) or is delivered
straight into a supervisor's terminal pane and submitted. Every destination lives
in one table, `VOICE_TARGETS` in `lib/config.lua`, and each one names its own
**transport** — which multiplexer owns the pane:

| Chord | Route | Transport | Address | typed with | submitted with |
|---|---|---|---|---|---|
| `Fn+A` | `orchestrator` | zellij | session `Orchestrator` | `action write-chars` | `action write 13` |
| `Fn+P` | `firstmate` | tmux | `firstmate:0.0` (`FIRSTMATE_PRIMARY_TMUX_TARGET`) | `send-keys -l` | `send-keys Enter` |

Headset MFB and `apps/volume_tap` use `VOICE_TARGET_DEFAULT`, which is
`orchestrator`. `Fn+C` is reserved for cancel-and-recall and can't be claimed by
a target. `lib/voice_targets.lua` (pure, unit tested in
`tests/spec/voice_targets_spec.lua`) does all resolution and argv construction —
no module holds a session name or a multiplexer path of its own, and
`apps/dictation` never branches on transport. Adding a destination is one
`VOICE_TARGETS` entry; adding a third multiplexer is one entry in
`voice_targets.TRANSPORTS` plus one in `config.VOICE_TRANSPORTS`.

Delivery is always two steps, because neither multiplexer has an atomic
type-and-submit: the text is typed **once**, unsubmitted, and the newline follows
only after the type is confirmed — never retyping on a failed submit, since a
duplicated instruction is worse than an unsubmitted one.

### Why firstmate is reached over tmux, not zellij

firstmate runs a **hybrid**: the captain/primary sits in a **tmux** pane while
crewmate tasks spawn as **zellij** tabs. That's forced, not chosen — firstmate's
away-mode supervisor daemon refuses at startup for any supervisor backend other
than `tmux` or `herdr` (`bin/fm-supervise-daemon.sh`, `docs/configuration.md`
"Away-mode supervisor backend"), and it resolves the supervisor pane's backend
independently of the runtime backend that spawns crewmates. So voice-in speaks
tmux to reach the captain and zellij only for the Orchestrator.

The tmux route types with `send-keys -l` and submits with `send-keys Enter` — the
same pair firstmate itself uses for tmux panes (`bin/fm-tmux-lib.sh`), so voice-in
talks to the captain exactly the way firstmate's own away-mode daemon does.
`orchestrator` stays on zellij `write-chars` + `write 13`, byte-for-byte the pair
it has always used, so this addition changes no working live path.

Launch the captain so that target resolves:

```sh
tmux new-session -s firstmate          # captain / primary in window 0, pane 0
# crewmate tabs stay in the shared "firstmate" ZELLIJ session — a different
# namespace entirely, which the tmux route cannot reach
```

### Safety: never deliver into a crewmate pane

Both transports address "whatever the target resolves to", so an ambient or
under-specified target could land dictation in a worker's prompt. Each transport
is guarded in `lib/voice_targets.lua`, and a refusal drops the take rather than
guessing a destination:

- **tmux** — the target must be an explicit `session:window[.pane]`. A bare
  `firstmate` would go to that session's *current* window, so it is refused.
  (Crewmates are zellij tabs, so a tmux target can't reach one at all; the
  explicit target is what stops delivery reaching the wrong tmux pane.)
- **zellij** — without an explicit `--pane-id`, `zellij --session <name> action …`
  delivers to whichever pane is *focused*. firstmate's crewmates share one
  session (default `firstmate`, overridable with `FM_ZELLIJ_SESSION`), so any
  zellij-transport route pointing at a name in `FIRSTMATE_CREW_SESSIONS` is
  refused — case-insensitively. zellij 0.44 *can* name a pane (`--pane-id
  terminal_3`, checked against 0.44.3) and a target may set `paneId`, but the
  primary's pane id isn't known when a chord is pressed and changes across
  restarts, so pane-id can't be the primary defence.

The argv builders also refuse an unresolved target, so no code path can construct
a delivery aimed at a crewmate even if `VOICE_TARGETS` is later edited to point
there. Any config conflict — a duplicate chord, a stolen `Fn+C`, an unknown
transport, an ambient target — arms **no** chord at all and shows "voice route
refused".

One tmux wrinkle worth knowing: `send-keys` has no `--` option terminator
(verified against tmux 3.7b — `send-keys -l "-x…"` fails with "unknown flag"), so
a transcript starting with a dash would be read as flags. `voice_targets` prefixes
a single space in that case, which is invisible in a prompt and preserves every
word. Because `hs.task` passes argv directly with no shell, quotes, `$VAR`, and
`;` all arrive literally.

## Assets not in git

Large binaries are `.gitignore`d (see `.gitignore`) — they live on disk but aren't versioned:

- **Noise WAVs** (`*.wav`) — `noise_{white,pink,brown,blue,violet}.wav`, `brown_noise*.wav`.
  Any 16-bit PCM WAV of the corresponding noise color works; generate e.g. with
  `ffmpeg -f lavfi -i anoisesrc=color=pink:d=600 -ar 44100 noise_pink.wav`.
- **MediaPipe models** (`*.task`) — `apps/noseguard/{hand,face}_landmarker.task`,
  downloadable from the [MediaPipe model zoo](https://ai.google.dev/edge/mediapipe/solutions/vision).
- **Swift overlay binary** (`apps/noseguard/overlay/overlay`) — build from source:
  `swiftc -O apps/noseguard/overlay/overlay.swift -o apps/noseguard/overlay/overlay`.
- **noseguard venv** (`apps/noseguard/.venv/`) — recreate with
  `python3 -m venv apps/noseguard/.venv && apps/noseguard/.venv/bin/pip install pyobjc`.
  Detection runs on Apple Vision, so `pyobjc` is the only requirement.

## TTS service setup

`apps/tts` needs a Python venv with [pocket-tts](https://github.com/kyutai-labs/pocket-tts)
installed (kept out of git, see `.gitignore`):

```sh
python3 -m venv ~/.hammerspoon/.venv-tts
~/.hammerspoon/.venv-tts/bin/pip install pocket-tts
hs -c 'hs.reload()'
```

On reload Hammerspoon frees port 8791 and launches the warm server; the model
downloads on first run. Then any app can talk:

```sh
curl -sX POST localhost:8790/speak -d 'hello from any app'
curl -s     localhost:8790/stop              # cancel + flush the queue (no body)
curl -s     localhost:8790/status            # {"speaking":…,"queued":…,"voice":…}
curl -s     localhost:8790/voices            # profile → voice map
hs -c 'speak("or straight from a shell")'
open 'hammerspoon://speak?text=or%20via%20url&voice=marius'
```

### Different voices for different work

Every entry point takes a **selector** — a profile key, a raw pocket-tts voice
name (26 built-ins: `alba`, `marius`, `vera`, `george`, `michael`, `jane`,
`eve`, `paul`, …), or a path / `hf://` URL to clone. The queue carries the voice
per chunk, so each caller can sound different:

```sh
curl -sX POST 'localhost:8790/speak?profile=alerts' -d 'disk almost full'   # marius
curl -sX POST 'localhost:8790/speak?voice=vera'     -d 'chapter one'         # raw name
curl -sX POST  localhost:8790/speak -H 'X-Voice: george' -d 'build passed'   # header
hs -c 'speak("tests are green", "code")'                                     # CLI, profile
open 'hammerspoon://speak?text=done&profile=system'                          # URL
```

Profiles live in `lib/config.lua` (`TTS_PROFILES`) — map any "kind of work" to a
voice (defaults: `default`=alba, `alerts`=marius, `code`=george, `reading`=vera,
`system`=michael). Header `X-Profile` / `X-Voice` and query `?profile=` / `?voice=`
both work; header wins. The menu-bar **Default voice** submenu switches the
fallback voice used when no selector is given. First use of a voice downloads its
prompt from HF (cached after). Set the language in `lib/config.lua` (`TTS_LANGUAGE`).
Logs: `/tmp/hs-tts.log` (queue) and the server's stdout.

## Tests

```sh
make install-deps   # luarocks install busted
make test           # busted specs under tests/, plus the noseguard geometry
```

`apps/noseguard/nose_geom.py` deliberately imports nothing from Vision or
AVFoundation, so its tests need no venv and no camera:

```sh
python3 -m unittest discover apps/noseguard/tests
```
