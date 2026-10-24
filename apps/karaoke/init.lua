-- Karaoke: the lyrics of whatever is playing, one line at a time, in a black
-- island that hangs from the top of the screen like the notch.
--
-- What is playing comes from `media-control stream` (brew install
-- media-control). It reads macOS's Now Playing center, so Spotify, Music and a
-- YouTube tab in Safari or Chrome all arrive the same way, with the playback
-- position and the moment it was taken. Without media-control the plugin
-- falls back to asking Spotify and Music over AppleScript once a second, which
-- cannot see a browser.
--
-- Lyrics come from LRCLIB (lrclib.net): free, no key, and synced to the line.
-- A YouTube title gets taken apart first (lib/karaoke.candidates), because
-- "Artist - Song (Official Video)" by the channel "ArtistVEVO" is not what a
-- lyrics database files the song under.
--
-- The line being sung sweeps from dim to white as it goes, and the next line
-- waits underneath. On a notched screen the text sits below the notch, with the
-- island growing out of it; elsewhere it hangs over the middle of the menu bar.
--
-- The tile has the switch, the screen, and the timing nudge for a song whose
-- lyrics run early or late. Cmd+Alt+Shift+K shows or hides the island.

local K     = require("lib.karaoke")
local utils = require("lib.utils")
local UI    = require("lib.ui")
local theme = UI.theme

local ctx = require("lib.context").new("Karaoke")

local MEDIA_CONTROL = "/opt/homebrew/bin/media-control"
local LOG           = "/tmp/hs-karaoke.log"
local HOTKEY        = { mods = { "cmd", "alt", "shift" }, key = "k" }
local USER_AGENT    = "hammerspoon-karaoke (https://github.com/Pierre-Mike/hammerspoon)"
local ENABLED_KEY   = "karaoke.enabled"
local SCREEN_KEY    = "karaoke.screen"   -- "main" or "builtin"

local FRAME_SECS  = 1 / 12   -- the sweep redraw, only while the island is up
local POLL_SECS   = 1        -- the AppleScript fallback
local PAUSE_HIDE  = 3        -- seconds paused before the island goes
local NONE_HIDE   = 5        -- seconds "no lyrics" stays up before it goes
local MAX_RESTART = 5        -- stream deaths in a row before falling back
local GET_TRIES   = 4        -- per request, waiting 1, 2, then 4 s between
local LOOKUP_AGAIN = 20      -- seconds before a song LRCLIB failed on is asked again
local LOOKUP_TRIES = 3       -- lookups per song before giving up on it

-- The sweep is this plugin's own drawing, so it is built by hand, but every
-- number in it is lib/theme's: the island is a ui surface, and the three
-- shades of white are the theme's three text colors.
local LINE_SIZE = theme.text.display
local NEXT_SIZE = theme.text.body
local WHITE = theme.color.text
local DIM   = theme.color.textTertiary
local SOFT  = theme.color.textSecondary
local BOLD  = theme.font.bold

local M = {
  np       = nil,     -- what is playing, from lib/karaoke.normalize
  lyrics   = nil,     -- { kind = "loading" | "synced" | "instrumental" | "none", lines }
  cache    = {},      -- np.key -> lyrics, for the session
  offsets  = {},      -- np.key -> seconds the lyrics are moved by
  failures = {},      -- np.key -> lookups LRCLIB did not answer
  source   = nil,     -- "media-control" or "AppleScript"
  canvas   = nil,
  shown    = false,
  drawn    = nil,     -- the text on the canvas now, so a frame only redraws on change
  since    = {},      -- when the current pause / "none" began
  restarts = 0,
  disposed = false,
}

local function logf(fmt, ...) utils.logf(LOG, fmt, ...) end

local function enabled()
  return hs.settings.get(ENABLED_KEY) ~= false
end

local function decode(s)
  if type(s) ~= "string" or s == "" then return nil end
  local ok, v = pcall(hs.json.decode, s)
  return ok and type(v) == "table" and v or nil
end

-- ── The island ─────────────────────────────────────────────────────────────
local function targetScreen()
  if hs.settings.get(SCREEN_KEY) == "builtin" then
    for _, s in ipairs(hs.screen.allScreens()) do
      if tostring(s:name()):find("Built%-in") then return s end
    end
  end
  return hs.screen.primaryScreen()
end

-- Element indices, so a frame touches only what moved.
local E = { bg = 1, base = 2, clip = 3, lit = 4, reset = 5, nextLine = 6 }

