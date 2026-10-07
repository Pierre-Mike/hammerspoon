#!/usr/bin/env python3
# Warm speech-to-text server: ONE model, loaded once, shared by every caller
# (apps/dictation and the pipecat voice agent both POST to it).
#
# The file keeps its historical name because callers point at it by path, but it
# serves any model the dictation menu offers. Which backend runs is chosen at
# launch, and the launcher must start it under the matching interpreter:
#
#   STT_ENGINE=parakeet  parakeet-mlx's python   STT_MODEL=<snapshot dir>
#   STT_ENGINE=mlxa      mlx-audio's python      STT_MODEL=<HF repo id or dir>
#
# STT_MODEL_ID is the name /health reports (defaults to STT_MODEL); STT_PORT
# overrides the port. PARAKEET_MODEL_PATH / PARAKEET_PORT / argv[1] still work, so
# an old launcher keeps getting a parakeet server.
#
#   POST /transcribe  body=<wav path>  -> batch transcription (text back)
#   POST /start       body=<raw path>  -> stream a growing headerless s16le/16k
#                                          mono PCM file as it records
#   POST /finish                        -> drain remaining audio, return text
#   POST /cancel                        -> abort the current streaming session
#   GET  /partial                       -> live hypothesis of the stream
#   GET  /health                        -> JSON: engine, model, ready, streams
#
# Errors come back as a non-200 status with a body starting "__ERROR__". Only the
# parakeet engine streams: on an mlx-audio model /start and /finish fail at once,
# so dictation falls back to /transcribe.
#
# All MLX work runs on ONE dedicated worker thread (model loaded there too):
# MLX's Metal stream is thread-bound. The HTTP server threads only hand the
# worker Session objects and signal them via events.
#
# A new /start preempts (aborts) any in-flight stream, so an orphaned session can
# never leak a stale transcript into a later /finish. Batch jobs queue instead of
# preempting; while a stream is live the worker serves them between feeds, so a
# voice-agent turn never waits for a dictation to end.
import json
import os
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ENGINE = os.environ.get("STT_ENGINE", "parakeet")
MODEL = (os.environ.get("STT_MODEL") or os.environ.get("PARAKEET_MODEL_PATH")
         or (sys.argv[1] if len(sys.argv) > 1 else None))
MODEL_ID = os.environ.get("STT_MODEL_ID") or MODEL
HOST = "127.0.0.1"
PORT = int(os.environ.get("STT_PORT") or os.environ.get("PARAKEET_PORT", "8765"))
STREAMS = ENGINE == "parakeet"
# mlx-audio only. Empty = each model's own default (Whisper detects the language
# per take); a code such as "fr" pins it.
LANGUAGE = os.environ.get("STT_LANGUAGE", "").strip()

SR = 16000
BLOCK = SR          # 1.0s feed blocks: smaller first chunks drop the leading word
CONTEXT = (256, 256)
DEPTH = 2

if ENGINE not in ("parakeet", "mlxa") or not MODEL:
    sys.exit(f"usage: STT_ENGINE=parakeet|mlxa STT_MODEL=<path or repo> {sys.argv[0]}")


def log(msg):
    print(f"[stt-server:{ENGINE}] {msg}", flush=True)


class Session:
    def __init__(self, kind, path):
        self.kind = kind          # 'stream' | 'batch'
        self.path = path
        self.abort = threading.Event()
        self.finish = threading.Event()
        self.done = threading.Event()
        self.text = None
        self.partial = ""        # latest live hypothesis, polled via GET /partial


_lock = threading.Lock()
_wake = threading.Event()
_current = {"sess": None}   # the live stream session (what /finish, /cancel act on)
_queue = deque()            # sessions waiting for the worker, oldest first
# What /health reports. `error` is set when the model failed to load, after which
# every request is answered with it instead of hanging until its timeout.
_state = {"ready": False, "error": None, "load_s": None}


def _new_session(kind, path):
    s = Session(kind, path)
    with _lock:
        if _state["error"]:
            s.text = f"__ERROR__ model failed to load: {_state['error']}"
            s.done.set()
            return s
        if kind == "stream":
            prev = _current["sess"]
            if prev is not None and not prev.done.is_set():
                prev.abort.set()    # preempt any in-flight stream
            _current["sess"] = s
        _queue.append(s)
    _wake.set()
    return s


def _next_batch():
    """Pop the oldest queued batch job, leaving any stream sessions in place."""
    with _lock:
        for s in _queue:
            if s.kind == "batch":
                _queue.remove(s)
                return s
    return None


