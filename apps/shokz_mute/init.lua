-- Keep Microsoft Teams' mute in step with the Shokz OpenComm2 mute button.
--
-- The button is readable over plain Bluetooth after all — see lib/hfp_mute for
-- the evidence and for why the CoreAudio route does not work. This module is
-- only wiring: a `log stream` task for the button, a websocket to Teams, and
-- the pure reducer in lib/teams_api deciding whether to act.
--
-- Why it is worth doing: the headset mutes in hardware (-84 dBFS measured), so
-- pressing it silences you whether or not Teams notices. Teams keeps showing
-- you as live, and you keep talking to nobody. This closes that gap in both
-- directions.
--
-- Two backends, picked by lib/teams_api.chooseBackend:
--
--   api   ws://localhost:8124. The good path: Teams reports its own mute, so
--         the reducer only acts on a genuine disagreement and a mute made in
--         the Teams window is adopted rather than fought. Needs
--         Settings -> Privacy -> Third-party app API turned on.
--   keys  a blind Cmd+Shift+M sent to Teams. No state, no self-correction.
--
-- On this machine the API path is shut off by tenant policy, not by a setting:
-- Teams' own config reports
--   "thirdPartyDevices":{"thirdPartyDevicesManagerEnabled":false}
-- so the option is absent from the UI and port 8124 never opens. An admin has
-- to enable third-party device pairing before "api" can ever work. Until then
-- "auto" lands on keystrokes, and the socket keeps retrying harmlessly so the
-- better path takes over by itself the day the policy changes.
--
-- Reading Teams' mute another way was tried and does not work: the meeting
-- window exposes 61 accessibility nodes and no mute control, even with
-- AXManualAccessibility forced on. Blind toggling really is the only fallback.
--
-- Relationship to apps/shokz: that module reads the VOLUME buttons by watching
-- CoreAudio levels. This one reads the MUTE button from the bluetoothd log.
-- Different buttons, different transports, no shared state.

local hfp   = require("lib.hfp_mute")
local teams = require("lib.teams_api")
local utils = require("lib.utils")

local LOG = "/tmp/hs-shokz-mute.log"

local TEAMS = {
  host = "localhost", port = 8124,
  manufacturer = "Logic20/20",
  device       = "Shokz OpenComm2",
  app          = "hammerspoon-shokz-mute",
  appVersion   = "1.0.0",
}

local TOKEN_KEY   = "shokzMute.teamsToken"
local RETRY_MIN   = 5    -- seconds
local RETRY_MAX   = 60
local ACK_TIMEOUT = 2    -- give Teams this long to acknowledge a toggle

local TEAMS_BUNDLE = "com.microsoft.teams2"

-- mac = nil means "any headset". Set M.mac to pin it to one device.
-- backend: "auto" | "api" | "keys" | "off" (see lib/teams_api.chooseBackend).
local M = { enabled = true, mac = nil, showMenubar = true, backend = "auto" }

local function logf(fmt, ...) utils.logf(LOG, fmt, ...) end

-- ── Runtime state ──────────────────────────────────────────────────────────
local state        = teams.initialState()
local headsetMuted = nil
local sock, logTask, logRestart, bar
local retry, retryTimer, ackTimer = RETRY_MIN, nil, nil
local reqId, buf = 0, ""

local apply, connect, scheduleReconnect, startLogStream, buildMenu -- mutually recursive

-- ── Menubar ────────────────────────────────────────────────────────────────
local function render()
  if not bar then return end
  local mic =
    (headsetMuted == true)  and "🔇" or
    (headsetMuted == false) and "🎙" or "🎧"
  -- A dot means the headset is understood but Teams is not reachable, so the
  -- two are not being kept in step.
  bar:setTitle(sock and mic or (mic .. "·"))
  bar:setTooltip((M.enabled and "" or "Paused\n") .. string.format(
    "Headset: %s\nTeams: %s\nBackend: %s",
    headsetMuted == nil and "unknown" or (headsetMuted and "muted" or "live"),
    sock and (state.inMeeting and (state.isMuted and "in call, muted" or "in call, live")
             or "connected") or "not connected (API off by policy)",
    teams.chooseBackend(M.backend, sock ~= nil)))
