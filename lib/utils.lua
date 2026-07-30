-- Pure utility functions — no hs.* dependency, fully unit-testable.

local M = {}

function M.logf(logfile, fmt, ...)
  local line = string.format(fmt, ...)
  local f = io.open(logfile, "a")
  if f then
    f:write(os.date("%H:%M:%S "), line, "\n")
    f:close()
  end
  print(line)
end

function M.readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Strip leading/trailing whitespace. Returns nil when input is nil.
function M.trim(text)
  if not text then return nil end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- URL-decode a percent-encoded string (handles + as space too).
function M.urldecode(s)
  if not s then return "" end
  s = s:gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Truncate text to maxLen bytes, appending "…" when cut. The cut point backs off
-- so a multi-byte UTF-8 character is never sliced in half (half a character
-- renders as a replacement glyph in alerts and log lines).
function M.truncate(text, maxLen)
  if not text or #text <= maxLen then return text end
  local cut = maxLen
  while cut > 1 do
    local b = text:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end   -- next byte starts a new char
    cut = cut - 1
  end
  return text:sub(1, cut) .. "…"
end

-- Estimate the number of display lines for text wrapped at charsPerLine.
function M.countWrappedLines(text, charsPerLine)
  if not text or text == "" then return 1 end
  local lines = 1
  local seg = 0
  for i = 1, #text do
    local c = text:sub(i, i)
    if c == "\n" then
      lines = lines + 1
      seg = 0
    else
      seg = seg + 1
      if seg >= charsPerLine then
        lines = lines + 1
        seg = 0
      end
    end
  end
  return lines
end

return M
