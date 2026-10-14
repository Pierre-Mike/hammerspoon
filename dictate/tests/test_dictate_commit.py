"""The three-condition commit rule, token by token.

Every case here is a word that either reached the cursor or did not, so a
failure reads as "you typed something you should not have".
"""

import pytest

from dictate import CommitState, Token, normalize, words


def toks(spec, *, conf=1.0, step=0.2):
    """Tokens from "text@start:end" pieces, or plain text at a steady pace."""
    out, t = [], 0.0
    for piece in spec:
        if "@" in piece:
            text, span = piece.rsplit("@", 1)
            start, end = (float(x) for x in span.split(":"))
        else:
            text, start, end = piece, t, t + step
        out.append(Token(text=text, start=start, end=end, confidence=conf))
        t = end
    return out


def sentence(text, *, start=0.0, step=0.2, conf=1.0):
    """One token per word, each carrying the space in front of it."""
    out, t = [], start
    for w in text.split():
        out.append(Token(text=" " + w, start=t, end=t + step, confidence=conf))
        t += step
    return out


# ── words() ─────────────────────────────────────────────────────────────────

def test_subword_tokens_become_one_word():
    ws = words(toks([" C", "l", "ick"]))
    assert [w.text for w in ws] == [" Click"]
    assert ws[0].key == "click"


def test_punctuation_stays_with_the_word_in_front_of_it():
    ws = words(toks([" Sub", "mit", ",", " you"]))
    assert [w.text for w in ws] == [" Submit,", " you"]
    assert [w.key for w in ws] == ["submit", "you"]


def test_a_word_spans_its_tokens_in_time_and_takes_the_lowest_confidence():
    ws = words([
        Token(" de", 2.0, 2.08, 0.97),
        Token("le", 2.08, 2.24, 0.55),
        Token("te", 2.24, 2.40, 1.00),
    ])
    assert len(ws) == 1
    assert ws[0].start == 2.0
    assert ws[0].end == 2.40
    assert ws[0].confidence == 0.55


def test_joining_a_prefix_of_words_reproduces_the_hypothesis_verbatim():
    t = toks([" Click", " Sub", "mit", ",", " you", " can"])
    whole = "".join(x.text for x in t)
    ws = words(t)
    for k in range(len(ws) + 1):
        assert whole.startswith("".join(w.text for w in ws[:k]))


def test_no_tokens_is_no_words():
    assert words([]) == []


def test_normalize_drops_case_and_punctuation_but_keeps_apostrophes():
    assert normalize("Don't,") == "don't"
    assert normalize("  Hello! ") == "hello"
    assert normalize("...") == ""


# ── The margin ──────────────────────────────────────────────────────────────

def test_nothing_is_typed_within_the_margin_of_the_audio_edge():
    st = CommitState(margin_s=1.5, confidence_floor=0.0)
    t = sentence("one two three", step=0.5)      # words end at 0.5, 1.0, 1.5
    st.advance(t, 2.0)                            # first pass: no agreement yet
    assert st.advance(t, 2.0) == "one"            # only the word ending at 0.5


def test_more_audio_moves_the_deadline_and_releases_the_next_word():
    st = CommitState(margin_s=1.5, confidence_floor=0.0)
    t = sentence("one two three", step=0.5)
    st.advance(t, 2.0)
    assert st.advance(t, 2.0) == "one"
    assert st.advance(t, 2.5) == " two"
    assert st.advance(t, 3.0) == " three"


def test_a_take_shorter_than_the_margin_types_nothing_live():
    st = CommitState(margin_s=1.5)
    t = sentence("hi there", step=0.4)
    st.advance(t, 0.8)
    assert st.advance(t, 0.8) == ""
    assert st.text == ""


# ── Agreement with the previous pass ────────────────────────────────────────

def test_the_first_pass_commits_nothing_because_it_has_nothing_to_agree_with():
    st = CommitState(margin_s=0.0, confidence_floor=0.0)
    assert st.advance(sentence("one two"), 10.0) == ""


def test_a_word_the_previous_pass_disagreed_with_is_held_back():
    st = CommitState(margin_s=0.0, confidence_floor=0.0)
    st.advance(sentence("use uh user"), 10.0)
    # Second pass changes the first word: nothing may be typed.
    assert st.advance(sentence("i uh user"), 10.0) == ""
    # Third pass agrees with the second, so the prefix goes out.
    assert st.advance(sentence("i uh user"), 10.0) == "i uh user"


def test_agreement_ignores_case_and_punctuation():
    st = CommitState(margin_s=0.0, confidence_floor=0.0)
    st.advance(sentence("we cannot use it"), 10.0)
    out = st.advance(toks([" We", " cannot", " use", " it."]), 10.0)
    assert out == "We cannot use it."


def test_a_word_added_at_the_end_is_not_committed_on_the_pass_that_coins_it():
    st = CommitState(margin_s=0.0, confidence_floor=0.0)
    st.advance(sentence("one two"), 10.0)
    assert st.advance(sentence("one two three"), 10.0) == "one two"
    assert st.advance(sentence("one two three"), 10.0) == " three"


# ── The confidence floor ────────────────────────────────────────────────────

