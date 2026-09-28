local t = require("lib.teams_api")

describe("teams_api.buildUrl", function()
  local opts = {
    host = "localhost", port = 8124,
    manufacturer = "Logic20/20", device = "Shokz OpenComm2",
    app = "hammerspoon-shokz", appVersion = "1.0.0",
  }

  it("includes the protocol version and identity", function()
    local u = t.buildUrl(opts)
    assert.truthy(u:find("^ws://localhost:8124/?%?"))
    assert.truthy(u:find("protocol%-version=2%.0%.0"))
    assert.truthy(u:find("app=hammerspoon%-shokz"))
  end)

  it("percent-encodes values so spaces and slashes survive", function()
    local u = t.buildUrl(opts)
    assert.truthy(u:find("Shokz%%20OpenComm2"))
    assert.truthy(u:find("Logic20%%2F20"))
    assert.is_nil(u:find("Shokz OpenComm2", 1, true))
  end)

  it("omits token when absent and appends it when present", function()
    assert.is_nil(t.buildUrl(opts):find("token=", 1, true))
    assert.truthy(t.buildUrl(opts, "abc123"):find("token=abc123", 1, true))
  end)
end)

describe("teams_api.classify", function()
  it("recognises a meeting update and flattens the state", function()
    local m = t.classify({ meetingUpdate = {
      meetingState = { isMuted = true, isInMeeting = true, isVideoOn = false },
      meetingPermissions = { canToggleMute = true },
    } })
    assert.equals("meeting", m.kind)
    assert.is_true(m.state.isMuted)
    assert.is_true(m.state.isInMeeting)
    assert.is_true(m.state.canToggleMute)
  end)

  it("recognises a token refresh", function()
    local m = t.classify({ tokenRefresh = "tok-1" })
    assert.equals("token", m.kind)
    assert.equals("tok-1", m.token)
  end)

  it("recognises success and error acknowledgements", function()
    assert.equals("ack", t.classify({ requestId = 3, response = "Success" }).kind)
    assert.is_true(t.classify({ requestId = 3, response = "Success" }).ok)

    local e = t.classify({ requestId = 4, response = "Error", errorMsg = "No active call" })
    assert.equals("ack", e.kind)
    assert.is_false(e.ok)
    assert.equals("No active call", e.error)
  end)

  it("returns unknown for anything else", function()
    assert.equals("unknown", t.classify({ hello = 1 }).kind)
    assert.equals("unknown", t.classify(nil).kind)
  end)
end)

describe("teams_api reducer", function()
  local function inMeeting(muted, canToggle)
    return { type = "meeting", state = {
      isInMeeting = true, isMuted = muted,
      canToggleMute = (canToggle == nil) and true or canToggle } }
  end

  it("takes no action before Teams has reported anything", function()
    local s, act = t.reduce(t.initialState(), { type = "headset", muted = true })
    assert.is_nil(act)
    assert.is_true(s.desired)
  end)

  -- First contact must not fire. Teams is the source of truth at startup,
  -- otherwise attaching mid-meeting would flip the user's mute at random.
  it("adopts the Teams state on first contact without acting", function()
    local s, act = t.reduce(t.initialState(), inMeeting(true))
    assert.is_nil(act)
    assert.is_true(s.desired)
  end)

  it("toggles when the headset disagrees with Teams", function()
    local s = t.reduce(t.initialState(), inMeeting(false))
    local s2, act = t.reduce(s, { type = "headset", muted = true })
    assert.equals("toggle-mute", act)
    assert.is_true(s2.pending)
  end)

  it("stays quiet when the headset already agrees with Teams", function()
    local s = t.reduce(t.initialState(), inMeeting(false))
    local _, act = t.reduce(s, { type = "headset", muted = false })
    assert.is_nil(act)
  end)

  it("does nothing outside a meeting but remembers the wish", function()
    local s = t.reduce(t.initialState(), { type = "meeting",
      state = { isInMeeting = false, isMuted = false, canToggleMute = false } })
    local s2, act = t.reduce(s, { type = "headset", muted = true })
    assert.is_nil(act)
    assert.is_true(s2.desired)
  end)

  -- Pressing mute before the call starts is the common case, so the wish has
  -- to survive until a meeting exists to apply it to.
  it("applies the remembered wish when the meeting starts", function()
    local s = t.reduce(t.initialState(), { type = "meeting",
      state = { isInMeeting = false, isMuted = false, canToggleMute = false } })
    s = t.reduce(s, { type = "headset", muted = true })
    local _, act = t.reduce(s, inMeeting(false))
    assert.equals("toggle-mute", act)
  end)

  it("holds off while a toggle is unacknowledged", function()
    local s = t.reduce(t.initialState(), inMeeting(false))
    local s2 = t.reduce(s, { type = "headset", muted = true })
    local _, act = t.reduce(s2, inMeeting(false)) -- stale update, ack not in yet
    assert.is_nil(act)
  end)

  it("clears pending on acknowledgement", function()
    local s = t.reduce(t.initialState(), inMeeting(false))
    local s2 = t.reduce(s, { type = "headset", muted = true })
    local s3, act = t.reduce(s2, { type = "ack", ok = true })
    assert.is_nil(act)
    assert.is_false(s3.pending)
  end)

  -- Last change wins. Muting in the Teams window must not be fought by the
  -- bridge, or clicking mute in the UI would bounce straight back.
  it("adopts a mute made in the Teams window", function()
    local s = t.reduce(t.initialState(), inMeeting(false))
    local s2, act = t.reduce(s, inMeeting(true))
    assert.is_nil(act)
    assert.is_true(s2.desired)
  end)

  it("never toggles when Teams says it is not permitted", function()
    local s = t.reduce(t.initialState(), inMeeting(false, false))
    local _, act = t.reduce(s, { type = "headset", muted = true })
    assert.is_nil(act)
  end)

  it("forgets meeting state when the socket closes", function()
    local s = t.reduce(t.initialState(), inMeeting(false))
    local s2, act = t.reduce(s, { type = "closed" })
    assert.is_nil(act)
    assert.is_false(s2.inMeeting)
    assert.is_false(s2.pending)
  end)
end)

describe("teams_api.chooseBackend", function()
  it("does nothing when switched off", function()
    assert.equals("none", t.chooseBackend("off", true))
    assert.equals("none", t.chooseBackend("off", false))
  end)

  it("uses keystrokes when told to, connected or not", function()
    assert.equals("keys", t.chooseBackend("keys", true))
    assert.equals("keys", t.chooseBackend("keys", false))
  end)

  -- "api" is the strict mode: better to do nothing than to fire a blind
  -- toggle at a Teams whose state cannot be read.
  it("stays silent in api mode while disconnected", function()
    assert.equals("api", t.chooseBackend("api", true))
    assert.equals("none", t.chooseBackend("api", false))
  end)

  it("falls back to keystrokes in auto mode", function()
    assert.equals("api", t.chooseBackend("auto", true))
    assert.equals("keys", t.chooseBackend("auto", false))
  end)
end)