def _run_batch(backend, s):
    try:
        s.text = backend.transcribe(s.path)
    except Exception as e:  # noqa: BLE001
        log(f"batch error: {e}")
        s.text = f"__ERROR__ {e}"
    s.done.set()


def _read_pcm(fh, leftover):
    import numpy as np
    import mlx.core as mx
    data = leftover + fh.read()
    usable = len(data) - (len(data) % 2)   # whole int16 samples only
    if usable == 0:
        return None, data
    samples = np.frombuffer(data[:usable], dtype=np.int16).astype(np.float32) / 32768.0
    return mx.array(samples), data[usable:]


def _feed(st, pending, arr):
    """Append arr to pending; feed full BLOCK pieces, return the remainder array."""
    import mlx.core as mx
    buf = arr if pending is None else mx.concatenate([pending, arr])
    n, off = buf.shape[0], 0
    while n - off >= BLOCK:
        st.add_audio(buf[off:off + BLOCK])
        off += BLOCK
    return buf[off:]


def _run_stream(backend, s):
    model = backend.model
    for _ in range(50):                     # wait for ffmpeg to create the file
        if os.path.exists(s.path):
            break
        time.sleep(0.02)
    t0, feeds, leftover, pending = time.time(), 0, b"", None
    with model.transcribe_stream(context_size=CONTEXT, depth=DEPTH) as st, \
            open(s.path, "rb") as fh:
        while not s.finish.is_set() and not s.abort.is_set():
            b = _next_batch()
            if b is not None:               # a voice-agent turn mid-dictation
                _run_batch(backend, b)
                continue
            arr, leftover = _read_pcm(fh, leftover)
            if arr is not None:
                pending = _feed(st, pending, arr); feeds += 1
                s.partial = (st.result.text or "").strip()   # live preview
            else:
                time.sleep(0.03)
        if s.abort.is_set():
            log("stream aborted"); s.done.set(); return
        # /finish: ffmpeg got SIGTERM (runs with -flush_packets 1, so the file
        # is nearly current). Short grace to catch its last bytes, then drain.
        deadline = time.time() + 0.12
        while time.time() < deadline:
            arr, leftover = _read_pcm(fh, leftover)
            if arr is not None:
                pending = _feed(st, pending, arr)
                deadline = time.time() + 0.05
            else:
                time.sleep(0.015)
        if pending is not None and pending.shape[0] > 0:
            st.add_audio(pending)
        s.text = (st.result.text or "").strip()
    log(f"stream done: feeds={feeds} {len(s.text)} chars in {time.time()-t0:.2f}s")
    s.done.set()


class ParakeetBackend:
    def __init__(self, path):
        from parakeet_mlx import from_pretrained
        self.model = from_pretrained(path)

    def transcribe(self, wav):
        return (self.model.transcribe(wav).text or "").strip()


def decode_kwargs(defaults, params, language=""):
    """generate() kwargs for one mlx-audio model.

    Starts from the batch CLI's defaults, filtered to what this model's
    generate() names, as generate_transcription does. Two departures:
      - language: the CLI forces "en", which makes Whisper decode French as
        English. Unpinned, it is left out so the model's own default applies
        (Whisper: detect per take). Pinned, it is passed through.
      - condition_on_previous_text=False where accepted: conditioning on its own
        output is what sends Whisper into repeating a sentence on trailing
        silence.
    """
    kw = {k: v for k, v in defaults.items()
          if k in params and k not in ("audio", "verbose", "stream", "language")}
    if language and "language" in params:
        kw["language"] = language
    if "condition_on_previous_text" in params:
        kw["condition_on_previous_text"] = False
    return kw


class MlxAudioBackend:
    """Any mlx-audio STT architecture, called the way its batch CLI calls it."""

    def __init__(self, repo):
        import inspect
        import mlx.core as mx
        from mlx_audio.stt.generate import parse_args
        from mlx_audio.stt.utils import load_model
        self.model = load_model(repo)
        defaults = vars(parse_args(["--audio", "-", "--output-path", "-"]))
        params = inspect.signature(self.model.generate).parameters
        self.kwargs = decode_kwargs(defaults, params, LANGUAGE)
        log(f"decode kwargs: {sorted(k for k in self.kwargs if k != 'generation_stream')} "
            f"language={self.kwargs.get('language', 'model default')}")
        if "generation_stream" in params:
            # Created on this (the worker) thread, which owns the MLX stream.
            self.kwargs["generation_stream"] = mx.new_stream(mx.default_device())

    def transcribe(self, wav):
        out = self.model.generate(wav, verbose=False, **self.kwargs)
        return (getattr(out, "text", "") or "").strip()


