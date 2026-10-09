-- Borrow the pasteboard and give it back. apps/tts uses it for Fn+S, which has
-- no way to read the selection except to press ⌘C and put the clipboard back.
--
-- apps/dictation used to borrow it the other way round, to paste a take through
-- ⌘V. It types the take now (apps/keystroke_typer) and leaves it on the
-- clipboard as the fallback, so nothing in this config pastes-and-restores any
-- more and M.pasteAndRestore is gone with it.
--
-- Every hs.* call goes through a `pb` / `deps` argument that defaults to the
-- real module, so the specs can hand in fakes.

local M = {}

-- Grab everything currently on the pasteboard and return a closure that puts it
-- back. readAllData keeps non-text flavours (images, rich text) intact; the
-- getContents path is the fallback for Hammerspoon builds without it.
function M.snapshot(pb)
  pb = pb or hs.pasteboard
  if pb.readAllData then
    local ok, data = pcall(pb.readAllData)
    if ok and type(data) == "table" and next(data) ~= nil then
      return function() pcall(pb.writeAllData, data) end
    end
  end
  local text = pb.getContents()
  return function()
    if text ~= nil then pcall(pb.setContents, text) end
  end
end

return M
