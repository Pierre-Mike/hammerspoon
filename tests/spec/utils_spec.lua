local utils = require("lib.utils")

describe("utils.trim", function()
  it("strips leading whitespace", function()
    assert.equals("hello", utils.trim("  hello"))
  end)

  it("strips trailing whitespace", function()
    assert.equals("hello", utils.trim("hello  "))
  end)

  it("strips both sides", function()
    assert.equals("hello", utils.trim("  hello  "))
  end)

  it("preserves inner whitespace", function()
    assert.equals("hello world", utils.trim("  hello world  "))
  end)

  it("returns nil for nil input", function()
    assert.is_nil(utils.trim(nil))
  end)

  it("returns empty string unchanged", function()
    assert.equals("", utils.trim(""))
  end)

  it("handles whitespace-only string", function()
    assert.equals("", utils.trim("   "))
  end)
end)

describe("utils.urldecode", function()
  it("decodes percent-encoded space", function()
    assert.equals("hello world", utils.urldecode("hello%20world"))
  end)

  it("converts + to space", function()
    assert.equals("hello world", utils.urldecode("hello+world"))
  end)

  it("decodes mixed encoding", function()
    assert.equals("foo bar baz", utils.urldecode("foo%20bar+baz"))
  end)

  it("returns empty string for nil", function()
    assert.equals("", utils.urldecode(nil))
  end)

  it("leaves plain strings untouched", function()
    assert.equals("hello", utils.urldecode("hello"))
  end)

  it("decodes newline", function()
    assert.equals("line1\nline2", utils.urldecode("line1%0Aline2"))
  end)
end)

describe("utils.truncate", function()
  it("leaves short strings intact", function()
    assert.equals("hi", utils.truncate("hi", 60))
  end)

  it("truncates and appends ellipsis", function()
    local result = utils.truncate("hello world", 5)
    assert.equals("hello…", result)
  end)

  it("returns nil for nil input", function()
    assert.is_nil(utils.truncate(nil, 60))
  end)

  it("exact length is not truncated", function()
    assert.equals("hello", utils.truncate("hello", 5))
  end)
end)

describe("utils.countWrappedLines", function()
  it("returns 1 for empty string", function()
    assert.equals(1, utils.countWrappedLines("", 40))
  end)

  it("returns 1 for short single line", function()
    assert.equals(1, utils.countWrappedLines("hello", 40))
  end)

  it("counts newlines", function()
    assert.equals(3, utils.countWrappedLines("a\nb\nc", 40))
  end)

  it("wraps long lines", function()
    -- "aaaaaaaaaa" = 10 chars, charsPerLine=5 → fills 2 lines + triggers wrap = 3
    -- (matches original init.lua algorithm: wrap at boundary increments lines)
    assert.equals(3, utils.countWrappedLines("aaaaaaaaaa", 5))
  end)

  it("does not wrap at exactly charsPerLine-1", function()
    -- "aaaa" = 4 chars, charsPerLine=5 → fits in 1 line
    assert.equals(1, utils.countWrappedLines("aaaa", 5))
  end)

  it("combines wrapping and newlines", function()
    -- "aaaaaa\nb" → line1 wraps at 5 (2 lines), then \n, then "b" = 3 lines total
    assert.equals(3, utils.countWrappedLines("aaaaaa\nb", 5))
  end)
end)
