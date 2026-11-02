-- lib/pronunciation: which words reach a lesson, when each comes back, and
-- what Claude is asked about them. Pure, so no hs mock is needed.

local pron = require("lib.pronunciation")

local DAY = 86400
local T0 = 1800000000

-- One analysed take, as apps/pronunciation/scorer.py returns it.
local function result(words)
  local out = {}
  for i, w in ipairs(words) do
    out[i] = {
      word = w[1], flagged = w[2] or false, score = w[2] and 0.6 or 1.0,
      expected = w.expected or "θ ɹ iː", heard = w.heard or "t ɹ iː",
      errors = w.errors or (w[2] and { { exp = "θ", got = "t" } } or {}),
      clip = w.clip,
    }
  end
  return { words = out }
end

describe("pronunciation.english", function()
  it("takes English dictation", function()
    assert.is_true(pron.english("I have three kids", nil))
    assert.is_true(pron.english("I have three kids", "en"))
  end)

  it("skips a take when dictation is pinned to another language", function()
    assert.is_false(pron.english("I have three kids", "fr"))
  end)

  it("skips a take that reads as French", function()
    assert.is_false(pron.english("Il a été très sympathique à l'école", nil))
  end)

  it("skips a take too short to say anything about", function()
    assert.is_false(pron.english("Yes.", nil))
  end)
end)

