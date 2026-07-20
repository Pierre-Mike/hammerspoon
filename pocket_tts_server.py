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
# API assumptions (pocket-tts >= Jan 2026):
#   from pocket_tts.models.tts_model import TTSModel
#   model = TTSModel.load_model()
#   model.sample_rate                      -> 24000
#   model.generate_audio_stream(text=..., voice=...)  -> yields PCM chunks
import os
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("POCKET_TTS_PORT", "8790"))
DEFAULT_VOICE = os.environ.get("POCKET_TTS_VOICE", "alba")
LANGUAGE = os.environ.get("POCKET_TTS_LANGUAGE", "english")
OUT_DIR = os.environ.get("POCKET_TTS_OUT", "/tmp")
ROTATE = 8  # keep the last N wavs so a file is never overwritten while afplay reads it

_ready = threading.Event()
_lock = threading.RLock()         # serialise synthesis + the output counter (re-entrant:
                                  # the handler holds it across synth(), which re-acquires
                                  # it for the rotating counter)
_model = {"m": None, "sr": 24000}
_counter = {"n": 0}


def log(msg):
    print(f"[pocket-tts-server] {msg}", flush=True)


def _load():
    t0 = time.time()
    log(f"loading model (language={LANGUAGE})")
    from pocket_tts.models.tts_model import TTSModel

    try:
        model = TTSModel.load_model(language=LANGUAGE)
    except TypeError:
        # older/newer signatures may not take `language`
        model = TTSModel.load_model()
    _model["m"] = model
    _model["sr"] = int(getattr(model, "sample_rate", 24000))
    log(f"model loaded in {time.time() - t0:.2f}s, sr={_model['sr']}")

    # Warm the graph so the first real /speak isn't slow.
    try:
        tw = time.time()
        for _ in model.generate_audio_stream(text="Ready.", voice=DEFAULT_VOICE):
            pass
        log(f"warmup synth {time.time() - tw:.2f}s")
    except Exception as e:  # noqa: BLE001
        log(f"warmup skipped: {e}")
    _ready.set()
    log("worker ready")


def _to_int16(chunk):
    """Coerce one yielded chunk (numpy/torch/list, float or int) to 1-D int16 bytes."""
    import numpy as np

    arr = chunk
    if hasattr(arr, "detach"):          # torch tensor
        arr = arr.detach().cpu().numpy()
    arr = np.asarray(arr).reshape(-1)
    if np.issubdtype(arr.dtype, np.floating):
        arr = np.clip(arr, -1.0, 1.0)
        arr = (arr * 32767.0).astype(np.int16)
    else:
        arr = arr.astype(np.int16)
    return arr.tobytes()


def synth(text, voice):
    """Synthesise text to a WAV file, return its path. Raises on failure."""
    model = _model["m"]
    sr = _model["sr"]
    pcm = bytearray()
    for chunk in model.generate_audio_stream(text=text, voice=voice):
        pcm.extend(_to_int16(chunk))
    if len(pcm) == 0:
        raise RuntimeError("no audio produced")

    with _lock:
        n = _counter["n"] % ROTATE
        _counter["n"] += 1
    path = os.path.join(OUT_DIR, f"hs-tts-{n}.wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(bytes(pcm))
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
        voice = self.headers.get("X-Voice", DEFAULT_VOICE) or DEFAULT_VOICE
        if not text:
            self._reply(400, "__ERROR__ empty text")
            return
        if not _ready.wait(timeout=120):
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
