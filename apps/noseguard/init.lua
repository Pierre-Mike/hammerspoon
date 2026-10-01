-- Nose Guard — disruptive nose-touch deterrent.
-- A headless Python daemon (noseguard.py) watches the webcam and fires
--   open "hammerspoon://noseguard?event=touch|ready|error"
-- on each detected nose touch. We answer with a fullscreen red flash +
-- alarm + a running counter. Works over any app — no focused browser tab.
--
-- The NoseGuard tile's Watching switch turns the daemon on/off; detection runs
-- only while it is ON. The camera choice persists across reloads.
--
-- Everything this plugin registers belongs to its context, including the two
-- things that are global and cannot simply be dropped: the hammerspoon://
-- handler the daemon calls back on, and the quit hook that reaps the daemon.
-- M.dispose() gives both back and puts the camera light out.

local ctx = require("lib.context").new("NoseGuard")

local M = {
  task = nil,        -- hs.task running the python daemon
  release = nil,     -- ctx handle on it: terminates the daemon and forgets it
  menu = nil,        -- hs.menubar
  canvas = nil,      -- fullscreen overlay
  flashTimer = nil,
  count = 0,
  sens = 55,         -- 0..100 → nose-zone radius, passed to daemon as NG_SENS
  hold = 0.5,        -- seconds of sustained contact before alert
  camId = "",        -- AVFoundation uniqueID, passed as NG_CAM_ID ("" = auto/builtin)
  camName = "",      -- its label, so a remembered camera names itself while away
  debug = false,     -- NG_DEBUG: daemon logs distance/ratio/speed once a second
}

-- Zone radius in mm at each sensitivity, for the menu. The daemon scales the
-- radius to your interpupillary distance (~63 mm), so these hold whether you're
-- leaning into the camera or sitting back — see nose_geom.touch_radius.
local ZONE_MM = { [35] = 13, [55] = 17, [75] = 20 }

local DIR = os.getenv("HOME") .. "/.hammerspoon/apps/noseguard"
local PY = DIR .. "/.venv/bin/python"
local SCRIPT = DIR .. "/noseguard.py"
local LOG = "/tmp/hs-noseguard.log"

-- Single source of truth: the daemon enumerates AVFoundation, we render its list.
-- Selecting by uniqueID (not index) survives the iPhone Continuity Camera
-- appearing/disappearing, which used to shift indices and pick the wrong device.
-- `list` starts the daemon's python and imports AVFoundation, a few hundred ms
-- each time, and the menu is rebuilt on every open and every redraw behind it.
-- A few seconds of cache keeps a redraw during a flash cheap; a camera plugged
-- in meanwhile shows up on the next open.
local CAM_TTL = 5
local camList, camListAt = {}, 0

local function cameras()
  if os.time() - camListAt < CAM_TTL then return camList end
  local out = hs.execute(PY .. " " .. SCRIPT .. " list 2>/dev/null")
  local ok, list = pcall(hs.json.decode, out or "")
  camList = (ok and type(list) == "table") and list or {}
  camListAt = os.time()
  return camList
end

-- Exactly one daemon means exactly one camera light. A config reload destroys
-- our hs.task but orphans the child python, which keeps its AVCaptureSession
-- open; overlapping start/stop leaks the same way. Anchored on "noseguard.py$"
-- so it never hits the "noseguard.py list" helper.
local function reap()
  hs.execute("/usr/bin/pkill -f 'noseguard\\.py$'")
end

local function logf(fmt, ...)
  local f = io.open(LOG, "a")
  if f then f:write(os.date("%H:%M:%S "), string.format(fmt, ...), "\n"); f:close() end
end

-- Verbatim (no string.format — daemon output contains % and would blow up).
local function logRaw(s)
  local f = io.open(LOG, "a")
  if f then f:write(s); f:close() end
end

-- ── Overlay flash ────────────────────────────────────────────────────────────
-- Visual flash is drawn by an external AppKit helper whose window sets
-- NSWindowSharingNone, so macOS excludes it from screen recording / sharing
-- (Zoom, Teams, ScreenCaptureKit) while it stays visible to the local user.
-- hs.canvas has no sharingType API, so it cannot be hidden from capture.
local OVERLAY = DIR .. "/overlay/overlay"

local function flash()
  -- hidden-from-capture red flash (self-dismisses after 1.2s)
  local overlay, done
  overlay, done = ctx:task(OVERLAY, function() done() end, { "1.2" })
  overlay:start()

  -- alarm: two system beeps
  hs.sound.getByName("Sosumi"):play()
  ctx:after(0.35, function()
    local s = hs.sound.getByName("Sosumi"); if s then s:play() end
  end)
end

-- ── Menubar ──────────────────────────────────────────────────────────────────
local function isOn() return M.task ~= nil and M.task:isRunning() end

-- The camera choice is remembered across reloads: the uniqueID the daemon wants,
-- plus the name it had. An id that is no longer connected costs nothing — the
-- daemon falls back to the built-in (pick_device) and picks the camera back up
-- once it returns, so an iPhone that wanders off does not clear the choice.
local CAM_ID_KEY, CAM_NAME_KEY = "noseguard.camId", "noseguard.camName"

local function camMenu()
  local items = {
    { title = "Auto (built-in)", checked = M.camId == "",
      fn = function() M.setCam("") end },
    { title = "-" },
  }
  local listed = false
  for _, c in ipairs(cameras()) do
    local tag = c.builtin and "" or " 📱"
    local off = (not c.connected) and " (offline)" or ""
    if c.id == M.camId then listed = true end
    items[#items + 1] = {
      title = c.name .. tag .. off,
      checked = (M.camId == c.id),
      disabled = not c.connected,
      fn = function() M.setCam(c.id, c.name) end,
    }
  end
  -- Remembered camera that AVFoundation no longer enumerates at all (unplugged,
  -- Continuity asleep): show it anyway, so the choice reads as itself instead of
  -- looking like nothing is selected.
  if M.camId ~= "" and not listed then
    items[#items + 1] = {
      title = (M.camName ~= "" and M.camName or "Remembered camera") .. " (not connected)",
      checked = true, disabled = true, fn = function() end,
    }
  end
  return items
