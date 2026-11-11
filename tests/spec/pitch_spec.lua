local P = require("lib.pitch")

-- A sung vowel is not a sine: the fundamental carries a stack of harmonics,
-- and the second one is often as loud as the first. This builds that as 16-bit
-- little-endian PCM, the shape ffmpeg writes.
local function voice(hz, seconds, amp, weights)
  amp, weights = amp or 6000, weights or { 1, 0.9, 0.5, 0.3 }
  local total = 0
  for _, w in ipairs(weights) do total = total + w end
  local out = {}
  for i = 0, math.floor(seconds * P.RATE) - 1 do
    local t, s = i / P.RATE, 0
    for k, w in ipairs(weights) do s = s + w * math.sin(2 * math.pi * k * hz * t) end
    out[#out + 1] = string.pack("<i2", math.floor(amp * s / total))
  end
  return table.concat(out)
end

-- Deterministic noise, so a failure reproduces.
local function noise(seconds, amp)
  local seed, out = 12345, {}
  for _ = 1, math.floor(seconds * P.RATE) do
    seed = (seed * 1103515245 + 12345) % 2147483648
    out[#out + 1] = string.pack("<i2", math.floor((seed / 2147483648 - 0.5) * 2 * amp))
  end
  return table.concat(out)
end

local function cents(a, b) return 1200 * math.log(a / b, 2) end

describe("pitch.decode", function()
  it("reads little-endian 16-bit samples", function()
    assert.same({ 1, -1, 32767 }, P.decode(string.pack("<i2i2i2", 1, -1, 32767)))
  end)

  it("ignores a trailing odd byte", function()
    assert.equals(1, #P.decode(string.pack("<i2", 5) .. "x"))
  end)
end)

describe("pitch.detect", function()
  for _, hz in ipairs({ 82.41, 110, 196, 220, 261.63, 440, 659.25, 880 }) do
    it(string.format("finds %.2f Hz within 5 cents", hz), function()
      local found = P.detect(P.decode(voice(hz, 0.1)))
      assert.is_not_nil(found)
      assert.is_true(math.abs(cents(found, hz)) < 5,
        string.format("heard %.2f Hz for %.2f Hz", found, hz))
    end)
  end

  it("does not jump an octave up when the second harmonic is the loudest", function()
    local found = P.detect(P.decode(voice(220, 0.1, 6000, { 0.4, 1, 0.5, 0.2 })))
    assert.is_not_nil(found)
    assert.is_true(math.abs(cents(found, 220)) < 50, string.format("heard %.2f Hz", found))
  end)

  it("hears nothing in silence", function()
    assert.is_nil(P.detect(P.decode(string.rep("\0", P.FRAME * 2))))
  end)

  it("hears nothing in noise", function()
    assert.is_nil(P.detect(P.decode(noise(0.1, 6000))))
  end)

  it("hears nothing in a whisper under the floor", function()
    assert.is_nil(P.detect(P.decode(voice(220, 0.1, 100))))
  end)

  it("needs a whole frame", function()
    assert.is_nil(P.detect(P.decode(voice(220, 0.01))))
  end)
end)

describe("pitch.note", function()
  it("names A4 in tune", function()
    local n = P.note(440)
    assert.equals("A4", n.label)
    assert.equals(69, n.midi)
    assert.near(0, n.cents, 1e-9)
  end)

  it("names middle C", function()
    assert.equals("C4", P.note(261.63).label)
  end)

  it("uses sharps", function()
    assert.equals("F♯3", P.note(185).label)
  end)

  it("says how far off the nearest note you are", function()
    assert.near(20, P.note(440 * 2 ^ (20 / 1200)).cents, 1e-6)
    assert.near(-30, P.note(440 * 2 ^ (-30 / 1200)).cents, 1e-6)
  end)

  it("rounds past the halfway point to the next note", function()
    local n = P.note(440 * 2 ^ (60 / 1200))
    assert.equals("A♯4", n.label)
    assert.near(-40, n.cents, 1e-6)
  end)
end)

describe("pitch.tone", function()
  it("is green near the note, orange a little off, red far off", function()
    assert.equals("success", P.tone(0))
    assert.equals("success", P.tone(-15))
    assert.equals("warning", P.tone(25))
    assert.equals("danger", P.tone(-40))
  end)
end)

describe("pitch.meter", function()
  it("shows nothing until you sing", function()
    local m = P.meter()
    assert.is_nil(m:reading(0))
  end)

  it("takes the middle of the last three frames, so one wild frame does not jump", function()
    local m = P.meter()
    m:push(220, 0.00)
    m:push(440, 0.08)   -- an octave slip for one frame
    m:push(221, 0.16)
    assert.equals("A3", m:reading(0.16).label)
  end)

  it("holds the last note through a short gap, then lets go", function()
    local m = P.meter()
    m:push(220, 0); m:push(220, 0.08); m:push(220, 0.16)
    m:push(nil, 0.24)
    assert.equals("A3", m:reading(0.24).label)
    m:push(nil, 0.70)
    assert.is_nil(m:reading(0.70))
  end)

  it("starts fresh after a gap, so the old note does not leak into the new one", function()
    local m = P.meter()
    m:push(220, 0); m:push(220, 0.08); m:push(220, 0.16)
    m:push(330, 2.00)
    assert.equals("E4", m:reading(2.00).label)
  end)
end)

describe("pitch.offset", function()
  it("puts the dot in the middle when in tune and at the ends at a quarter tone", function()
    assert.equals(0, P.offset(0, 100))
    assert.equals(100, P.offset(50, 100))
    assert.equals(-100, P.offset(-50, 100))
    assert.equals(40, P.offset(20, 100))
  end)
end)

describe("pitch.captureArgs", function()
  it("streams the mic as raw 16 kHz mono into the file the meter tails", function()
    local a = P.captureArgs("MacBook Pro Microphone", "/tmp/x.raw")
    local s = table.concat(a, " ")
    assert.truthy(s:find("-f avfoundation -i :MacBook Pro Microphone", 1, true))
    assert.truthy(s:find("-ar 16000 -ac 1", 1, true))
    assert.truthy(s:find("-f s16le -flush_packets 1 /tmp/x.raw", 1, true))
  end)
end)
