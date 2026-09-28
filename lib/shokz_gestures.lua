-- Pure gesture logic for the Shokz OpenComm2 — no hs.* dependency, fully
-- unit-testable. The wiring lives in apps/shokz.
--
-- Background: over plain Bluetooth the OpenComm2 gives macOS almost nothing to
-- hook. The multifunction button reaches the machine through mediaremoted and
-- never becomes a CGEvent, so no event tap can see it. What IS observable is
-- the volume:
-- pressing volume+/- changes the output device's level, and the level itself
-- reveals who moved it.

local M = {}

-- Each source moves the volume on its own scale, so the resulting level says
-- which one moved it:
--
--   Headset, A2DP (music) → AVRCP absolute volume, 0..127 → lands on n/127
--   Headset, HFP  (call)  → HFP speaker gain,      0..15  → lands on n/15
--   Mac media keys        → 16 steps                      → lands on n/16
--
-- Both headset grids are real: 85/127 = 66.929…% while the headset was in A2DP,
-- 8/15 = 53.333…% after it switched to HFP. Checking only the 127 grid silently
-- drops every press made during a call.
--
-- The grids coincide only at 0% and 100%, which is why those report "ambiguous"
-- instead of being guessed at.
local HEADSET_GRIDS = { 127, 15 }
local MAC_GRID = 16

local function landsOn(vol, scale, tol)
  local x = vol * scale / 100
  return math.abs(x - math.floor(x + 0.5)) < (tol or 0.02)
end

-- Returns "headset", "mackey", or "ambiguous".
function M.classify(vol, tol)
  local headset = false
  for _, g in ipairs(HEADSET_GRIDS) do
    if landsOn(vol, g, tol) then
      headset = true
      break
    end
  end
  local mac = landsOn(vol, MAC_GRID, tol)
  if headset and not mac then return "headset" end
  if mac and not headset then return "mackey" end
  return "ambiguous"
end

-- Recognises a tight opposite-direction pair: volume+ immediately followed by
-- volume-, or the reverse. Two opposite presses cancel out, so the volume ends
-- where it started and nothing ever has to be written back — no fighting the
-- headset's own volume state and no watcher feedback loop.
--
-- Firing only on EXACTLY two presses inside the window is what stops a genuine
-- correction (up, up, down — overshoot then fix) from being read as a gesture.
--
-- Returns function(dir, now) -> chord, state
--   chord : "up_down" | "down_up" | nil
--   state : { n = presses retained, gap = seconds since the previous press }
--           purely diagnostic, so the log can explain why a chord did or did
--           not fire without re-deriving it from timestamps.
function M.newRecognizer(window)
  window = window or 0.6
  local history = {}
  return function(dir, now)
    local gap = (#history > 0) and (now - history[#history].t) or nil
    history[#history + 1] = { dir = dir, t = now }
    local keep = {}
    for _, e in ipairs(history) do
      if now - e.t <= window then keep[#keep + 1] = e end
    end
    history = keep
    local state = { n = #history, gap = gap }
    if #history ~= 2 then return nil, state end
    local a, b = history[1].dir, history[2].dir
    if a == b then return nil, state end
    history = {} -- consume, so a third press starts a fresh pair
    return ((a == "up") and "up_down" or "down_up"), state
  end
end

return M
