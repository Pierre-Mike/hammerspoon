"""Which words of a take were said differently from how they are written.

The speech model that types dictation is trained to guess the word you meant,
so a transcript hides most mispronunciations: "tree" in "I have tree kids"
still comes out as "three". This module uses that on purpose. The transcript
says which words were meant, espeak says how those words are pronounced, and a
phoneme recognizer (wav2vec2 trained on espeak's own symbols) says which sounds
were made. Lining the two phone strings up shows, word by word, where they
part.

Everything here is pure: phone lists in, word results out. scorer.py owns the
model, espeak and the HTTP server, and tests/test_align.py drives this file
without either.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# Marks that change nothing a listener would correct: stress, length, syllable
# breaks, ties. "iː" and "i" are the same lesson.
_STRIP = str.maketrans("", "", "ˈˌːˑ.‿͡")

# Symbols espeak and the recognizer write differently for one sound, or that
# American English treats as the same sound. Each maps to one spelling, so an
# accent nobody would correct does not count as an error.
_SAME = {
    "ɡ": "g",
    "r": "ɹ",
    "ʔ": "t",      # the glottal stop in "button"
    "ɐ": "ə",
    "ʌ": "ə",
    "ᵻ": "ɪ",
    "ɚ": "əɹ",
    "ɝ": "əɹ",
    "ɜ": "ə",
    "ɜɹ": "əɹ",
    "o": "oʊ",
    "e": "eɪ",
    "ɒ": "ɑ",
    "ɔ": "ɑ",
    "ɫ": "l",
    "n̩": "n",
    "l̩": "l",
    "m̩": "m",
}

_VOWEL_CHARS = set("aeiouyæɑɒɔəɛɜɪʊʌɐᵻɚɝøœɤɯɨʉ")

# Words that carry no lesson: so short and so common that the recognizer's
# noise on them would drown everything else.
STOPWORDS = frozenset("""
a an the and or but if of to in on at by for with from as is am are was were be
been it its it's i i'm i've i'll i'd you you're we he she they them their there
this that these those my your our so do does did not no yes just uh um like oh
ok okay yeah me us him her his hers our ours mine yours what who how why when
""".split())

FLAG_BELOW = 0.8       # a word scoring under this is flagged
MIN_PHONES = 3         # shorter words are left alone, see STOPWORDS
PASS_AT = 0.8          # a drill attempt passes at or above this
FRAME_S = 0.02         # wav2vec2 emits one frame per 20 ms
CLIP_PAD_S = 0.25      # silence kept either side of a word's clip

WORD_RE = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)*")


def words_of(text: str) -> list[str]:
    """The words of a transcript, lowercased. Digits and symbols are dropped:
    espeak would read "25" as two words the transcript does not have."""
    return [w.lower() for w in WORD_RE.findall(text or "")]


def norm(phone: str) -> str:
    p = phone.translate(_STRIP)
    return _SAME.get(p, p)


def is_vowel(phone: str) -> bool:
    return bool(phone) and phone[0] in _VOWEL_CHARS


@dataclass
class Heard:
    phone: str
    start: float
    end: float


@dataclass
class WordResult:
    word: str
    index: int
    expected: list[str]
    heard: list[str] = field(default_factory=list)
    errors: list[dict] = field(default_factory=list)
    score: float = 1.0
    start: float | None = None
    end: float | None = None
    flagged: bool = False

    def to_json(self) -> dict:
        return {
            "word": self.word, "index": self.index,
            "expected": " ".join(self.expected), "heard": " ".join(self.heard),
            "errors": self.errors, "score": round(self.score, 3),
            "start": self.start, "end": self.end, "flagged": self.flagged,
        }


def split_phones(ipa: str) -> list[str]:
    """espeak's output with a space between phones, as phonemizer gives it."""
    return [p for p in ipa.split() if p.translate(_STRIP)]


# The flap in "water" and "model" stands for a t or a d, so it matches both.
_FLAP = "ɾ"


def same(exp: str, got: str) -> bool:
    return exp == got or (got == _FLAP and exp in ("t", "d")) or (exp == _FLAP and got in ("t", "d"))


def _cost(a: str, b: str) -> float:
    if same(a, b):
        return 0.0
    # Vowel for vowel is the cheaper mistake, so the alignment prefers pairing
    # vowels with vowels over sliding a consonant across.
    return 0.6 if is_vowel(a) and is_vowel(b) else 1.0


def align(exp: list[str], got: list[str]) -> list[tuple[int | None, int | None]]:
    """Edit-distance alignment of two normalised phone lists. Returns pairs of
    (expected index, heard index); None on one side is a deletion or an
    insertion."""
    n, m = len(exp), len(got)
    d = [[0.0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        d[i][0] = float(i)
    for j in range(1, m + 1):
        d[0][j] = float(j)
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i - 1][j - 1] + _cost(exp[i - 1], got[j - 1]),
                          d[i - 1][j] + 1.0,
                          d[i][j - 1] + 1.0)
    pairs: list[tuple[int | None, int | None]] = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + _cost(exp[i - 1], got[j - 1]):
            pairs.append((i - 1, j - 1)); i -= 1; j -= 1
        elif i > 0 and d[i][j] == d[i - 1][j] + 1.0:
            pairs.append((i - 1, None)); i -= 1
        else:
            pairs.append((None, j - 1)); j -= 1
    pairs.reverse()
    return pairs


