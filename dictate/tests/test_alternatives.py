"""What the review panel is told about each word: how sure the model was, and
what else it nearly wrote there.

The model is scripted frame by frame, so a failure reads as "the panel offered
the wrong word" or "it marked a word the model was sure of".
"""

from dictate.alternatives import Model, greedy, group, guesses, key, transcribe

BLANK = 0
VOCAB = {1: " into", 2: " in", 3: " two", 4: " it", 5: ".", 6: " cat", 7: "s", 8: "'s",
         9: "z", 10: " sat", 11: "at", 12: " sad", 13: " Sat"}
IDS = {t: i for i, t in VOCAB.items()}


def scripted(script, frames):
    """script[frame][last] = ([(token text, p), ...], advance); "*" is any last."""
    def step(frame, last, state):
        entry = script[frame]
        top, advance = entry.get(VOCAB.get(last), entry.get("*"))
        return [(IDS.get(t, BLANK), p) for t, p in top], advance, None
    return Model(step=step, frames=frames, blank=BLANK, text=VOCAB.__getitem__)


# "into it." The model was 60% sure of "into" and 35% on "in" then "two".
INTO = scripted({
    0: {None: ([(" into", .60), (" in", .35), (".", .03)], 1)},
    1: {" into": ([("blank", .95)], 1),
        " in": ([(" two", .90), (" it", .05)], 1)},
    2: {" into": ([(" it", .99)], 1),
        " two": ([(" it", .98)], 1)},
    3: {"*": ([(".", .60), ("blank", .40)], 1)},
}, frames=4)

# "cats sat": unsure of the plural and of the verb.
CATS = scripted({
    0: {None: ([(" cat", .99)], 0),
        " cat": ([("s", .55), ("blank", .30), ("'s", .10), ("z", .02)], 1)},
    1: {"s": ([(" sat", .50), ("at", .30), (" sad", .15), (" Sat", .05)], 1),
        "'s": ([(" sat", .90)], 1),
        "z": ([(" sat", .90)], 1)},
}, frames=2)


def test_the_greedy_decode_writes_what_the_model_was_surest_of():
    picks = greedy(INTO)
    assert "".join(p.text for p in picks) == " into it."
    assert [["".join(p.text for p in w)] for w in group(picks)] == [[" into"], [" it."]]


def test_an_unsure_word_offers_what_the_model_wrote_down_the_other_branch():
    words = guesses(INTO, greedy(INTO))
    assert words[0].text == "into"
    assert words[0].p == 0.6
    assert words[0].alts == ("in two",)


def test_a_doubt_about_the_full_stop_is_not_a_doubt_about_the_word():
    words = guesses(INTO, greedy(INTO))
    assert words[1].text == "it."
    assert words[1].p == 0.99
    assert words[1].alts == ()


def test_an_alternative_inside_a_word_keeps_the_part_before_it():
    words = guesses(CATS, greedy(CATS))
    assert words[0].text == "cats"
    assert words[0].alts == ("cat's",)


def test_a_runner_up_below_min_p_gets_no_branch():
    words = guesses(CATS, greedy(CATS), min_p=0.01)
    assert words[0].alts == ("cat's", "catz")


def test_a_piece_that_would_glue_onto_the_word_before_is_not_offered():
    words = guesses(CATS, greedy(CATS))
    assert words[1].text == "sat"
    assert "at" not in words[1].alts
    assert "catsat" not in [key(a) for a in words[1].alts]


def test_the_same_word_in_other_case_is_not_an_alternative():
    words = guesses(CATS, greedy(CATS), min_p=0.01)
    assert words[1].alts == ("sad",)


def test_alternatives_are_capped_most_likely_first():
    words = guesses(CATS, greedy(CATS), min_p=0.01, keep=1)
    assert words[0].alts == ("cat's",)


def test_a_sure_word_is_never_branched():
    words = guesses(CATS, greedy(CATS), floor=0.5)
    assert [(w.unsure, w.alts) for w in words] == [(False, ()), (False, ())]


def test_the_endpoint_body_has_the_text_and_every_word():
    body = transcribe(INTO)
    assert body == {"text": "into it.", "words": [
        {"text": "into", "p": 0.6, "unsure": True, "alts": ["in two"]},
        {"text": "it.", "p": 0.99, "unsure": False, "alts": []},
    ]}