-- Built once per track, because its width follows that track's longest line.
local function build()
  local screen = targetScreen()
  local full, frame = screen:fullFrame(), screen:frame()
  local notch = K.hasNotch(screen:name(), full, frame)
  -- Under the notch nothing shows, so the text starts below the menu bar there.
  local top = notch and (frame.y - full.y) or 6
  local h = top + 64

  local widths = {}
  local probe = hs.canvas.new({ x = 0, y = 0, w = 10, h = 10 })
  probe[1] = { type = "text", text = "", textFont = BOLD, textSize = LINE_SIZE }
  local lines = (M.lyrics and M.lyrics.lines) or {}
  for i, l in ipairs(lines) do widths[i] = probe:minimumTextSize(1, l.text).w end
  if M.np then widths[#widths + 1] = probe:minimumTextSize(1, M.np.title .. " · " .. M.np.artist).w end
  probe:delete()
  local w = K.notchWidth(widths, full.w)

  -- Solid, because it should read as part of the screen like the notch does;
  -- an island, so its top corners sit above the screen and only the bottom two
  -- show rounded. The backdrop is element 1, which is E.bg.
  local c, release = ctx:ui():surface("island", K.notchFrame(full, w, h), { island = true, solid = true })
  local pad = theme.space.xl
  local lineFrame = { x = pad, y = top + 4, w = w - 2 * pad, h = 30 }
  c[E.base] = { type = "text", text = "", textFont = BOLD, textSize = LINE_SIZE,
                textColor = DIM, textAlignment = "center", textLineBreak = "truncateTail",
                frame = lineFrame }
  c[E.clip] = { type = "rectangle", action = "clip", frame = { x = 0, y = 0, w = 0, h = h } }
  c[E.lit] = { type = "text", text = "", textFont = BOLD, textSize = LINE_SIZE,
               textColor = WHITE, textAlignment = "center", textLineBreak = "truncateTail",
               frame = lineFrame }
  c[E.reset] = { type = "resetClip" }
  c[E.nextLine] = { type = "text", text = "", textSize = NEXT_SIZE, textColor = SOFT,
                    textAlignment = "center", textLineBreak = "truncateTail",
                    frame = { x = pad, y = top + 36, w = w - 2 * pad, h = 22 } }
  M.canvas, M.release, M.lineFrame, M.shown = c, release, lineFrame, false
  M.drawn, M.drawnNext, M.swept = nil, nil, nil
end

local function hide()
  if M.canvas and M.shown then M.canvas:hide(0.25) end
  M.shown = false
end

local function show()
  if not M.canvas then build() end
  if not M.shown then M.canvas:show(0.25) end
  M.shown = true
end

-- A new track, screen or lyrics set means a new width, so the island is drawn
-- again rather than resized.
local function rebuild()
  local was = M.shown
  if M.release then M.release() end
  M.canvas, M.release, M.shown = nil, nil, false
  if was then show() end
end

-- Every write to a canvas element redraws the window, so a frame writes only
-- what changed: the sweep when it has moved a whole point, the text when the
-- line turns over.
local function paint(d)
  local c = M.canvas
  if M.drawn ~= d.current then
    c[E.base].text = d.current
    c[E.lit].text = d.current
    local tw = math.min(c:minimumTextSize(E.lit, d.current).w, M.lineFrame.w)
    M.textLeft, M.textWidth = M.lineFrame.x + (M.lineFrame.w - tw) / 2, tw
    M.drawn, M.swept = d.current, nil
  end
  if M.drawnNext ~= d.next then
    c[E.nextLine].text = d.next
    M.drawnNext = d.next
  end
  local w = math.floor(M.textWidth * d.progress)
  if M.swept ~= w then
    c[E.clip].frame = { x = M.textLeft, y = 0, w = w, h = M.lineFrame.y + M.lineFrame.h }
    M.swept = w
  end
end

-- ── Frames ─────────────────────────────────────────────────────────────────
local function now() return hs.timer.secondsSinceEpoch() end

local function wanted(t)
  if not enabled() or not M.np then return false end
  if not M.np.playing and t - (M.since.pause or t) >= PAUSE_HIDE then return false end
  if M.since.none and t - M.since.none >= NONE_HIDE then return false end
  return true
end

local ticker

local function tick()
  local t = now()
  if not wanted(t) then
    hide()
    if ticker then ticker:stop() end
    return
  end
  show()
  local pos = K.position(M.np, t) + (M.offsets[M.np.key] or 0)
  paint(K.display(M.np, M.lyrics, pos))
end

local function wake()
  if M.disposed then return end
  tick()
  if ticker and M.shown and not ticker:running() then ticker:start() end
end

ticker = ctx:timer(FRAME_SECS, tick)
ticker:stop()

-- ── Lyrics ─────────────────────────────────────────────────────────────────
local function current(key) return not M.disposed and M.np and M.np.key == key end

local lookup

-- "error" is not cached: it means LRCLIB did not answer, not that it has
-- nothing, so the same song is asked about again a little later.
local function setLyrics(key, lyrics)
  if lyrics.kind ~= "error" then M.cache[key] = lyrics end
  if not current(key) then return end
  M.lyrics = lyrics
  local gone = lyrics.kind == "none" or lyrics.kind == "error"
  M.since.none = gone and now() or nil
  logf("lyrics for %s: %s", (key:gsub("\n", " / ")), K.status(M.np, lyrics))
  rebuild()
  wake()
  if lyrics.kind == "error" then
    M.failures[key] = (M.failures[key] or 0) + 1
    if M.failures[key] < LOOKUP_TRIES then
      ctx:after(LOOKUP_AGAIN, function() if current(key) then lookup(M.np) end end)
    end
  end
end

-- LRCLIB answers 503 "busy" to a good share of requests at peak, so a request
-- is tried a few times with the wait doubling before it counts as failed.
local function get(url, onDone, attempt)
  attempt = attempt or 1
  hs.http.asyncGet(url, { ["User-Agent"] = USER_AGENT }, function(status, body)
    if M.disposed then return end
    local busy = status == 503 or status == 429 or status <= 0
    if busy and attempt < GET_TRIES then
      ctx:after(2 ^ (attempt - 1), function() get(url, onDone, attempt + 1) end)
      return
    end
    onDone(status, decode(body))
  end)
end

-- Walks lib/karaoke.plan until a step finds synced lyrics. A step that never
-- got an answer marks the whole lookup failed rather than empty.
lookup = function(np)
  local key, duration = np.key, np.duration
  local steps, failed = K.plan(np), false
  local function step(i)
    if not current(key) then return end
    local s = steps[i]
    if not s then return setLyrics(key, { kind = failed and "error" or "none" }) end
    get(s.url, function(status, body)
      if status ~= 200 and status ~= 404 then failed = true end
      local rec = status == 200 and body or nil
      if s.kind == "search" then rec = K.pickBest(rec, duration) end
      local lyrics = K.fromRecord(rec)
      if lyrics.kind ~= "none" then return setLyrics(key, lyrics) end
      step(i + 1)
    end)
  end
  step(1)
end

-- ── What is playing ────────────────────────────────────────────────────────
local function onPlaying(np)
  local was = M.np
  M.np = np
  if not np then
    M.lyrics = nil
    return wake()
  end
  if np.playing then M.since.pause = nil elseif not M.since.pause then M.since.pause = now() end
  if not was or was.key ~= np.key then
    logf("playing %s", (np.key:gsub("\n", " / ")))
    M.lyrics = M.cache[np.key] or { kind = "loading" }
    M.since.none = M.lyrics.kind == "none" and now() or nil
    rebuild()
    if not M.cache[np.key] then lookup(np) end
  end
  wake()
end

-- media-control prints one JSON object per line; a read can end mid-line.
local pending = ""
local function onChunk(out)
  pending = pending .. (out or "")
  while true do
    local line, rest = pending:match("^([^\n]*)\n(.*)$")
    if not line then break end
    pending = rest
    local msg = decode(line)
    if msg and msg.type == "data" then
      M.restarts = 0
      onPlaying(K.normalize(msg.payload))
    end
  end
end

local startFallback

local function startStream()
  M.source = "media-control"
  pending = ""
  local task, done
  task, done = ctx:task(MEDIA_CONTROL, function(code, _, err)
    done()
    if M.disposed or M.stream ~= task then return end
    M.stream = nil
    logf("media-control exited %s %s", tostring(code), utils.trim(err or "") or "")
    M.restarts = M.restarts + 1
    if M.restarts > MAX_RESTART then return startFallback() end
    ctx:after(3, startStream)
  end, function(_, out)
    onChunk(out)
    return true
  end, { "stream", "--no-diff", "--no-artwork", "--micros" })
  M.stream = task
  task:start()
end

-- Spotify and Music over AppleScript: no browser, but no install either.
local function appleScriptPlaying()
  for _, p in ipairs({
    { mod = hs.spotify, id = "com.spotify.client" },
    { mod = hs.itunes,  id = "com.apple.Music" },
  }) do
    local ok, raw = pcall(function()
      local m = p.mod
      if not (m and m.isRunning() and m.isPlaying()) then return nil end
      return {
        bundleIdentifier = p.id, playing = true,
        title = m.getCurrentTrack(), artist = m.getCurrentArtist(), album = m.getCurrentAlbum(),
        duration = m.getDuration(), elapsedTime = m.getPosition(), timestamp = now(),
      }
    end)
    if ok and raw then return K.normalize(raw) end
  end
  return nil
end

startFallback = function()
  M.source = "AppleScript"
  logf("falling back to AppleScript")
  ctx:timer(POLL_SECS, function() onPlaying(appleScriptPlaying()) end)
end

-- ── Tile ───────────────────────────────────────────────────────────────────
M.menu = ctx:tile("Karaoke")

local function setEnabled(on)
  hs.settings.set(ENABLED_KEY, on)
  M.menu:setTitle(on and "🎤" or "🎤💤")
  wake()
end

function M.toggle() setEnabled(not enabled()) end

-- Positive moves the lyrics sooner; nil puts them back where LRCLIB had them.
function M.nudge(by)
  if not M.np then return end
  local k = M.np.key
  M.offsets[k] = by and ((M.offsets[k] or 0) + by) or nil
  if M.offsets[k] == 0 then M.offsets[k] = nil end
end

local function buildMenu()
  local items = {
    { title = "Show lyrics", switch = true, checked = enabled(), fn = M.toggle },
  }
  if M.np then
    items[#items + 1] = { title = "♪ " .. M.np.title .. (M.np.artist ~= "" and (" · " .. M.np.artist) or ""),
                          disabled = true }
  end
  items[#items + 1] = { title = K.status(M.np, M.lyrics), disabled = true }
  items[#items + 1] = { title = "-" }
  local off = M.np and M.offsets[M.np.key] or 0
  items[#items + 1] = { title = "Lyrics sooner by 0.5 s", disabled = not M.np,
                        fn = function() M.nudge(0.5) end }
  items[#items + 1] = { title = "Lyrics later by 0.5 s", disabled = not M.np,
                        fn = function() M.nudge(-0.5) end }
  if off ~= 0 then
    items[#items + 1] = { title = string.format("Reset timing (now %.1f s %s)",
                                                math.abs(off), off > 0 and "sooner" or "later"),
                          fn = function() M.nudge(nil) end }
  end
  items[#items + 1] = { title = "Look up the lyrics again", disabled = not M.np,
                        fn = function()
                          M.cache[M.np.key], M.failures[M.np.key] = nil, nil
                          M.lyrics, M.since.none = { kind = "loading" }, nil
                          rebuild(); lookup(M.np); wake()
                        end }
  items[#items + 1] = { title = "-" }
  local onBuiltin = hs.settings.get(SCREEN_KEY) == "builtin"
  items[#items + 1] = { title = "On the main screen", checked = not onBuiltin,
                        fn = function() hs.settings.set(SCREEN_KEY, "main"); rebuild() end }
  items[#items + 1] = { title = "On the built-in screen", checked = onBuiltin,
                        fn = function() hs.settings.set(SCREEN_KEY, "builtin"); rebuild() end }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Source: " .. (M.source or "none"), disabled = true }
  if M.source == "AppleScript" then
    items[#items + 1] = { title = "brew install media-control to follow YouTube", disabled = true }
  end
  return items
end

M.menu:setMenu(buildMenu)
M.menu:setTooltip("Karaoke · Cmd+Alt+Shift+K")
setEnabled(enabled())

ctx:hotkey(HOTKEY.mods, HOTKEY.key, M.toggle)
ctx:watcher("screen", function() rebuild() end)
-- Light and dark change the island's colors, and it stays up for a whole song.
ctx:ui():onAppearance(function() rebuild() end)

if hs.fs.attributes(MEDIA_CONTROL) then startStream() else startFallback() end

function M.dispose()
  M.disposed = true
  ctx:dispose()
  M.canvas, M.release, M.stream, M.shown = nil, nil, nil, false
end

return M