end

-- ── Teams ──────────────────────────────────────────────────────────────────
local function sendAction(action)
  if not sock then return false end
  reqId = reqId + 1
  -- Built by hand rather than through hs.json.encode: an empty Lua table
  -- encodes as [] and Teams wants {} for parameters.
  local payload = string.format(
    '{"action":"%s","parameters":{},"requestId":%d}', action, reqId)
  -- isData defaults to TRUE in hs.websocket, which sends a binary frame.
  -- Teams ignores those, so text has to be forced.
  sock:send(payload, false)
  logf("-> %s (requestId=%d)", action, reqId)
  return true
end

apply = function(ev)
  local newState, action = teams.reduce(state, ev)
  state = newState
  if action == "toggle-mute" and sendAction("toggle-mute") then
    if ackTimer then ackTimer:stop() end
    -- Without this, one dropped acknowledgement would wedge the reducer in
    -- `pending` and every later press would be ignored.
    ackTimer = hs.timer.doAfter(ACK_TIMEOUT, function()
      ackTimer = nil
      logf("no acknowledgement in %.1fs, clearing pending", ACK_TIMEOUT)
      apply({ type = "ack", ok = false })
    end)
  end
  render()
end

local function onWebsocket(event, message)
  if event == "open" then
    retry = RETRY_MIN
    logf("connected to Teams")
    sendAction("query-meeting-state")
    render()

  elseif event == "received" then
    local ok, decoded = pcall(hs.json.decode, message)
    if not ok or type(decoded) ~= "table" then
      logf("undecodable message: %s", utils.truncate(tostring(message), 120))
      return
    end
    local m = teams.classify(decoded)
    if m.kind == "token" then
      hs.settings.set(TOKEN_KEY, m.token)
      logf("paired with Teams; token stored")
    elseif m.kind == "meeting" then
      apply({ type = "meeting", state = m.state })
    elseif m.kind == "ack" then
      if ackTimer then ackTimer:stop(); ackTimer = nil end
      if not m.ok then logf("Teams refused the action: %s", tostring(m.error)) end
      apply({ type = "ack", ok = m.ok })
    end

  elseif event == "closed" or event == "fail" then
    logf("websocket %s: %s", event, utils.truncate(tostring(message or ""), 120))
    sock = nil
    apply({ type = "closed" })
    scheduleReconnect()
  end
end

connect = function()
  if not M.enabled then return end
  local token = hs.settings.get(TOKEN_KEY)
  local url = teams.buildUrl(TEAMS, token)
  logf("connecting to Teams%s", token and " (with stored token)" or " (first pairing)")
  sock = hs.websocket.new(url, onWebsocket)
end

scheduleReconnect = function()
  if not M.enabled then return end
  if retryTimer then retryTimer:stop() end
  logf("retrying in %ds (is Teams > Settings > Privacy > Third-party app API on?)", retry)
  retryTimer = hs.timer.doAfter(retry, function()
    retryTimer = nil
    connect()
  end)
  retry = math.min(retry * 2, RETRY_MAX)
end

-- ── Keystroke backend ──────────────────────────────────────────────────────
-- Teams offers a toggle and, without the local API, no way to read the mute
-- back. So this is one keystroke per press and nothing more. The two stay in
-- step while nothing else moves the Teams mute; if they drift, one more press
-- on the headset lines them up again.
--
-- Sent to the Teams application rather than to the focused window, so it does
-- not matter what has focus and no other app can receive it by accident.
-- Outside a call Teams ignores Cmd+Shift+M, so there is no need to gate on
-- whether a meeting is running.
local function sendKeystroke(muted)
  local app = hs.application.get(TEAMS_BUNDLE) or hs.application.get("Microsoft Teams")
  if not app then
    logf("Teams is not running, keystroke skipped (headset %s)",
      muted and "MUTED" or "UNMUTED")
    return false
  end
  hs.eventtap.keyStroke({ "cmd", "shift" }, "m", 0, app)
  logf("-> Cmd+Shift+M to Teams (headset %s)", muted and "MUTED" or "UNMUTED")
  return true