end

local function sensItem(label, v)
  return {
    title = string.format("%s%s (%d mm)", M.sens == v and "  ✓ " or "    ", label,
                          ZONE_MM[v]),
    fn = function() M.setSens(v) end,
  }
end

-- Title and tile status only; the menu itself is a function (see buildMenu).
local function refresh()
  if not M.menu then return end
  M.menu:setTitle(isOn() and "👃" or "👃💤")
  M.menu:setTooltip(string.format("%s · %d touch%s today",
    isOn() and "Watching" or "Off", M.count, M.count == 1 and "" or "es"))
end

-- Built when the menu opens, not stored: listing cameras spawns the daemon's
-- `list` helper, and a stored table would pay for that on every redraw —
-- including once per nose touch, mid-flash.
local function buildMenu()
  return {
    { title = string.format("Touches today: %d", M.count), disabled = true },
    { title = "-" },
    { title = "Watching", switch = true, checked = isOn(),
      fn = function() M.toggle() end },
    { title = "Reset count", fn = function() M.count = 0; refresh() end },
    { title = "-" },
    { title = "Nose zone", disabled = true },
    sensItem("Tight", 35),
    sensItem("Medium", 55),
    sensItem("Loose", 75),
    { title = "-" },
    { title = "Camera", menu = camMenu() },
    { title = "-" },
    { title = (M.debug and "✓ " or "") .. "Log detection detail",
      fn = function() M.setDebug(not M.debug) end },
    { title = "Test flash", fn = flash },
    { title = "Open log", fn = function() hs.execute("open " .. LOG) end },
  }
end

-- ── Daemon control ─────────────────────────────────────────────────────────
function M.start()
  if isOn() then return end
  reap()   -- stray daemons before spawning, so one tile means one camera light
  local task, release
  task, release = ctx:task(PY, function(code, _, err)
    logf("daemon exited code=%s err=%s", tostring(code), tostring(err))
    if M.task ~= task then return end   -- superseded by a stop or a restart
    release()                           -- it is gone; stop holding it
    M.task, M.release = nil, nil
    refresh()
  -- Stream the daemon's own output into the same log, so "Log detection detail"
  -- is actually readable from "Open log" instead of vanishing with the process.
  end, function(_, out, err)
    if out and out ~= "" then logRaw(out) end
    if err and err ~= "" then logRaw(err) end
    return true
  end, { SCRIPT })
  M.task, M.release = task, release
  M.task:setEnvironment({
    HOME = os.getenv("HOME"),
    PATH = "/opt/homebrew/bin:/usr/bin:/bin",
    NG_SENS = tostring(M.sens),
    NG_HOLD = tostring(M.hold),
    NG_CAM_ID = M.camId,
    NG_DEBUG = M.debug and "1" or "0",
  })
  M.task:start()
  logf("daemon started sens=%d hold=%s debug=%s", M.sens, tostring(M.hold),
       tostring(M.debug))
  refresh()
end

function M.stop()
  if M.release then M.release() end    -- terminates the daemon, drops the effect
  M.task, M.release = nil, nil
  if M.canvas then M.canvas:delete(); M.canvas = nil end
  logf("daemon stopped")
  refresh()
end

function M.toggle()
  if isOn() then M.stop() else M.start() end
end

local function restart()
  if isOn() then M.stop(); ctx:after(0.3, M.start) end  -- reload env
end

function M.setSens(v)
  M.sens = v
  restart()
  refresh()
end

function M.setDebug(v)
  M.debug = v
  restart()
  refresh()
end

function M.setCam(id, name)
  M.camId = id or ""
  M.camName = (M.camId ~= "" and name) or ""
  hs.settings.set(CAM_ID_KEY, M.camId)
  hs.settings.set(CAM_NAME_KEY, M.camName)
  restart()
  refresh()
end

-- ── urlevent from the daemon ─────────────────────────────────────────────────
ctx:url("noseguard", function(_, params)
  local ev = params.event or "touch"
  if ev == "touch" then
    M.count = M.count + 1
    flash()
    refresh()
  elseif ev == "error" then
    hs.notify.new({ title = "Nose Guard", informativeText = "Camera unavailable" }):send()
    M.stop()
  elseif ev == "ready" then
    logf("daemon ready")
  end
end)

-- Kill the daemon on config reload / Hammerspoon quit, otherwise it orphans and
-- keeps the camera light on while the menu shows 💤 (off). pkill-on-start is the
-- backstop; this closes the window between reload and the next start.
--
-- Through the context rather than hs.shutdownCallback directly: that is one
-- global slot, and taking it would have silently stopped whichever other plugin
-- had claimed it first.
ctx:atExit(reap)

-- ── init ───────────────────────────────────────────────────────────────────
M.menu = ctx:tile("NoseGuard")
M.camId = hs.settings.get(CAM_ID_KEY) or ""
M.camName = hs.settings.get(CAM_NAME_KEY) or ""
M.menu:setMenu(buildMenu)
refresh()
-- start OFF; the Watching switch turns it on (camera permission prompt fires then)

-- Switching the plugin off has to put the camera light out, so the context is
-- unwound first — tile, daemon, flash timers, URL handler, quit hook — and then
-- the orphan a terminate can still leave behind is reaped.
function M.dispose()
  ctx:dispose()
  reap()
end

return M
