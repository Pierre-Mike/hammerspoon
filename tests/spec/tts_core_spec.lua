local tts = require("lib.tts_core")

describe("tts_core.sanitize", function()
  it("returns empty string for nil", function()
    assert.equals("", tts.sanitize(nil))
  end)

  it("trims both ends", function()
    assert.equals("hello", tts.sanitize("  hello  "))
  end)

  it("collapses internal whitespace runs", function()
    assert.equals("hello world", tts.sanitize("hello   world"))
  end)

  it("collapses newlines and tabs to single spaces", function()
    assert.equals("a b c", tts.sanitize("a\n\tb\n\nc"))
  end)

  it("returns empty string for whitespace-only input", function()
    assert.equals("", tts.sanitize("  \n\t "))
  end)
end)

describe("tts_core.splitSentences", function()
  it("returns empty table for empty input", function()
    assert.same({}, tts.splitSentences(""))
    assert.same({}, tts.splitSentences(nil))
    assert.same({}, tts.splitSentences("   "))
  end)

  it("keeps a single short sentence whole", function()
    assert.same({ "Hello there." }, tts.splitSentences("Hello there."))
  end)

  it("merges short adjacent sentences under maxLen", function()
    -- both fit together well under 220
    assert.same({ "One. Two. Three." }, tts.splitSentences("One. Two. Three."))
  end)

  it("splits into separate chunks when merge would exceed maxLen", function()
    local a = string.rep("a", 200) .. "."
    local b = string.rep("b", 200) .. "."
    assert.same({ a, b }, tts.splitSentences(a .. " " .. b))
  end)

  it("preserves ! and ? terminators", function()
    assert.same({ "Really?! Yes! Ok." }, tts.splitSentences("Really?! Yes! Ok."))
  end)

  it("hard-wraps a single sentence longer than maxLen at word boundaries", function()
    local long = string.rep("word ", 60)          -- 300 chars, no terminator
    local chunks = tts.splitSentences(long, 100)
    assert.is_true(#chunks >= 3)
    for _, c in ipairs(chunks) do
      assert.is_true(#c <= 100)
      assert.is_nil(c:match("^%s"))               -- no leading whitespace
      assert.is_nil(c:match("%s$"))               -- no trailing whitespace
    end
    -- reassembling on single spaces yields the original words
    assert.equals((long:gsub("%s+$", "")), table.concat(chunks, " "))
  end)

  it("emits an overlong single word whole rather than mangling it", function()
    local word = string.rep("x", 50)
    local chunks = tts.splitSentences(word, 10)
    assert.same({ word }, chunks)
  end)

  it("handles text with no terminator as one chunk when short", function()
    assert.same({ "no terminator here" }, tts.splitSentences("no terminator here"))
  end)
end)

describe("tts_core queue primitives", function()
  it("enqueue appends a single string and returns length", function()
    local q = {}
    assert.equals(1, tts.enqueue(q, "a"))
    assert.equals(2, tts.enqueue(q, "b"))
    assert.same({ "a", "b" }, q)
  end)

  it("enqueue appends a list of chunks", function()
    local q = {}
    assert.equals(3, tts.enqueue(q, { "a", "b", "c" }))
    assert.same({ "a", "b", "c" }, q)
  end)

  it("enqueue skips empty and nil chunks", function()
    local q = {}
    tts.enqueue(q, { "a", "", "b" })
    assert.same({ "a", "b" }, q)
  end)

  it("dequeue returns head first (FIFO) and nil when empty", function()
    local q = {}
    tts.enqueue(q, { "first", "second" })
    assert.equals("first", tts.dequeue(q))
    assert.equals("second", tts.dequeue(q))
    assert.is_nil(tts.dequeue(q))
  end)

  it("clear empties the queue and returns the drop count", function()
    local q = {}
    tts.enqueue(q, { "a", "b", "c" })
    assert.equals(3, tts.clear(q))
    assert.same({}, q)
    assert.equals(0, tts.clear(q))
  end)
end)