def worker():
    import mlx.core as mx  # (worker thread must own the MLX stream)
    # Bound MLX's Metal buffer cache. Left unbounded it grows across streaming
    # sessions (measured: 3.7GB cache on top of 1.2GB weights, 11GB peak) and
    # drives the system into paging. 512MB keeps buffer reuse fast while capping
    # the idle footprint to roughly the resident model weights.
    mx.set_cache_limit(512 * 1024 * 1024)
    MB = 1024 * 1024

    def memlog(tag):
        log(f"mem[{tag}] active={mx.get_active_memory() / MB:.0f}MB "
            f"cache={mx.get_cache_memory() / MB:.0f}MB "
            f"peak={mx.get_peak_memory() / MB:.0f}MB")

    log(f"loading model: {MODEL}")
    t0 = time.time()
    try:
        backend = ParakeetBackend(MODEL) if ENGINE == "parakeet" else MlxAudioBackend(MODEL)
    except Exception as e:  # noqa: BLE001
        log(f"model load FAILED: {e}")
        with _lock:
            _state["error"] = str(e)
            waiting = list(_queue); _queue.clear()
        for s in waiting:
            s.text = f"__ERROR__ model failed to load: {e}"; s.done.set()
        return
    log(f"model loaded in {time.time() - t0:.2f}s")
    try:
        import numpy as np
        import wave
        warm = "/tmp/hs-parakeet-warm.wav"
        if not os.path.exists(warm):
            with wave.open(warm, "w") as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
                w.writeframes(np.zeros(SR, dtype=np.int16).tobytes())
        tw = time.time(); backend.transcribe(warm)
        log(f"warmup inference {time.time() - tw:.2f}s")
    except Exception as e:  # noqa: BLE001
        log(f"warmup skipped: {e}")
    mx.clear_cache()
    _state["load_s"] = round(time.time() - t0, 2)
    _state["ready"] = True
    memlog("ready")
    log("worker ready")
    while True:
        _wake.wait(); _wake.clear()
        while True:
            with _lock:
                s = _queue.popleft() if _queue else None
            if s is None:
                break
            if s.abort.is_set():
                s.done.set(); continue
            try:
                if s.kind == "batch":
                    _run_batch(backend, s)
                else:
                    _run_stream(backend, s)
            except Exception as e:  # noqa: BLE001
                log(f"{s.kind} error: {e}")
                s.text = f"__ERROR__ {e}"; s.done.set()
            # Idle now: hand cached Metal scratch buffers back to the OS so the
            # resident footprint between dictations stays at the model's weights.
            mx.clear_cache()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _body(self):
        n = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(n).decode("utf-8").strip() if n else ""

    def _reply(self, code, text, ctype="text/plain"):
        b = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", f"{ctype}; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        body = self._body()
        if self.path in ("/start", "/finish") and not STREAMS:
            # Fail fast: dictation treats any non-200 here as "use /transcribe".
            self._reply(501, f"__ERROR__ {MODEL_ID} does not stream; use /transcribe")
        elif self.path == "/start":
            _new_session("stream", body); self._reply(200, "started")
        elif self.path == "/finish":
            with _lock:
                s = _current["sess"]
            if s is None:
                self._reply(500, "__ERROR__ no session"); return
            s.finish.set()
            if s.done.wait(timeout=30):
                t = s.text or ""
                self._reply(200 if not t.startswith("__ERROR__") else 500, t)
            else:
                self._reply(500, "__ERROR__ timeout")
        elif self.path == "/cancel":
            with _lock:
                s = _current["sess"]
            if s is not None:
                s.abort.set()
            self._reply(200, "cancelled")
        elif self.path == "/transcribe":
            s = _new_session("batch", body)
            if s.done.wait(timeout=60):
                t = s.text or ""
                self._reply(200 if not t.startswith("__ERROR__") else 500, t)
            else:
                self._reply(500, "__ERROR__ timeout")
        else:
            self._reply(404, "no")

    def do_GET(self):
        if self.path == "/partial":
            with _lock:
                s = _current["sess"]
            txt = s.partial if (s is not None and not s.done.is_set()) else ""
            self._reply(200, txt)
        elif self.path == "/health":
            self._reply(200, json.dumps({
                "engine": ENGINE, "model": MODEL_ID, "path": MODEL,
                "streams": STREAMS, "ready": _state["ready"],
                "error": _state["error"], "load_s": _state["load_s"],
                "pid": os.getpid(),
            }), "application/json")
        else:
            self._reply(200, "ok")


threading.Thread(target=worker, daemon=True).start()
log(f"listening on http://{HOST}:{PORT} ({MODEL_ID})")
ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
