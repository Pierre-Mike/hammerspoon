#!/usr/bin/env python3
# Warm pocket-tts synthesis server — the "voice" behind apps/tts.lua.
#
#   POST /speak    body=<text>   [header X-Voice: alba]  -> writes a WAV, returns its path
#   GET  /health                                          -> "ok" once the model is resident
#   GET  /                                                -> "ok"
#
# Mirrors parakeet_server.py: the model is loaded once and kept in memory so each
# request pays only synthesis time (~1/6 real-time on an M4 CPU) instead of the
# multi-second cold start of `pocket-tts generate`. Synthesis is serialised on a
# lock — pocket-tts is CPU-bound and apps/tts.lua already feeds it one chunk at a
# time, so there is never useful concurrency to exploit, and one WAV writer at a
# time keeps the rotating output paths race-free.
#
# The generation flow mirrors pocket_tts.main.generate (the library's own CLI):
#   model = TTSModel.load_model(language=...)
#   state = model.get_state_for_audio_prompt(voice)          # predefined name / url / path
#   chunks = model.generate_audio_stream(model_state=state, text_to_generate=text)
#   stream_audio_chunks(path, chunks, model.config.mimi.sample_rate)   # writes the WAV
# Voice states are cached per voice string (get_state_for_audio_prompt fetches the
# prompt audio from HF the first time), so repeat requests skip that download.
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("POCKET_TTS_PORT", "8791"))
DEFAULT_VOICE = os.environ.get("POCKET_TTS_VOICE", "").strip()   # "" -> language default
LANGUAGE = os.environ.get("POCKET_TTS_LANGUAGE", "english").strip() or None
OUT_DIR = os.environ.get("POCKET_TTS_OUT", "/tmp")
ROTATE = 8  # keep the last N wavs so a file is never overwritten while afplay reads it

_ready = threading.Event()
_lock = threading.RLock()         # serialise synthesis + the output counter (re-entrant:
                                  # the handler holds it across synth(), which re-acquires
                                  # it for the rotating counter)
_model = {"m": None, "sr": 24000}
_states = {}                       # voice string -> model_state dict (cache)
_counter = {"n": 0}
_helpers = {}                      # lazily-imported library functions


def log(msg):
    print(f"[pocket-tts-server] {msg}", flush=True)


def _load():
    t0 = time.time()
    log(f"loading model (language={LANGUAGE})")
    from pocket_tts.models.tts_model import TTSModel
    from pocket_tts.data.audio import stream_audio_chunks
    from pocket_tts.default_parameters import get_default_voice_for_language

    _helpers["stream_audio_chunks"] = stream_audio_chunks
    _helpers["default_voice"] = get_default_voice_for_language

    model = TTSModel.load_model(language=LANGUAGE)
    model.to("cpu")                                    # match the "runs on CPU" contract
    _model["m"] = model
    _model["sr"] = int(model.config.mimi.sample_rate)
    log(f"model loaded in {time.time() - t0:.2f}s, sr={_model['sr']}")

    # Warm the graph + prime the default voice state so the first /speak is fast.
    try:
        tw = time.time()
        synth("Ready.", DEFAULT_VOICE)
        log(f"warmup synth {time.time() - tw:.2f}s")
    except Exception as e:  # noqa: BLE001
        log(f"warmup skipped: {e}")
    _ready.set()
    log("worker ready")


def _voice_state(voice):
    """Return (and cache) the model_state for a voice string. '' -> language default."""
    key = voice or ""
    st = _states.get(key)
    if st is None:
        resolved = voice or _helpers["default_voice"](LANGUAGE)
        st = _model["m"].get_state_for_audio_prompt(resolved)
        _states[key] = st
    return st


def synth(text, voice):
    """Synthesise text to a WAV file, return its path. Raises on failure."""
    model = _model["m"]
    state = _voice_state(voice)
    chunks = model.generate_audio_stream(model_state=state, text_to_generate=text)

    with _lock:
        n = _counter["n"] % ROTATE
        _counter["n"] += 1
    path = os.path.join(OUT_DIR, f"hs-tts-{n}.wav")
    _helpers["stream_audio_chunks"](path, chunks, _model["sr"])   # writes the WAV
    return path


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _body(self):
        n = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(n).decode("utf-8").strip() if n else ""

    def _reply(self, code, text):
        b = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/health":
            self._reply(200 if _ready.is_set() else 503,
                        "ok" if _ready.is_set() else "loading")
        else:
            self._reply(200, "ok")

    def do_POST(self):
        if self.path != "/speak":
            self._reply(404, "no")
            return
        text = self._body()
        voice = (self.headers.get("X-Voice") or DEFAULT_VOICE).strip()
        if not text:
            self._reply(400, "__ERROR__ empty text")
            return
        if not _ready.wait(timeout=180):
            self._reply(503, "__ERROR__ model not ready")
            return
        try:
            with _lock:
                # hold the lock across synthesis: pocket-tts is CPU-bound and not
                # guaranteed re-entrant; serial matches the Lua-side queue anyway.
                path = synth(text, voice)
            self._reply(200, path)
        except Exception as e:  # noqa: BLE001
            log(f"synth error: {e}")
            self._reply(500, f"__ERROR__ {e}")


threading.Thread(target=_load, daemon=True).start()
log(f"listening on http://{HOST}:{PORT}")
try:
    HTTPServer((HOST, PORT), Handler).serve_forever()
except KeyboardInterrupt:
    pass