# Slips a listener barely hears. s for z is often espeak's fault: it reads
# "use" as the noun. A lost ə is usually run into the word before it.
_MINOR_SWAPS = {frozenset(("s", "z"))}


def _weight(err: dict) -> float:
    if not err["exp"]:
        return 0.5                                    # an extra sound
    if not err["got"]:
        if err["exp"] == "ə":
            return 0.25
        return 0.75 if is_vowel(err["exp"]) else 1.0  # a missing sound
    if frozenset((err["exp"], err["got"])) in _MINOR_SWAPS:
        return 0.5
    return 0.5 if is_vowel(err["exp"]) and is_vowel(err["got"]) else 1.0


def score_words(words: list[str], expected: list[list[str]], heard: list[Heard]) -> list[WordResult]:
    """Line up each word's expected phones against the whole heard sequence.

    `expected[i]` is word i's phones from espeak. `heard` is the recognizer's
    phones with their times, for the whole take. A sound heard between two
    words belongs to neither and costs nothing: the recognizer hears breaths
    and the words the transcript dropped there.
    """
    exp_flat, owner = [], []
    for wi, phones in enumerate(expected):
        for p in phones:
            exp_flat.append(norm(p)); owner.append(wi)
    got_flat = [norm(h.phone) for h in heard]

    results = [WordResult(word=w, index=i, expected=[norm(p) for p in expected[i]])
               for i, w in enumerate(words)]
    pairs = align(exp_flat, got_flat)

    last_owner = None
    for k, (ei, gi) in enumerate(pairs):
        if ei is not None:
            r = results[owner[ei]]
            last_owner = owner[ei]
            if gi is not None:
                r.heard.append(got_flat[gi])
                h = heard[gi]
                r.start = h.start if r.start is None else min(r.start, h.start)
                r.end = h.end if r.end is None else max(r.end, h.end)
                if not same(exp_flat[ei], got_flat[gi]):
                    r.errors.append({"exp": exp_flat[ei], "got": got_flat[gi]})
            else:
                r.errors.append({"exp": exp_flat[ei], "got": ""})
        else:
            # An insertion counts only inside a word: the next expected phone
            # must belong to the same word as the last one.
            nxt = next((owner[e] for e, _ in pairs[k + 1:] if e is not None), None)
            if last_owner is not None and nxt == last_owner:
                r = results[last_owner]
                r.heard.append(got_flat[gi])
                r.errors.append({"exp": "", "got": got_flat[gi]})

    for r in results:
        n = max(len(r.expected), 1)
        r.score = max(0.0, 1.0 - sum(_weight(e) for e in r.errors) / n)
        r.flagged = (r.score < FLAG_BELOW and len(r.expected) >= MIN_PHONES
                     and r.word not in STOPWORDS)
    return results


# What the recognizer may answer with. It was trained on about forty
# languages, and on a clip of one word it drifts into them: a lone "achieve"
# came back as Mandarin tones (ɑ5 s. i5). So every symbol is masked except
# the ones espeak uses for American English (measured over 20,000 words of
# /usr/share/dict/words) and the French sounds a French speaker brings to
# English, which are the errors worth naming.
ENGLISH_PHONES = frozenset("""
ɪ n ə s k l t ɹ m æ d ɛ ɑː p b oʊ ɚ f aɪ i eɪ ɡ ɾ ɐ iː z əl h uː ʃ dʒ v ᵻ ŋ ʌ j
iə ɔː ɑːɹ θ tʃ ɔːɹ ɜː w ʊ aʊ ɔɪ ɔ ʊɹ ʒ ð ɛɹ ɪɹ aɪɚ aɪə ʔ n̩ r ɑ ɜ u e o a
""".split())
FRENCH_PHONES = frozenset("ʁ y ø œ ɛ̃ ɑ̃ ɔ̃ œ̃".split())


def allowed_ids(vocab: dict[str, int]) -> list[int]:
    """Token ids the decoder may pick: the blank, then English and French sounds."""
    keep = ENGLISH_PHONES | FRENCH_PHONES | {"<pad>"}
    return sorted(i for p, i in vocab.items() if p in keep)


def ctc_runs(ids: list[int], blank: int, id_to_phone: dict[int, str]) -> list[Heard]:
    """Greedy CTC decode with times: one Heard per run of the same id, blanks
    dropped. Word-separator tokens, if the vocabulary has any, are dropped too."""
    out: list[Heard] = []
    prev, start = None, 0
    for f, i in enumerate(ids + [None]):
        if i != prev:
            if prev is not None and prev != blank:
                p = id_to_phone.get(prev, "")
                if p.strip() and p not in ("|", "<unk>", "<s>", "</s>"):
                    out.append(Heard(p, round(start * FRAME_S, 3), round(f * FRAME_S, 3)))
            prev, start = i, f
    return out


def clip_span(r: WordResult, duration: float) -> tuple[float, float] | None:
    """Where to cut a word's clip from its take, with a little air either side."""
    if r.start is None or r.end is None:
        return None
    return max(0.0, r.start - CLIP_PAD_S), min(duration, r.end + CLIP_PAD_S)