def test_a_word_below_the_floor_stops_the_prefix_there():
    st = CommitState(margin_s=0.0, confidence_floor=0.80)
    t = [
        Token(" one", 0.0, 0.2, 0.99),
        Token(" two", 0.2, 0.4, 0.73),
        Token(" three", 0.4, 0.6, 0.99),
    ]
    st.advance(t, 10.0)
    assert st.advance(t, 10.0) == "one"


def test_one_weak_token_holds_back_the_whole_word_it_belongs_to():
    st = CommitState(margin_s=0.0, confidence_floor=0.80)
    t = [Token(" to", 0.0, 0.1, 0.99), Token("ken", 0.1, 0.2, 0.40)]
    st.advance(t, 10.0)
    assert st.advance(t, 10.0) == ""


# ── No one condition is enough ──────────────────────────────────────────────

def test_each_condition_catches_what_the_others_let_through():
    late = sentence("alpha beta", start=8.6, step=0.5)      # ends at 9.6
    weak = [Token(" alpha", 0.0, 0.2, 0.5), Token(" beta", 0.2, 0.4, 0.5)]
    for state, t, audio in (
        (CommitState(margin_s=1.5, confidence_floor=0.0), late, 10.0),
        (CommitState(margin_s=0.0, confidence_floor=0.8), weak, 10.0),
    ):
        state.advance(t, audio)
        assert state.advance(t, audio) == ""


# ── Contradiction ───────────────────────────────────────────────────────────

def test_a_pass_that_disagrees_with_typed_text_is_skipped():
    st = CommitState(margin_s=0.0, confidence_floor=0.0)
    st.advance(sentence("one two"), 10.0)
    assert st.advance(sentence("one two"), 10.0) == "one two"
    assert st.advance(sentence("one three four"), 10.0) == ""
    assert st.contradicted
    assert "one" in st.contradiction
    assert st.text == "one two"


def test_a_transient_disagreement_does_not_end_the_take():
    """Measured: on a 24s take the model dropped one word on a single pass out
    of twenty-one. Treating that as final cost the next sixteen seconds."""
    st = CommitState(margin_s=0.0, confidence_floor=0.0)
    st.advance(sentence("flag all thermal"), 10.0)
    assert st.advance(sentence("flag all thermal"), 10.0) == "flag all thermal"
    assert st.advance(sentence("flag thermal images"), 10.0) == ""     # "all" gone
    st.advance(sentence("flag all thermal images and"), 10.0)
    assert st.advance(sentence("flag all thermal images and"), 10.0) == " images and"
    assert st.text == "flag all thermal images and"


def test_a_pass_that_loses_words_it_already_typed_is_a_disagreement():
    st = CommitState(margin_s=0.0, confidence_floor=0.0)
    st.advance(sentence("one two three"), 10.0)
    st.advance(sentence("one two three"), 10.0)
    assert st.advance(sentence("one"), 10.0) == ""
    assert st.contradicted
    assert st.disagreements == 1


def test_a_permanent_disagreement_simply_never_commits_again():
    st = CommitState(margin_s=0.0, confidence_floor=0.0)
    st.advance(sentence("uh should we"), 10.0)
    assert st.advance(sentence("uh should we"), 10.0) == "uh should we"
    for _ in range(4):
        assert st.advance(sentence("should we believe the reed"), 10.0) == ""
    assert st.text == "uh should we"
    assert st.skipped == 4


def test_rendering_may_drift_behind_the_cursor_without_contradicting():
    """Punctuation and casing move; the words do not. Those characters are
    already in the document, so the committed text is frozen as it was typed."""
    st = CommitState(margin_s=0.0, confidence_floor=0.0)
    st.advance(toks([" We", " cannot", " use", " it.", " We"]), 10.0)
    st.advance(toks([" We", " cannot", " use", " it.", " We"]), 10.0)
    assert st.text == "We cannot use it. We"
    st.advance(toks([" we", " cannot", " use", " it,", " we", " said"]), 10.0)
    assert not st.contradicted
    assert st.text == "We cannot use it. We"


# ── Shape of the committed text ─────────────────────────────────────────────

def test_the_first_word_does_not_arrive_with_a_leading_space():
    st = CommitState(margin_s=0.0, confidence_floor=0.0)
    st.advance(sentence("hello world"), 10.0)
    assert st.advance(sentence("hello world"), 10.0) == "hello world"
    assert not st.text.startswith(" ")


def test_later_chunks_keep_the_space_that_separates_them():
    st = CommitState(margin_s=0.0, confidence_floor=0.0)
    st.advance(sentence("a b"), 10.0)
    st.advance(sentence("a b"), 10.0)
    st.advance(sentence("a b c"), 10.0)
    assert st.advance(sentence("a b c"), 10.0) == " c"
    assert st.text == "a b c"


def test_committed_text_only_ever_grows():
    st = CommitState(margin_s=0.5, confidence_floor=0.8)
    seen = ""
    for n in range(2, 9):
        t = sentence(" ".join(f"w{i}" for i in range(n)), step=0.3)
        st.advance(t, n * 0.3 + 0.5)
        assert st.text.startswith(seen)
        seen = st.text


@pytest.mark.parametrize("audio_s", [0.0, 0.3, 1.49])
def test_no_audio_to_speak_of_commits_nothing(audio_s):
    st = CommitState()
    assert st.advance(sentence("anything at all"), audio_s) == ""
