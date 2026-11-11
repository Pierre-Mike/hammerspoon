"""The words the model was unsure of, and what else it heard there.

The review panel marks a word the model was not sure of and offers the words it
nearly wrote instead. Parakeet TDT has no n-best list, but every step of its
greedy decode scores the whole vocabulary, so the runner-up tokens are there for
the taking. A runner-up is only a piece of a word ("give" against "give" + "s"),
so each one is followed: force it at that step, keep decoding greedily from the
decoder state the best token was emitted from, and stop at the first word start
past the audio the word took. What comes out is what the model would have
written there had it gone the other way, which may be two words: "hammer spoon"
for "hammerspoon".

Measured on a 51-second take with parakeet-tdt-0.6b-v2: the greedy pass costs
0.6s and the branches 0.04s, because a branch runs the small decoder and joint
for a handful of steps and never the encoder again.

Confidence here is the probability of the token the decode chose, not the
entropy reading the live dictation uses (dictate/commit.py). Entropy over 1025
tokens squeezes everything into 0.84 to 0.90 on that take, which cannot tell
"give" at 56% from a word the model was sure of. A word is scored by its letter
tokens only: on the same take the weakest token of most words was the comma or
full stop after them, and a doubt about punctuation is not a doubt about the
word.

Pure: stdlib only. The model is injected as a `Model`, so parakeet_server.py
passes in an adapter over parakeet-mlx and the specs pass in a scripted one.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

# A word whose weakest letter token is below this is marked as unsure.
FLOOR = 0.80
# A runner-up token below this probability is not worth a branch.
MIN_P = 0.05
# At most this many alternatives per word, most likely first.
KEEP = 3
# A branch gives up after this many tokens without reaching a word start.
BRANCH_LIMIT = 12

_LETTER = re.compile(r"\w")
_NOT_WORD = re.compile(r"[^\w']+")


@dataclass
class Model:
    """What the decode needs from a TDT model.

    step(frame, last, state) runs the decoder on `last` (None at the start) and
    the joint on `frame`, and returns:
      top      [(token, probability), ...] best first, at least the best few
      advance  frames the duration head says to move on by
      after    the decoder state to carry once a token is emitted here
    """

    step: Callable[[int, Optional[int], Any], tuple[list[tuple[int, float]], int, Any]]
    frames: int
    blank: int
    text: Callable[[int], str]
    max_symbols: Optional[int] = None


@dataclass(frozen=True)
class Pick:
    """One emitted token and the decode position it was emitted from."""

    token: int
    text: str
    p: float
    top: tuple[tuple[int, float], ...]
    frame: int
    last: Optional[int]
    state: Any = field(compare=False, repr=False)


@dataclass(frozen=True)
class Word:
    text: str
    p: float
    unsure: bool = False
    alts: tuple[str, ...] = ()


def key(text: str) -> str:
    """A word reduced to what tells it apart: lowercase letters and digits."""
    return _NOT_WORD.sub("", text.lower())


def starts_word(text: str) -> bool:
    return text.startswith(" ")


def has_letters(text: str) -> bool:
    return bool(_LETTER.search(text))


def greedy(model: Model, frame: int = 0, last: Optional[int] = None, state: Any = None, *,
           force: Optional[int] = None, until: Optional[int] = None) -> list[Pick]:
    """The greedy TDT decode from (frame, last, state).

    `force` replaces the first token the decode emits. With `until` it stops in
    front of the first token that starts a word at or past that frame, or after
    BRANCH_LIMIT tokens.
    """
    out: list[Pick] = []
    symbols = 0
    while frame < model.frames:
        top, advance, after = model.step(frame, last, state)
        token = top[0][0] if force is None else force
        if token != model.blank:
            text = model.text(token)
            if until is not None and out and (
                    (starts_word(text) and frame >= until) or len(out) >= BRANCH_LIMIT):
                break
            p = top[0][1] if force is None else dict(top).get(force, 0.0)
            out.append(Pick(token, text, p, tuple(top), frame, last, state))
            last, state = token, after
        force = None
        frame += advance
        symbols = 0 if advance else symbols + 1
        if model.max_symbols is not None and symbols >= model.max_symbols:
            frame, symbols = frame + 1, 0
    return out


def group(picks: list[Pick]) -> list[list[Pick]]:
    """Tokens into words: a token with a leading space starts a new one."""
    out: list[list[Pick]] = []
    for pick in picks:
        if starts_word(pick.text) or not out:
            out.append([pick])
        else:
            out[-1].append(pick)
    return out


def _alternatives(model: Model, word: list[Pick], until: int, floor: float,
                  min_p: float) -> list[str]:
    heard = "".join(p.text for p in word).strip()
    seen, found = {key(heard)}, []
    shaky = sorted((i for i, p in enumerate(word) if has_letters(p.text) and p.p < floor),
                   key=lambda i: word[i].p)
    for i in shaky:
        pick = word[i]
        prefix = "".join(p.text for p in word[:i])
        for token, p in pick.top:
            if token in (pick.token, model.blank) or p < min_p:
                continue
            if i == 0 and not starts_word(model.text(token)):
                continue      # would glue itself onto the word before
            branch = greedy(model, pick.frame, pick.last, pick.state, force=token, until=until)
            alt = (prefix + "".join(b.text for b in branch)).strip()
            if has_letters(alt) and key(alt) not in seen:
                seen.add(key(alt))
                found.append((p, alt))
    found.sort(key=lambda f: -f[0])
    return [alt for _, alt in found]


def guesses(model: Model, picks: list[Pick], *, floor: float = FLOOR, min_p: float = MIN_P,
            keep: int = KEEP) -> list[Word]:
    """Every word of the decode, with its score and, when unsure, what else it heard."""
    out, words = [], group(picks)
    for n, word in enumerate(words):
        letters = [p.p for p in word if has_letters(p.text)]
        p = min(letters) if letters else 1.0
        until = words[n + 1][0].frame if n + 1 < len(words) else model.frames
        alts = _alternatives(model, word, until, floor, min_p)[:keep] if p < floor else []
        out.append(Word("".join(x.text for x in word).strip(), round(p, 3), p < floor, tuple(alts)))
    return out


def transcribe(model: Model, **kw) -> dict:
    """The JSON body POST /words answers with."""
    picks = greedy(model)
    words = [w for w in guesses(model, picks, **kw) if w.text]
    return {
        "text": "".join(p.text for p in picks).strip(),
        "words": [{"text": w.text, "p": w.p, "unsure": w.unsure, "alts": list(w.alts)}
                  for w in words],
    }
