-- Reading Microsoft Teams' meeting mute from its accessibility tree.
-- No hs.* dependency: apps/shokz_mute does the walking and the clicking.
--
-- The approach comes from hugoh/TeamsControl.spoon (MIT), which adapted the
-- button search from RobvH/teams-mac-hotkeys. During a call Teams exposes an
-- AXButton labelled "Mute mic" or "Unmute mic" about 20 levels deep in its
-- WebView2 tree. The label names the action the button performs, so
-- "Unmute mic" means the mic is muted right now.

local M = {}

M.MAX_DEPTH = 25

-- "Mute mic" or "Unmute mic" -> muted?  Anything else -> nil. Matched on the
-- end of the label, as TeamsControl does ("ute mic$").
function M.mutedFromLabel(label)
  if type(label) ~= "string" then return nil end
  if label:match("Unmute mic$") then return true end
  if label:match("Mute mic$") then return false end
  return nil
end

local function labelOf(el)
  return el.AXDescription or el.AXTitle
end

-- Depth-first search for the first AXButton whose label is the mic button.
-- Works on hs.axuielement objects and on plain tables alike, since both are
-- read by indexing.
function M.findMuteButton(el, maxDepth, depth)
  if el == nil then return nil end
  maxDepth, depth = maxDepth or M.MAX_DEPTH, depth or 0
  if depth > maxDepth then return nil end
  if el.AXRole == "AXButton" and M.mutedFromLabel(labelOf(el)) ~= nil then
    return el
  end
  local children = el.AXChildren
  if type(children) ~= "table" then return nil end
  for _, child in ipairs(children) do
    local found = M.findMuteButton(child, maxDepth, depth + 1)
    if found then return found end
  end
  return nil
end

-- Muted state read from a button found earlier, or nil once the reference has
-- gone stale (Teams swapped the node out, or the call ended).
function M.readButton(btn)
  if btn == nil then return nil end
  return M.mutedFromLabel(labelOf(btn))
end

-- Teams' main meeting window stops updating while Teams is in the background,
-- but the floating compact view (a non-standard window) stays live, so it is
-- searched first. `wins` is a list of { standard = bool, ... }; order within
-- each group is kept.
function M.searchOrder(wins)
  local out = {}
  for _, standard in ipairs({ false, true }) do
    for _, w in ipairs(wins) do
      if (w.standard and true or false) == standard then out[#out + 1] = w end
    end
  end
  return out
end

-- What to do after a headset press, given Teams' mute as read on screen
-- (nil when it could not be read):
--   "none"    Teams already matches
--   "toggle"  send Cmd+Shift+M, then check it landed
--   "blind"   send Cmd+Shift+M with no way to check, as before this module
function M.plan(headsetMuted, teamsMuted)
  if teamsMuted == nil then return "blind" end
  if teamsMuted == headsetMuted then return "none" end
  return "toggle"
end

-- One poll after Cmd+Shift+M (phase "keystroke") or after the click fallback
-- (phase "click"). Each phase has its own retry budget.
--   "done"   Teams now reads the desired state
--   "wait"   poll again shortly
--   "click"  the keystroke never landed (it can hit a focused text field such
--            as meeting notes), so click the button itself
--   "fail"   neither worked
function M.verifyStep(phase, attempt, maxRetries, teamsMuted, desired)
  if teamsMuted ~= nil and teamsMuted == desired then return "done" end
  if attempt < maxRetries then return "wait" end
  if phase == "keystroke" then return "click" end
  return "fail"
end

-- Centre of an AXPosition / AXSize pair. AXPress does nothing on Teams'
-- WebView2 controls, so the fallback is a real click at this point.
function M.clickPoint(pos, size)
  if not (pos and size) then return nil end
  return { x = pos.x + size.w / 2, y = pos.y + size.h / 2 }
end

return M
