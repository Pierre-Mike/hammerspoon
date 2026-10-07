-- lib/clipboard: borrow the pasteboard and give it back. The pasteboard, the
-- keystroke and the timer are passed in, so these specs own all three.
local clip = require("lib.clipboard")

-- A pasteboard with every flavour (readAllData) and a changeCount that moves on
-- each write, like the real one.
local function fakePasteboard(initial)
  local pb = { data = initial, count = 1 }
  function pb.readAllData() return pb.data end
  function pb.writeAllData(d) pb.data = d; pb.count = pb.count + 1 end
  function pb.getContents() return pb.data and pb.data["public.utf8-plain-text"] end
  function pb.setContents(s) pb.data = { ["public.utf8-plain-text"] = s }; pb.count = pb.count + 1 end
  function pb.changeCount() return pb.count end
  return pb
end

local function deps(pb)
  local d = { pb = pb, sent = {}, timers = {} }
  d.keyStroke = function(mods, key) d.sent[#d.sent + 1] = { mods = mods, key = key, text = pb.getContents() } end
  d.after = function(delay, fn) d.timers[#d.timers + 1] = { delay = delay, fn = fn } end
  return d
end

local IMAGE = { ["public.png"] = "PNGDATA", ["public.utf8-plain-text"] = "caption" }

describe("clipboard.snapshot", function()
  it("puts back every flavour, not just the text", function()
    local pb = fakePasteboard(IMAGE)
    local restore = clip.snapshot(pb)
    pb.setContents("other")
    restore()
    assert.same(IMAGE, pb.data)
  end)

  it("falls back to plain text when readAllData is unavailable", function()
    local pb = fakePasteboard({ ["public.utf8-plain-text"] = "old" })
    pb.readAllData = nil
    local restore = clip.snapshot(pb)
    pb.setContents("new")
    restore()
    assert.equals("old", pb.getContents())
  end)
end)

describe("clipboard.pasteAndRestore", function()
  it("pastes the text with ⌘V, then restores the user's clipboard after a delay", function()
    local pb = fakePasteboard(IMAGE)
    local d = deps(pb)
    clip.pasteAndRestore("dictated words", d)
    assert.equals(1, #d.sent)
    assert.same({ "cmd" }, d.sent[1].mods)
    assert.equals("v", d.sent[1].key)
    assert.equals("dictated words", d.sent[1].text)
    -- Not restored yet: the app reads the pasteboard when it handles ⌘V.
    assert.equals("dictated words", pb.getContents())
    assert.equals(1, #d.timers)
    assert.is_true(d.timers[1].delay > 0)
    d.timers[1].fn()
    assert.same(IMAGE, pb.data)
  end)

  -- The user copied something between the paste and the restore. Theirs wins.
  it("leaves the clipboard alone if it changed after the paste", function()
    local pb = fakePasteboard(IMAGE)
    local d = deps(pb)
    clip.pasteAndRestore("dictated words", d)
    pb.setContents("copied meanwhile")
    d.timers[1].fn()
    assert.equals("copied meanwhile", pb.getContents())
  end)

  it("does nothing for empty text", function()
    local pb = fakePasteboard(IMAGE)
    local d = deps(pb)
    clip.pasteAndRestore("", d)
    assert.equals(0, #d.sent)
    assert.same(IMAGE, pb.data)
  end)
end)
