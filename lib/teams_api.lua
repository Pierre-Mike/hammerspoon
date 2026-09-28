-- Microsoft Teams local API: URL building, message shapes, and the pure
-- reconcile logic that keeps Teams' mute in step with a hardware mute button.
-- No hs.* dependency; the socket lives in apps/shokz_mute.
--
-- New Teams listens on ws://localhost:8124 once the user enables
-- Settings -> Privacy -> Third-party app API. The first connection raises a
-- pairing prompt inside Teams, and the reply carries a token to reuse from
-- then on. Until the setting is on, the port is simply closed.
--
-- The API offers toggle-mute, not set-mute. A blind toggle drifts out of step
-- the first time anything else moves the mute, so every decision below is made
-- against the isMuted that Teams itself reports. Two rules follow from that:
--
--   * never act on first contact — Teams is authoritative at startup, and
--     firing on connect would flip the mute of whoever is already in a call
--   * last change wins — a mute made in the Teams window is adopted, not
--     fought, otherwise clicking mute in the UI bounces straight back

local utils = require("lib.utils")

local M = {}

local PROTOCOL = "2.0.0"

function M.buildUrl(opts, token)
  opts = opts or {}
  local q = {
    "protocol-version=" .. PROTOCOL,
    "manufacturer=" .. utils.urlencode(opts.manufacturer or "unknown"),
    "device=" .. utils.urlencode(opts.device or "unknown"),
    "app=" .. utils.urlencode(opts.app or "hammerspoon"),
    "app-version=" .. utils.urlencode(opts.appVersion or "1.0.0"),
  }
  if token and token ~= "" then
    q[#q + 1] = "token=" .. utils.urlencode(token)
  end
  return string.format("ws://%s:%d/?%s",
    opts.host or "localhost", opts.port or 8124, table.concat(q, "&"))
end

-- Normalise one decoded message into { kind, ... }. Callers decode the JSON;
-- keeping that out of here is what lets this file stay pure.
function M.classify(msg)
  if type(msg) ~= "table" then return { kind = "unknown" } end

  if msg.meetingUpdate then
    local st = msg.meetingUpdate.meetingState or {}
    local pm = msg.meetingUpdate.meetingPermissions or {}
    return { kind = "meeting", state = {
      isInMeeting   = st.isInMeeting,
      isMuted       = st.isMuted,
      isVideoOn     = st.isVideoOn,
      isHandRaised  = st.isHandRaised,
      isRecordingOn = st.isRecordingOn,
      isSharing     = st.isSharing,
      canToggleMute = pm.canToggleMute,
    } }
  end

  if msg.tokenRefresh then
    return { kind = "token", token = msg.tokenRefresh }
  end

  if msg.response then
    return {
      kind = "ack",
      ok = (msg.response == "Success"),
      requestId = msg.requestId,
      error = msg.errorMsg,
    }
  end

  return { kind = "unknown" }
end

-- ── Reconcile ──────────────────────────────────────────────────────────────
-- state:
--   desired    what the headset last asked for (nil until it says something)
--   inMeeting  Teams has an active call
--   isMuted    Teams' own mute, as last reported
--   canToggle  Teams says toggle-mute is permitted
--   pending    a toggle was sent and has not been acknowledged

function M.initialState()
  return {
    desired = nil, inMeeting = false, isMuted = nil,
    canToggle = nil, pending = false,
  }
end

local function copy(s)
  return {
    desired = s.desired, inMeeting = s.inMeeting, isMuted = s.isMuted,
    canToggle = s.canToggle, pending = s.pending,
  }
end

-- Act only when Teams can act and the two genuinely disagree.
local function reconcile(s)
  if s.desired == nil then return s, nil end
  if not s.inMeeting then return s, nil end
  if s.canToggle == false then return s, nil end
  if s.isMuted == s.desired then return s, nil end
  s.pending = true
  return s, "toggle-mute"
end

-- reduce(state, event) -> newState, action
--   event  { type = "headset", muted = bool }
--          { type = "meeting", state = {...} }
--          { type = "ack", ok = bool }
--          { type = "closed" }
--   action "toggle-mute" or nil
function M.reduce(state, ev)
  local s = copy(state)
  local kind = ev and ev.type

  if kind == "headset" then
    s.desired = ev.muted and true or false
    return reconcile(s)

  elseif kind == "meeting" then
    local st = ev.state or {}
    local wasInMeeting, prevMuted = s.inMeeting, s.isMuted
    s.inMeeting = st.isInMeeting and true or false
    s.isMuted   = st.isMuted
    s.canToggle = st.canToggleMute

    -- A toggle is in flight. Updates that arrive before the acknowledgement
    -- may still describe the old mute, so acting on them would double-toggle.
    if s.pending then return s, nil end

    if s.desired == nil then
      s.desired = s.isMuted
      return s, nil
    end

    if (not wasInMeeting) and s.inMeeting then
      return reconcile(s)
    end

    if prevMuted ~= nil and prevMuted ~= s.isMuted then
      s.desired = s.isMuted
      return s, nil
    end

    return s, nil

  elseif kind == "ack" then
    s.pending = false
    return s, nil

  elseif kind == "closed" then
    s.inMeeting, s.isMuted, s.canToggle, s.pending = false, nil, nil, false
    return s, nil
  end

  return s, nil
end

-- ── Backend choice ─────────────────────────────────────────────────────────
-- The local API is the good path, but a tenant can switch it off: Logic20/20's
-- Teams reports "thirdPartyDevices":{"thirdPartyDevicesManagerEnabled":false},
-- so port 8124 never opens and no amount of retrying helps. The fallback is a
-- blind Cmd+Shift+M, which cannot read Teams back and so cannot self-correct.
--
--   mode "auto"  API when the socket is up, keystrokes otherwise
--   mode "api"   API only; do nothing while disconnected
--   mode "keys"  keystrokes only
--   mode "off"   do nothing
function M.chooseBackend(mode, apiConnected)
  if mode == "off" then return "none" end
  if mode == "keys" then return "keys" end
  if mode == "api" then return apiConnected and "api" or "none" end
  return apiConnected and "api" or "keys"
end

return M
