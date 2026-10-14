-- The "Codec" wake word's rules — no hs.* dependency, fully unit-testable. The
-- microphone, the timer and the HTTP calls live in apps/wake_word.
--
-- Say "Codec" with no call open and the voice agent starts one, without
-- reaching for ⌃⌥⌘V or the headset chord.
--
-- There is no wake-word model here, and that is deliberate. openWakeWord ships
-- "hey jarvis" and "alexa"; it does not ship "Codec", and training one is hours
-- of synthetic data and a GPU. What this Mac already has is a warm Parakeet on
-- :8765 that transcribes a one-second clip in about 0.15 s, so the wake word is
-- a transcript match: capture a rolling window, transcribe it, look for the
-- word. Arbitrary wake words cost nothing extra, which is the whole reason the
-- cheaper engine lost.
--
-- Three things keep that from being expensive or rude:
--
--   • /transcribe is the batch route, and batch jobs QUEUE behind a live
--     stream rather than preempting it (parakeet_server.py). Polling /start
--     instead would abort a dictation take mid-sentence on every tick.
--   • a window below RMS_FLOOR is never sent. A quiet room costs one file
--     read per tick and no model time at all.
--   • nothing is transcribed while a call is live (there is nothing to start)
--     or while dictation holds the microphone (otherwise dictating the word
--     "codec" into a text field would open a call).
--
-- The rolling capture pays for itself twice. It is what makes the transcript
-- match possible at all, and it is also a recording of the seconds before the
-- word — so "please read me the weather, Codec" does not lose its first half
-- to a microphone that was not open yet. See the Preroll section below.
--
-- It lives beside dictation rather than inside the voice agent because that is
-- whose resources it uses: dictation's microphone and dictation's Parakeet. The
-- agent is only the thing it wakes, and it reaches it over HTTP.

local M = {}

-- Where the on/off choice lives between Hammerspoon reloads. Unset means on:
-- see enabled. The key still says voice_agent because that is where the switch
-- used to be, and renaming it would forget every choice already made.
M.SETTING = "voice_agent.wakeWord"

-- The word itself, as it is shown. Matching is case-insensitive and goes
-- through VARIANTS.
M.WORD = "Codec"

-- What Parakeet actually returns when this word is spoken, which is not always
-- the word. Measured against pocket-tts renderings of "Codec" on 2026-10-12:
-- two voices gave "codec", two gave "Kodak", and "Hey Codec" came back as
-- "Hikodec" — the wake word glued to what preceded it. So the match is a
-- substring of the de-punctuated transcript rather than a whole token, and the
-- near-homophones are listed beside the word.
--
-- The cost of this list is false starts: "codex" is transcribed as "codec" by
-- this model, so saying "codex" opens a call. That is the trade — a wake word
-- that answers half the time is worse than one that occasionally answers when
-- it was not called, and a false start is one ⌃⌥⌘V away from closed.
M.VARIANTS = { "codec", "kodec", "kodak", "kodek", "codeck", "codack" }

-- The capture. 16 kHz mono signed 16-bit is what the STT server wants, so the
-- bytes on disk are the bytes it reads.
M.RATE = 16000
M.BYTES_PER_S = M.RATE * 2

-- A window long enough to hold the word whole, read twice as often as it is
-- long. The overlap is the point: "Codec" takes about 0.9 s, so a word cannot
-- fall between two windows and be heard as two halves.
--
-- Four seconds rather than the one-and-a-bit the word itself needs, because
-- this window is also the preroll: whatever was said before the wake word has
-- to still be in it when the word arrives. Four seconds holds a sentence like
-- "please read me the weather, Codec" with room in front of it. See preroll.
M.WINDOW_S = 4
M.TICK_S = 1.5

-- Below this there is nothing to transcribe. A silent 16-bit room measures in
-- the tens; speech at a normal distance measures in the hundreds to thousands
-- (a live take on this Mac measured 1587). 180 sits between them.
M.RMS_FLOOR = 180

-- Less audio than this is a window that has only just started filling — after
-- a rotation, or in the first seconds of capture. Transcribing it would spend
-- model time on a fragment.
M.MIN_S = 0.8

-- ffmpeg appends to one file forever at 32 kB/s, so capture is restarted when
-- it gets big rather than left to fill the disk. 15 minutes is 28 MB and four
-- restarts an hour, each costing the few hundred milliseconds it takes to open
-- the microphone again.
M.ROTATE_BYTES = M.BYTES_PER_S * 60 * 15

