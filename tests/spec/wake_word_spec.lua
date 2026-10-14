-- The word is matched in a transcript, not in an audio model, so these are the
-- rules that decide whether saying "Codec" opens a call.

local ww = require("lib.wake_word")

describe("wake_word.match", function()
  it("hears the word on its own, whatever the case and punctuation", function()
    assert.is_true(ww.match("Codec."))
    assert.is_true(ww.match("codec"))
    assert.is_true(ww.match("CODEC!"))
  end)

  it("hears it in a sentence", function()
    assert.is_true(ww.match("Codec, start a call."))
    assert.is_true(ww.match("Codec. Start a call."))
  end)

  -- Measured against this Mac's Parakeet on 2026-10-12: two of four rendered
  -- voices came back as "Kodak", and "Hey Codec" came back glued as "Hikodec".
  -- A literal match on "codec" would have missed every one of them.
  it("hears what Parakeet actually returns for the word", function()
    assert.is_true(ww.match("Kodak."))
    assert.is_true(ww.match("Kodak, are you there?"))
    assert.is_true(ww.match("Hikodec."))
  end)

  it("stays quiet on ordinary speech", function()
    assert.is_false(ww.match("Let me look at the code."))
    assert.is_false(ww.match("I'm writing some code again."))
    assert.is_false(ww.match(""))
  end)

  it("stays quiet on anything that is not a transcript", function()
    assert.is_false(ww.match(nil))
    assert.is_false(ww.match(42))
  end)
end)

describe("wake_word.enabled", function()
  it("is on when nobody has chosen", function()
    assert.is_true(ww.enabled(nil))
  end)

  it("is off only when it was switched off", function()
    assert.is_false(ww.enabled(false))
    assert.is_true(ww.enabled(true))
  end)

  -- A setting of the wrong type is a tampered or stale value, and the safe
  -- reading of one is "never chosen", not "off".
  it("reads a nonsense setting as never chosen", function()
    assert.is_true(ww.enabled("yes"))
  end)

  -- The switch used to live in the voice agent's tile. Keeping its key is what
  -- carries a user's "off" across the move.
  it("keeps the setting key the voice agent used", function()
    assert.equals("voice_agent.wakeWord", ww.SETTING)
  end)
end)

describe("wake_word.window", function()
  it("takes the last window of a long capture", function()
    local offset, length = ww.window(20 * ww.BYTES_PER_S)
    assert.equals(ww.WINDOW_S * ww.BYTES_PER_S, length)
    assert.equals((20 - ww.WINDOW_S) * ww.BYTES_PER_S, offset)
  end)

  -- The window is the preroll as well as the match, so it has to be long
  -- enough to still hold the sentence the wake word ended.
  it("is long enough to hold a sentence in front of the word", function()
    assert.is_true(ww.WINDOW_S >= 3)
  end)

  -- Overlap is what stops a word falling between two ticks and being heard as
  -- two halves: every moment has to appear in at least two windows.
  it("overlaps itself by more than a tick", function()
    assert.is_true(ww.WINDOW_S > 2 * ww.TICK_S)
  end)

  it("takes everything there is when the capture is younger than a window", function()
    local offset, length = ww.window(2 * ww.BYTES_PER_S)
    assert.equals(0, offset)
    assert.equals(2 * ww.BYTES_PER_S, length)
  end)

  it("asks for nothing while the capture is still a fragment", function()
    assert.is_nil(ww.window(1000))
    assert.is_nil(ww.window(0))
  end)

  -- A 16-bit sample read from the wrong byte pair is noise, and noise is loud:
  -- an odd offset would defeat the silence gate as well as the transcript.
  it("never cuts a sample in half", function()
    local offset, length = ww.window(2 * ww.BYTES_PER_S + 1)
    assert.equals(0, offset % 2)
    assert.equals(0, length % 2)
  end)
end)

