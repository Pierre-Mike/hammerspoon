-- Pure helpers behind the karaoke pitch meter — no hs.* dependency.
--
-- The microphone arrives as raw 16 kHz mono PCM, the same capture lib/wake_word
-- uses. Each frame of the island reads the last 48 ms of it, finds the note
-- being sung with YIN (de Cheveigné and Kawahara, 2002), and says how far it
-- is from the nearest note of the piano, in cents. A hundred cents is one
-- semitone, so ±50 is as far off as a note can be before it is the next one.
--
-- No melody is known, so the meter cannot say which note you meant to sing.
-- It says which note you are on and whether you are in the middle of it.

local ww = require("lib.wake_word")

local M = {}

M.RATE      = 16000
M.MIN_HZ    = 70     -- a low C♯2, under most basses
M.MAX_HZ    = 1100   -- a C♯6, over most sopranos
M.WINDOW    = 512    -- samples compared per lag: 32 ms
M.FRAME     = 768    -- samples read per frame: the window plus the longest lag
M.THRESHOLD = 0.15   -- YIN's dip: lower is stricter about what counts as a note
-- Root mean square in 16-bit units, about -40 dBFS. Breath, the room and a
-- song leaking out of headphones sit under it; a sung note sits well over.
M.FLOOR     = 300

M.HOLD = 0.35   -- seconds a note stays on the meter after the voice stops
M.GAP  = 0.30   -- seconds of silence after which the next note starts fresh
M.KEEP = 3      -- frames the median is taken over

-- Within this many cents reads as in tune, within the next as close.
M.IN_TUNE = 15
M.CLOSE   = 30

local NAMES = { "C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B" }

function M.decode(pcm)
  local out = {}
  if type(pcm) ~= "string" then return out end
  for i = 1, #pcm - 1, 2 do
    out[#out + 1] = string.unpack("<i2", pcm, i)
  end
  return out
end

-- The fundamental of the last FRAME samples in Hz, or nil when there is no
-- note: too quiet, too noisy, or too short.
--
-- YIN takes the first lag whose normalised difference dips under the
-- threshold, rather than the deepest dip. A sung vowel repeats at twice its
-- period as well as at its period, and the first dip is the one that is the
-- note. Parabolic interpolation then puts the lag between two samples, which
-- matters most at the top: at 880 Hz one sample is a third of a semitone.
function M.detect(x, rate)
  rate = rate or M.RATE
  local n = #(x or {})
  if n < M.FRAME then return nil end
  local start, w = n - M.FRAME, M.WINDOW
  local minLag = math.floor(rate / M.MAX_HZ)
  local maxLag = math.ceil(rate / M.MIN_HZ)

  local energy = 0
  for j = start + 1, start + w do local v = x[j]; energy = energy + v * v end
  if math.sqrt(energy / w) < M.FLOOR then return nil end

  local cmnd, running = { [0] = 1 }, 0
  for tau = 1, maxLag + 1 do
    local d = 0
    for j = start + 1, start + w do
      local diff = x[j] - x[j + tau]
      d = d + diff * diff
    end
    running = running + d
    cmnd[tau] = running > 0 and d * tau / running or 1
  end

  local tau
  for t = minLag, maxLag do
    if cmnd[t] < M.THRESHOLD then
      tau = t
      while tau < maxLag and cmnd[tau + 1] < cmnd[tau] do tau = tau + 1 end
      break
    end
  end
  if not tau then return nil end

  local a, b, c = cmnd[tau - 1], cmnd[tau], cmnd[tau + 1]
  local bend = a - 2 * b + c
  local shift = bend ~= 0 and 0.5 * (a - c) / bend or 0
  return rate / (tau + shift)
end

-- The nearest note to `hz` and how far off it, A4 = 440 Hz.
function M.note(hz)
  local midi = 69 + 12 * math.log(hz / 440, 2)
  local nearest = math.floor(midi + 0.5)
  local octave = nearest // 12 - 1
  local name = NAMES[nearest % 12 + 1]
  return { hz = hz, midi = nearest, name = name, octave = octave,
           label = name .. octave, cents = (midi - nearest) * 100 }
end

-- A tone name from lib/theme for the dot.
function M.tone(cents)
  local off = math.abs(cents)
  if off <= M.IN_TUNE then return "success" end
  if off <= M.CLOSE then return "warning" end
  return "danger"
end

-- Where the dot sits from the middle of a bar `half` points either side.
function M.offset(cents, half)
  return math.max(-1, math.min(1, cents / 50)) * half
end

-- ── The meter ──────────────────────────────────────────────────────────────
-- Frames go in at the island's 12 a second, notes come out. A median over the
-- last three voiced frames keeps one frame that caught a consonant or an
-- octave slip from throwing the dot across the bar, and a short hold keeps the
-- note up between two words instead of blinking.
local Meter = {}
Meter.__index = Meter

function M.meter()
  return setmetatable({ recent = {}, voicedAt = nil }, Meter)
end

function Meter:push(hz, t)
  if not hz then return end
  if self.voicedAt and t - self.voicedAt > M.GAP then self.recent = {} end
  local r = self.recent
  r[#r + 1] = hz
  if #r > M.KEEP then table.remove(r, 1) end
  self.voicedAt = t
end

function Meter:reading(t)
  if not self.voicedAt or t - self.voicedAt > M.HOLD then return nil end
  local sorted = { table.unpack(self.recent) }
  table.sort(sorted)
  return M.note(sorted[math.ceil(#sorted / 2)])
end

-- ── The capture ────────────────────────────────────────────────────────────
-- The same long-lived ffmpeg as the wake word's, writing to its own file.
M.RAW    = "/tmp/hs-karaoke-mic.raw"
M.ROTATE = M.RATE * 2 * 60 * 10   -- ten minutes, then a fresh file

function M.captureArgs(mic, raw)
  return ww.captureArgs(mic, raw or M.RAW, M.RATE)
end

-- Where the last frame starts in a capture `size` bytes long, or nil while
-- there is not a frame yet. Kept on a sample boundary.
function M.tail(size)
  size = (tonumber(size) or 0) - (tonumber(size) or 0) % 2
  if size < M.FRAME * 2 then return nil end
  return size - M.FRAME * 2, M.FRAME * 2
end

return M