end

-- ── Headset ────────────────────────────────────────────────────────────────
local function handleLine(line)
  local ev = hfp.parseLine(line)
  if not ev or not hfp.matches(ev, M.mac) then return end
  headsetMuted = ev.muted
  logf("headset %s (gain %d, %s)", ev.muted and "MUTED" or "UNMUTED", ev.gain, ev.mac)

  local backend = teams.chooseBackend(M.backend, sock ~= nil)
  if backend == "api" then
    apply({ type = "headset", muted = ev.muted })
  elseif backend == "keys" then
    sendKeystroke(ev.muted)
    render()
  else
    logf("backend=%s, nothing sent", M.backend)
    render()
  end
end

-- `log stream` writes whole lines but the pipe splits on buffer boundaries,
-- not on newlines, so partial lines have to be carried across callbacks.
local function onStream(_, stdOut, _)
  if not M.enabled then return false end
  if stdOut and #stdOut > 0 then
    buf = buf .. stdOut
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then break end
      local line = buf:sub(1, nl - 1)
      buf = buf:sub(nl + 1)
      local ok, err = pcall(handleLine, line)
      if not ok then logf("handleLine failed: %s", tostring(err)) end
    end
    -- A line this long is not one of ours; drop it rather than grow forever.
    if #buf > 8192 then buf = "" end
  end
  return true
end

startLogStream = function()
  if not M.enabled then return end
  if logTask and logTask:isRunning() then return end
  -- The exit callback checks it is still the current task: stop() terminates
  -- and forgets the task at once, but its callback fires later, and a pause and
  -- resume in between would otherwise clear the NEW task and schedule a third.
  -- Two live streams would decode every press twice and toggle Teams twice.
  local task
  task = hs.task.new("/usr/bin/log", function(code)
    if logTask ~= task then return end
    logTask = nil
    if not M.enabled then return end
    logf("log stream exited (%s); restarting in 5s", tostring(code))
    logRestart = hs.timer.doAfter(5, function() logRestart = nil; startLogStream() end)
  end, onStream, hfp.logArgs())
  logTask = task
  logTask:start()
  logf("watching bluetoothd for mic gain events")
end

-- ── Hub controls ───────────────────────────────────────────────────────────
-- The headset mutes in hardware and only reports it, so nothing here can mute
-- the headset. What can be driven is the Teams side and this module itself.