describe("wake_word.preroll", function()
  local W = ww.BYTES_PER_S

  -- The span the session cannot hear for itself: from where the matching
  -- window began to wherever the capture has reached by the time /start
  -- answered. Here, a 4 s window plus a 1 s gap while the mic was opening.
  it("reads from the window's start to the end of the capture", function()
    local size = 30 * W
    local startByte = size - 5 * W
    local offset, length = ww.preroll(size, startByte)
    assert.equals(startByte, offset)
    assert.equals(5 * W, length)
  end)

  it("is longer than the window it started from", function()
    local size = 30 * W
    local startByte = size - ww.WINDOW_S * W
    local _, windowOnly = ww.preroll(size, startByte)
    local _, withGap = ww.preroll(size + 2 * W, startByte)
    assert.is_true(withGap > windowOnly)
  end)

  -- A /start that took many seconds. The sentence being rescued is at the
  -- front of the span, so the cap drops the newest audio, not the oldest.
  it("caps a long span by dropping the newest audio", function()
    local size = 100 * W
    local offset, length = ww.preroll(size, 0)
    assert.equals(0, offset)
    assert.equals(ww.PREROLL_MAX_S * W, length)
  end)

  -- The capture is restarted when it gets big (needsRotate). An offset taken
  -- before that points past the end of the new file.
  it("asks for nothing when a rotation moved the file out from under it", function()
    assert.is_nil(ww.preroll(2 * W, 10 * W))
  end)

  it("asks for nothing when no new audio has arrived", function()
    assert.is_nil(ww.preroll(10 * W, 10 * W))
  end)

  it("never cuts a sample in half", function()
    local offset, length = ww.preroll(5 * W + 1, 3)
    assert.equals(0, offset % 2)
    assert.equals(0, length % 2)
  end)

  it("treats a missing or negative offset as the start of the file", function()
    assert.equals(0, (ww.preroll(4 * W, nil)))
    assert.equals(0, (ww.preroll(4 * W, -100)))
  end)
end)

describe("wake_word.utterance", function()
  -- The whole point: the half of the sentence that was said before the
  -- microphone opened comes through, with the word still on it.
  it("keeps the sentence the wake word ended", function()
    assert.equals("Please read me the weather, Codec.",
                  ww.utterance("Please read me the weather, Codec."))
  end)

  it("keeps the sentence when the word came first", function()
    assert.equals("Codec, what is on my calendar?",
                  ww.utterance("Codec, what is on my calendar?"))
  end)

  -- Calling the agent and stopping is not an utterance. Sending it would have
  -- the agent answer its own name; the call opens listening instead.
  it("says nothing when the wake word is all there was", function()
    assert.is_nil(ww.utterance("Codec"))
    assert.is_nil(ww.utterance("Codec."))
    assert.is_nil(ww.utterance("  kodak,  "))
  end)

  it("says nothing for an empty or absent transcript", function()
    assert.is_nil(ww.utterance(""))
    assert.is_nil(ww.utterance("   "))
    assert.is_nil(ww.utterance(nil))
    assert.is_nil(ww.utterance(42))
  end)

  it("flattens the whitespace a transcript arrives with", function()
    assert.equals("read me the weather Codec",
                  ww.utterance("  read me   the weather\n Codec  "))
  end)

  -- Every spelling the model gives this word counts as the word, the same way
  -- match counts them.
  it("recognises the variants match recognises", function()
    for _, variant in ipairs(ww.VARIANTS) do
      assert.is_nil(ww.utterance(variant))
      assert.equals("weather " .. variant, ww.utterance("weather " .. variant))
    end
  end)
end)

describe("wake_word.rms", function()
  it("is zero for digital silence", function()
    assert.equals(0, ww.rms(string.rep("\0\0", 4096)))
  end)

  it("rises above the floor for a loud signal", function()
    assert.is_true(ww.rms(string.rep(string.pack("<i2", 3000), 4096)) > ww.RMS_FLOOR)
  end)

  it("stays under the floor for room noise", function()
    assert.is_true(ww.rms(string.rep(string.pack("<i2", 40), 4096)) < ww.RMS_FLOOR)
  end)

  it("survives a window with nothing in it", function()
    assert.equals(0, ww.rms(""))
    assert.equals(0, ww.rms(nil))
  end)
end)

