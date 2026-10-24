local K = require("lib.karaoke")

describe("karaoke.parseLrc", function()
  it("reads [mm:ss.xx] lines in time order", function()
    local lines = K.parseLrc("[00:17.54] With the blood\n[00:14.30] History repeats itself\n")
    assert.equals(2, #lines)
    assert.equals(14.3, lines[1].t)
    assert.equals("History repeats itself", lines[1].text)
    assert.equals(17.54, lines[2].t)
  end)

  it("takes [mm:ss] and three-digit fractions", function()
    local lines = K.parseLrc("[01:02] a\n[01:03.250] b")
    assert.equals(62, lines[1].t)
    assert.equals(63.25, lines[2].t)
  end)

  it("gives a line with several stamps one entry per stamp", function()
    local lines = K.parseLrc("[00:10.00][00:40.00] Chorus\n[00:20.00] Verse")
    assert.equals(3, #lines)
    assert.equals("Chorus", lines[1].text)
    assert.equals("Verse", lines[2].text)
    assert.equals("Chorus", lines[3].text)
    assert.equals(40, lines[3].t)
  end)

  it("skips tags and applies [offset:] in milliseconds, positive meaning sooner", function()
    local lines = K.parseLrc("[ar:Queen]\n[offset:+500]\n[00:10.00] Is this the real life")
    assert.equals(1, #lines)
    assert.equals(9.5, lines[1].t)
  end)

  it("keeps an empty stamped line as a gap", function()
    local lines = K.parseLrc("[00:10.00] sing\n[00:12.00]\n[00:20.00] again")
    assert.equals(3, #lines)
    assert.equals("", lines[2].text)
  end)

  it("handles CRLF and nil", function()
    assert.equals(1, #K.parseLrc("[00:01.00] x\r\n"))
    assert.equals("x", K.parseLrc("[00:01.00] x\r\n")[1].text)
    assert.same({}, K.parseLrc(nil))
  end)
end)

describe("karaoke.lineAt", function()
  local lines = K.parseLrc("[00:10.00] a\n[00:20.00] b\n[00:30.00] c")

  it("is 0 before the first line", function()
    assert.equals(0, K.lineAt(lines, 5))
  end)

  it("is the last line that has started", function()
    assert.equals(1, K.lineAt(lines, 10))
    assert.equals(1, K.lineAt(lines, 19.99))
    assert.equals(2, K.lineAt(lines, 20))
    assert.equals(3, K.lineAt(lines, 300))
  end)

  it("is 0 for no lyrics", function()
    assert.equals(0, K.lineAt({}, 10))
  end)
end)

describe("karaoke.progress", function()
  local lines = K.parseLrc("[00:10.00] twelve chars\n[00:13.00] b\n[01:00.00] c")

  it("is 0 when the line starts and 1 once it should be sung", function()
    assert.equals(0, K.progress(lines, 1, 10))
    assert.equals(1, K.progress(lines, 1, 12.9))
  end)

  it("moves through the line in between", function()
    -- Twelve characters at ~0.15 s each, but never less than two seconds.
    assert.near(0.5, K.progress(lines, 1, 11), 1e-9)
  end)

  it("does not stretch a short line across a long gap", function()
    -- "b" starts at 13 and "c" at 60: the sweep ends long before 60.
    assert.equals(1, K.progress(lines, 2, 20))
  end)

  it("is 0 with no line", function()
    assert.equals(0, K.progress(lines, 0, 5))
  end)
end)

describe("karaoke.normalize", function()
  local raw = {
    playbackRate = 1, timestampEpochMicros = 1792687851600037, album = "",
    elapsedTimeMicros = 86337, playing = true, bundleIdentifier = "com.apple.WebKit.GPU",
    parentApplicationBundleIdentifier = "com.apple.Safari",
    title = "Rilès - Una Vez Más (Que será, será) (Prod. Rilès)", artist = "Rilès",
    durationMicros = 256281000,
  }

  it("turns micros into seconds and names the app", function()
    local np = K.normalize(raw)
    assert.equals("com.apple.Safari", np.app)
    assert.is_true(np.browser)
    assert.is_true(np.playing)
    assert.equals(256.281, np.duration)
    assert.near(0.086337, np.elapsed, 1e-9)
    assert.near(1792687851.600037, np.at, 1e-3)
  end)

  it("is nil for an empty payload", function()
    assert.is_nil(K.normalize({}))
    assert.is_nil(K.normalize(nil))
  end)

  it("keys a track by app, artist and title, not position", function()
    local a = K.normalize(raw)
    local moved = {}
    for k, v in pairs(raw) do moved[k] = v end
    moved.elapsedTimeMicros = 99000000
    assert.equals(a.key, K.normalize(moved).key)
  end)

  it("knows Spotify is not a browser", function()
    local np = K.normalize({ bundleIdentifier = "com.spotify.client", title = "x", artist = "y",
                             playing = true })
    assert.is_false(np.browser)
  end)
end)

describe("karaoke.position", function()
  it("runs the clock forward while playing", function()
    local np = { elapsed = 10, at = 1000, rate = 1, playing = true }
    assert.equals(15, K.position(np, 1005))
  end)

  it("stands still while paused", function()
    local np = { elapsed = 10, at = 1000, rate = 0, playing = false }
    assert.equals(10, K.position(np, 1005))
  end)

  it("never runs past the end", function()
    local np = { elapsed = 10, at = 1000, rate = 1, playing = true, duration = 12 }
    assert.equals(12, K.position(np, 1100))
  end)
end)

describe("karaoke.cleanTitle", function()
  it("drops video noise", function()
    assert.equals("Una Vez Más (Que será, será)",
                  K.cleanTitle("Una Vez Más (Que será, será) (Prod. Rilès)"))
    assert.equals("Blinding Lights", K.cleanTitle("Blinding Lights (Official Music Video)"))
    assert.equals("Blinding Lights", K.cleanTitle("Blinding Lights [Official Audio]"))
    assert.equals("Levitating", K.cleanTitle("Levitating (Lyrics) | Dua Lipa"))
    assert.equals("Hello", K.cleanTitle("Hello (Official Video) HD"))
    assert.equals("Song", K.cleanTitle("Song (Visualizer)"))
  end)

  it("leaves a plain title alone", function()
    assert.equals("Bohemian Rhapsody", K.cleanTitle("Bohemian Rhapsody"))
  end)
end)

describe("karaoke.cleanArtist", function()
  it("drops YouTube channel suffixes", function()
    assert.equals("Rilès", K.cleanArtist("Rilès - Topic"))
    assert.equals("Adele", K.cleanArtist("AdeleVEVO"))
    assert.equals("Queen", K.cleanArtist("Queen Official"))
  end)
end)

describe("karaoke.candidates", function()
  it("splits 'Artist - Title' from a browser and tries the clean title first", function()
    local np = K.normalize({
      bundleIdentifier = "com.apple.WebKit.GPU", parentApplicationBundleIdentifier = "com.apple.Safari",
      title = "Rilès - Una Vez Más (Que será, será) (Prod. Rilès)", artist = "Rilès", playing = true,
    })
    local c = K.candidates(np)
    assert.same({ artist = "Rilès", title = "Una Vez Más (Que será, será)" }, c[1])
    -- With every parenthetical gone, for databases that file it under the bare name.
    local bare = false
    for _, x in ipairs(c) do
      if x.title == "Una Vez Más" and x.artist == "Rilès" then bare = true end
    end
    assert.is_true(bare)
  end)

  it("uses the app's own artist and title for a music player", function()
    local np = K.normalize({ bundleIdentifier = "com.spotify.client", title = "Bohemian Rhapsody - Remastered 2011",
                             artist = "Queen", playing = true })
    local c = K.candidates(np)
    assert.same({ artist = "Queen", title = "Bohemian Rhapsody - Remastered 2011" }, c[1])
    -- "- Remastered 2011" is a Spotify suffix, not an artist split.
    assert.same({ artist = "Queen", title = "Bohemian Rhapsody" }, c[2])
  end)

  it("has no duplicates", function()
    local np = K.normalize({ bundleIdentifier = "com.spotify.client", title = "Hello", artist = "Adele",
                             playing = true })
    assert.equals(1, #K.candidates(np))
  end)
end)

describe("karaoke.getUrl / searchUrl", function()
  it("encodes the query for LRCLIB", function()
    local u = K.getUrl({ artist = "Rilès", title = "Una Vez Más" }, 256.281)
    assert.equals("https://lrclib.net/api/get?artist_name=Ril%C3%A8s&track_name=Una%20Vez%20M%C3%A1s&duration=256", u)
  end)

  it("leaves duration out when it is unknown", function()
    local u = K.getUrl({ artist = "A", title = "B" })
    assert.equals("https://lrclib.net/api/get?artist_name=A&track_name=B", u)
  end)

  it("searches with one free-text query", function()
    assert.equals("https://lrclib.net/api/search?q=Queen%20Hello", K.searchUrl("Queen Hello"))
  end)
end)

describe("karaoke.plan", function()
  local np = K.normalize({
    bundleIdentifier = "com.apple.WebKit.GPU", parentApplicationBundleIdentifier = "com.apple.Safari",
    title = "Ren - Vincent's Tale - Starry Night", artist = "Ren", playing = true,
    durationMicros = 479521000,
  })
  local plan = K.plan(np)

  it("asks for the exact match on the best guess first", function()
    assert.equals("get", plan[1].kind)
    assert.equals("https://lrclib.net/api/get?artist_name=Ren&track_name=Vincent%27s%20Tale%20-%20Starry%20Night&duration=480",
                  plan[1].url)
  end)

  it("searches the fields next, then ends on free text", function()
    assert.equals("search", plan[2].kind)
    assert.equals("https://lrclib.net/api/search?track_name=Vincent%27s%20Tale%20-%20Starry%20Night&artist_name=Ren",
                  plan[2].url)
    assert.equals("https://lrclib.net/api/search?q=Ren%20Vincent%27s%20Tale%20-%20Starry%20Night",
                  plan[#plan].url)
  end)

  it("never asks the same thing twice", function()
    local seen = {}
    for _, p in ipairs(plan) do
      assert.is_nil(seen[p.url])
      seen[p.url] = true
    end
  end)
end)

describe("karaoke.pickBest", function()
  local results = {
    { id = 1, duration = 218, syncedLyrics = "[00:01.00] a" },
    { id = 2, duration = 300, syncedLyrics = nil, plainLyrics = "a" },
    { id = 3, duration = 255, syncedLyrics = "[00:01.00] b" },
    { id = 4, duration = 400, syncedLyrics = "[00:01.00] c" },
  }

  it("takes synced lyrics closest in length", function()
    assert.equals(3, K.pickBest(results, 256.3).id)
  end)

  it("refuses one that is too far off in length", function()
    assert.is_nil(K.pickBest({ results[1] }, 256))
  end)

  it("takes the first synced one when length is unknown", function()
    assert.equals(1, K.pickBest(results, nil).id)
  end)

  it("is nil for nothing usable", function()
    assert.is_nil(K.pickBest({ results[2] }, 300))
    assert.is_nil(K.pickBest(nil, 300))
  end)
end)

describe("karaoke.fromRecord", function()
  it("parses synced lyrics", function()
    local l = K.fromRecord({ syncedLyrics = "[00:01.00] a\n[00:02.00] b" })
    assert.equals("synced", l.kind)
    assert.equals(2, #l.lines)
  end)

  it("marks instrumentals", function()
    assert.equals("instrumental", K.fromRecord({ instrumental = true }).kind)
  end)

  it("is none without synced lyrics", function()
    assert.equals("none", K.fromRecord({ plainLyrics = "a" }).kind)
    assert.equals("none", K.fromRecord(nil).kind)
  end)
end)

describe("karaoke.notch", function()
  it("hangs from the top center of the screen", function()
    local f = K.notchFrame({ x = 0, y = 0, w = 3440, h = 1440 }, 600, 70)
    assert.same({ x = 1420, y = 0, w = 600, h = 70 }, f)
  end)

  it("works on a screen that is not at the origin", function()
    local f = K.notchFrame({ x = -1512, y = -982, w = 1512, h = 982 }, 500, 80)
    assert.same({ x = -1006, y = -982, w = 500, h = 80 }, f)
  end)

  it("knows a built-in display with a tall menu bar has a notch", function()
    assert.is_true(K.hasNotch("Built-in Liquid Retina XDR Display",
                              { x = 0, y = 0, w = 1512, h = 982 }, { x = 0, y = 38, w = 1512, h = 944 }))
    assert.is_false(K.hasNotch("NB34C",
                               { x = 0, y = 0, w = 3440, h = 1440 }, { x = 0, y = 30, w = 3440, h = 1410 }))
    assert.is_false(K.hasNotch("Built-in Retina Display",
                               { x = 0, y = 0, w = 1440, h = 900 }, { x = 0, y = 25, w = 1440, h = 875 }))
  end)

  it("sizes to the widest line within limits", function()
    assert.equals(420, K.notchWidth({ 100, 200 }, 3440))
    assert.equals(760, K.notchWidth({ 100, 700 }, 3440))
    assert.equals(1200, K.notchWidth({ 3000 }, 3440))
    assert.equals(756, K.notchWidth({ 3000 }, 1512))
  end)
end)

describe("karaoke.display", function()
  local np = { title = "Hello", artist = "Adele" }
  local lyrics = K.fromRecord({ syncedLyrics = "[00:10.00] Hello, it's me\n[00:14.00]\n[00:20.00] I was wondering" })

  it("shows a note and the first line before the singing starts", function()
    local d = K.display(np, lyrics, 3)
    assert.equals("♪", d.current)
    assert.equals("Hello, it's me", d.next)
    assert.equals(0, d.progress)
  end)

  it("shows the line being sung and the one after it", function()
    local d = K.display(np, lyrics, 11)
    assert.equals("Hello, it's me", d.current)
    assert.equals("", d.next)
    assert.is_true(d.progress > 0 and d.progress < 1)
  end)

  it("shows a note over an empty line, and the line coming up", function()
    local d = K.display(np, lyrics, 15)
    assert.equals("♪", d.current)
    assert.equals("I was wondering", d.next)
  end)

  it("names the song while it looks, and when it found nothing", function()
    assert.equals("Hello · Adele", K.display(np, { kind = "loading" }, 0).current)
    assert.equals("Looking up lyrics…", K.display(np, { kind = "loading" }, 0).next)
    assert.equals("No synced lyrics for this one", K.display(np, { kind = "none" }, 0).next)
    assert.equals("♪ Instrumental", K.display(np, { kind = "instrumental" }, 0).current)
    assert.equals("LRCLIB is busy, trying again soon", K.display(np, { kind = "error" }, 0).next)
  end)
end)

describe("karaoke.status", function()
  it("says what the tile shows", function()
    assert.equals("Nothing playing", K.status(nil, nil))
    local np = { title = "Hello", artist = "Adele", playing = true }
    assert.equals("Looking up lyrics…", K.status(np, { kind = "loading" }))
    assert.equals("No synced lyrics found", K.status(np, { kind = "none" }))
    assert.equals("Instrumental", K.status(np, { kind = "instrumental" }))
    local lines = {}
    for i = 1, 42 do lines[i] = { t = i, text = "x" } end
    assert.equals("Synced · 42 lines", K.status(np, { kind = "synced", lines = lines }))
  end)
end)
