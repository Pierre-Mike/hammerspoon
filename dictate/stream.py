"""Re-transcribe the growing audio of a take, and say what is safe to type.

The parakeet model this machine runs commits nothing mid-stream. Its streaming
mode splits tokens into a finalised list and a draft list, but the split point
is `length - context_size[1] * depth`, which at the shipped settings is 40.96
seconds of lookahead: measured over a five-take corpus, the finalised list was
empty on every block of every take, including a 19.5s one. Shrinking the
lookahead to force early finalisation starves the encoder and the transcript
falls apart. parakeet-tdt-0.6b-v2 was trained with full attention; it is not one
of NVIDIA's cache-aware checkpoints.

So stability comes from here instead. Each pass runs the ORDINARY batch model
over all the audio so far, which means every pass has batch accuracy, and
successive passes are compared to decide what has settled (see commit.py).

It is affordable. `generate` over a growing prefix costs roughly 10ms per second
of audio on top of a 30ms floor — 41ms at 1s, 130ms at 10s, 220ms at 19.5s — so
a fixed poll would creep up to a busy third of the wall clock on a long take.
`interval` therefore backs off to `backoff x` the last pass, which settles at
about 2s for a 60s take.

This class owns no thread, no clock and no model. The caller feeds it audio,
asks whether a pass is due, and runs one; `transcribe` is injected, so a spec
drives a whole take through a scripted model in microseconds.
"""

from __future__ import annotations

import threading
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass

import numpy as np

from dictate.commit import (
    CONFIDENCE_FLOOR,
    MARGIN_S,
    CommitState,
    Token,
)

SAMPLE_RATE = 16000
# How often a pass is attempted, before back-off. Measured over ten takes, going
# from one pass a second to one every 0.4s lifts the text on screen at release
# from 66% to 82%, because the last pass before the user lets go is that much
# less stale. It costs a duty cycle of 0.21 at worst, on the 24-second take.
INTERVAL_S = 0.4
# Next pass is due `BACKOFF` x the last pass's cost, when that is the longer
# wait. Keeps the worker's duty cycle under a third however long the take runs.
BACKOFF = 3.0
# Below this there is not enough audio to be worth a pass, let alone a commit.
MIN_AUDIO_S = 0.5

Transcribe = Callable[[np.ndarray], Sequence[Token]]


@dataclass(frozen=True)
class Snapshot:
    """What a poll sees. `stable` is already at the cursor; `text` is not."""

    audio_s: float
    text: str
    stable: str
    contradicted: bool
    passes: int
    pass_ms: int

    def as_dict(self) -> dict:
        return {
            "audio_s": round(self.audio_s, 3),
            "text": self.text,
            "stable": self.stable,
            "contradicted": self.contradicted,
            "passes": self.passes,
            "pass_ms": self.pass_ms,
        }


class StreamingTranscriber:
    def __init__(
        self,
        transcribe: Transcribe,
        *,
        margin_s: float = MARGIN_S,
        confidence_floor: float = CONFIDENCE_FLOOR,
        interval_s: float = INTERVAL_S,
        backoff: float = BACKOFF,
        min_audio_s: float = MIN_AUDIO_S,
        sample_rate: int = SAMPLE_RATE,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._transcribe = transcribe
        self._sample_rate = sample_rate
        self._interval_s = interval_s
        self._backoff = backoff
        self._min_audio_s = min_audio_s
        self._clock = clock
        self._state = CommitState(margin_s=margin_s, confidence_floor=confidence_floor)
        self._chunks: list[np.ndarray] = []
        self._samples = 0
        self._next_due = clock()
        self._text = ""
        self._passes = 0
        self._pass_ms = 0
        self._final: str | None = None
        self._lock = threading.Lock()

    # ── Audio in ────────────────────────────────────────────────────────────

    def feed(self, samples: np.ndarray) -> None:
        """Append mono float32 audio. Cheap: the join is deferred to a pass."""
        if samples is None or len(samples) == 0:
            return
        with self._lock:
            self._chunks.append(np.asarray(samples, dtype=np.float32))
            self._samples += len(samples)

    @property
    def audio_s(self) -> float:
        return self._samples / self._sample_rate

    def _audio(self) -> np.ndarray:
        with self._lock:
            if len(self._chunks) > 1:
                self._chunks = [np.concatenate(self._chunks)]
            return self._chunks[0] if self._chunks else np.zeros(0, dtype=np.float32)

    # ── Passes ──────────────────────────────────────────────────────────────

    def due(self) -> bool:
        """True when enough audio has arrived and the back-off has elapsed."""
        return self.audio_s >= self._min_audio_s and self._clock() >= self._next_due

    def step(self) -> str:
        """Run a pass if one is due. Returns the text to type now (often "")."""
        if not self.due():
            return ""
        return self._pass(self.audio_s)

    def _pass(self, audio_s: float, *, margin: bool = True) -> str:
        t0 = self._clock()
        tokens = list(self._transcribe(self._audio()))
        cost = self._clock() - t0
        # Measured against the audio the pass actually SAW, not against audio
        # that arrived while it was running: a word is unstable because of how
        # close it sits to the edge of what the model heard.
        chunk = self._state.advance(tokens, audio_s) if margin else ""
        with self._lock:
            self._text = "".join(t.text for t in tokens).strip()
            self._passes += 1
            self._pass_ms = int(cost * 1000)
        self._next_due = self._clock() + max(self._interval_s, self._backoff * cost)
        return chunk

    def finish(self) -> str:
        """One last pass over all the audio. Returns the final transcript.

        No margin: there is no more audio coming, so nothing is held back. The
        committed text stays frozen — the caller reconciles what is on screen
        against this.
        """
        self._pass(self.audio_s, margin=False)
        self._final = self._text
        return self._final

    # ── What a poll sees ────────────────────────────────────────────────────

    @property
    def stable(self) -> str:
        return self._state.text

    @property
    def text(self) -> str:
        return self._text

    @property
    def contradicted(self) -> bool:
        return self._state.contradicted

    @property
    def contradiction(self) -> str | None:
        return self._state.contradiction

    def snapshot(self) -> Snapshot:
        with self._lock:
            return Snapshot(
                audio_s=self._samples / self._sample_rate,
                text=self._text,
                stable=self._state.text,
                contradicted=self._state.contradicted,
                passes=self._passes,
                pass_ms=self._pass_ms,
            )


def pcm_to_float32(data: bytes) -> np.ndarray:
    """Headerless s16le to mono float32. Trailing half-sample bytes are dropped."""
    usable = len(data) - (len(data) % 2)
    if usable <= 0:
        return np.zeros(0, dtype=np.float32)
    return np.frombuffer(data[:usable], dtype=np.int16).astype(np.float32) / 32768.0
