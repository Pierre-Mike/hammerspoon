#!/usr/bin/env python3
"""Replay recorded takes through the live-dictation transcriber and grade it.

Answers the three questions the design has to get right, per take:

  corrections  was the text typed live a prefix of the final transcript? If it
               was, the only thing left to do at release is append. If it was
               not, the user needs characters taken back.
  coverage     how much of the final transcript was already on screen when the
               user let go of Fn.
  lag          how long after a word was spoken it reached the keyboard.

The clock is virtual and the model is real. Audio arrives at 1x, and a pass
charges its true measured inference cost against the same timeline, so the
back-off and the duty cycle behave exactly as they would live — without waiting
out the takes in real time.

  M=<snapshot dir> python dictate/tools/dictate_replay.py take.wav [take.wav ...]
"""

from __future__ import annotations

import json
import os
import sys
import time
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from dictate import StreamingTranscriber, Token, normalize  # noqa: E402

SR = 16000
IDLE = 0.02        # the server's sleep when there is nothing to do


class VirtualClock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def advance(self, d):
        self.t += d


def load(path):
    with wave.open(path) as w:
        assert w.getframerate() == SR, f"{path} is not {SR} Hz"
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def model_transcribe(model, clock):
    import mlx.core as mx
    from parakeet_mlx.audio import get_logmel
    pc = model.preprocessor_config

    def transcribe(samples):
        t0 = time.perf_counter()
        result = model.generate(get_logmel(mx.array(samples), pc))[0]
        # Inference costs what it costs; the simulated clock pays for it, which
        # is what makes the back-off and the duty cycle below meaningful.
        clock.advance(time.perf_counter() - t0)
        return [Token(t.text, t.start, t.end, float(t.confidence))
                for t in result.tokens]

    return transcribe


def replay(model, path, **opts):
    audio = load(path)
    dur = len(audio) / SR
    clock = VirtualClock()
    st = StreamingTranscriber(model_transcribe(model, clock), clock=clock, **opts)

    fed = 0.0
    events = []          # (audio_s at the pass, words added)
    busy = 0.0
    while True:
        avail = min(dur, clock())
        if avail > fed:
            st.feed(audio[int(fed * SR):int(avail * SR)])
            fed = avail
        if fed > 0 and st.due():
            before = clock()
            chunk = st.step()
            busy += clock() - before
            if chunk:
                events.append((st.audio_s, len(chunk.split())))
            continue
        if fed >= dur:
            break
        clock.advance(IDLE)

    live = st.stable
    release_at = clock()
    t0 = clock()
    final = st.finish()
    tail_s = clock() - t0
    busy += tail_s

    # Grading. Words, not characters: punctuation and casing behind the cursor
    # are allowed to drift, and a comma that became a period is not a wrong word.
    live_w = [normalize(w) for w in live.split()]
    final_w = [normalize(w) for w in final.split()]
    prefix_ok = final_w[:len(live_w)] == live_w
    chars_ok = final.startswith(live)

    # Lag: a committed word's distance from when it was spoken. The final pass
    # knows when each word ended, and the committed words are its first N.
    from dictate import words as split_words
    lags = []
    if prefix_ok and live_w:
        final_tokens = st._transcribe(st._audio())           # noqa: SLF001
        fw = split_words(list(final_tokens))
        i = 0
        for at, n in events:
            for _ in range(n):
                if i < len(fw) and i < len(live_w):
                    lags.append(at - fw[i].end)
                i += 1

    return {
        "take": os.path.basename(path),
        "audio_s": round(dur, 2),
        "passes": st.snapshot().passes,
        "duty": round(busy / max(release_at, 1e-9), 3),
        "live_chars": len(live),
        "final_chars": len(final),
        "coverage": round(len(live) / len(final), 3) if final else 0.0,
        "word_coverage": round(len(live_w) / len(final_w), 3) if final_w else 0.0,
        "prefix_ok": prefix_ok,
        "chars_ok": chars_ok,
        "contradicted": st.contradicted,
        "lag_mean": round(sum(lags) / len(lags), 2) if lags else None,
        "lag_max": round(max(lags), 2) if lags else None,
        "tail_s": round(tail_s, 2),
        "live": live,
        "final": final,
    }


def main():
    paths = sorted(sys.argv[1:])
    if not paths:
        sys.exit(__doc__)
    import mlx.core as mx
    from parakeet_mlx import from_pretrained
    from parakeet_mlx.audio import get_logmel
    model = from_pretrained(os.environ["M"])
    # The warm server warms up at startup, so a real take never pays MLX's graph
    # compilation. Without this the first take replayed gets a 1.5-second
    # "pass" and backs off past five of its own polls.
    for _ in range(2):
        model.generate(get_logmel(mx.array(np.zeros(SR, dtype=np.float32)),
                                  model.preprocessor_config))
    from dictate import CONFIDENCE_FLOOR, INTERVAL_S, MARGIN_S
    opts = {
        "margin_s": float(os.environ.get("MARGIN", MARGIN_S)),
        "confidence_floor": float(os.environ.get("CONF", CONFIDENCE_FLOOR)),
        "interval_s": float(os.environ.get("INTERVAL", INTERVAL_S)),
    }
    rows = [replay(model, p, **opts) for p in paths]

    print(f"\n  margin={opts['margin_s']}s floor={opts['confidence_floor']} "
          f"interval={opts['interval_s']}s   model={os.path.basename(os.environ['M'])[:12]}\n")
    head = f"  {'take':<28}{'audio':>7}{'passes':>8}{'duty':>7}{'live%':>7}{'words%':>8}{'lag':>7}{'ok':>5}"
    print(head)
    print("  " + "-" * (len(head) - 2))
    for r in rows:
        print(f"  {r['take']:<28}{r['audio_s']:>6.1f}s{r['passes']:>8}{r['duty']:>7.2f}"
              f"{100 * r['coverage']:>6.0f}%{100 * r['word_coverage']:>7.0f}%"
              f"{(r['lag_mean'] if r['lag_mean'] is not None else 0):>6.1f}s"
              f"{'  yes' if r['prefix_ok'] else '   NO':>5}")
    total_a = sum(r["audio_s"] for r in rows)
    live_c = sum(r["live_chars"] for r in rows)
    final_c = sum(r["final_chars"] for r in rows)
    lags = [r["lag_mean"] for r in rows if r["lag_mean"] is not None]
    bad = [r["take"] for r in rows if not r["prefix_ok"]]
    print("  " + "-" * (len(head) - 2))
    print(f"  {len(rows)} takes, {total_a:.1f}s of speech")
    print(f"  typed before release: {live_c}/{final_c} characters "
          f"({100 * live_c / final_c:.0f}%)")
    print(f"  corrections needed:   {len(bad)}  {bad if bad else ''}")
    print(f"  contradictions:       {sum(1 for r in rows if r['contradicted'])}")
    if lags:
        print(f"  lag:                  {sum(lags) / len(lags):.1f}s mean, "
              f"{max(r['lag_max'] for r in rows if r['lag_max'] is not None):.1f}s worst")
    out = os.environ.get("OUT")
    if out:
        with open(out, "w") as f:
            json.dump(rows, f, indent=2)
        print(f"  detail -> {out}")


if __name__ == "__main__":
    main()
