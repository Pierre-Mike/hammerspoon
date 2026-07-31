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
| `apps/dictation` | Hold **Fn** (or headset MFB) to record; release to transcribe with [parakeet-mlx](https://github.com/senstella/parakeet-mlx) and paste at the cursor. A warm server (`parakeet_server.py`, port 8765) keeps the model resident for live-preview streaming. `Fn+A` routes the transcript into the zellij `Orchestrator` session and `Fn+P` into the firstmate primary instead of pasting — see [Voice routing targets](#voice-routing-targets). `Fn+C` cancels & recalls the last result. Menu-bar picker switches speech models. |
| `apps/brown_noise` | Menu-bar noise machine: play/stop, volume, and color (white/pink/brown/blue/violet). |
| `apps/volume_tap` | Voice control for the default supervisor (Orchestrator) via volume-key taps. |
| `apps/noseguard` | Nose-touch deterrent — a headless Python daemon (`noseguard.py`) watches the camera via AVFoundation + Apple Vision and disrupts you when a fingertip rests on your nose. Only the nose landmarks count, the contact radius scales to your interpupillary distance rather than the frame, and contact has to hold still for half a second — so beards, eating, and hands merely raised near the face don't fire. Geometry and debounce live in `nose_geom.py` (pure, unit-tested). |
| `apps/tts` | Spoken-text queue any app can post to. Text arrives over HTTP (`POST :8790/speak`), the `hs -c 'speak("…")'` CLI, or a `hammerspoon://speak?text=…` URL; a FIFO queue plays chunks serially so nothing talks over itself. Long text is split into sentences so playback starts on the first one. Voice comes from a warm [Kyutai pocket-tts](https://github.com/kyutai-labs/pocket-tts) server (`pocket_tts_server.py`, port 8791) kept resident on CPU. Menu-bar item shows queue depth + Stop. |

## Voice routing targets

A dictated transcript either pastes at the cursor (plain **Fn**) or is delivered
straight into a supervisor's zellij pane and submitted. Every destination lives
in one table, `VOICE_TARGETS` in `lib/config.lua`:

| Chord | Route | zellij session | typed with | submitted with |
|---|---|---|---|---|
| `Fn+A` | `orchestrator` | `Orchestrator` | `action write-chars` | `action write 13` |
| `Fn+P` | `firstmate` | `firstmate-primary` (`FIRSTMATE_PRIMARY_SESSION`) | `action paste` | `action send-keys Enter` |

Headset MFB and `apps/volume_tap` use `VOICE_TARGET_DEFAULT`, which is
`orchestrator`. `Fn+C` is reserved for cancel-and-recall and can't be claimed by
a target. Adding or retargeting a destination is a `lib/config.lua` edit — no
module holds a session name of its own, and `lib/voice_targets.lua` (pure, unit
tested in `tests/spec/voice_targets_spec.lua`) does all the resolution.

Delivery is always two steps, because zellij has no atomic type-and-submit
action: the text is typed **once**, unsubmitted, and the newline follows only
after the type is confirmed — never retyping on a failed submit, since a
duplicated instruction is worse than an unsubmitted one.

### Why the two routes use different zellij primitives

`action paste` uses **bracketed paste mode** and does not auto-submit, which is
popup-safe: per-character `write-chars` can trip a Claude Code completion or
slash-command popup that then swallows the Enter. This was verified empirically
against real zellij 0.44 by firstmate (`bin/backends/zellij.sh`), which uses
`paste` + `send-keys Enter` for exactly this reason.

The new `firstmate` route takes that better pair. `orchestrator` deliberately
stays on `write-chars` + `write 13` — the exact pair it has always used — so
adding a second destination doesn't change a working live path. Each target
names its own `input` / `submit` method, so switching Orchestrator over later is
a one-word config edit.

### Why firstmate gets its own session

**firstmate runs one zellij tab per crewmate task inside a single shared
session** (default name `firstmate`, overridable with `FM_ZELLIJ_SESSION`).
Without an explicit `--pane-id`, `zellij --session <name> action …` delivers to
whichever pane is *focused* — so aiming voice at the shared session would drop
the captain's dictation into whatever worker tab happened to be focused.

So the `firstmate` route targets a **dedicated session holding only the
primary**, where the focused pane is always the right pane. This is an assumption
the config makes about how you launch things:

```sh
zellij --session firstmate-primary        # captain / primary lives here, alone
# crewmate tabs stay in the shared "firstmate" session, which voice never touches
```

zellij 0.44 *can* name a pane (`--pane-id terminal_3`, supported on
`write-chars` / `paste` / `write` / `send-keys` — checked against 0.44.3), and a
target may set `paneId` to pin one. It isn't the default because the primary's
pane id isn't known when a chord is pressed and changes across restarts, so it
can't be the primary defence — but it's there if you ever run the primary inside
a session that holds other panes.

The shared session names are listed in `FIRSTMATE_CREW_SESSIONS` (the default
`firstmate`, plus `FM_ZELLIJ_SESSION` when it is set in Hammerspoon's
environment). `lib/voice_targets.lua` refuses to resolve any route pointing at
one of them — case-insensitively — and the argv builders refuse an unresolved
target, so no code path can construct a delivery aimed at a crewmate pane even
if `VOICE_TARGETS` is later edited to point there. A route that fails this check,
or any other config conflict, arms **no** chord at all and shows "voice route
refused" instead of guessing a destination.

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
