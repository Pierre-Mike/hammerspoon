-- lib/dictation_takes names the saved take recordings and decides which to
-- rotate out. Pure: the caller lists and deletes the files.
local takes = require("lib.dictation_takes")

describe("dictation_takes.name", function()
  it("names a take by its local start time, so names sort by age", function()
    local t = os.time({ year = 2026, month = 10, day = 7, hour = 14, min = 3, sec = 9 })
    assert.equals("take-20261007-140309.wav", takes.name(t))
  end)
end)

describe("dictation_takes.prune", function()
  local NAMES = {
    "take-20261007-140000.wav", "take-20261007-090000.wav", "notes.txt",
    "take-20261006-230000.wav", "take-20261007-120000.wav",
    "take-20261005-080000.wav", "take-20261007-130000.wav",
  }

  it("keeps the newest N takes, newest first", function()
    local keep = takes.prune(NAMES, 3)
    assert.same({
      "take-20261007-140000.wav", "take-20261007-130000.wav", "take-20261007-120000.wav",
    }, keep)
  end)

  it("returns the older takes to delete and never touches other files", function()
    local _, remove = takes.prune(NAMES, 3)
    table.sort(remove)
    assert.same({
      "take-20261005-080000.wav", "take-20261006-230000.wav", "take-20261007-090000.wav",
    }, remove)
  end)

  it("removes nothing when there are fewer takes than the limit", function()
    local keep, remove = takes.prune({ "take-20261007-140000.wav" }, 5)
    assert.same({ "take-20261007-140000.wav" }, keep)
    assert.same({}, remove)
  end)
end)

describe("dictation_takes.label", function()
  it("shows the date and time a take was recorded", function()
    assert.equals("Oct 07 14:03:09", takes.label("take-20261007-140309.wav"))
  end)

  it("falls back to the file name when it is not a take", function()
    assert.equals("odd.wav", takes.label("odd.wav"))
  end)
end)
