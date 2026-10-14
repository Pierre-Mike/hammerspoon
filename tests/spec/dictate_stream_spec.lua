_G.hs = require("hs")

local dstream = require("lib.dictate_stream")

-- apps/keystroke_typer's splitter, which is what a real caller hands in: a
-- backspace count has to be in keypresses, and "é" is one press of two bytes.
local clusters = require("apps.keystroke_typer").clusters

describe("dictate_stream.delta", function()
  it("is the text that arrived since the last poll", function()
    assert.equals(" world", dstream.delta("hello", "hello world"))
  end)

  it("is empty when nothing new has settled", function()
    assert.equals("", dstream.delta("hello", "hello"))
    assert.equals("", dstream.delta("", ""))
  end)

  it("is the whole prefix on the first commit of a take", function()
    assert.equals("Hello there", dstream.delta("", "Hello there"))
  end)

  -- The committed text is frozen on the server, so this should never happen.
  -- nil is how the caller finds out that it did.
  it("is nil when the settled text no longer contains what was typed", function()
    assert.is_nil(dstream.delta("hello world", "goodbye world"))
    assert.is_nil(dstream.delta("hello world", "hello"))
  end)
end)

describe("dictate_stream.committedLen", function()
  it("ends where the typed words end", function()
    assert.equals(5, dstream.committedLen("hello world", "hello"))
    assert.equals(11, dstream.committedLen("hello world", "hello world"))
  end)

  it("is zero when nothing has been typed", function()
    assert.equals(0, dstream.committedLen("hello world", ""))
    assert.equals(0, dstream.committedLen("", "anything"))
  end)

  -- A comma that moves must not drag the highlight back with it.
  it("ignores punctuation and casing drift behind the cursor", function()
    assert.equals(#"We cannot use it,", dstream.committedLen(
      "We cannot use it, we said", "we cannot use it."))
  end)

  it("never cuts a character in half", function()
    local n = dstream.committedLen("naïve idea", "naïve")
    assert.equals("naïve", ("naïve idea"):sub(1, n))
  end)
end)

describe("dictate_stream.reconcile", function()
  it("appends the tail that was never typed", function()
    local r = dstream.reconcile("Hello there", "Hello there, world.", { clusters = clusters })
    assert.equals("append", r.action)
    assert.equals(0, r.backspaces)
    assert.equals(", world.", r.text)
  end)

  it("types the whole transcript when nothing went out live", function()
    local r = dstream.reconcile("", "Hello there.", { clusters = clusters })
    assert.equals("append", r.action)
    assert.equals("Hello there.", r.text)
  end)

  it("does nothing when the two already agree", function()
    local r = dstream.reconcile("Hello there.", "Hello there.", { clusters = clusters })
    assert.equals("none", r.action)
  end)

  -- The failure that made this word-based. A ten-take run ended with one take
  -- word-perfect at 190 characters and one period different; read as
  -- characters that is a 100-character divergence and the take is abandoned.
  it("leaves punctuation and casing behind the cursor alone", function()
    local r = dstream.reconcile(
      "those will not be compress or thumbnail. They will be injected",
      "those will not be compress or thumbnail They will be injected",
      { clusters = clusters })
    assert.equals("none", r.action)
    assert.equals(0, r.backspaces)
  end)

  it("still picks up punctuation the transcript hangs off the last word", function()
    local r = dstream.reconcile("Hello there", "Hello there.", { clusters = clusters })
    assert.equals("append", r.action)
    assert.equals(".", r.text)
  end)

  -- The one failure in ten takes: a leading "Uh" five passes agreed on, which
  -- the final full-audio pass deleted.
  it("takes back a short tail that turned out to be the wrong words", function()
    local r = dstream.reconcile("Uh should we believe the",
                                "Should we believe the Reed of the Ixif?",
                                { clusters = clusters })
    assert.equals("fix", r.action)
    assert.equals(24, r.backspaces)
    assert.equals("Should we believe the Reed of the Ixif?", r.text)
  end)

  it("backspaces only to the last word the two agree on", function()
    local r = dstream.reconcile("one two three", "one two four", { clusters = clusters })
    assert.equals("fix", r.action)
    assert.equals(#" three", r.backspaces)
    assert.equals(" four", r.text)
  end)

  it("counts a backspace per keypress, not per byte", function()
    local r = dstream.reconcile("a naïve", "a careful", { clusters = clusters })
    assert.equals(7, #" naïve")                   -- bytes
    assert.equals(6, r.backspaces)                -- keypresses
  end)

  it("refuses to delete more than the bound and hands over the clipboard", function()
    local typed = "wrong " .. string.rep("x", 60)
    local r = dstream.reconcile(typed, "right answer", { clusters = clusters })
    assert.equals("clipboard", r.action)
    assert.equals("right answer", r.text)
  end)

  it("takes the bound from the caller", function()
    local r = dstream.reconcile("one two three", "one four",
                                { clusters = clusters, maxBackspaces = 2 })
    assert.equals("clipboard", r.action)
  end)

  it("works without a splitter, counting bytes", function()
    local r = dstream.reconcile("one two", "one three")
    assert.equals("fix", r.action)
    assert.equals(#" two", r.backspaces)
  end)
end)

describe("dictate_stream.available", function()
  local function st(over)
    local s = { on = true, engine = "parakeet", dictate = true, llmCleanup = false }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end

  it("is on when the setting, the model and the server all allow it", function()
    assert.is_true((dstream.available(st())))
  end)

  it("is off when the user switched it off", function()
    local ok, why = dstream.available(st({ on = false }))
    assert.is_false(ok)
    assert.equals("off", why)
  end)

  -- Only parakeet's generate() returns tokens with timestamps, and without
  -- those there is no margin to measure.
  it("is off on a model that carries no token timestamps", function()
    local ok, why = dstream.available(st({ engine = "mlxa" }))
    assert.is_false(ok)
    assert.is_truthy(why:find("mlxa", 1, true))
  end)

  it("is off when the server has no commit rule loaded", function()
    assert.is_false((dstream.available(st({ dictate = false }))))
  end)

  -- LM Studio rewrites the finished transcript wholesale, and a rewrite has no
  -- prefix to have committed against.
  it("is off when the LM Studio clean-up is on", function()
    local ok, why = dstream.available(st({ llmCleanup = true }))
    assert.is_false(ok)
    assert.is_truthy(why:find("LM Studio", 1, true))
  end)

  it("is off given nothing at all", function()
    assert.is_false((dstream.available(nil)))
  end)
end)
