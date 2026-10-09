-- lib/clipboard: borrow the pasteboard and give it back. The pasteboard is
-- passed in, so these specs own it.
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
