-- The last few dictation recordings, kept so a take can be run again through
-- another model — no hs.* dependency. apps/dictation copies each finished WAV
-- into the takes directory under name(); prune() says which ones to delete.

local M = {}

M.KEEP = 5
M.PATTERN = "^take%-(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)%.wav$"

-- Named by local start time, so a plain string sort is a sort by age.
function M.name(epoch)
  return os.date("take-%Y%m%d-%H%M%S.wav", epoch)
end

-- Given every file name in the takes directory, returns the newest `keep` takes
-- (newest first) and the older ones to delete. Other files are ignored.
function M.prune(names, keep)
  local found = {}
  for _, n in ipairs(names or {}) do
    if n:match(M.PATTERN) then found[#found + 1] = n end
  end
  table.sort(found, function(a, b) return a > b end)
  local kept, remove = {}, {}
  for i, n in ipairs(found) do
    if i <= (keep or M.KEEP) then kept[#kept + 1] = n else remove[#remove + 1] = n end
  end
  return kept, remove
end

-- Menu label: when the take was recorded.
function M.label(name)
  local y, mo, d, h, mi, s = name:match(M.PATTERN)
  if not y then return name end
  local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
                      hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
  return os.date("%b %d %H:%M:%S", t)
end

return M
