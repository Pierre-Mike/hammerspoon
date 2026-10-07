-- lib/transcript_filter cleans a finished transcript before it is pasted. Pure,
-- so no hs mock is needed.
local tf = require("lib.transcript_filter")

describe("transcript_filter.clean", function()
  -- Whisper fills silence with phrases from its training subtitles. When one of
  -- them is the whole take, nothing was said.
  it("drops a known hallucination when it is the entire transcript", function()
    local o = { stockLines = true }
    assert.equals("", tf.clean("Thanks for watching!", o))
    assert.equals("", tf.clean("  Thank you.  ", o))
    assert.equals("", tf.clean("you", o))
    assert.equals("", tf.clean("Subtitles by the Amara.org community", o))
    assert.equals("", tf.clean("[BLANK_AUDIO]", o))
  end)

  -- Parakeet doesn't invent subtitle lines, so on it a short "Thank you." was
  -- really said and must paste.
  it("keeps stock lines when stockLines is off", function()
    assert.equals("Thank you.", tf.clean("Thank you."))
    assert.equals("Bye", tf.clean("Bye", { stockLines = false }))
  end)

  it("keeps the same words inside a real dictation", function()
    assert.equals("Thank you for the review, merging now.",
      tf.clean("Thank you for the review, merging now."))
    assert.equals("Did you see it?", tf.clean("Did you see it?"))
  end)

  -- The loop Whisper falls into on trailing silence: one sentence over and over.
  it("collapses a sentence repeated back to back", function()
    assert.equals("Open the file.",
      tf.clean("Open the file. Open the file. Open the file."))
  end)

  it("keeps a sentence that repeats with something in between", function()
    assert.equals("Yes. No. Yes.", tf.clean("Yes. No. Yes."))
  end)

  it("treats repeats that differ only in case and spacing as the same", function()
    assert.equals("Hello there.", tf.clean("Hello there.  hello there."))
  end)

  it("trims and passes ordinary text through", function()
    assert.equals("ship it", tf.clean("  ship it \n"))
  end)

  it("returns an empty string for nil or blank input", function()
    assert.equals("", tf.clean(nil))
    assert.equals("", tf.clean("   "))
  end)
end)