describe("wake_word.wavHeader", function()
  -- The STT server is handed a path and opens it with ffmpeg, so this header is
  -- the only thing standing between a raw capture and a file it can read.
  it("is a 44-byte mono 16 kHz PCM header", function()
    local h = ww.wavHeader(96000)
    assert.equals(44, #h)
    assert.equals("RIFF", h:sub(1, 4))
    assert.equals("WAVE", h:sub(9, 12))
    assert.equals("fmt ", h:sub(13, 16))
    assert.equals("data", h:sub(37, 40))
    assert.equals(96036, string.unpack("<I4", h, 5))     -- RIFF size: 36 + data
    assert.equals(1, string.unpack("<I2", h, 21))        -- PCM
    assert.equals(1, string.unpack("<I2", h, 23))        -- mono
    assert.equals(16000, string.unpack("<I4", h, 25))    -- sample rate
    assert.equals(32000, string.unpack("<I4", h, 29))    -- byte rate
    assert.equals(16, string.unpack("<I2", h, 35))       -- bits per sample
    assert.equals(96000, string.unpack("<I4", h, 41))    -- data size
  end)
end)

-- ── The voice agent, seen from here ────────────────────────────────────────
-- The daemon's /status is the only thing this app reads from the agent, and
-- it is read without a JSON decoder, so its edges are pinned down here.

describe("wake_word.daemonState", function()
  it("is idle when the daemon answers with no call open", function()
    assert.equals("idle", ww.daemonState(200, '{"running": false, "agent": "up"}'))
  end)

  it("is live while a call is open", function()
    assert.equals("live", ww.daemonState(200, '{"running": true, "agent": "up"}'))
  end)

  -- A call would start and then fail, so there is nothing worth waking.
  it("is agent_down when the DSH process behind the daemon is down", function()
    assert.equals("agent_down", ww.daemonState(200, '{"running": false, "agent": "down"}'))
  end)

  it("stays live when the DSH process goes down mid-call", function()
    assert.equals("live", ww.daemonState(200, '{"running": true, "agent": "down"}'))
  end)

  it("reads a daemon that predates the agent field as idle", function()
    assert.equals("idle", ww.daemonState(200, '{"running": false}'))
  end)

  it("is down when the daemon does not answer, or answers with something else", function()
    assert.equals("down", ww.daemonState(0, ""))
    assert.equals("down", ww.daemonState(502, '{"running": false}'))
    assert.equals("down", ww.daemonState(200, "<html>502</html>"))
    assert.equals("down", ww.daemonState(200, '{"ok": true}'))
    assert.equals("down", ww.daemonState(200, nil))
  end)
end)

describe("wake_word.callState", function()
  local plugin = { state = "idle" }

  it("is absent without the voice agent plugin, whatever the daemon says", function()
    assert.equals("absent", ww.callState("idle", nil))
    assert.equals("absent", ww.callState("live", nil))
  end)

  it("believes its own poll while the plugin is loaded", function()
    assert.equals("idle", ww.callState("idle", plugin))
    assert.equals("live", ww.callState("live", plugin))
    assert.equals("agent_down", ww.callState("agent_down", plugin))
  end)

  -- ⌃⌥⌘V goes through the plugin, which knows at once; the poll is a tick
  -- behind, and that tick would otherwise be transcribed mid-call.
  it("takes a live call from the plugin before its own poll has seen it", function()
    assert.equals("live", ww.callState("idle", { state = "live" }))
  end)

  it("is down before the first poll has answered", function()
    assert.equals("down", ww.callState(nil, plugin))
  end)
end)

describe("wake_word.listening", function()
  it("listens when the daemon is idle and nobody else wants the microphone", function()
    assert.is_true(ww.listening(true, "idle", false))
  end)

  it("does not listen while switched off", function()
    assert.is_false(ww.listening(false, "idle", false))
  end)

  -- Otherwise dictating the word "codec" into a text field opens a call.
  it("does not listen while dictation has the microphone", function()
    assert.is_false(ww.listening(true, "idle", true))
  end)

  -- There is nothing to start, and the window would hear the agent's own voice
  -- coming back through the speakers.
  it("does not listen during a call", function()
    assert.is_false(ww.listening(true, "live", false))
  end)

  it("does not listen when there is no daemon to wake", function()
    assert.is_false(ww.listening(true, "down", false))
    assert.is_false(ww.listening(true, "agent_down", false))
  end)

  it("does not listen when the voice agent plugin is not loaded", function()
    assert.is_false(ww.listening(true, "absent", false))
  end)
end)

describe("wake_word.fire", function()
  it("fires the first time", function()
    assert.is_true(ww.fire(1000, nil))
  end)

  -- The windows overlap by half, so one spoken word lands in two transcripts.
  it("does not fire twice on one overlapping window", function()
    assert.is_false(ww.fire(1001.5, 1000))
  end)

  it("fires again once the cooldown has passed", function()
    assert.is_true(ww.fire(1000 + ww.COOLDOWN_S, 1000))
  end)
end)

describe("wake_word.needsRotate", function()
  it("leaves a young capture alone", function()
    assert.is_false(ww.needsRotate(0))
    assert.is_false(ww.needsRotate(ww.ROTATE_BYTES - 1))
  end)

  it("asks for a fresh file once the old one is big", function()
    assert.is_true(ww.needsRotate(ww.ROTATE_BYTES))
  end)
end)

describe("wake_word.captureArgs", function()
  local args = ww.captureArgs("MacBook Pro Microphone", "/tmp/x.raw")
  local joined = table.concat(args, " ")

  it("captures the named device at the rate the STT server wants", function()
    assert.truthy(joined:find("avfoundation", 1, true))
    assert.truthy(joined:find(":MacBook Pro Microphone", 1, true))
    assert.truthy(joined:find("16000", 1, true))
    assert.equals("/tmp/x.raw", args[#args])
  end)

  -- Measured on 2026-10-12: with the segment muxer the file was still 0 bytes
  -- after 7 seconds of capture, because a segment is held until it closes. A
  -- tailed file that is always empty is a wake word that never hears anything.
  it("flushes packets, so the file can be tailed", function()
    assert.truthy(joined:find("-flush_packets 1", 1, true))
    assert.truthy(joined:find("-f s16le", 1, true))
  end)
end)

describe("wake_word.menu", function()
  it("is ticked and says it is listening when it is", function()
    local item = ww.menu(true, "idle", false, true)
    assert.is_true(item.checked)
    assert.equals("listening", item.state)
    assert.truthy(item.title:find("Codec", 1, true))
    assert.truthy(item.title:find(ww.GLYPH.listening, 1, true))
  end)

  it("is unticked and says off when it is switched off", function()
    local item = ww.menu(false, "idle", false, true)
    assert.is_false(item.checked)
    assert.equals("off", item.state)
    assert.truthy(item.title:find("off", 1, true))
  end)

  -- Switched on is not the same as listening, and a tick on its own cannot say
  -- which of the two is true right now.
  it("stays ticked but says why it is not listening", function()
    assert.equals("paused", ww.menu(true, "live", false, true).state)
    assert.truthy(ww.menu(true, "live", false, true).title:find("call in progress", 1, true))

    assert.equals("paused", ww.menu(true, "idle", true, true).state)
    assert.truthy(ww.menu(true, "idle", true, true).title:find("dictation", 1, true))

    assert.equals("paused", ww.menu(true, "down", false, true).state)
    assert.equals("starting", ww.menu(true, "idle", false, false).state)

    assert.is_true(ww.menu(true, "live", false, true).checked)
  end)

  it("says the voice agent is off when there is nothing to wake", function()
    local item = ww.menu(true, "absent", false, false)
    assert.equals("paused", item.state)
    assert.is_true(item.checked)
    assert.truthy(item.title:find("voice agent", 1, true))
  end)
end)

describe("wake_word.settled", function()
  it("has nothing to wait for before the first call ends", function()
    assert.is_true(ww.settled(1000, nil))
  end)

  -- Capture runs through a call, so the window at the moment one closes is the
  -- call itself: the user's last words, and the agent's reply off the speakers.
  -- Reading it let "codec" said during a call reopen it the instant it closed,
  -- which is what the first end-to-end run did.
  it("waits while the window is still full of the call that just ended", function()
    assert.is_false(ww.settled(1000, 1000))
    assert.is_false(ww.settled(1000 + ww.WINDOW_S, 1000))
  end)

  it("listens again once the window is all post-call audio", function()
    assert.is_true(ww.settled(1000 + ww.SETTLE_S, 1000))
  end)

  it("is the gate listening consults", function()
    assert.is_false(ww.listening(true, "idle", false, false))
    assert.is_true(ww.listening(true, "idle", false, true))
    -- A caller that does not track call ends is not punished for it.
    assert.is_true(ww.listening(true, "idle", false, nil))
  end)
end)
