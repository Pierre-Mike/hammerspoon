-- Nose Guard — disruptive face-touch deterrent.
-- A headless Python daemon (noseguard.py) watches the webcam and fires
--   open "hammerspoon://noseguard?event=touch|ready|error"
-- on each detected hand-to-face touch. We answer with a fullscreen red flash +
-- alarm + a running counter. Works over any app — no focused browser tab.
--
-- Menubar 👃 toggles the daemon on/off. Detection runs only while ON.

local M = {
  task = nil,        -- hs.task running the python daemon
  menu = nil,        -- hs.menubar
  canvas = nil,      -- fullscreen overlay
  flashTimer = nil,
  count = 0,
  sens = 55,         -- 0..100, passed to daemon as NG_SENS
  hold = 0.4,        -- seconds of sustained touch before alert
  camId = "",        -- AVFoundation uniqueID, passed as NG_CAM_ID ("" = auto/builtin)
}

local DIR = os.getenv("HOME") .. "/.hammerspoon/apps/noseguard"
local PY = DIR .. "/.venv/bin/python"
local SCRIPT = DIR .. "/noseguard.py"
local LOG = "/tmp/hs-noseguard.log"

-- Single source of truth: the daemon enumerates AVFoundation, we render its list.
-- Selecting by uniqueID (not index) survives the iPhone Continuity Camera
-- appearing/disappearing, which used to shift indices and pick the wrong device.
local function cameras()
  local out = hs.execute(PY .. " " .. SCRIPT .. " list 2>/dev/null")
  local ok, list = pcall(hs.json.decode, out or "")
  if ok and type(list) == "table" then return list end
  return {}
end

local function logf(fmt, ...)
  local f = io.open(LOG, "a")
  if f then f:write(os.date("%H:%M:%S "), string.format(fmt, ...), "\n"); f:close() end
end

-- ── Overlay flash ────────────────────────────────────────────────────────────
-- Visual flash is drawn by an external AppKit helper whose window sets
-- NSWindowSharingNone, so macOS excludes it from screen recording / sharing
-- (Zoom, Teams, ScreenCaptureKit) while it stays visible to the local user.
-- hs.canvas has no sharingType API, so it cannot be hidden from capture.
local OVERLAY = DIR .. "/overlay/overlay"

local function flash()
  -- hidden-from-capture red flash (self-dismisses after 1.2s)
  hs.task.new(OVERLAY, nil, { "1.2" }):start()

  -- alarm: two system beeps
  hs.sound.getByName("Sosumi"):play()
  hs.timer.doAfter(0.35, function()
    local s = hs.sound.getByName("Sosumi"); if s then s:play() end
  end)
end

-- ── Menubar ──────────────────────────────────────────────────────────────────
local function isOn() return M.task ~= nil and M.task:isRunning() end

local function camMenu()
  local items = {
    { title = (M.camId == "" and "✓ " or "   ") .. "Auto (built-in)",
      fn = function() M.setCam("") end },
    { title = "-" },
  }
  for _, c in ipairs(cameras()) do
    local tag = c.builtin and "" or " 📱"
    local off = (not c.connected) and " (offline)" or ""
    items[#items + 1] = {
      title = (M.camId == c.id and "✓ " or "   ") .. c.name .. tag .. off,
      disabled = not c.connected,
      fn = function() M.setCam(c.id) end,
    }
  end
  return items
end

local function updateMenu()
  if not M.menu then return end
  M.menu:setTitle(isOn() and "👃" or "👃💤")
  M.menu:setMenu({
    { title = string.format("Touches today: %d", M.count), disabled = true },
    { title = "-" },
    { title = isOn() and "Stop watching" or "Start watching", fn = function() M.toggle() end },
    { title = "Reset count", fn = function() M.count = 0; updateMenu() end },
    { title = "-" },
    { title = "Sensitivity", disabled = true },
    { title = (M.sens == 35 and "  ✓ " or "    ") .. "Low",    fn = function() M.setSens(35) end },
    { title = (M.sens == 55 and "  ✓ " or "    ") .. "Medium", fn = function() M.setSens(55) end },
    { title = (M.sens == 75 and "  ✓ " or "    ") .. "High",   fn = function() M.setSens(75) end },
    { title = "-" },
    { title = "Camera", menu = camMenu() },
    { title = "-" },
    { title = "Test flash", fn = flash },
    { title = "Open log", fn = function() hs.execute("open " .. LOG) end },
  })
end

-- ── Daemon control ─────────────────────────────────────────────────────────
function M.start()
  if isOn() then return end
  -- Reap stray daemons before spawning. A Hammerspoon config reload destroys
  -- our hs.task but orphans the child python process — it keeps its
  -- AVCaptureSession open and the camera light on. Overlapping start/stop can
  -- leak the same way. pkill enforces exactly one daemon = one camera light.
  -- Anchored on "noseguard.py$" so it never hits the "noseguard.py list" helper.
  hs.execute("/usr/bin/pkill -f 'noseguard\\.py$'")
  M.task = hs.task.new(PY, function(code, _, err)
    logf("daemon exited code=%s err=%s", tostring(code), tostring(err))
    M.task = nil
    updateMenu()
  end, { SCRIPT })
  M.task:setEnvironment({
    HOME = os.getenv("HOME"),
    PATH = "/opt/homebrew/bin:/usr/bin:/bin",
    NG_SENS = tostring(M.sens),
    NG_HOLD = tostring(M.hold),
    NG_CAM_ID = M.camId,
  })
  M.task:start()
  logf("daemon started sens=%d hold=%s", M.sens, tostring(M.hold))
  updateMenu()
end

function M.stop()
  if M.task then M.task:terminate(); M.task = nil end
  if M.canvas then M.canvas:delete(); M.canvas = nil end
  logf("daemon stopped")
  updateMenu()
end

function M.toggle()
  if isOn() then M.stop() else M.start() end
end

function M.setSens(v)
  M.sens = v
  if isOn() then M.stop(); hs.timer.doAfter(0.3, M.start) end  -- restart with new env
  updateMenu()
end

function M.setCam(v)
  M.camId = v
  if isOn() then M.stop(); hs.timer.doAfter(0.3, M.start) end
  updateMenu()
end

-- ── urlevent from the daemon ─────────────────────────────────────────────────
hs.urlevent.bind("noseguard", function(_, params)
  local ev = params.event or "touch"
  if ev == "touch" then
    M.count = M.count + 1
    flash()
    updateMenu()
  elseif ev == "error" then
    hs.notify.new({ title = "Nose Guard", informativeText = "Camera unavailable" }):send()
    M.stop()
  elseif ev == "ready" then
    logf("daemon ready")
  end
end)

-- Kill the daemon on config reload / Hammerspoon quit, otherwise it orphans
-- and keeps the camera light on while the menu shows 💤 (off). pkill-on-start
-- is the backstop; this closes the window between reload and the next start.
hs.shutdownCallback = function()
  hs.execute("/usr/bin/pkill -f 'noseguard\\.py$'")
end

-- ── init ───────────────────────────────────────────────────────────────────
M.menu = hs.menubar.new()
updateMenu()
-- start OFF; user toggles from the 👃 menu (camera permission prompt fires then)

return M
