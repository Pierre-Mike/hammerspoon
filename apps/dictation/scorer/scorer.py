# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["torch", "transformers", "phonemizer", "soundfile", "numpy"]
# ///
"""The pronunciation scorer: one warm phoneme model behind a local HTTP port.

apps/dictation/pronunciation.lua starts this with `uv run --script scorer.py`
when there is a take to look at or a lesson open, and stops it after a few
idle minutes, so the model only holds memory while it is being used.

  GET  /health    {"ok": true, "loaded": bool}
  POST /analyze   {"wav", "text", "clips"?} -> {"words": [...], "duration"}
                  one dictation take; flagged words get a clip cut into `clips`
  POST /score     {"wav", "text"} -> the same shape, for a lesson attempt

The model is facebook/wav2vec2-lv-60-espeak-cv-ft. It was trained on espeak's
phone symbols, which is why espeak is also what says how a word should sound:
both sides of the comparison spell sounds the same way. The comparison itself
is align.py. Nothing leaves the machine.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import align  # noqa: E402

MODEL_ID = "facebook/wav2vec2-lv-60-espeak-cv-ft"
ESPEAK_LIB = "/opt/homebrew/lib/libespeak-ng.dylib"
RATE = 16000

_state: dict = {"loaded": False, "error": None}
_ready = threading.Event()
_lock = threading.Lock()


def log(msg: str) -> None:
    print(time.strftime("%H:%M:%S ") + msg, file=sys.stderr, flush=True)


def load() -> None:
    try:
        if os.path.exists(ESPEAK_LIB):
            os.environ.setdefault("PHONEMIZER_ESPEAK_LIBRARY", ESPEAK_LIB)
        t = time.time()
        import torch
        from phonemizer.backend import EspeakBackend
        from transformers import AutoModelForCTC, AutoProcessor
        proc = AutoProcessor.from_pretrained(MODEL_ID)
        # The repo ships pytorch_model.bin; without this, transformers also
        # fetches a converted safetensors copy, another 1.26 GB.
        model = AutoModelForCTC.from_pretrained(MODEL_ID, use_safetensors=False).eval()
        vocab = proc.tokenizer.get_vocab()
        mask = torch.full((len(vocab),), float("-inf"))
        mask[align.allowed_ids(vocab)] = 0.0
        _state.update(
            mask=mask,
            torch=torch, proc=proc, model=model,
            id_to_phone={i: p for p, i in vocab.items()},
            blank=proc.tokenizer.pad_token_id,
            espeak=EspeakBackend("en-us", with_stress=False),
            loaded=True,
        )
        log(f"model loaded in {time.time() - t:.1f}s")
    except Exception as e:  # reported on /health and on every request
        _state["error"] = f"{type(e).__name__}: {e}"
        log("load failed: " + _state["error"])
    finally:
        _ready.set()


def expected_phones(words: list[str]) -> list[list[str]]:
    from phonemizer.separator import Separator
    out = _state["espeak"].phonemize(words, separator=Separator(phone=" ", word=""), strip=True)
    return [align.split_phones(s) for s in out]


# Silence either side of the audio. A clip that starts or stops on a word
# loses its edge sounds: macOS `say` reading "think" came back without its k,
# "pronunciation" without its p. Times are shifted back after.
PAD_S = 0.3


def recognize(audio) -> list[align.Heard]:
    import numpy as np
    torch = _state["torch"]
    pad = np.zeros(int(PAD_S * RATE), dtype="float32")
    x = _state["proc"](np.concatenate([pad, audio, pad]), sampling_rate=RATE, return_tensors="pt").input_values
    with torch.no_grad():
        logits = _state["model"](x).logits[0]
        ids = (logits + _state["mask"][: logits.shape[-1]]).argmax(-1).tolist()
    heard = align.ctc_runs(ids, _state["blank"], _state["id_to_phone"])
    for h in heard:
        h.start, h.end = max(0.0, round(h.start - PAD_S, 3)), max(0.0, round(h.end - PAD_S, 3))
    return heard


def read_wav(path: str):
    import numpy as np
    import soundfile as sf
    audio, sr = sf.read(path, dtype="float32", always_2d=False)
    if getattr(audio, "ndim", 1) > 1:
        audio = audio.mean(axis=1)
    if sr != RATE:  # dictation records at 16 kHz; anything else is resampled crudely
        n = int(len(audio) * RATE / sr)
        audio = np.interp(np.linspace(0, len(audio), n, endpoint=False),
                          np.arange(len(audio)), audio).astype("float32")
    return audio


def cut_clip(audio, span, path: str) -> None:
    import soundfile as sf
    a, b = (int(t * RATE) for t in span)
    sf.write(path, audio[a:b], RATE, subtype="PCM_16")


def run(body: dict, clips: bool) -> dict:
    words = align.words_of(body.get("text", ""))
    audio = read_wav(body["wav"])
    duration = len(audio) / RATE
    if not words:
        return {"words": [], "duration": duration}
    with _lock:
        heard = recognize(audio)
        expected = expected_phones(words)
    results = align.score_words(words, expected, heard)
    out = []
    clip_dir = body.get("clips") if clips else None
    if clip_dir:
        os.makedirs(clip_dir, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for r in results:
        j = r.to_json()
        span = align.clip_span(r, duration)
        if clip_dir and r.flagged and span:
            path = os.path.join(clip_dir, f"{r.word.replace(chr(39), '')}-{stamp}-{r.index}.wav")
            cut_clip(audio, span, path)
            j["clip"] = path
        out.append(j)
    return {"words": out, "duration": round(duration, 2),
            "heard": " ".join(h.phone for h in heard)}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, obj: dict) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            return self._send(200, {"ok": True, "loaded": _state["loaded"], "error": _state["error"]})
        self._send(404, {"error": "no such route"})

    def do_POST(self):
        if self.path not in ("/analyze", "/score"):
            return self._send(404, {"error": "no such route"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        except ValueError:
            return self._send(400, {"error": "body is not JSON"})
        if not isinstance(body.get("wav"), str) or not os.path.exists(body["wav"]):
            return self._send(400, {"error": "no such wav"})
        _ready.wait()
        if not _state["loaded"]:
            return self._send(503, {"error": _state["error"] or "model not loaded"})
        try:
            t = time.time()
            res = run(body, clips=self.path == "/analyze")
            log(f"{self.path} {len(res['words'])} words over {res['duration']}s in {time.time() - t:.2f}s")
            self._send(200, res)
        except Exception as e:
            log(f"{self.path} failed: {type(e).__name__}: {e}")
            self._send(500, {"error": f"{type(e).__name__}: {e}"})

    def log_message(self, *_):  # one line per request comes from do_POST instead
        pass


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8796)
    args = ap.parse_args()
    srv = HTTPServer(("127.0.0.1", args.port), Handler)
    threading.Thread(target=load, daemon=True).start()
    log(f"listening on 127.0.0.1:{args.port}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
