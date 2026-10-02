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

Apps load themselves: anything under `apps/` with an `init.lua`, and any single
`.lua` file there, is picked up at startup — see [Plugins](#plugins).

| App | What it does |
|-----|--------------|
| `apps/dictation` | Hold **Fn** (or headset MFB) to record; release to transcribe with [parakeet-mlx](https://github.com/senstella/parakeet-mlx) and paste at the cursor. A warm server (`parakeet_server.py`, port 8765) keeps the model resident for live-preview streaming. `Fn+A` routes the transcript into the zellij `Orchestrator` session and `Fn+P` into the firstmate primary's tmux pane instead of pasting — see [Voice routing targets](#voice-routing-targets). `Fn+C` cancels & recalls the last result. `Fn+S` cancels and reads the current *selection* aloud through `apps/tts`. Menu-bar picker switches speech models. |
| `apps/brown_noise` | Noise machine in the hub: a Play switch, volume slider, and color picker (white/pink/brown/blue/violet). |
| `apps/volume_tap` | Voice control for the default supervisor (Orchestrator) via volume-key taps. |
| `apps/noseguard` | Nose-touch deterrent — a headless Python daemon (`noseguard.py`) watches the camera via AVFoundation + Apple Vision and disrupts you when a fingertip rests on your nose. Only the nose landmarks count, the contact radius scales to your interpupillary distance rather than the frame, and contact has to hold still for half a second — so beards, eating, and hands merely raised near the face don't fire. Geometry and debounce live in `nose_geom.py` (pure, unit-tested). |
| `apps/tts` | Spoken-text queue any app can post to. Text arrives over HTTP (`POST :8790/speak`), the `hs -c 'speak("…")'` CLI, or a `hammerspoon://speak?text=…` URL; a FIFO queue plays chunks serially so nothing talks over itself. Long text is split into sentences so playback starts on the first one. `Fn+S` reads the current selection aloud. Voice comes from a warm [Kyutai pocket-tts](https://github.com/kyutai-labs/pocket-tts) server (`pocket_tts_server.py`, port 8791) kept resident on CPU. Menu-bar item shows queue depth + Stop. |
| `apps/lmstudio` | Runs the local [LM Studio](https://lmstudio.ai) MLX server from the hub: a Server switch, a ✓ picker that switches the loaded model, and a memory panel showing what every model on disk costs and what the Mac has free. Switching unloads the resident model of the same kind first, so an embedding model keeps serving while the chat model changes. `--ttl` gives an idle model's memory back on its own. See [LM Studio](#lm-studio). |
| `apps/dsh` | Runs the [DeepSeek Harness](https://github.com/deepseek-ai) web profile from the hub: a Server switch, Restart, and "Open the web UI" — which starts the server first when it is off, then opens the browser once it answers. See [DeepSeek Harness](#deepseek-harness). |
| `apps/shokz` | Volume-button chords on the Shokz OpenComm2 (e.g. volume− then volume+), read from CoreAudio volume changes. Other apps claim chords from its `actions` table; `apps/voice_agent` uses one. |
| `apps/shokz_mute` | Keeps Microsoft Teams' mute in step with the headset's hardware mute button, read from the bluetoothd log. Uses the Teams local API when allowed, otherwise sends Cmd+Shift+M to Teams. Hub tile: sync switch, status, re-align, reconnect, backend picker. |

### One menu-bar button

All apps share a single 🔨 menu-bar item (`lib/menuhub.lua`). Clicking it opens a
Control Center-style panel (`lib/menuhub_panel.html`): one tile per app with its live
icon and status, in light and dark mode. A tile opens that app's menu in the same
design: grouped lists, ✓ pickers, switches, sliders, drill-in submenus, and actions
that run in place.
Option-click 🔨 for the plain dropdown. A new app gets a tile, not a new icon:

```lua
local ctx = require("lib.context").new("My app")

M.menu = ctx:tile("My app")                       -- instead of hs.menubar.new()
M.menu:setTitle("✅")                             -- same setTitle/setIcon/setMenu/
M.menu:setMenu(function() return { ... } end)     -- setTooltip/setClickCallback API
```

## Plugins

Each app is a plugin: a folder `apps/<name>/init.lua`, or a single
`apps/<name>.lua`. Dropping one in is enough, no file lists it, and one that
throws on require fails alone instead of taking down everything after it.
`init.lua` names only the few whose load order matters, which is also the tile
order in the hub.

An app builds everything through its own context (`lib/context.lua`), which
remembers how to undo it:

```lua
local ctx = require("lib.context").new("My app")

ctx:tile("My app")                      -- a hub tile, removed on dispose
ctx:timer(15, poll)                     -- doEvery, stopped on dispose
ctx:after(2, once)                      -- doAfter, and it forgets itself as it fires
ctx:task(bin, onExit, args)             -- hs.task, terminated on dispose
ctx:hotkey({ "cmd" }, "d", fn)          -- deleted on dispose
ctx:url("myapp", fn)                    -- hammerspoon://myapp, unbound on dispose
ctx:atExit(cleanup)                     -- instead of hs.shutdownCallback

function M.dispose() ctx:dispose() end  -- what makes the app switchable
```

Every constructor returns `handle, release`. The handle is the real `hs` object,
so calling code reads as it always did; `release()` tears that one effect down
early and forgets it, which is what an app calls when it kills its own task
instead of `task:terminate()`.

`ctx:atExit` exists because `hs.shutdownCallback` is a single global slot: the
last app to set it wins and the one it replaced silently stops running at quit.
Contexts share one callback that fans out.

The 🧩 **Plugins** tile carries a switch per app, and what is switched off
persists across reloads. Switching off is only as good as the app: one with a
`dispose()` genuinely goes away, while one without can only be stopped from
loading next time, and its row says `(reload to remove)` rather than pretending
otherwise.

### Spoons

[Spoons](https://www.hammerspoon.org/Spoons/) load into a context too, so one
written by anyone else gets a tile and a teardown:

```lua
local ctx = require("lib.spoon").load("Caffeine", {
  hotkeys = { toggleWhileLocked = { { "cmd", "alt" }, "c" } },
  icon    = "☕️",
})
```

`:stop()` is registered as the teardown, and the `hs.*` constructors are swapped
for recording ones while `:bindHotkeys()` and `:start()` run, so handles a
careless `:stop()` forgets are tracked anyway. That capture only sees
constructors called during those two calls — a Spoon that arms a timer later
from its own callback escapes it — so it makes a careless Spoon survivable, not
safe.

## Voice routing targets

A dictated transcript either pastes at the cursor (plain **Fn**) or is delivered
straight into a supervisor's terminal pane and submitted. Every destination lives
in one table, `VOICE_TARGETS` in `lib/config.lua`, and each one names its own
**transport** — which multiplexer owns the pane:

| Chord | Route | Transport | Address | Delivered by |
|---|---|---|---|---|
| `Fn+A` | `orchestrator` | zellij | session `Orchestrator` | `action write-chars` → `action write 13` |
| `Fn+P` | `firstmate` | tmux | `firstmate:0.0` (`FIRSTMATE_PRIMARY_TMUX_TARGET`) | `load-buffer -` → `paste-buffer -p -d` → `send-keys Enter` |

Headset MFB and `apps/volume_tap` use `VOICE_TARGET_DEFAULT`, which is
`orchestrator`. `Fn+C` is reserved for cancel-and-recall and can't be claimed by
a target. `lib/voice_targets.lua` (pure, unit tested in
`tests/spec/voice_targets_spec.lua`) does all resolution and command
construction — no module holds a session name or a multiplexer path of its own.

Each transport returns an ordered **step list**, so the step *count* differs by
transport (two for zellij, three for tmux) and `apps/dictation` simply runs
whatever list it is handed, stopping at the first failure. It never branches on
transport. Adding a destination is one `VOICE_TARGETS` entry; adding a third
multiplexer is one entry in `voice_targets.TRANSPORTS` plus one in
`config.VOICE_TRANSPORTS` — and no change in `apps/dictation` either way.

No multiplexer here has an atomic type-and-submit, so the text is typed **once**
and the newline follows only after the type is confirmed. A failed submit never
retypes: a duplicated instruction is worse than an unsubmitted one.

### Why firstmate is reached over tmux, not zellij

firstmate runs a **hybrid**: the captain/primary sits in a **tmux** pane while
crewmate tasks spawn as **zellij** tabs. That's forced, not chosen — firstmate's
away-mode supervisor daemon refuses at startup for any supervisor backend other
than `tmux` or `herdr` (`bin/fm-supervise-daemon.sh`, `docs/configuration.md`
"Away-mode supervisor backend"), and it resolves the supervisor pane's backend
independently of the runtime backend that spawns crewmates. So voice-in speaks
tmux to reach the captain and zellij only for the Orchestrator.

Launch the captain so that target resolves:

```sh
tmux new-session -s firstmate -c ~/Github/firstmate   # primary in window 0, pane 0
# crewmate tabs stay in the shared "firstmate" ZELLIJ session — a different
# namespace entirely, which the tmux route cannot reach
```

### Why both routes paste rather than type

`zellij action paste` and `tmux paste-buffer -p` both use **bracketed paste
mode**, and neither auto-submits. That's the point: the pane receives one paste
rather than N keystrokes, so a Claude Code completion or slash-command popup can't
open mid-transcript and swallow the Enter that follows. Verified against the
installed tmux 3.7b — with the pane's program having enabled bracketed paste
(`DECSET 2004`), the payload arrives wrapped:

```
033 [ 2 0 0 ~   p o p u p   s a f e   p a y l o a d   033 [ 2 0 1 ~
```

When the program hasn't enabled it (a bare shell), tmux sends the text plain, so
`-p` is safe to pass unconditionally.

On tmux the transcript is staged with `load-buffer -b <buf> -`, i.e. **on stdin**,
so it never appears in argv at all. That matters: `tmux send-keys` has no `--`
option terminator (verified — `send-keys -l "-x…"` fails with "unknown flag -x"),
so an argv-carried transcript starting with a dash would be parsed as flags.
Nothing needs escaping if nothing is passed as an argument. `paste-buffer -d` then
deletes the buffer so spoken text doesn't linger in tmux's buffer stack.

This deliberately diverges from firstmate's own tmux adapter, which uses
`send-keys -l` (`bin/fm-tmux-lib.sh:426`) — bracketed paste is the safer
primitive, for the same reason firstmate itself chose `action paste` over
`write-chars` on the zellij side.

`orchestrator` deliberately stays on zellij `write-chars` + `write 13`,
byte-for-byte the pair it has always used, so this addition changes no working
live path. Switching it to `paste` + `enter` later is a one-word config edit
(`input` / `submit` on that target).

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

`deliverySteps` also refuses an unresolved target, so no code path can construct
a delivery aimed at a crewmate even if `VOICE_TARGETS` is later edited to point
there. Any config conflict — a duplicate chord, a stolen `Fn+C`, an unknown
transport, an ambient target, a misspelled `input`/`submit` — arms **no** chord at
all and shows "voice route refused".

Because `hs.task` passes argv directly with no shell, quotes, `$VAR`, and `;`
arrive literally on both transports. Verified end-to-end against a real tmux pane,
running the exact steps the module builds:

```
ship the migration branch then open a draft PR
-- a transcript that starts with dashes
-t looks like a tmux flag
quotes 'single' and "double" plus $HOME and a ; semicolon
unicode déjà vu — em dash and émoji ✅
```

`apps/voice_agent` is optional: it lives in
[pipecat-voice-agent](https://github.com/Pierre-Mike/pipecat-voice-agent), whose
`hammerspoon/install.sh` symlinks it (and `lib/voice_toggle.lua`) in here. On a
fresh clone it is simply not there, and discovery skips it.

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

## Speech models

The dictation menubar lists every speech model cached under
`~/.cache/huggingface/hub`, with its published English WER and its RAM footprint.
A model joins the list by being downloaded and leaves it by being deleted —
`apps/dictation` reads each model's `config.json` to decide which backend runs it,
so nothing in the code needs editing:

- a **NeMo** config (the parakeet family) runs on the warm `parakeet_server.py`,
  the only backend that streams, so these are the only models with a live preview
  (🟢) and the only ones that cost ~0.2s per dictation rather than seconds
- any other `model_type` mlx-audio implements runs through its batch CLI (🟡):
  the WAV is transcribed on release, with no preview and a cold model load

```sh
hf download mlx-community/parakeet-tdt-0.6b-v2      # streaming, English
hf download mlx-community/whisper-large-v3-asr-8bit # batch, 99 languages
hs -c 'hs.reload()'                                 # the menu picks them up
```

Add the model to `CATALOG` in `apps/dictation/init.lua` to give it a readable
name and a WER; without an entry it still appears, under its bare repo name. The
WER there is measured locally against the exact quantised snapshot, not copied
from a leaderboard, because quantisation moves it: the 4-bit Qwen3-ASR build
measures 3.93 where the full-precision original tops the Open ASR Leaderboard.
`ENGINES` in the same file is the list of architectures the picker will run — an
mlx-audio release that adds an architecture needs a key here too, and
`test_stt.sh` keeps its own copy in step.

The batch backend needs `soundfile` and `sentencepiece`, which mlx-audio does not
pull in itself: `uv tool install mlx-audio --with soundfile --with sentencepiece`.
Without them Granite fails on load and Cohere Transcribe fails on its tokenizer.

`./test_stt.sh` transcribes one clip (`/tmp/hs-dictate.wav` by default — dictate
once and it is there) with every cached model in turn, so accuracy and speed can
be compared on your own voice and microphone rather than on a benchmark corpus.

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

### Speak the selection — `Fn+S`

Select text anywhere, press **Fn+S**, and it reads aloud. Same chord family as
`Fn+A` / `Fn+C`: holding Fn opens the mic as usual, and `Fn+S` cancels that
capture before handing the selection to the queue, so nothing is recorded.

macOS has no API for "the current selection", so the chord copies it (⌘C), reads
the pasteboard, and puts your clipboard back — including images and rich text.
A copy only counts if the pasteboard's change count actually moves, so pressing
`Fn+S` with nothing selected says *nothing selected* rather than re-reading
whatever was already on your clipboard.

```sh
hs -c 'speakSelection()'            # same thing without the chord
hs -c 'speakSelection("alerts")'    # in another voice
open 'hammerspoon://speakSelection?profile=code'
```

Read-aloud uses the `reading` voice (vera) by default — change it, or the copy
timeout, under `TTS_SELECTION` in `lib/config.lua`. Long selections stream: the
first sentence starts talking while the rest is still synthesising, and
`curl -s localhost:8790/stop` (or the menu-bar **Stop**) kills it mid-sentence.

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

## LM Studio

`apps/lmstudio` drives the local LM Studio server from the 🧠 tile: start and
stop it, switch the loaded model, and read what each model costs in memory
before you load it.

Needs LM Studio's CLI at `~/.lmstudio/bin/lms` (LM Studio → Developer → Install
CLI). Without it the tile says so and offers nothing else.

Clicking a model switches to it — the loaded model of the **same kind** is
unloaded first, then the new one loads. Two 15 GB chat models do not fit in
32 GB, so a switch has to be a swap; an embedding model is a different kind and
keeps serving while the chat model changes under it.

The memory section reads the machine the way Activity Monitor does (app + wired
+ compressed pages; see `lib/lmstudio.memory`). A model whose weights plus
2 GB of working headroom would not fit, even counting the memory the swap gives
back, is marked ⚠︎ — a warning, not a block.

"Auto-unload when idle" passes `--ttl` to the next load, so an idle 15 GB model
gives its memory back on its own. It is a load-time flag: it binds the model you
load next, not the one already resident.

Three sources feed the tile, because none of them has everything:

| source | gives | cost |
|---|---|---|
| `GET /api/v0/models` | which models are loaded, at what context | ~8 ms |
| `lms ls --json` | every model on disk, and the only byte counts | ~250 ms |
| `lms ps --json` | models loaded with the server off, and unload identifiers | ~160 ms |

`lib/lmstudio.catalog` joins them on the model key. Nothing is queried while the
menu is being built — menuhub rebuilds an app's menu on every open and every
redraw behind it, and a 250 ms spawn on that path would be felt. A 15 s poll
keeps the state current and the menu renders what is already cached. Only the
cheap HTTP call runs at that rate; the disk catalog refreshes every 5 minutes,
and the down-state probe (which costs two spawns) no more than every 45 s.

When the HTTP call goes unanswered the tile asks `lms server status` for the
real port before concluding the server is off, so a server restarted on another
port is picked back up instead of showing as dead.

## DeepSeek Harness

`apps/dsh` drives the harness's web profile from the 🐋 tile: start it, stop it,
restart it, and open its browser UI.

Needs the `dsh` launcher on `/opt/homebrew/bin`, `/usr/local/bin` or
`~/.local/bin` (`npm i -g @deepseek-ai/dsh`). Without it the tile says so.

The tile runs `dsh --profile web --no-open --port 3080` and holds the process
itself, so Stop is a SIGTERM the node server shuts down cleanly on. `--no-open`
matters: starting a server from the menu bar should not pull a browser window to
the front. "Open the web UI" is the item that opens one, and from a cold start it
starts the server first and waits for it to answer, so the browser never loads a
dead address.

Two things can hold port 3080 without the tile knowing — a server started in a
terminal, and one this tile started before a Hammerspoon reload threw away the
handle. So every start frees the port first, and the running state comes from
asking the address rather than from our own bookkeeping:

| question | answer |
|---|---|
| is it up? | a 15 s `GET` on the bound address; any status means something answered |
| where is it? | the `dsh web: http://…` line the server prints on stdout |
| what still holds the port? | `lsof -tiTCP:3080 -sTCP:LISTEN` |

`-sTCP:LISTEN` is what makes that last one safe. A bare `lsof -ti :3080` also
matches sockets whose *remote* port is 3080, and Hammerspoon holds one of those
every time the tile polls — the same pattern took Hammerspoon down from
`apps/voice_agent` before it was fixed there.

Nothing starts on a config reload. The Server switch and "Open the web UI" are
the only things that turn it on.

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
