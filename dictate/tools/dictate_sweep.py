#!/usr/bin/env python3
"""Record every pass of a replayed take, then sweep the commit rule over them.

The recording is the expensive half and does not depend on the thresholds: the
pass schedule is set by the audio and by what inference costs, so one run of the
model serves the whole grid. Each take is replayed on a virtual clock that pays
the true measured cost of every pass, and every pass's tokens are kept.

  record:  M=<snapshot> python dictate/tools/dictate_sweep.py record out.json take.wav …
  sweep:   python dictate/tools/dictate_sweep.py sweep out.json
  blame:   python dictate/tools/dictate_sweep.py blame out.json <margin> <conf>
"""

from __future__ import annotations

import json
import os
import sys
import time
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from dictate import CommitState, Token, normalize, words  # noqa: E402

SR = 16000
IDLE = 0.02
INTERVAL = float(os.environ.get("INTERVAL", "1.0"))
BACKOFF = float(os.environ.get("BACKOFF", "3.0"))
MIN_AUDIO = 0.5


def load(path):
    with wave.open(path) as w:
        raw = w.readframes(w.getnframes())
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0


def record(out_path, paths):
    from parakeet_mlx import from_pretrained
    from parakeet_mlx.audio import get_logmel
    import mlx.core as mx

    model = from_pretrained(os.environ["M"])
    pc = model.preprocessor_config
    # The warm server does a warm-up inference at startup, so the first real
    # take never pays MLX's graph compilation. Without this the first take gets
    # a 1.5s "pass" and backs off past five of its own polls.
    for _ in range(2):
        model.generate(get_logmel(mx.array(np.zeros(SR, dtype=np.float32)), pc))

    def run(samples):
        t0 = time.perf_counter()
        r = model.generate(get_logmel(mx.array(samples), pc))[0]
        cost = time.perf_counter() - t0
        return [{"t": tk.text, "s": round(tk.start, 3), "e": round(tk.end, 3),
                 "c": round(float(tk.confidence), 4)} for tk in r.tokens], cost

    takes = []
    for p in sorted(paths):
        audio = load(p)
        dur = len(audio) / SR
        now, fed, next_due, passes, busy = 0.0, 0.0, 0.0, [], 0.0
        while True:
            avail = min(dur, now)
            fed = max(fed, avail)
            if fed >= MIN_AUDIO and now >= next_due:
                toks, cost = run(audio[:int(fed * SR)])
                now += cost
                busy += cost
                passes.append({"audio_s": round(fed, 3), "tok": toks,
                               "ms": round(cost * 1000)})
                next_due = now + max(INTERVAL, BACKOFF * cost)
                continue
            if fed >= dur:
                break
            now += IDLE
        release_at = now
        toks, cost = run(audio)
        takes.append({
            "take": os.path.basename(p), "audio_s": round(dur, 2),
            "passes": passes, "final": toks,
            "duty": round((busy + cost) / release_at, 3),
            "final_ms": round(cost * 1000),
        })
        print(f"  recorded {os.path.basename(p):<30} {dur:5.1f}s  "
              f"{len(passes):>3} passes  duty {takes[-1]['duty']:.2f}", flush=True)
    with open(out_path, "w") as f:
        json.dump(takes, f)
    print(f"-> {out_path}")


def toks(raw):
    return [Token(t["t"], t["s"], t["e"], t["c"]) for t in raw]


def grade(take, margin, conf, agg="min"):
    """Run the commit rule over one recorded take. Returns the verdict."""
    st = CommitState(margin_s=margin, confidence_floor=conf, aggregate=agg)
    for p in take["passes"]:
        st.advance(toks(p["tok"]), p["audio_s"])
    final = "".join(t["t"] for t in take["final"]).strip()
    live_w = [normalize(w) for w in st.text.split()]
    final_w = [normalize(w) for w in final.split()]
    return {
        "take": take["take"],
        "ok": final_w[:len(live_w)] == live_w,
        "contradicted": st.contradicted,
        "live_chars": len(st.text),
        "final_chars": len(final),
        "live": st.text,
        "final": final,
    }


def sweep(path):
    takes = json.load(open(path))
    print(f"\n  {len(takes)} takes, "
          f"{sum(t['audio_s'] for t in takes):.1f}s of speech, "
          f"interval={INTERVAL}s backoff={BACKOFF}\n")
    print(f"  {'agg':>6}{'margin':>8}{'floor':>7}{'bad':>6}{'typed live':>14}{'clean':>9}")
    print("  " + "-" * 50)
    best = []
    for agg in ("min",):
        for margin in (0.75, 1.0, 1.2, 1.5, 2.0):
            for conf in (0.0, 0.75, 0.80, 0.85, 0.90):
                rows = [grade(t, margin, conf, agg) for t in takes]
                bad = [r for r in rows if not r["ok"]]
                live = sum(r["live_chars"] for r in rows)
                total = sum(r["final_chars"] for r in rows)
                clean = sum(1 for r in rows if r["ok"])
                best.append((len(bad), -live, agg, margin, conf, live, total, clean))
                if len(bad) <= 3:
                    print(f"  {agg:>6}{margin:>8.1f}{conf:>7.2f}{len(bad):>6}"
                          f"{live:>8}/{total:<5}{100 * live / total:>4.0f}%"
                          f"{clean:>6}/{len(takes)}")
    best.sort()
    bad, _, agg, margin, conf, live, total, clean = best[0]
    print(f"\n  best: agg={agg} margin={margin}s floor={conf} -> {bad} corrections, "
          f"{100 * live / total:.0f}% typed live, {clean}/{len(takes)} takes clean")


def blame(path, margin, conf):
    takes = json.load(open(path))
    for t in takes:
        r = grade(t, margin, conf)
        flag = "ok " if r["ok"] else "BAD"
        print(f"\n  [{flag}] {r['take']}  {100 * r['live_chars'] / max(r['final_chars'], 1):.0f}%")
        print(f"    live : {r['live']!r}")
        if not r["ok"]:
            print(f"    final: {r['final']!r}")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    if cmd == "record":
        record(sys.argv[2], sys.argv[3:])
    elif cmd == "sweep":
        sweep(sys.argv[2])
    elif cmd == "blame":
        blame(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
