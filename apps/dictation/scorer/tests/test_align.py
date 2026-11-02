"""Word scoring without the model: phone lists in, verdicts out.

Each case is a word that either reaches the weekly lesson or does not, so a
failure reads as "you would have drilled something you said fine" or "you
would never have heard about this one".
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from align import (Heard, align, allowed_ids, clip_span, ctc_runs, norm, same,  # noqa: E402
                   score_words, split_phones, words_of)


def heard(spec, step=0.1, t=0.0):
    """Heard phones at a steady pace from a space-separated string."""
    out = []
    for p in spec.split():
        out.append(Heard(p, round(t, 3), round(t + step, 3)))
        t += step
    return out


def by_word(results):
    return {r.word: r for r in results}


# ── words_of ────────────────────────────────────────────────────────────────

def test_words_keep_apostrophes_and_drop_digits():
    assert words_of("I don't have 25 Things.") == ["i", "don't", "have", "things"]


# ── normalisation ───────────────────────────────────────────────────────────

def test_stress_and_length_marks_are_not_errors():
    assert norm("ˈiː") == norm("i")


def test_symbols_for_one_american_sound_are_equal():
    assert same("t", "ɾ") and same("d", "ɾ") and not same("t", "d")
    assert norm("ɐ") == norm("ə")
    assert norm("ɡ") == "g"


def test_split_phones_drops_empty_marks():
    assert split_phones("θ ɹ ˈiː ˈ") == ["θ", "ɹ", "ˈiː"]


# ── alignment ───────────────────────────────────────────────────────────────

def test_align_pairs_a_substitution():
    assert align(["θ", "ɹ", "i"], ["t", "ɹ", "i"]) == [(0, 0), (1, 1), (2, 2)]


def test_align_marks_a_dropped_sound():
    pairs = align(["h", "æ", "v"], ["æ", "v"])
    assert (0, None) in pairs


# ── score_words ─────────────────────────────────────────────────────────────

def test_th_said_as_t_is_flagged():
    words = ["i", "have", "three", "kids"]
    exp = [["aɪ"], ["h", "æ", "v"], ["θ", "ɹ", "iː"], ["k", "ɪ", "d", "z"]]
    got = heard("aɪ h æ v t ɹ iː k ɪ d z")
    r = by_word(score_words(words, exp, got))
    assert r["three"].flagged
    assert r["three"].errors == [{"exp": "θ", "got": "t"}]
    assert not r["have"].flagged
    assert not r["kids"].flagged


def test_a_clean_take_flags_nothing():
    words = ["think", "about", "it"]
    exp = [["θ", "ɪ", "ŋ", "k"], ["ɐ", "b", "aʊ", "t"], ["ɪ", "t"]]
    got = heard("θ ɪ ŋ k ə b aʊ ɾ ɪ t")
    assert not any(r.flagged for r in score_words(words, exp, got))


def test_a_dropped_h_is_flagged():
    words = ["happy"]
    exp = [["h", "æ", "p", "i"]]
    got = heard("æ p i")
    r = score_words(words, exp, got)[0]
    assert r.errors == [{"exp": "h", "got": ""}]
    assert r.flagged


def test_one_vowel_off_in_a_long_word_is_not_flagged():
    words = ["computer"]
    exp = [["k", "ə", "m", "p", "j", "u", "t", "ɚ"]]
    got = heard("k ɑ m p j u t ɚ")
    r = score_words(words, exp, got)[0]
    assert r.score > 0.9 and not r.flagged


def test_stopwords_are_never_flagged():
    words = ["the", "this"]
    exp = [["ð", "ə"], ["ð", "ɪ", "s"]]
    got = heard("d ə d i s")
    assert not any(r.flagged for r in score_words(words, exp, got))


def test_sounds_between_words_cost_nothing():
    words = ["green", "tea"]
    exp = [["g", "ɹ", "iː", "n"], ["t", "iː"]]
    got = heard("g ɹ iː n ə m t iː")
    r = by_word(score_words(words, exp, got))
    assert r["green"].errors == [] and r["tea"].errors == []


def test_a_sound_added_inside_a_word_counts():
    words = ["street"]
    exp = [["s", "t", "ɹ", "iː", "t"]]
    got = heard("ə s t ɹ iː t")   # in front of the word: free
    assert score_words(words, exp, got)[0].errors == []
    got = heard("s ə t ɹ iː t")   # inside it: an error
    assert score_words(words, exp, got)[0].errors == [{"exp": "", "got": "ə"}]


def test_word_times_come_from_its_heard_phones():
    words = ["three", "kids"]
    exp = [["θ", "ɹ", "iː"], ["k", "ɪ", "d", "z"]]
    got = heard("t ɹ iː k ɪ d z", step=0.1, t=1.0)
    r = by_word(score_words(words, exp, got))
    assert r["three"].start == 1.0 and r["three"].end == 1.3
    assert r["kids"].start == 1.3


def test_clip_span_pads_and_clamps():
    words = ["three"]
    exp = [["θ", "ɹ", "iː"]]
    r = score_words(words, exp, heard("t ɹ iː", t=0.1))[0]
    start, end = clip_span(r, duration=0.5)
    assert start == 0.0 and end == 0.5


# Three false alarms from the first real takes, 2026-10-30.

def test_a_flapped_d_is_american_not_an_error():
    words = ["model"]
    exp = [["m", "ɑ", "d", "əl"]]
    r = score_words(words, exp, heard("m ɑ ɾ əl"))[0]
    assert r.errors == [] and not r.flagged


def test_s_for_z_is_a_small_slip():
    # espeak reads "use" as the noun, /jus/; the verb is /juz/.
    words = ["use"]
    exp = [["j", "u", "s"]]
    r = score_words(words, exp, heard("j u z"))[0]
    assert not r.flagged


def test_a_schwa_lost_to_the_word_before_is_not_flagged():
    # "the other" run together loses the ə of "other".
    words = ["other"]
    exp = [["ə", "ð", "əɹ"]]
    r = score_words(words, exp, heard("ð əɹ"))[0]
    assert not r.flagged


def test_sh_said_as_s_is_still_flagged():
    words = ["should"]
    exp = [["ʃ", "ʊ", "d"]]
    assert score_words(words, exp, heard("s ʊ d"))[0].flagged


# ── allowed_ids ─────────────────────────────────────────────────────────────

def test_the_recognizer_may_only_answer_in_english_and_french_sounds():
    vocab = {"<pad>": 0, "θ": 1, "ɑ5": 2, "ts.": 3, "ʁ": 4, "ɑːɹ": 5, "<s>": 6}
    assert allowed_ids(vocab) == [0, 1, 4, 5]


# ── ctc_runs ────────────────────────────────────────────────────────────────

def test_ctc_collapses_runs_and_drops_blanks_with_times():
    vocab = {0: "<pad>", 1: "θ", 2: "ɹ"}
    out = ctc_runs([0, 1, 1, 0, 2, 2, 2, 0], blank=0, id_to_phone=vocab)
    assert [h.phone for h in out] == ["θ", "ɹ"]
    assert out[0].start == 0.02 and out[0].end == 0.06
    assert out[1].start == 0.08 and out[1].end == 0.14


def test_ctc_keeps_a_repeated_sound_split_by_a_blank():
    vocab = {0: "<pad>", 1: "t"}
    assert [h.phone for h in ctc_runs([1, 0, 1], 0, vocab)] == ["t", "t"]
