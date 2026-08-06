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
| `apps/dictation` | Hold **Fn** (or headset MFB) to record; release to transcribe with [parakeet-mlx](https://github.com/senstella/parakeet-mlx) and paste at the cursor. A warm server (`parakeet_server.py`, port 8765) keeps the model resident for live-preview streaming. `Fn+A` routes the transcript to a zellij `Orchestrator` session instead of pasting; `Fn+C` cancels & recalls the last result. Menu-bar picker switches speech models. |
| `apps/brown_noise` | Menu-bar noise machine: play/stop, volume, and color (white/pink/brown/blue/violet). |
| `apps/volume_tap` | Voice control for the Orchestrator via volume-key taps. |
| `apps/noseguard` | Nose-touch deterrent — a headless Python daemon (`noseguard.py`) watches the camera via AVFoundation + Apple Vision and disrupts you when a fingertip rests on your nose. Only the nose landmarks count, the contact radius scales to your interpupillary distance rather than the frame, and contact has to hold still for half a second — so beards, eating, and hands merely raised near the face don't fire. Geometry and debounce live in `nose_geom.py` (pure, unit-tested). |
| `apps/shokz` | Turns the Shokz OpenComm2's volume buttons into general-purpose triggers. Tapping volume− then volume+ (or the reverse) inside 0.6s fires an action; the two presses cancel out so the volume ends where it started. See [Shokz buttons over Bluetooth](#shokz-buttons-over-bluetooth) for why the other buttons can't be used. |
| `apps/tts` | Spoken-text queue any app can post to. Text arrives over HTTP (`POST :8790/speak`), the `hs -c 'speak("…")'` CLI, or a `hammerspoon://speak?text=…` URL; a FIFO queue plays chunks serially so nothing talks over itself. Long text is split into sentences so playback starts on the first one. Voice comes from a warm [Kyutai pocket-tts](https://github.com/kyutai-labs/pocket-tts) server (`pocket_tts_server.py`, port 8791) kept resident on CPU. Menu-bar item shows queue depth + Stop. |

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

## Shokz buttons over Bluetooth

What an OpenComm2 paired straight to the Mac (no Loop dongle) actually exposes,
measured rather than assumed:

| Button | What reaches macOS | Usable as a trigger |
|--------|-------------------|---------------------|
| Multifunction, 1× / 2× / 3× | Play/pause, next, previous — delivered by `mediaremoted` to the now-playing app | **No.** It never becomes a CGEvent, so no event tap sees it |
| Multifunction, hold | Nothing outside a call | No |
| Volume + / − , tap | Changes the output device's volume | **Yes** — this is what `apps/shokz` uses |
| Volume + , hold | Powers the headset off | No |
| Volume − , hold | One step, same as a tap | No |
| Mute | Nothing — needs the Loop dongle, and only works mid-call | No |

The multifunction button is the surprising one. Pressing it does control the Mac
(3/3 presses toggled QuickTime playback in a timed test), but an `hs.eventtap` on
`systemDefined` running throughout logged nothing at all. AVRCP goes through
MediaRemote straight to the now-playing app, bypassing the CGEvent layer that
Hammerspoon, Karabiner and BetterTouchTool all hook. Plugging in the **Loop
dongle** changes this: the headset then presents as USB HID, media keys become
real events, and the mute button starts reaching the host.

That leaves the volume buttons, and the level itself says who moved it:

| Source | Scale | Lands on |
|--------|-------|----------|
| Headset in A2DP (music) | AVRCP absolute volume, 0–127 | `n/127` — e.g. 85/127 = 66.929% |
| Headset in HFP (call) | HFP speaker gain, 0–15 | `n/15` — e.g. 8/15 = 53.333% |
| Mac's own volume keys | 16 steps | `n/16` — e.g. 10/16 = 62.5% |

Both headset grids are live and it switches between them with the Bluetooth
profile, so checking only the 0–127 grid silently drops every press made during a
call. The grids overlap only at 0% and 100%.

Gestures are opposite-direction pairs (`volume− then volume+`, or the reverse)
because the two presses cancel out: the volume ends exactly where it started, so
nothing has to be written back and there is no feedback loop with the headset's
own volume state. `down_up` is the one to prefer — it starts on volume−, so a
slipped press can't turn into the volume+ long-press that powers the headset off.
Firing only on exactly two presses inside the window is what keeps an ordinary
overshoot-and-correct (up, up, down) from being read as a gesture.

Remap in `apps/shokz/init.lua` (`M.actions`). Log: `/tmp/hs-shokz.log`.

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
