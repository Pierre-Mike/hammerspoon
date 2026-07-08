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
| `apps/noseguard` | Face-touch deterrent — a Python + MediaPipe daemon (`noseguard.py`) watches the camera and disrupts you when you touch your face. CPU delegate only (the Metal GPU delegate aborts on macOS). |

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
  `python3 -m venv apps/noseguard/.venv && apps/noseguard/.venv/bin/pip install mediapipe numpy opencv-python pyobjc`.

## Tests

```sh
make install-deps   # luarocks install busted
make test           # busted specs under tests/
```
