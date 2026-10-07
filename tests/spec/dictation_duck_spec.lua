-- Ducking is a two-call protocol: duckNoise() saves the user's volume and drops
-- it, unduckNoise() puts it back. The pairing is the whole contract, so these
-- specs drive apps/dictation through its public surface (toggle) and assert on
-- the ledger of setVolume calls rather than on any single value.
--
-- The bug this guards: duckNoise() used to overwrite the saved volume every
-- time. One missed restore and the next duck saved 30 — the already-ducked
-- level — as the "original", so every restore after that handed back 30 and the
-- user's real volume was gone for good.

_G.hs = require("hs")

-- Menubar stub, same shape plugins_spec and context_spec use.
package.loaded["lib.menuhub"] = {
  item = function(_)
    return {
      setTitle = function() end, setIcon = function() end,
      setMenu = function() end, setTooltip = function() end,
    }
  end,
}

-- Mirrors DUCK_LEVEL in apps/dictation/init.lua. Kept local on purpose: a spec
-- that imported the constant would still pass if both sides drifted together.
local DUCK_LEVEL = 30
local START_VOLUME = 62

-- The output device under test, plus a ledger of every volume write it sees.
local ledger = {}
local device = {}
function device:volume() return self.vol end
function device:setVolume(v)
  self.vol = v
  ledger[#ledger + 1] = (v == DUCK_LEVEL) and "duck" or "restore"
end

local present = true
hs.audiodevice = {
  defaultOutputDevice = function() return present and device or nil end,
  -- lib.audiowatch installs a system watcher at require time.
  watcher = { setCallback = function() end, start = function() end },
}

-- A clock the spec owns, so a take can be made long enough to clear
-- MIN_DURATION (0.6s) and reach the transcript path instead of the short-tap one.
local clock = 1000
hs.timer.secondsSinceEpoch = function() return clock end

-- Only /finish returns a transcript; everything else answers empty, which is
-- what the real server does for /start and /cancel.
hs.http.asyncPost = function(url, _, _, cb)
  if not cb then return end
  if tostring(url):match("/finish$") then cb(200, "hello world", {}) else cb(200, "", {}) end
end

local d = require("apps.dictation.init")

local function counts()
  local ducks, restores = 0, 0
  for _, e in ipairs(ledger) do
    if e == "duck" then ducks = ducks + 1 else restores = restores + 1 end
  end
  return ducks, restores
end

-- A take the user abandons before MIN_DURATION: start, release immediately.
local function shortTake()
  d.toggle()
  d.toggle()
end

-- A take that produces a transcript: start, let three seconds pass, release.
local function fullTake()
  d.toggle()
  clock = clock + 3
  d.toggle()
end

-- The failure the guard exists for: a take that ducks and then never restores,
-- the way a dropped server callback leaves it.
local function leakedTake()
  d.toggle()
  clock = clock + 3
  d.recording = false   -- the take ends; nothing unducks
end

before_each(function()
  ledger = {}
  present = true
  clock = clock + 100
  device.vol = START_VOLUME
  d.ducked, d.preDuckVolume, d.recording, d.cancelled = false, nil, false, false
end)

describe("dictation ducking", function()
  it("drops the volume on record and puts it back on release", function()
    d.toggle()
    assert.equals(DUCK_LEVEL, device.vol)
    assert.is_true(d.ducked)
    assert.equals(START_VOLUME, d.preDuckVolume)

    clock = clock + 3
    d.toggle()
    assert.equals(START_VOLUME, device.vol)
    assert.is_false(d.ducked)
    assert.is_nil(d.preDuckVolume)
  end)

  it("restores a tap too short to transcribe", function()
    shortTake()
    assert.equals(START_VOLUME, device.vol)
    assert.is_false(d.ducked)
  end)

  it("restores a take cancelled by chord", function()
    d.toggle()
    d.cancelled = true
    clock = clock + 3
    d.toggle()
    assert.equals(START_VOLUME, device.vol)
    assert.is_false(d.ducked)
  end)

  -- The re-entry guard. Without it this second duck saves 30 as the original.
  it("keeps the saved volume when a duck follows a missed restore", function()
    leakedTake()
    assert.equals(DUCK_LEVEL, device.vol)
    assert.equals(START_VOLUME, d.preDuckVolume)

    d.toggle()
    assert.equals(START_VOLUME, d.preDuckVolume, "second duck overwrote the saved volume")

    clock = clock + 3
    d.toggle()
    assert.equals(START_VOLUME, device.vol)
  end)

  -- The reported pattern: three leaked restores in a row. The user's volume has
  -- to survive all of them.
  it("survives three leaked restores in a row", function()
    leakedTake(); leakedTake(); leakedTake()
    assert.equals(START_VOLUME, d.preDuckVolume)

    fullTake()
    assert.equals(START_VOLUME, device.vol)
    assert.is_false(d.ducked)
  end)

  it("never writes more restores than ducks", function()
    fullTake(); shortTake(); leakedTake(); fullTake(); shortTake()
    local ducks, restores = counts()
    assert.equals(ducks, restores, "ducks and restores drifted apart")
    assert.equals(START_VOLUME, device.vol)
  end)

  -- A second release after the transcript already landed must not fire another
  -- restore, or it would write a stale volume over whatever the user just set.
  it("does not restore twice for one duck", function()
    fullTake()
    local _, before = counts()
    device.vol = 10          -- user reaches for the volume keys
    d.toggle(); d.toggle()   -- stray release
    local _, after = counts()
    assert.equals(before + 1, after)
    assert.equals(10, device.vol)
  end)

  it("picks up a volume the user changed between takes", function()
    fullTake()
    device.vol = 15
    d.toggle()
    assert.equals(15, d.preDuckVolume)
    clock = clock + 3
    d.toggle()
    assert.equals(15, device.vol)
  end)

  -- No output device is not an error, but it must not leave the module believing
  -- it ducked — the next real device would be restored to a volume never saved.
  it("stays unducked when there is no output device", function()
    present = false
    d.toggle()
    assert.is_false(d.ducked)
    assert.is_nil(d.preDuckVolume)
    clock = clock + 3
    d.toggle()
    assert.same({}, ledger)
  end)
end)
