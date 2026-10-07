#!/usr/bin/env python3
# Warm pocket-tts synthesis server — the "voice" behind apps/tts.lua.
#
#   POST /speak    body=<text>   [header X-Voice: alba]  -> streams the audio as it is made
#   POST /speak    [header X-Format: path]               -> writes a WAV, returns its path
#   GET  /health                                          -> "ok" once the model is resident
#   GET  /                                                -> "ok"
#
# Mirrors parakeet_server.py: the model is loaded once and kept in memory so each
# request pays only synthesis time (~1/6 real-time on an M4 CPU) instead of the
# multi-second cold start of `pocket-tts generate`. Synthesis is serialised on a
# lock — pocket-tts is CPU-bound and not thread-safe, and apps/tts.lua already
# feeds it one chunk at a time, so there is never useful concurrency to exploit.
#
# The generation flow mirrors pocket_tts.main.generate (the library's own CLI):
#   model = TTSModel.load_model(language=...)
#   state = model.get_state_for_audio_prompt(voice)          # predefined name / url / path
#   chunks = model.generate_audio_stream(model_state=state, text_to_generate=text)
# Voice states are cached per voice string (get_state_for_audio_prompt fetches the
# prompt audio from HF the first time), so repeat requests skip that download.
#
# ---- why /speak streams ----------------------------------------------------
# generate_audio_stream is a real stream: it runs the language model on one
# thread, the mimi decoder on another, and yields each ~80ms frame of audio the
# moment it is decoded. The server used to pour all of that into
# stream_audio_chunks(), which writes a WAV, and answer with the path once the
# file was closed — so every caller waited out the whole utterance to hear its
# first syllable. Measured on 2026-10-07 that cost 1.10s at the median and 3.66s
# at p90 for the voice agent's first sentence.
#
# Now the frames go straight onto the socket under chunked transfer encoding,
# behind a 44-byte WAV header, and first audio arrives at the first frame
# instead of at the end. The headers are held back until that first frame is in
# hand, which costs nothing (it is the thing we are waiting for) and keeps a
# failed voice load a real 500 rather than a stream that stops early.
#
# X-Format: path keeps the old behaviour for callers that need a finished file.
# apps/tts.lua is the one that does: it plays through afplay, which wants a path
# and will not read a growing file.
import os
import threading
import time
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = "127.0.0.1"
PORT = int(os.environ.get("POCKET_TTS_PORT", "8791"))
DEFAULT_VOICE = os.environ.get("POCKET_TTS_VOICE", "").strip()   # "" -> language default
LANGUAGE = os.environ.get("POCKET_TTS_LANGUAGE", "english").strip() or None
OUT_DIR = os.environ.get("POCKET_TTS_OUT", "/tmp")
ROTATE = 8  # keep the last N wavs so a file is never overwritten while afplay reads it

# Matches what pocket_tts' own StreamingWAVWriter.finalize appends. Players clip
# the last few milliseconds without it, and it is free: it rides out after the
# audio the listener is already hearing.
TAIL_SILENCE_S = 0.2

_ready = threading.Event()
_lock = threading.RLock()         # serialise synthesis + the output counter (re-entrant:
                                  # the handler holds it across synth_to_file(), which
                                  # re-acquires it for the rotating counter)
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
    # Drained rather than written: this is the path real requests take now.
    try:
        tw = time.time()
        with _lock:
            for _ in synth_stream("Ready.", DEFAULT_VOICE):
                pass
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


def wav_header(sample_rate, channels=1, bits=16, data_size=0xFFFFFFFF):
    """A 44-byte PCM WAV header.

    The default sizes are the all-ones "length unknown" marker, which is what a
    stream has: the server cannot know how long an utterance is until it has
    finished saying it. Readers that care (ffmpeg, and pipecat, which just skips
    44 bytes) treat it as "read until the stream ends".
    """
    block_align = channels * bits // 8
    riff_size = data_size if data_size == 0xFFFFFFFF else data_size + 36
    return b"".join([
        b"RIFF", riff_size.to_bytes(4, "little"), b"WAVE",
        b"fmt ", (16).to_bytes(4, "little"),
        (1).to_bytes(2, "little"),              # PCM, uncompressed
        channels.to_bytes(2, "little"),
        sample_rate.to_bytes(4, "little"),
        (sample_rate * block_align).to_bytes(4, "little"),
        block_align.to_bytes(2, "little"),
        bits.to_bytes(2, "little"),
        b"data", data_size.to_bytes(4, "little"),
    ])


def _pcm16(chunk):
    """One generated chunk — a [samples] float tensor — as little-endian int16.

    The same conversion pocket_tts.data.audio.StreamingWAVWriter does on its way
    to disk, written with tensor methods so this server never imports torch.
    """
    return chunk.clamp(-1, 1).mul(32767).short().detach().cpu().numpy().tobytes()


def synth_stream(text, voice):
    """Yield PCM16 bytes for `text` as pocket-tts decodes them.

    Callers must hold _lock for the whole iteration: generate_audio_stream is
    documented as not thread-safe and it walks the shared model.
    """
    model = _model["m"]
    state = _voice_state(voice)
    for chunk in model.generate_audio_stream(model_state=state, text_to_generate=text):
        yield _pcm16(chunk)


