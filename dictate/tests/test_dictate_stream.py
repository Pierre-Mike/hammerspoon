"""Driving a whole take through a scripted model: pacing, back-off, and what
the poll sees at each second."""

import numpy as np
import pytest

from dictate import StreamingTranscriber, Token, pcm_to_float32

SR = 16000


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def tick(self, d):
        self.t += d


class Model:
    """Transcribes however much audio it is given, from a scripted word list.

    One word per 0.5s of audio, so a pass over 3s of audio "hears" six words.
    `cost` is how long the clock says the pass took.
    """

    def __init__(self, script, *, clock=None, cost=0.0, conf=1.0, rate=0.5):
        self.script = script.split()
        self.clock = clock
        self.cost = cost
        self.conf = conf
        self.rate = rate
        self.calls = 0
        self.lengths = []

    def __call__(self, samples):
        self.calls += 1
        audio_s = len(samples) / SR
        self.lengths.append(round(audio_s, 3))
        if self.clock:
            self.clock.tick(self.cost)
        n = min(len(self.script), int(audio_s / self.rate))
        return [
            Token(" " + w, i * self.rate, (i + 1) * self.rate,
                  self.conf if callable(self.conf) is False else self.conf)
            for i, w in enumerate(self.script[:n])
        ]


def audio(seconds):
    return np.zeros(int(seconds * SR), dtype=np.float32)


def new(model, clock, **kw):
    kw.setdefault("margin_s", 1.5)
    kw.setdefault("confidence_floor", 0.80)
    kw.setdefault("min_audio_s", 0.5)
    return StreamingTranscriber(model, clock=clock, **kw)


# ── Pacing ──────────────────────────────────────────────────────────────────

def test_no_pass_runs_before_there_is_audio_worth_one():
    c = Clock()
    s = new(Model("a b c"), c)
    s.feed(audio(0.2))
    c.tick(5.0)
    assert not s.due()
    assert s.step() == ""


def test_a_pass_runs_once_a_second_by_default():
    c = Clock()
    m = Model("one two three four five six seven eight")
    s = new(m, c, interval_s=1.0)
    for _ in range(5):
        s.feed(audio(1.0))
        c.tick(1.0)
        s.step()
    assert m.calls == 5
    assert m.lengths == [1.0, 2.0, 3.0, 4.0, 5.0]


def test_a_slow_pass_backs_the_next_one_off():
    c = Clock()
    m = Model("one two three", clock=c, cost=0.5)   # 0.5s per pass
    s = new(m, c, interval_s=1.0, backoff=3.0)
    s.feed(audio(2.0))
    s.step()                       # runs, costs 0.5s, next due 1.5s later
    assert m.calls == 1
    c.tick(1.0)
    assert not s.due()
    c.tick(0.6)
    assert s.due()


def test_a_fast_pass_still_waits_the_interval():
    c = Clock()
    m = Model("one two three", clock=c, cost=0.04)
    s = new(m, c, interval_s=1.0, backoff=3.0)
    s.feed(audio(2.0))
    s.step()
    c.tick(0.5)
    assert not s.due()
    c.tick(0.6)
    assert s.due()


# ── What reaches the cursor ─────────────────────────────────────────────────

def test_a_take_types_its_prefix_while_it_is_still_being_spoken():
    c = Clock()
    m = Model("alpha bravo charlie delta echo foxtrot")
    s = new(m, c, interval_s=1.0)
    typed = ""
    for _ in range(3):                       # 3s of audio, 1s at a time
        s.feed(audio(1.0))
        c.tick(1.0)
        typed += s.step()
    # 3s heard, margin 1.5s -> words ending at or before 1.5s: alpha, bravo, charlie
    assert typed == "alpha bravo charlie"
    assert s.stable == typed


def test_the_live_hypothesis_runs_ahead_of_what_was_typed():
    c = Clock()
    m = Model("alpha bravo charlie delta echo foxtrot")
    s = new(m, c, interval_s=1.0)
    for _ in range(3):
        s.feed(audio(1.0))
        c.tick(1.0)
        s.step()
    snap = s.snapshot()
    assert snap.text == "alpha bravo charlie delta echo foxtrot"
    assert snap.stable == "alpha bravo charlie"
    assert snap.text.startswith(snap.stable)


def test_finish_transcribes_everything_and_holds_the_typed_text_still():
    c = Clock()
    m = Model("alpha bravo charlie delta")
    s = new(m, c, interval_s=1.0)
    for _ in range(2):
        s.feed(audio(1.0))
        c.tick(1.0)
        s.step()
    before = s.stable
    final = s.finish()
    assert final == "alpha bravo charlie delta"
    assert s.stable == before          # finish types nothing; the caller does


def test_a_take_too_short_to_commit_still_comes_back_whole():
    c = Clock()
    m = Model("yes please")
    s = new(m, c, interval_s=1.0)
    s.feed(audio(1.0))
    c.tick(1.0)
    assert s.step() == ""
    assert s.finish() == "yes please"
    assert s.stable == ""


def test_low_confidence_keeps_everything_off_the_screen():
    c = Clock()
    m = Model("alpha bravo charlie delta echo foxtrot", conf=0.5)
    s = new(m, c, interval_s=1.0, confidence_floor=0.80)
    typed = ""
    for _ in range(4):
        s.feed(audio(1.0))
        c.tick(1.0)
        typed += s.step()
    assert typed == ""
    assert s.finish() == "alpha bravo charlie delta echo foxtrot"


def test_the_committed_prefix_is_always_a_prefix_of_the_final_transcript():
    c = Clock()
    m = Model("we cannot use the event anymore we are trying to get away from it")
    s = new(m, c, interval_s=1.0)
    for _ in range(9):
        s.feed(audio(1.0))
        c.tick(1.0)
        s.step()
    stable = s.stable
    final = s.finish()
    assert stable
    assert final.startswith(stable)


# ── Audio bookkeeping ───────────────────────────────────────────────────────

def test_audio_fed_in_small_pieces_is_one_buffer_to_the_model():
    c = Clock()
    m = Model("a b c d")
    s = new(m, c)
    for _ in range(10):
        s.feed(audio(0.2))
    c.tick(1.0)
    s.step()
    assert m.lengths == [2.0]
    assert s.audio_s == pytest.approx(2.0)


def test_feeding_nothing_is_not_an_error():
    s = new(Model("a"), Clock())
    s.feed(None)
    s.feed(np.zeros(0, dtype=np.float32))
    assert s.audio_s == 0.0


def test_pcm_bytes_become_mono_float32():
    raw = np.array([0, 16384, -16384, 32767], dtype=np.int16).tobytes()
    out = pcm_to_float32(raw)
    assert out.dtype == np.float32
    assert out == pytest.approx([0.0, 0.5, -0.5, 0.99997], abs=1e-4)


def test_a_half_sample_at_the_end_of_the_buffer_is_dropped():
    raw = np.array([1000, 2000], dtype=np.int16).tobytes() + b"\x01"
    assert len(pcm_to_float32(raw)) == 2
    assert len(pcm_to_float32(b"\x01")) == 0


def test_the_snapshot_reports_what_the_pass_cost():
    c = Clock()
    m = Model("a b c d e f", clock=c, cost=0.13)
    s = new(m, c)
    s.feed(audio(3.0))
    s.step()
    snap = s.snapshot()
    assert snap.pass_ms == 130
    assert snap.passes == 1
    assert snap.as_dict()["audio_s"] == 3.0
    assert snap.as_dict()["contradicted"] is False
