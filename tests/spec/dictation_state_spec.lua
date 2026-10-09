-- The state listener registry: who else learns that the microphone is ours.
--
-- The voice agent shares this Mac's one microphone and the same STT server on
-- :8765, so while a dictation take is in flight it must not hear the take or
-- answer it. It finds out through M.onState, and the contract these specs pin
-- down is what it relies on:
--
--   • exactly one true at the start of a take and one false at the end,
--     whichever way the take ends
--   • false always arrives, including on the paths that produce no transcript
--     (a cancel, a tap under MIN_DURATION), because a listener left held would
--     leave the agent deaf with nothing to release it
--   • a listener that throws costs neither the take nor the other listeners
--
-- Same harness as dictation_duck_spec: stub lib.menuhub, own the clock, drive
-- apps/dictation through toggle(), assert on a ledger.

_G.hs = require("hs")

package.loaded["lib.menuhub"] = {
  item = function(_)
    return {
      setTitle = function() end, setIcon = function() end,
      setMenu = function() end, setTooltip = function() end,
    }
  end,
}

-- No output device, so ducking stays out of the way of what is under test here.
hs.audiodevice = {
  defaultOutputDevice = function() return nil end,
  watcher = { setCallback = function() end, start = function() end },
}

-- A clock the spec owns: a take has to clear MIN_DURATION (0.6s) to reach the
-- transcript path rather than the short-tap one.
local clock = 2000
hs.timer.secondsSinceEpoch = function() return clock end

-- Only /finish answers with a transcript, which is what the real server does.
hs.http.asyncPost = function(url, _, _, cb)
  if not cb then return end
  if tostring(url):match("/finish$") then cb(200, "bonjour", {}) else cb(200, "", {}) end
end

local d = require("apps.dictation.init")

-- Every value each listener was handed, in order.
local ledger = {}

local function listen(name)
  d.onState(name, function(active)
    ledger[#ledger + 1] = name .. ":" .. tostring(active)
  end)
end

-- Registration calls the handler once with the current value, and these specs
-- are about the transitions after that. Subscribe, then start counting.
local function listenQuietly(name)
  listen(name)
  ledger = {}
end

local function fullTake()
  d.toggle()
  clock = clock + 3
  d.toggle()
end

local function shortTake()
  d.toggle()
  d.toggle()
end

before_each(function()
  ledger = {}
  clock = clock + 100
  d.listeners, d.listenerOrder = {}, {}
  d.recording = false
  d.cancelled = false
  -- The streaming engine (parakeet), so a take ends through the /finish reply
  -- above rather than through ffmpeg's exit callback, which the hs.task mock
  -- never fires. Which engine ends the take is beside the point here: what
  -- matters is that every path ends with one false.
  d.stream = true
end)

describe("dictation state listeners", function()
  it("fires true then false across a full take", function()
    listenQuietly("agent")
    fullTake()
    assert.are.same({ "agent:true", "agent:false" }, ledger)
  end)

  it("fires false on a tap shorter than MIN_DURATION", function()
    listenQuietly("agent")
    shortTake()
    -- The short-tap path produces no transcript, so this is the one most
    -- likely to forget the release. A listener left on true here would hold
    -- the voice agent shut until its lease ran out.
    assert.are.same({ "agent:true", "agent:false" }, ledger)
    assert.is_false(d.recording)
  end)

  it("fires false when the take is cancelled by a chord", function()
    listenQuietly("agent")
    d.toggle()
    clock = clock + 3
    d.cancelled = true
    d.toggle()
    assert.are.same({ "agent:true", "agent:false" }, ledger)
    assert.is_false(d.recording)
  end)

  it("calls a late subscriber immediately with the current value", function()
    listen("early")
    assert.are.same({ "early:false" }, ledger)

    ledger = {}
    d.toggle()                      -- a take is now in flight
    assert.are.same({ "early:true" }, ledger)

    ledger = {}
    listen("late")                  -- subscribing mid-take
    assert.are.same({ "late:true" }, ledger)
  end)

  it("never hands a listener the value it is already holding", function()
    listenQuietly("agent")
    -- Churn: short taps, full takes and a cancel, back to back. The voice
    -- agent turns each edge into a POST, so a repeated value is a wasted call
    -- and, on the false side, a resume that races the next hold.
    shortTake()
    fullTake()
    d.toggle(); clock = clock + 3; d.cancelled = true; d.toggle()
    shortTake()

    assert.is_true(#ledger >= 6)
    for i = 2, #ledger do
      assert.are_not.equal(ledger[i], ledger[i - 1])
    end
    assert.are.equal("agent:false", ledger[#ledger])
  end)

  it("keeps a listener that throws from breaking the take or the others", function()
    d.onState("broken", function() error("listener blew up") end)
    listenQuietly("agent")

    fullTake()

    -- The healthy listener still saw both edges...
    assert.are.same({ "agent:true", "agent:false" }, ledger)
    -- ...and the take itself completed: the transcript path ran to the end.
    assert.is_false(d.recording)
    assert.are.equal("bonjour", d.lastResult)
  end)

  it("fans out in registration order", function()
    d.onState("first", function(a) ledger[#ledger + 1] = "first:" .. tostring(a) end)
    d.onState("second", function(a) ledger[#ledger + 1] = "second:" .. tostring(a) end)
    ledger = {}

    d.toggle()

    assert.are.same({ "first:true", "second:true" }, ledger)
  end)

  it("replaces a handler registered under a name already taken", function()
    d.onState("agent", function() ledger[#ledger + 1] = "old" end)
    d.onState("agent", function() ledger[#ledger + 1] = "new" end)
    ledger = {}

    d.toggle()

    -- A Hammerspoon reload re-registers under the same name. Stacking a second
    -- handler there would double every POST the voice agent makes.
    assert.are.same({ "new" }, ledger)
    assert.are.equal(1, #d.listenerOrder)
  end)

  it("still answers isRecording for the pull-style callers", function()
    assert.is_false(d.isRecording())
    d.toggle()
    assert.is_true(d.isRecording())
    clock = clock + 3
    d.toggle()
    assert.is_false(d.isRecording())
  end)
end)
