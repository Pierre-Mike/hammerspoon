local synthetic = require("lib.synthetic")

describe("synthetic.isOurs", function()
  it("recognises an event this process posted", function()
    assert.is_true(synthetic.isOurs(4242, 4242))
  end)

  it("does not recognise anyone else's", function()
    assert.is_false(synthetic.isOurs(99, 4242))
  end)

  -- A pid we could not read must never be read as permission to swallow a
  -- real keystroke: the chord tap would eat Fn+C for the user too.
  it("treats an unreadable pid as a stranger's", function()
    assert.is_false(synthetic.isOurs(nil, 4242))
    assert.is_false(synthetic.isOurs(0, 0))
    assert.is_false(synthetic.isOurs(4242, nil))
  end)
end)

describe("synthetic.isTyper", function()
  it("recognises the typer's mark", function()
    assert.is_true(synthetic.isTyper(synthetic.TYPER))
  end)

  -- An event nobody marked reads 0, and apps/tts's ⌘C is ours without being
  -- the typer's.
  it("does not recognise an unmarked event", function()
    assert.is_false(synthetic.isTyper(0))
    assert.is_false(synthetic.isTyper(nil))
    assert.is_false(synthetic.isTyper(1))
  end)
end)
