"""Live dictation: type the words that have settled, while the user still talks.

apps/dictation used to type nothing until Fn came up, so the first word of a
20-second take waited the whole take. This package re-transcribes the growing
audio once a second and hands back the prefix that is safe to put at the cursor;
Hammerspoon types it and reconciles the tail when the take ends.

This file is the CONTRACT; the bodies live in submodules re-exported here:
  commit.py  Token, Word, CommitState (the three-condition rule), normalize(),
             words() — pure, stdlib only
  stream.py  StreamingTranscriber (growing audio -> stable text), Snapshot,
             pcm_to_float32()

The model is injected, so nothing here imports mlx: parakeet_server.py runs
under parakeet-mlx's interpreter and passes in a `transcribe(samples) -> tokens`
adapter, while the specs pass in a scripted one.
"""

from dictate.commit import (
    CONFIDENCE_FLOOR,
    MARGIN_S,
    CommitState,
    Token,
    Word,
    normalize,
    words,
)
from dictate.stream import (
    BACKOFF,
    INTERVAL_S,
    MIN_AUDIO_S,
    SAMPLE_RATE,
    Snapshot,
    StreamingTranscriber,
    pcm_to_float32,
)

__all__ = [
    "BACKOFF",
    "CONFIDENCE_FLOOR",
    "INTERVAL_S",
    "MARGIN_S",
    "MIN_AUDIO_S",
    "SAMPLE_RATE",
    "CommitState",
    "Snapshot",
    "StreamingTranscriber",
    "Token",
    "Word",
    "normalize",
    "pcm_to_float32",
    "words",
]