def _patch_wav_sizes(path):
    """Rewrite the RIFF and data chunk lengths to match what is on disk.

    stream_audio_chunks writes the header before it knows how much audio there
    is and stamps a 2GB placeholder it never goes back to fix. afplay reads to
    EOF so it never noticed, but anything that trusts the header — ffmpeg, and
    parakeet-mlx through it — waits forever for audio that is not coming.
    """
    size = os.path.getsize(path)
    with open(path, "r+b") as f:
        idx = f.read(4096).find(b"data")
        if idx < 0 or size < idx + 8:
            log(f"warning: no data chunk found in {path}, header left as written")
            return
        f.seek(4)
        f.write((size - 8).to_bytes(4, "little"))            # RIFF chunk size
        f.seek(idx + 4)
        f.write((size - idx - 8).to_bytes(4, "little"))      # data chunk size


def synth_to_file(text, voice):
    """Synthesise text to a WAV file, return its path. Raises on failure.

    For callers that cannot consume a stream — afplay, and the checks that want
    to inspect a finished file. Everything else gets the audio over the wire.
    """
    model = _model["m"]
    state = _voice_state(voice)
    chunks = model.generate_audio_stream(model_state=state, text_to_generate=text)

    with _lock:
        n = _counter["n"] % ROTATE
        _counter["n"] += 1
    path = os.path.join(OUT_DIR, f"hs-tts-{n}.wav")
    _helpers["stream_audio_chunks"](path, chunks, _model["sr"])   # writes the WAV
    _patch_wav_sizes(path)
    return path


class Handler(BaseHTTPRequestHandler):
    # Chunked transfer encoding is an HTTP/1.1 feature; the default 1.0 has no
    # way to say "more audio is coming" short of closing the socket.
    protocol_version = "HTTP/1.1"
    # Small writes are the point here — one ~80ms frame of audio at a time —
    # so Nagle must not sit on them waiting for company.
    disable_nagle_algorithm = True
    # HTTP/1.1 keeps connections open. Bound how long an idle one holds a thread.
    timeout = 300

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

    def _param(self, name):
        """A query-string value from the request path, or ''."""
        parts = self.path.split("?", 1)
        if len(parts) < 2:
            return ""
        for field in parts[1].split("&"):
            key, _, value = field.partition("=")
            if key == name:
                return value.strip().lower()
        return ""

    def _wants_path(self):
        """True when the caller asked for a finished WAV instead of the stream."""
        fmt = (self.headers.get("X-Format") or "").strip().lower() or self._param("format")
        return fmt == "path"

    # ---- chunked transfer encoding ----------------------------------------
    # Written by hand: BaseHTTPRequestHandler will set the header but does not
    # frame the body. Every write returns False once the client has hung up,
    # which is how a barged-in sentence stops costing CPU.

    def _write_chunk(self, data):
        if not data:
            return True
        try:
            self.wfile.write(f"{len(data):x}\r\n".encode("ascii") + data + b"\r\n")
            return True
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
            return False

    def _begin_stream(self):
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        return self._write_chunk(wav_header(_model["sr"]))

    def _end_stream(self):
        try:
            self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def _speak_stream(self, text, voice):
        """Answer /speak with the audio itself, frame by frame."""
        started = False
        try:
            # closing() inside the lock: abandoning the generator unwinds
            # pocket-tts' own machinery, which is no more thread-safe than
            # driving it forward.
            with _lock, closing(synth_stream(text, voice)) as stream:
                for pcm in stream:
                    # The first frame buys the right to commit to a 200: before
                    # it, a bad voice or a model error can still be reported.
                    if not started:
                        started = True
                        if not self._begin_stream():
                            return
                    if not self._write_chunk(pcm):
                        return
                if not started and not self._begin_stream():
                    return
                self._write_chunk(bytes(int(_model["sr"] * TAIL_SILENCE_S) * 2))
            self._end_stream()
        except Exception as e:  # noqa: BLE001
            log(f"synth error: {e}")
            if started:
                # Mid-stream: there is no status code left to send. Drop the
                # connection without the terminating chunk so the client sees a
                # broken transfer instead of a sentence that just stops early.
                self.close_connection = True
            else:
                self._reply(500, f"__ERROR__ {e}")

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/health":
            self._reply(200 if _ready.is_set() else 503,
                        "ok" if _ready.is_set() else "loading")
        else:
            self._reply(200, "ok")

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/speak":
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
        if not self._wants_path():
            self._speak_stream(text, voice)
            return
        try:
            with _lock:
                # hold the lock across synthesis: pocket-tts is CPU-bound and not
                # guaranteed re-entrant; serial matches the Lua-side queue anyway.
                path = synth_to_file(text, voice)
            self._reply(200, path)
        except Exception as e:  # noqa: BLE001
            log(f"synth error: {e}")
            self._reply(500, f"__ERROR__ {e}")


threading.Thread(target=_load, daemon=True).start()
log(f"listening on http://{HOST}:{PORT}")
try:
    # Threading so /health still answers while a sentence is being spoken. The
    # voice agent probes it with a one-second deadline before every French
    # sentence, and a single-threaded server busy for four seconds would fail
    # that probe and demote the French model for half a minute.
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
except KeyboardInterrupt:
    pass
