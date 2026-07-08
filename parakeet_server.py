#!/usr/bin/env python3
# Warm + streaming parakeet-mlx transcription server.
#
#   POST /transcribe  body=<wav path>  -> batch transcription (text back)
#   POST /start       body=<raw path>  -> stream a growing headerless s16le/16k
#                                          mono PCM file as it records
#   POST /finish                        -> drain remaining audio, return text
#   POST /cancel                        -> abort the current streaming session
#
# All MLX work runs on ONE dedicated worker thread (model loaded there too):
# MLX's Metal stream is thread-bound. The HTTP server (main thread) only hands
# the worker Session objects and signals them via events.
#
# Each /start makes a fresh Session and preempts (aborts) any in-flight one, so
# an orphaned session can never leak a stale transcript into a later /finish.
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

MODEL = os.environ.get("PARAKEET_MODEL_PATH") or sys.argv[1]
HOST = "127.0.0.1"
PORT = int(os.environ.get("PARAKEET_PORT", "8765"))

SR = 16000
BLOCK = SR          # 1.0s feed blocks: smaller first chunks drop the leading word
CONTEXT = (256, 256)
DEPTH = 2


def log(msg):
    print(f"[parakeet-server] {msg}", flush=True)


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
_current = {"sess": None}   # the live session (what /finish, /cancel act on)
_pending = {"sess": None}   # next session for the worker to pick up


def _new_session(kind, path):
    s = Session(kind, path)
    with _lock:
        prev = _current["sess"]
        if prev is not None and not prev.done.is_set():
            prev.abort.set()    # preempt any in-flight session
        _current["sess"] = s
        _pending["sess"] = s
    _wake.set()
    return s


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


def _run_stream(model, s):
    for _ in range(50):                     # wait for ffmpeg to create the file
        if os.path.exists(s.path):
            break
        time.sleep(0.02)
    t0, feeds, leftover, pending = time.time(), 0, b"", None
    with model.transcribe_stream(context_size=CONTEXT, depth=DEPTH) as st, \
            open(s.path, "rb") as fh:
        while not s.finish.is_set() and not s.abort.is_set():
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

    from parakeet_mlx import from_pretrained
    log(f"loading model: {MODEL}")
    t0 = time.time()
    model = from_pretrained(MODEL)
    log(f"model loaded in {time.time() - t0:.2f}s")
    try:
        import numpy as np
        import wave
        warm = "/tmp/hs-parakeet-warm.wav"
        if not os.path.exists(warm):
            with wave.open(warm, "w") as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
                w.writeframes(np.zeros(SR, dtype=np.int16).tobytes())
        tw = time.time(); model.transcribe(warm)
        log(f"warmup inference {time.time() - tw:.2f}s")
    except Exception as e:  # noqa: BLE001
        log(f"warmup skipped: {e}")
    mx.clear_cache()
    memlog("ready")
    log("worker ready")
    while True:
        _wake.wait(); _wake.clear()
        with _lock:
            s = _pending["sess"]; _pending["sess"] = None
        if s is None or s.abort.is_set():
            continue
        try:
            if s.kind == "batch":
                s.text = (model.transcribe(s.path).text or "").strip()
                s.done.set()
            else:
                _run_stream(model, s)
        except Exception as e:  # noqa: BLE001
            log(f"{s.kind} error: {e}")
            s.text = f"__ERROR__ {e}"; s.done.set()
        # Idle now: hand cached Metal scratch buffers back to the OS so the
        # resident footprint between dictations stays at the model's ~1.2GB.
        mx.clear_cache()


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

    def do_POST(self):
        body = self._body()
        if self.path == "/start":
            _new_session("stream", body); self._reply(200, "started")
        elif self.path == "/finish":
            with _lock:
                s = _current["sess"]
            if s is None:
                self._reply(500, "__ERROR__ no session"); return
            s.finish.set()
            if s.done.wait(timeout=30):
                self._reply(200, s.text or "")
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
        else:
            self._reply(200, "ok")


threading.Thread(target=worker, daemon=True).start()
log(f"listening on http://{HOST}:{PORT}")
HTTPServer((HOST, PORT), Handler).serve_forever()