describe("pronunciation.ingest", function()
  it("starts tracking a flagged word but keeps it out of lessons after one slip", function()
    local s = pron.new()
    local entered = pron.ingest(s, result({ { "three", true }, { "kids" } }), T0)
    assert.equals(1, s.words.three.flags)
    assert.is_nil(s.words.three.box)
    assert.same({}, entered)
    assert.is_nil(s.words.kids, "a word said well is not tracked")
    assert.equals(1, s.takes)
  end)

  it("puts a word in practice the second time it is flagged", function()
    local s = pron.new()
    pron.ingest(s, result({ { "three", true } }), T0)
    local entered = pron.ingest(s, result({ { "three", true } }), T0 + 60)
    assert.same({ "three" }, entered)
    assert.equals(0, s.words.three.box)
    assert.equals(T0 + 60, s.words.three.due)
  end)

  it("counts how often a tracked word was said, flagged or not", function()
    local s = pron.new()
    pron.ingest(s, result({ { "three", true } }), T0)
    pron.ingest(s, result({ { "three" } }), T0 + 1)
    assert.equals(2, s.words.three.seen)
    assert.equals(1, s.words.three.flags)
  end)

  it("tallies the sound swaps behind a word", function()
    local s = pron.new()
    pron.ingest(s, result({ { "three", true } }), T0)
    pron.ingest(s, result({ { "three", true, errors = { { exp = "ɹ", got = "" } } } }), T0)
    assert.equals(1, s.words.three.patterns["θ→t"])
    assert.equals(1, s.words.three.patterns["ɹ→∅"])
  end)

  it("keeps the newest clips and returns the ones to delete", function()
    local s = pron.new()
    local drop
    for i = 1, pron.CLIPS_PER_WORD + 2 do
      drop = select(2, pron.ingest(s, result({ { "three", true, clip = "/c/" .. i .. ".wav" } }), T0 + i))
    end
    assert.equals(pron.CLIPS_PER_WORD, #s.words.three.clips)
    assert.equals("/c/" .. (pron.CLIPS_PER_WORD + 2) .. ".wav", s.words.three.clips[1])
    assert.same({ "/c/2.wav" }, drop)
  end)

  it("brings a mastered word back when it slips twice again", function()
    local s = pron.new()
    pron.ingest(s, result({ { "three", true } }), T0)
    pron.ingest(s, result({ { "three", true } }), T0)
    s.words.three.box, s.words.three.mastered = nil, T0
    pron.ingest(s, result({ { "three", true } }), T0 + DAY)
    assert.is_nil(s.words.three.box)
    pron.ingest(s, result({ { "three", true } }), T0 + DAY)
    assert.equals(0, s.words.three.box)
    assert.is_nil(s.words.three.mastered)
  end)
end)

-- A word that is in practice, flagged `flags` times, in `box`, due at `due`.
local function practising(s, word, box, due, flags)
  s.words[word] = { word = word, seen = flags or 2, flags = flags or 2, patterns = {}, clips = {},
                    box = box, due = due }
end

describe("pronunciation.due", function()
  it("lists due words, the least learned and most slipped first", function()
    local s = pron.new()
    practising(s, "three", 1, T0 - 1, 2)
    practising(s, "think", 0, T0, 2)
    practising(s, "with", 0, T0, 5)
    practising(s, "later", 2, T0 + DAY)
    local words = {}
    for _, e in ipairs(pron.due(s, T0, 10)) do words[#words + 1] = e.word end
    assert.same({ "with", "think", "three" }, words)
  end)

  it("stops at the limit", function()
    local s = pron.new()
    for i = 1, 5 do practising(s, "w" .. i, 0, T0) end
    assert.equals(3, #pron.due(s, T0, 3))
  end)
end)

describe("pronunciation.lessonItems", function()
  it("falls back to the weakest words when nothing is due", function()
    local s = pron.new()
    practising(s, "three", 2, T0 + DAY, 2)
    practising(s, "think", 1, T0 + DAY, 4)
    local items = pron.lessonItems(s, T0, 10)
    assert.equals("think", items[1].word)
    assert.equals(2, #items)
  end)
end)

describe("pronunciation.grade", function()
  it("moves a passed word up a box and out by that box's interval", function()
    local s = pron.new()
    practising(s, "three", 0, T0)
    pron.grade(s, "three", true, T0)
    assert.equals(1, s.words.three.box)
    assert.equals(T0 + pron.INTERVALS[1] * DAY, s.words.three.due)
  end)

  it("masters a word that passes in the last box", function()
    local s = pron.new()
    practising(s, "three", #pron.INTERVALS, T0)
    pron.grade(s, "three", true, T0)
    assert.equals(T0, s.words.three.mastered)
    assert.is_nil(s.words.three.box)
  end)

  it("sends a missed word back to the start, due tomorrow", function()
    local s = pron.new()
    practising(s, "three", 3, T0)
    pron.grade(s, "three", false, T0)
    assert.equals(0, s.words.three.box)
    assert.equals(T0 + DAY, s.words.three.due)
    assert.equals(1, s.words.three.tries)
    assert.equals(0, s.words.three.passes)
  end)
end)

describe("pronunciation.attempt", function()
  local function scored(score, errors)
    return { words = { { word = "three", score = score, heard = "t ɹ iː", errors = errors or {} } } }
  end

  it("passes at the bar", function()
    local ok, w = pron.attempt(scored(pron.PASS_AT), "three")
    assert.is_true(ok)
    assert.equals("three", w.word)
  end)

  it("fails below it", function()
    assert.is_false((pron.attempt(scored(0.5), "three")))
  end)

  it("fails when nothing was heard", function()
    assert.is_false((pron.attempt({ words = {} }, "three")))
  end)
end)

describe("pronunciation.patterns", function()
  it("sums sound swaps across practised words, the commonest first", function()
    local s = pron.new()
    practising(s, "three", 0, T0); s.words.three.patterns = { ["θ→t"] = 3 }
    practising(s, "think", 0, T0); s.words.think.patterns = { ["θ→t"] = 2, ["ŋ→n"] = 1 }
    local p = pron.patterns(s, 5)
    assert.equals("θ→t", p[1].pattern)
    assert.equals(5, p[1].count)
    assert.same({ "think", "three" }, p[1].words)
  end)
end)

describe("pronunciation.tip", function()
  it("has a built-in tip for the commonest swaps", function()
    assert.truthy(pron.tip({ patterns = { ["θ→t"] = 2 } }):find("teeth"))
  end)

  it("prefers Claude's tip when there is one", function()
    assert.equals("Bite lightly.", pron.tip({ patterns = { ["θ→t"] = 2 }, coach = { tip = "Bite lightly." } }))
  end)
end)

describe("pronunciation.shouldRemind", function()
  it("reminds once a week when enough words are due", function()
    local s = pron.new()
    for i = 1, pron.REMIND_AT do practising(s, "w" .. i, 0, T0) end
    s.lastLesson = T0 - 8 * DAY
    assert.is_true(pron.shouldRemind(s, T0))
    s.lastReminder = T0 - 3600
    assert.is_false(pron.shouldRemind(s, T0), "not twice in a day")
  end)

  it("stays quiet after a recent lesson or with too few words", function()
    local s = pron.new()
    practising(s, "three", 0, T0)
    s.lastLesson = T0 - 8 * DAY
    assert.is_false(pron.shouldRemind(s, T0))
    for i = 1, pron.REMIND_AT do practising(s, "w" .. i, 0, T0) end
    s.lastLesson = T0 - DAY
    assert.is_false(pron.shouldRemind(s, T0))
  end)
end)

describe("pronunciation.coach", function()
  it("asks about words only, never the sentence they came from", function()
    local s = pron.new()
    practising(s, "three", 0, T0)
    s.words.three.expected, s.words.three.heard = "θ ɹ iː", "t ɹ iː"
    s.words.three.sentence = "the secret project has three kids"
    local input = pron.coachInput({ s.words.three })
    assert.truthy(input:find("three", 1, true))
    assert.falsy(input:find("secret", 1, true))
  end)

  it("builds a claude -p command with no tools", function()
    local argv = pron.coachArgv("claude-haiku-5-5")
    local joined = table.concat(argv, " ")
    assert.truthy(joined:find("--tools", 1, true))
    assert.truthy(joined:find("--output-format json", 1, true))
  end)

  it("reads Claude's JSON answer into tips by word", function()
    local reply = { result = '```json\n[{"word":"three","respell":"THREE","tip":"Tongue between teeth.","sentence":"I have three cats."}]\n```' }
    local seen
    local by = pron.parseCoach(reply, function(s)
      seen = s
      return { { word = "three", respell = "THREE", tip = "Tongue between teeth.", sentence = "I have three cats." } }
    end)
    assert.equals('[{"word":"three","respell":"THREE","tip":"Tongue between teeth.","sentence":"I have three cats."}]', seen,
                  "the code fence is stripped before decoding")
    assert.equals("THREE", by.three.respell)
    assert.equals("I have three cats.", by.three.sentence)
  end)

  it("returns nothing for an error reply", function()
    assert.is_nil(pron.parseCoach({ is_error = true, result = "logged out" }, function() return {} end))
  end)
end)