-- One toggle on the Teams side, to line it up again after the two drift (the
-- keystroke backend cannot read Teams' mute back, so drift is possible).
local function flipTeams()
  local backend = teams.chooseBackend(M.backend, sock ~= nil)
  if backend ~= "keys" then return end
  logf("manual flip of Teams mute via keystroke")
  sendKeystroke(headsetMuted)
end

-- Only offered while disconnected: closing a live socket would fire its own
-- reconnect and leave two in flight.
local function reconnect()
  if sock or not M.enabled then return end
  if retryTimer then retryTimer:stop(); retryTimer = nil end
  retry = RETRY_MIN
  connect()
end

local BACKENDS = {
  { id = "auto", label = "Auto (API, else keystrokes)" },
  { id = "api",  label = "Teams API only" },
  { id = "keys", label = "Keystrokes only" },
  { id = "off",  label = "Off" },
}

buildMenu = function()
  local connected = sock ~= nil and sock:status() == "open"
  local live = teams.chooseBackend(M.backend, sock ~= nil)
  local items = {
    { title = "Sync headset → Teams", switch = true, checked = M.enabled,
      fn = function() if M.enabled then M.stop(true) else M.start() end end },
    { title = "-" },
    { title = "Headset: " .. (headsetMuted == nil and "unknown"
        or (headsetMuted and "muted" or "live")), disabled = true },
    { title = "Teams: " .. (connected and (state.inMeeting
        and (state.isMuted and "in call, muted" or "in call, live") or "connected")
        or "not connected"), disabled = true },
    { title = "Sending via: " .. live, disabled = true },
    { title = "-" },
    -- Keystrokes only: they cannot read Teams back, so they can drift. The API
    -- path reconciles by itself, and a manual toggle there would race the
    -- reducer's own (acks carry no request id to tell them apart).
    { title = "Flip Teams mute once", fn = flipTeams,
      disabled = (not M.enabled) or live ~= "keys" },
    { title = connected and "Connected to Teams" or (sock and "Connecting to Teams…")
        or "Reconnect to Teams", fn = reconnect,
      disabled = sock ~= nil or not M.enabled },
    { title = "-" },
    { title = "Backend", disabled = true },
  }
  for _, b in ipairs(BACKENDS) do
    items[#items + 1] = {
      title = b.label, checked = (M.backend == b.id),
      fn = function() M.backend = b.id; logf("backend -> %s", b.id); render() end,
    }
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Open log", fn = function() hs.execute("/usr/bin/open -a Console " .. LOG) end }
  return items
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────
-- Unlike the CoreAudio watcher in apps/shokz, both resources here can really be
-- released, so a reload tears the old instance down instead of running two.
-- keepMenu: pause from the hub switch, leaving the tile in place to resume.
function M.stop(keepMenu)
  M.enabled = false
  if retryTimer then retryTimer:stop(); retryTimer = nil end
  if ackTimer then ackTimer:stop(); ackTimer = nil end
  if sock then pcall(function() sock:close() end); sock = nil end
  if logRestart then logRestart:stop(); logRestart = nil end
  if logTask then pcall(function() logTask:terminate() end); logTask = nil end
  if keepMenu then
    render()
  elseif bar then
    pcall(function() bar:delete() end); bar = nil
  end
  logf("stopped")
end

function M.start()
  M.enabled = true
  state = teams.initialState()
  if M.showMenubar and not bar then
    bar = require("lib.menuhub").item("Shokz mute")
    bar:setMenu(buildMenu)
  end
  render()
  startLogStream()
  connect()
  logf("shokz_mute started")
end

-- Diagnostics: `hs -c 'return hs.inspect(require("apps.shokz_mute").status())'`
function M.status()
  return {
    headsetMuted = headsetMuted,
    teamsConnected = sock ~= nil,
    socketStatus = sock and sock:status() or "none",
    logStreamRunning = logTask ~= nil and logTask:isRunning() or false,
    paired = hs.settings.get(TOKEN_KEY) ~= nil,
    backendMode = M.backend,
    backendLive = teams.chooseBackend(M.backend, sock ~= nil),
    reducer = state,
  }
end

-- Guards a partial reload (re-requiring this file), where _G survives.
local PREV = _G.__shokz_mute
if PREV and PREV.stop then pcall(PREV.stop) end
_G.__shokz_mute = M

-- Guards a full hs.reload(), where it does not. The Lua state is destroyed, so
-- the guard above never fires and the `log stream` child is orphaned. It does
-- eventually die of SIGPIPE writing to its dead pipe, but that can be hours
-- later — one idle process per reload until then. Measured: a reload left a
-- second `log stream` with PPID 1.
--
-- apps/noseguard already owns hs.shutdownCallback, so chain rather than
-- assign, or its teardown is silently dropped.
local priorShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
  pcall(M.stop)
  if priorShutdown then pcall(priorShutdown) end
end

M.start()

return M
