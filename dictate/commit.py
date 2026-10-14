"""Which words of a hypothesis are safe to type at the cursor.

A speech model revises what it already said. Re-transcribing the growing audio
once a second gives a batch-quality hypothesis every pass, but the tail of each
one keeps moving: measured on this machine's parakeet-tdt-0.6b-v2, nine of
fifteen revisions across a five-take corpus changed a word, at a median depth of
two words from the end and a maximum of five.

A keyboard has no undo we control, so a word may only be typed once it is
settled. Three conditions decide that, and the corpus says no one of them is
enough on its own:

  margin      the word ended at least `margin_s` before the end of the audio
              the pass saw. Instability is a function of distance from the edge
              of the audio, not of word count.
  agreement   the previous pass put the same normalised word at the same index.
  confidence  every token of the word scored at least `confidence_floor`.
              Tokens that later changed averaged 0.917 (p10 0.733); tokens that
              never changed averaged 0.974 (p10 0.894).

Swept over ten takes and 92 seconds of speech (dictate/tools/dictate_sweep.py, two
independent recordings that agree to within four points), margin 1.2s with floor
0.80 puts 82% of the transcript on screen before the user lets go, and nine of
the ten takes need nothing taken back. The tenth is one word, and it is a word
no margin and no amount of agreement can catch: a leading "Uh" that five
consecutive passes agreed on, 6 seconds back from the edge of the audio, which
the final full-audio pass then deleted. Only a confidence floor of 0.90 catches
it, and that floor costs 45 points of coverage — fitting one word at the price
of half the feature. It is left to the caller's reconciliation instead, which
took it back in 24 keystrokes.

The rendering of a committed word is FROZEN. The model emits punctuation and
casing as tokens, so a sentence boundary that moves re-cases everything behind
it: two passes in the corpus rewrote 16 and 33 words of rendering without
changing a single word. Those characters are already in the user's document, so
`text` only ever grows, and drift behind the cursor is accepted rather than
chased.

A pass may also disagree with a word already typed. That pass is skipped — it
cannot be used to extend text it does not agree with — but it is not fatal, and
this is the one place the first implementation of this file was wrong. Most
disagreements are transient: on a 24-second take the model dropped "all" from
"flag all thermal" on one pass out of twenty-one, and treating that as final
threw away the next sixteen seconds of typing. A later pass that agrees again
resumes exactly where the typed text ends, which is as safe as the commit that
put it there. A disagreement that is NOT transient needs no special handling:
no pass agrees, so nothing more is committed, and the caller reconciles once at
the end against the final transcript.

Pure: stdlib only, no numpy, no model. Every number here is measured, so a spec
hands in tokens and reads back what would have been typed.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# Seconds a word must sit back from the end of the audio before it is typed.
MARGIN_S = 1.2
# Lowest token confidence a word may carry and still be typed.
CONFIDENCE_FLOOR = 0.80

_NOT_WORD = re.compile(r"[^a-z0-9']+")
_RUN = re.compile(r"\S+")

# How a word's confidence is read off its tokens. A word is several sub-word
# pieces ("de" + "le" + "te"), each scored on its own, and the two readings
# answer different questions: `min` asks whether any piece is shaky, `mean` asks
# whether the word as a whole is. Measured over ten takes, `min` is the one that
# separates words that later changed from words that did not — see
# dictate/tools/dictate_sweep.py.
AGGREGATE = {
    "min": min,
    "mean": lambda cs: sum(cs) / len(cs),
}


@dataclass(frozen=True)
class Token:
    """One model token: a sub-word piece with its place in the audio.

    `text` carries the leading space that marks a word start, which is why
    joining tokens reproduces the model's own spacing exactly.
    """

    text: str
    start: float
    end: float
    confidence: float = 1.0


@dataclass(frozen=True)
class Word:
    """One whitespace-delimited word, assembled from the tokens that spell it.

    `text` runs from the end of the previous word to the end of this one, so
    joining a prefix of words reproduces that prefix of the hypothesis verbatim,
    spaces included.
    """

    text: str
    key: str          # normalised, for comparing one pass against the next
    start: float
    end: float
    confidence: float  # the lowest of its tokens', not the mean


def normalize(s: str) -> str:
    """What two passes have to agree on: letters, digits and apostrophes.

    Case and punctuation are left out on purpose. They are the part that keeps
    moving after the words have settled, and a comma that becomes a period is
    not a reason to withhold the next sentence.
    """
    return _NOT_WORD.sub("", (s or "").lower())


def words(tokens: list[Token], aggregate: str = "min") -> list[Word]:
    """Group sub-word tokens into words.

    Done by character offset rather than by "does this token start with a
    space", so a token holding an internal space splits the way a reader would
    split it, and a bare punctuation token stays attached to the word in front
    of it.
    """
    agg = AGGREGATE[aggregate]
    if not tokens:
        return []
    text = "".join(t.text for t in tokens)
    owner: list[int] = []
    for i, t in enumerate(tokens):
        owner.extend([i] * len(t.text))
    out: list[Word] = []
    cut = 0
    for m in _RUN.finditer(text):
        lo, hi = m.start(), m.end()
        mine = tokens[owner[lo]:owner[hi - 1] + 1]
        out.append(Word(
            text=text[cut:hi],
            key=normalize(m.group()),
            start=min(t.start for t in mine),
            end=max(t.end for t in mine),
            confidence=agg([t.confidence for t in mine]),
        ))
        cut = hi
    return out


@dataclass
class CommitState:
    """What has been typed, and what the pass before this one said.

    One instance per take. `text` is the frozen rendering already at the cursor;
    `keys` is the same thing as normalised words, which is what a later pass is
    checked against.
    """

    margin_s: float = MARGIN_S
    confidence_floor: float = CONFIDENCE_FLOOR
    aggregate: str = "min"
    text: str = ""
    keys: list[str] = field(default_factory=list)
    prev_keys: list[str] = field(default_factory=list)
    # True once any pass has disagreed with text already typed. Reported, not
    # acted on: it says the take is worth a look in the log, not that the rest
    # of it must be abandoned.
    contradicted: bool = False
    contradiction: str | None = None
    disagreements: int = 0
    skipped: int = 0

    def advance(self, tokens: list[Token], audio_s: float) -> str:
        """Take one pass's tokens; return the text to type now (may be empty).

        `audio_s` is how much audio this pass saw, which is what the margin is
        measured against.
        """
        ws = words(tokens, self.aggregate)
        keys = [w.key for w in ws]
        # Always against the pass immediately before, even a skipped one: the
        # agreement condition asks "did the model say this twice running".
        prev, self.prev_keys = self.prev_keys, keys
        if keys[:len(self.keys)] != self.keys:
            self.disagreements += 1
            self.skipped += 1
            if not self.contradicted:
                self.contradicted = True
                self.contradiction = (
                    f"committed {self.keys!r}, pass says {keys[:len(self.keys)]!r}"
                )
            return ""
        self.skipped = 0

        deadline = audio_s - self.margin_s
        taken: list[Word] = []
        i = len(self.keys)
        while i < len(ws):
            w = ws[i]
            if w.end > deadline:
                break
            if w.confidence < self.confidence_floor:
                break
            if i >= len(prev) or prev[i] != w.key:
                break
            taken.append(w)
            i += 1
        if not taken:
            return ""

        chunk = "".join(w.text for w in taken)
        if not self.text:
            # The first word carries the space the model puts in front of every
            # word, and the cursor is not a place for a leading space.
            chunk = chunk.lstrip()
        self.text += chunk
        self.keys.extend(w.key for w in taken)
        return chunk
