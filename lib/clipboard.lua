-- Borrow the pasteboard and give it back. Shared by apps/tts (Fn+S copies the
-- selection) and apps/dictation (a take pastes through ⌘V).
--
-- Every hs.* call goes through a `pb` / `deps` argument that defaults to the
-- real module, so the specs can hand in fakes.

local M = {}

-- How long the target app gets to read the pasteboard after ⌘V before the
-- user's own clipboard goes back. The app reads it when it handles the key
-- event, not when we post it, so this cannot be zero.
M.RESTORE_DELAY = 0.5

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

-- Paste `text` at the cursor through ⌘V, then put the user's clipboard back
-- after RESTORE_DELAY. The restore is skipped if the pasteboard changed in the
-- meantime: that is the user copying something, and theirs wins.
--   deps = { pb, keyStroke(mods, key), after(delay, fn), delay }
function M.pasteAndRestore(text, deps)
  if type(text) ~= "string" or text == "" then return end
  deps = deps or {}
  local pb = deps.pb or hs.pasteboard
  local keyStroke = deps.keyStroke or function(mods, key) hs.eventtap.keyStroke(mods, key, 0) end
  local after = deps.after or function(delay, fn) return hs.timer.doAfter(delay, fn) end

  local restore = M.snapshot(pb)
  pb.setContents(text)
  local mine = pb.changeCount and pb.changeCount() or nil
  keyStroke({ "cmd" }, "v")
  return after(deps.delay or M.RESTORE_DELAY, function()
    if mine ~= nil and pb.changeCount() ~= mine then return end
    restore()
  end)
end

return M