-- One trigger, then a pause. The window overlaps by design, so the same spoken
-- word appears in two consecutive transcripts; without this the second one
-- would arrive while the call it already started was still opening.
M.COOLDOWN_S = 8

-- How long to stay quiet after a call closes. Capture runs through a call, so
-- the moment one ends the window is a window of that call — the user's own
-- last words, and the agent's reply coming back off the speakers. Listening to
-- that would let "codec" said *during* a call reopen it the instant it closes,
-- which is what happened the first time this was run end to end. Waiting a
-- window and a tick means nothing is read until the audio is all from after the
-- call.
M.SETTLE_S = M.WINDOW_S + M.TICK_S

-- The preroll is read from the same rolling capture, so it cannot run away
-- even if the daemon takes a long time to answer /start. Ten seconds is a
-- window plus six: past that the call is not the one the user was talking
-- into, and transcribing more only spends model time.
M.PREROLL_MAX_S = 10

M.RAW = "/tmp/hs-voice-wake.raw"
M.WAV = "/tmp/hs-voice-wake-window.wav"
-- A second file rather than the window's, because the window keeps being
-- rewritten by ticks that land while the preroll is still being transcribed.
M.PREROLL_WAV = "/tmp/hs-voice-wake-preroll.wav"
M.LOG = "/tmp/hs-voice-wake.log"

-- Unset means on: the feature ships enabled, and only an explicit `false` from
-- the menu turns it off. Any other stored type is treated as never-chosen
-- rather than as a value.
function M.enabled(stored)
  if stored == false then return false end
  return true
end

-- Does this transcript contain the wake word? Case-insensitive, and punctuation
-- is not a separator the caller has to think about: "Codec." and "codec," and
-- "Hikodec" all match.
function M.match(text, variants)
  if type(text) ~= "string" then return false end
  -- Lower-case first, then flatten everything that is not a letter or a digit,
  -- so a variant never has to carry punctuation of its own.
  local norm = text:lower():gsub("[^%w]+", " ")
  for _, variant in ipairs(variants or M.VARIANTS) do
    if norm:find(variant, 1, true) then return true end
  end
  return false
end

-- Which slice of the growing capture file to read: the last WINDOW_S of it, on
-- a sample boundary. Returns offset, length — or nil when there is not yet
-- enough audio to be worth a transcription.
--
-- Stateless on purpose. Reading "everything since last time" would mean holding
-- an offset that a rotation, a restart or a dropped tick makes a lie; asking
-- only "what is the last window" cannot go stale.
function M.window(size, windowS, minS, rate)
  size = tonumber(size) or 0
  local bytesPerS = (rate or M.RATE) * 2
  local window = math.floor((windowS or M.WINDOW_S) * bytesPerS)
  local minimum = math.floor((minS or M.MIN_S) * bytesPerS)
  if size < minimum then return nil end
  local length = math.min(size, window)
  -- Even offset and even length: a 16-bit sample must not be cut in half, or
  -- every sample in the window is read from the wrong byte pair.
  length = length - (length % 2)
  local offset = size - length
  offset = offset - (offset % 2)
  return offset, length
end

-- ── Preroll ────────────────────────────────────────────────────────────────
-- The wake word is the end of a sentence, not the start of one. "Please read
-- me the weather, Codec" is one thought, and a call that opens on the word
-- hears only the silence after it: the sentence is already in the past by the
-- time the microphone is live.
--
-- It is not lost, though. The capture that heard the wake word is still on
-- disk, and it holds the whole window — the sentence and the word. So the
-- preroll is that window, extended to the moment the call's own microphone
-- opens, transcribed once, and handed to the agent as the first thing the
-- user said. One transcription over one contiguous span, so there is no seam
-- in the middle of the sentence.

-- Which slice of the capture is the preroll: from `startByte` (where the
-- window that heard the word began) to wherever the file has reached now.
-- That span covers two gaps at once — what was said before the word, and what
-- was said while the daemon was opening the microphone.
--
-- Capped at `maxS`, and the cap drops the NEWEST audio rather than the oldest.
-- Only a daemon that took seconds to answer /start can reach the cap, and by
-- then the audio near the end is closer to the live call than to the sentence
-- this exists to rescue. The sentence is at the front, so the front is what
-- survives.
--
-- Returns offset, length, or nil when there is nothing new to read.
function M.preroll(size, startByte, maxS, rate)
  size = tonumber(size) or 0
  startByte = tonumber(startByte) or 0
  if startByte < 0 then startByte = 0 end
  -- A rotation restarted the capture under us: the offset points past the end
  -- of a file that is now shorter, and there is no preroll to recover.
  if startByte >= size then return nil end
  local bytesPerS = (rate or M.RATE) * 2
  local cap = math.floor((maxS or M.PREROLL_MAX_S) * bytesPerS)
  local length = math.min(size - startByte, cap)
  -- Even offset and even length, for the same reason window needs them: a
  -- 16-bit sample cut in half is read from the wrong byte pair ever after.
  length = length - (length % 2)
  startByte = startByte - (startByte % 2)
  if length < 2 then return nil end
  return startByte, length
end

-- What the preroll transcript should hand the agent, or nil for "say nothing".
--
-- Nil when there is no sentence to rescue: a transcript that is the wake word
-- and nothing else means the user called the agent and stopped, and feeding
-- "Codec" back as their first utterance would have the agent answer its own
-- name. The call still opens; it just opens listening, which is what the user
-- asked for.
--
-- The word is kept in whatever it does come back with. It is how the sentence
-- was actually said, the agent reads it as being addressed, and a transcript
-- that quietly differs from the audio is the harder thing to debug.
function M.utterance(text, variants)
  if type(text) ~= "string" then return nil end
  local clean = text:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if clean == "" then return nil end
  -- Strip the wake word the same way match finds it — on the flattened text,
  -- so punctuation around it is not what decides this.
  local rest = clean:lower():gsub("[^%w]+", " ")
  -- Longest variant first, because several are prefixes of others: "codec"
  -- taken out of "codeck" leaves a "k" behind, and a stray letter would read
  -- as a sentence worth sending.
  local longest = {}
  for _, variant in ipairs(variants or M.VARIANTS) do longest[#longest + 1] = variant end
  table.sort(longest, function(a, b) return #a > #b end)
  for _, variant in ipairs(longest) do
    rest = rest:gsub(variant, " ")
  end
  if rest:gsub("%s+", "") == "" then return nil end
  return clean
end

-- Loud enough to be speech? Root mean square over the window, sampling every
-- `stride`-th frame because 64000 samples of Lua arithmetic per tick buys no
-- more certainty than 8000 do.
function M.rms(pcm, stride)
  if type(pcm) ~= "string" or #pcm < 2 then return 0 end
  stride = stride or 8
  local frames = math.floor(#pcm / 2)
  local sum, counted = 0, 0
  for i = 1, frames, stride do
    local sample = string.unpack("<i2", pcm, (i - 1) * 2 + 1)
    sum = sum + sample * sample
    counted = counted + 1
  end
  if counted == 0 then return 0 end
  return math.sqrt(sum / counted)
end

-- A 44-byte canonical WAV header for `dataLen` bytes of mono 16-bit PCM. The
-- STT server is handed a path and loads it with ffmpeg, so the raw capture only
-- has to be given a header to become a file it can read.
function M.wavHeader(dataLen, rate, channels)
  rate = rate or M.RATE
  channels = channels or 1
  local bits = 16
  local blockAlign = channels * bits // 8
  local byteRate = rate * blockAlign
  return "RIFF" .. string.pack("<I4", 36 + dataLen) .. "WAVEfmt "
      .. string.pack("<I4I2I2I4I4I2I2", 16, 1, channels, rate, byteRate, blockAlign, bits)
      .. "data" .. string.pack("<I4", dataLen)
end

-- ── The voice agent, seen from here ────────────────────────────────────────
-- Everything this app needs from the agent is one word: is a call open? The
-- daemon answers that on GET /status, and it is the only thing read from it.

-- The daemon's /status (or /start, which answers with the same payload) as one
-- of the states apps/voice_agent's menu uses, so the rules below read the same
-- in both places:
--   idle       : answering, no call, and the DSH process that thinks is up
--   live       : a call is open
--   agent_down : answering, but its DSH process is down, so a call would fail
--   down       : not answering, or answering with something that is not status
--
-- A pattern match rather than a JSON decoder, for the reason lib/voice_toggle
-- gives: one known shape from one known producer, and this module stays pure.
function M.daemonState(code, body)
  if code ~= 200 or type(body) ~= "string" or not body:match("^%s*{") then return "down" end
  local running = body:match('"running"%s*:%s*(%a+)')
  if running == "true" then return "live" end
  if running ~= "false" then return "down" end
  if body:match('"agent"%s*:%s*"down"') then return "agent_down" end
  return "idle"
end

-- What the wake word should believe about the call. `polled` is this app's own
-- last answer from /status, nil before the first one. `plugin` is
-- apps/voice_agent's module table, or nil when that plugin is not loaded.
--
-- No plugin means nothing to wake, whatever the daemon says: the agent's
-- supervisor is switched off, and a call started behind its back would have no
-- menu bar, no hotkey and nobody watching it. That reads as "absent".
--
-- A live state from the plugin wins over an idle poll, because the plugin hears
-- about ⌃⌥⌘V the instant the daemon answers it, and this app's poll is up to a
-- tick behind. Without that, the first tick of a call started from the keyboard
-- would be transcribed as if no call were open.
function M.callState(polled, plugin)
  if type(plugin) ~= "table" then return "absent" end
  if plugin.state == "live" then return "live" end
  return polled or "down"
end

-- Should the next tick transcribe anything? `state` is callState's answer, so
-- this answers "idle, and nobody else wants the microphone".
--
-- Not listening is not the same as not capturing: ffmpeg keeps running across a
-- call and across a dictation take, because restarting it on every Fn press
-- would reopen the microphone dozens of times an hour for no gain. Only the
-- transcription is gated.
function M.listening(enabled, state, dictating, settled)
  if not enabled then return false end
  if dictating then return false end
  -- Default true so a caller that does not track call ends still works.
  if settled == false then return false end
  -- "down" cannot be woken: there is no daemon to POST /start at. "live" has
  -- nothing to start, and transcribing it would hear the agent's own voice
  -- coming back through the speakers. "absent" has nobody to supervise the
  -- call it would start.
  return state == "idle"
end

-- Is this trigger allowed through? The cooldown is what stops the overlapping
-- window from firing twice on one spoken word. `last` is nil before the first.
function M.fire(now, last, cooldown)
  if type(last) ~= "number" then return true end
  return (now - last) >= (cooldown or M.COOLDOWN_S)
end

-- Has the capture refilled with audio from after the last call? `endedAt` is
-- nil when no call has closed since Hammerspoon loaded, and then there is
-- nothing to wait for.
function M.settled(now, endedAt, settle)
  if type(endedAt) ~= "number" then return true end
  return (now - endedAt) >= (settle or M.SETTLE_S)
end

-- Has the capture file grown past the point where it should be started again?
function M.needsRotate(size, cap)
  return (tonumber(size) or 0) >= (cap or M.ROTATE_BYTES)
end

-- The ffmpeg arguments that keep RAW filled with the microphone.
--
-- `-flush_packets 1` is the whole reason this is a plain s16le output and not
-- the segment muxer: the segment muxer holds a segment in memory until it
-- closes it, so a file being tailed stays at zero bytes for the length of a
-- segment. Measured on 2026-10-12 — with the segment muxer the file was still
-- 0 bytes after 7 seconds; with this, it was within a second of real time.
function M.captureArgs(mic, raw, rate)
  return { "-y", "-hide_banner", "-loglevel", "error",
           "-f", "avfoundation", "-i", ":" .. tostring(mic),
           "-ar", tostring(rate or M.RATE), "-ac", "1",
           "-f", "s16le", "-flush_packets", "1", raw or M.RAW }
end

-- The glyphs the switch can carry, so the state is readable before the words
-- are. The listening one is also the tile's face in the hub.
M.GLYPH = { listening = "\u{1F442}", paused = "\u{23F8}", off = "\u{25CB}", starting = "\u{1F550}" }

-- The switch in the tile, as data: what it says, and whether it is ticked. The
-- title carries the state because the tick only says "switched on", and
-- switched on while a call is live is not the same as listening.
function M.menu(enabled, state, dictating, capturing)
  local kind, why
  if not enabled then
    kind, why = "off", "off"
  elseif state == "absent" then
    kind, why = "paused", "paused, the voice agent plugin is off"
  elseif dictating then
    kind, why = "paused", "paused, dictation has the microphone"
  elseif state == "live" then
    kind, why = "paused", "paused, call in progress"
  elseif state ~= "idle" then
    kind, why = "paused", "waiting for the daemon"
  elseif not capturing then
    kind, why = "starting", "starting the microphone"
  else
    kind, why = "listening", "listening"
  end
  return {
    title = string.format("%s  Wake word %q: %s", M.GLYPH[kind], M.WORD, why),
    checked = enabled and true or false,
    state = kind,
  }
end

return M
