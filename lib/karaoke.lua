-- Pure helpers behind apps/karaoke — no hs.* dependency.
--
-- What is playing comes from `media-control stream`, which reads macOS's Now
-- Playing center through /usr/bin/perl (the one kind of process macOS 15.4+
-- still lets in), so Spotify, Music and a YouTube tab in any browser all look
-- the same. Lyrics come from LRCLIB (lrclib.net), a free database of synced
-- LRC lyrics with no key. This module turns one into a lookup on the other,
-- reads the LRC, and works out which line is being sung right now.

local utils = require("lib.utils")

local M = {}

M.API = "https://lrclib.net/api"

-- How far a database entry's length may be from what is playing before it is
-- the wrong recording. A music video runs a few seconds longer than the album
-- cut; a live version or an extended mix runs a lot longer.
M.MAX_DRIFT = 10

local function trim(s) return utils.trim(s) or "" end

local function chars(s)
  return select(2, tostring(s or ""):gsub("[^\128-\191]", ""))
end

-- ── LRC ────────────────────────────────────────────────────────────────────
-- [mm:ss], [mm:ss.xx] and [mm:ss.xxx]; a line can carry several stamps when a
-- chorus repeats. [ar:], [ti:] and friends are skipped, and [offset:+500]
-- moves every line half a second sooner, which is what the LRC format means
-- by a positive offset.
function M.parseLrc(text)
  local out, offset = {}, 0
  if type(text) ~= "string" then return out end
  local off = text:match("%[offset:%s*([+-]?%d+)%s*%]")
  if off then offset = tonumber(off) / 1000 end
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw:gsub("\r$", "")
    local stamps, rest = {}, line
    while true do
      local mm, ss, frac, after = rest:match("^%s*%[(%d+):(%d+)%.?(%d*)%](.*)$")
      if not mm then break end
      local t = tonumber(mm) * 60 + tonumber(ss)
      if frac ~= "" then t = t + tonumber(frac) / (10 ^ #frac) end
      stamps[#stamps + 1] = t
      rest = after
    end
    for _, t in ipairs(stamps) do
      out[#out + 1] = { t = math.max(0, t - offset), text = trim(rest) }
    end
  end
  -- Stable for equal stamps, so two lines stamped alike keep file order.
  for i, l in ipairs(out) do l.i = i end
  table.sort(out, function(a, b)
    if a.t ~= b.t then return a.t < b.t end
    return a.i < b.i
  end)
  for _, l in ipairs(out) do l.i = nil end
  return out
end

-- Index of the last line that has started, or 0 before the first.
function M.lineAt(lines, pos)
  local lo, hi, found = 1, #(lines or {}), 0
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if lines[mid].t <= pos then found = mid; lo = mid + 1 else hi = mid - 1 end
  end
  return found
end

-- How far through line i the sweep should be, 0 to 1. LRC only says when a
-- line starts, so its end is a guess: about 0.15 s a character, never under
-- two seconds, and never past the next line. Without the cap, a short line
-- before an instrumental break would crawl across the whole break.
function M.progress(lines, i, pos)
  local l = lines and lines[i]
  if not l then return 0 end
  local finish = l.t + math.max(2, chars(l.text) * 0.15)
  local nxt = lines[i + 1]
  if nxt then finish = math.min(finish, nxt.t - 0.2) end
  if finish <= l.t then return 1 end
  return math.max(0, math.min(1, (pos - l.t) / (finish - l.t)))
end

-- ── Now playing ────────────────────────────────────────────────────────────
-- A YouTube tab's title is "Artist - Song (Official Video)" and its artist is
-- the channel, so a browser gets its title taken apart before the lookup.
M.BROWSERS = {
  ["com.apple.Safari"] = true, ["com.apple.SafariTechnologyPreview"] = true,
  ["com.apple.WebKit.GPU"] = true,
  ["com.google.Chrome"] = true, ["com.google.Chrome.beta"] = true,
  ["com.google.Chrome.canary"] = true, ["org.chromium.Chromium"] = true,
  ["company.thebrowser.Browser"] = true, ["company.thebrowser.dia"] = true,
  ["com.brave.Browser"] = true, ["com.microsoft.edgemac"] = true,
  ["org.mozilla.firefox"] = true, ["app.zen-browser.zen"] = true,
  ["com.vivaldi.Vivaldi"] = true, ["com.operasoftware.Opera"] = true,
  ["com.kagi.kagimacOS"] = true,
}

-- One media-control payload (or the same shape built from AppleScript) into
-- seconds. `at` is the epoch second at which `elapsed` was true.
function M.normalize(raw)
  if type(raw) ~= "table" or type(raw.title) ~= "string" or raw.title == "" then return nil end
  local app = raw.parentApplicationBundleIdentifier or raw.bundleIdentifier or "?"
  local playing = raw.playing == true
  local np = {
    app      = app,
    browser  = M.BROWSERS[app] == true,
    title    = raw.title,
    artist   = raw.artist or "",
    album    = raw.album or "",
    playing  = playing,
    rate     = tonumber(raw.playbackRate) or (playing and 1 or 0),
    duration = raw.durationMicros and raw.durationMicros / 1e6 or tonumber(raw.duration),
    elapsed  = raw.elapsedTimeMicros and raw.elapsedTimeMicros / 1e6 or tonumber(raw.elapsedTime) or 0,
    at       = raw.timestampEpochMicros and raw.timestampEpochMicros / 1e6 or tonumber(raw.timestamp),
  }
  np.key = table.concat({ app, np.artist, np.title }, "\n")
  return np
end

function M.position(np, now)
  local pos = np.elapsed or 0
  if np.playing and np.at then pos = pos + (now - np.at) * (np.rate or 1) end
  if np.duration and pos > np.duration then pos = np.duration end
  return math.max(0, pos)
end

-- ── Cleaning titles ────────────────────────────────────────────────────────
-- A bracket is noise when it describes the upload rather than the song.
local NOISE = { "official", "video", "audio", "lyric", "visuali", "paroles", "clip",
                "prod%.", "prod ", "produced", "explicit", "color coded",
                "%f[%w]hd%f[%W]", "%f[%w]hq%f[%W]", "%f[%w]4k%f[%W]",
                "%f[%w]mv%f[%W]", "m/v" }

local function isNoise(inner)
  local s = inner:lower()
  for _, w in ipairs(NOISE) do
    if s:find(w) then return true end
  end
  return false
end

local function squash(s)
  return trim((s:gsub("%s+", " ")))
end

function M.cleanTitle(s)
  s = tostring(s or "")
  s = s:gsub("%s*|.*$", "")
  s = s:gsub("%s*([%(%[])([^%)%]]*)[%)%]]", function(_, inner)
    if isNoise(inner) then return "" end
  end)
  s = s:gsub("%s+[Hh][DdQq]$", ""):gsub("%s+4[Kk]$", "")
  return squash(s)
end

function M.cleanArtist(s)
  s = tostring(s or "")
  s = s:gsub("%s*%-%s*Topic$", ""):gsub("VEVO$", ""):gsub("%s+[Oo]fficial$", "")
  return squash(s)
end

-- Spotify writes the edition after a dash: "Song - Remastered 2011".
local EDITION = { "remaster", "edit", "version", "live", "mono", "stereo", "mix" }

local DASHES = { " - ", " – ", " — " }

-- First "a - b" split on any dash, or nil.
local function splitDash(s)
  local best
  for _, d in ipairs(DASHES) do
    local i = s:find(d, 1, true)
    if i and (not best or i < best.i) then best = { i = i, len = #d } end
  end
  if not best then return nil end
  return s:sub(1, best.i - 1), s:sub(best.i + best.len)
end

-- Last dash, for the edition suffix.
local function lastDash(s)
  local best
  for _, d in ipairs(DASHES) do
    local from = 1
    while true do
      local i = s:find(d, from, true)
      if not i then break end
      if not best or i > best then best = i end
      from = i + 1
    end
  end
  return best
end

-- The title with every bracket, edition and feature credit gone: the name a
-- lyrics database is most likely to file the song under.
function M.bareTitle(s)
  s = M.cleanTitle(s):gsub("%s*[%(%[][^%)%]]*[%)%]]", "")
  local i = lastDash(s)
  if i then
    local tail = s:sub(i):lower()
    for _, w in ipairs(EDITION) do
      if tail:find(w, 1, true) then s = s:sub(1, i - 1); break end
    end
  end
  local lower = s:lower()
  local f = lower:find("%s+feat%.?%s") or lower:find("%s+ft%.%s")
  if f then s = s:sub(1, f - 1) end
  return squash(s)
end

-- Every { artist, title } worth asking LRCLIB for, best guess first.
function M.candidates(np)
  local out, seen = {}, {}
  local function add(artist, title)
    artist, title = trim(artist), trim(title)
    if artist == "" or title == "" then return end
    local k = artist:lower() .. "\n" .. title:lower()
    if seen[k] then return end
    seen[k] = true
    out[#out + 1] = { artist = artist, title = title }
  end
  if np.browser then
    local a, t = splitDash(np.title)
    if a then
      add(M.cleanArtist(a), M.cleanTitle(t))
      add(M.cleanArtist(a), M.bareTitle(t))
    end
    add(M.cleanArtist(np.artist), M.cleanTitle(np.title))
    add(M.cleanArtist(np.artist), M.bareTitle(np.title))
    -- LRCLIB also holds entries filed under the raw YouTube title.
    add(np.artist, np.title)
  else
    add(np.artist, np.title)
    add(np.artist, M.bareTitle(np.title))
  end
  return out
end

-- ── LRCLIB ─────────────────────────────────────────────────────────────────
-- /get matches exactly on artist and title and within two seconds on length,
-- which is why the duration is sent when it is known.
function M.getUrl(c, duration)
  local u = string.format("%s/get?artist_name=%s&track_name=%s", M.API,
                          utils.urlencode(c.artist), utils.urlencode(c.title))
  if duration then u = u .. "&duration=" .. math.floor(duration + 0.5) end
  return u
end

function M.searchUrl(q)
  return M.API .. "/search?q=" .. utils.urlencode(q)
end

-- /search on the fields is fuzzy, so "Starry Night" by Ren finds "Vincent's
-- Tale - Starry Night - Act I", and it answers with every length on file.
function M.searchFieldsUrl(c)
  return string.format("%s/search?track_name=%s&artist_name=%s", M.API,
                       utils.urlencode(c.title), utils.urlencode(c.artist))
end

-- Every request worth making for one song, in order. The exact match on the
-- best guess comes first because it is one answer and usually right; the
-- field search next, because it forgives a title that is close; then the
-- other guesses; then free text as the last resort.
function M.plan(np)
  local out, seen = {}, {}
  local function add(kind, url)
    if seen[url] then return end
    seen[url] = true
    out[#out + 1] = { kind = kind, url = url }
  end
  local tries = M.candidates(np)
  local first = tries[1]
  if not first then return out end
  add("get", M.getUrl(first, np.duration))
  add("search", M.searchFieldsUrl({ artist = first.artist, title = M.bareTitle(first.title) }))
  for i = 2, #tries do add("get", M.getUrl(tries[i], np.duration)) end
  add("search", M.searchUrl(first.artist .. " " .. M.bareTitle(first.title)))
  return out
end

-- From /search results: the synced entry closest in length, if any is close
-- enough to be the same recording.
function M.pickBest(results, duration)
  local best, bestDiff
  for _, r in ipairs(results or {}) do
    if type(r) == "table" and type(r.syncedLyrics) == "string" and r.syncedLyrics ~= "" then
      if not duration then return r end
      local diff = math.abs((tonumber(r.duration) or 0) - duration)
      if diff <= M.MAX_DRIFT and (not bestDiff or diff < bestDiff) then
        best, bestDiff = r, diff
      end
    end
  end
  return best
end

-- One LRCLIB record into what the notch draws from.
function M.fromRecord(rec)
  if type(rec) ~= "table" then return { kind = "none" } end
  if rec.instrumental == true then return { kind = "instrumental" } end
  local lines = M.parseLrc(rec.syncedLyrics)
  if #lines == 0 then return { kind = "none" } end
  return { kind = "synced", lines = lines }
end

-- ── What the notch shows ───────────────────────────────────────────────────
local NOTE = "♪"

function M.display(np, lyrics, pos)
  local name = np.title .. (np.artist ~= "" and (" · " .. np.artist) or "")
  local kind = lyrics and lyrics.kind or "loading"
  if kind == "loading" then return { current = name, next = "Looking up lyrics…", progress = 0 } end
  if kind == "none" then return { current = name, next = "No synced lyrics for this one", progress = 0 } end
  if kind == "instrumental" then return { current = NOTE .. " Instrumental", next = name, progress = 0 } end
  if kind == "error" then return { current = name, next = "LRCLIB is busy, trying again soon", progress = 0 } end

  local lines = lyrics.lines
  local i = M.lineAt(lines, pos)
  local nxt = lines[i + 1]
  if i == 0 then return { current = NOTE, next = nxt and nxt.text or "", progress = 0 } end
  local text = lines[i].text
  if text == "" then
    -- The next sung line, not the next stamp, which may be another gap.
    local j = i + 1
    while lines[j] and lines[j].text == "" do j = j + 1 end
    return { current = NOTE, next = lines[j] and lines[j].text or "", progress = 0 }
  end
  return { current = text, next = nxt and nxt.text or "", progress = M.progress(lines, i, pos) }
end

function M.status(np, lyrics)
  if not np then return "Nothing playing" end
  local kind = lyrics and lyrics.kind or "loading"
  if kind == "loading" then return "Looking up lyrics…" end
  if kind == "none" then return "No synced lyrics found" end
  if kind == "instrumental" then return "Instrumental" end
  if kind == "error" then return "LRCLIB did not answer" end
  return string.format("Synced · %d lines", #lyrics.lines)
end

-- ── Geometry ───────────────────────────────────────────────────────────────
-- A notched MacBook's menu bar is about 37 pt tall, against 24 to 30 on every
-- other screen, and that is the one thing Hammerspoon can see of the notch.
function M.hasNotch(name, full, frame)
  return tostring(name or ""):find("Built%-in") ~= nil and (frame.y - full.y) >= 32
end

M.MIN_WIDTH = 420
M.MAX_WIDTH = 1200
M.PADDING   = 60

-- Wide enough for the longest line, within limits, so the island does not
-- change width on every line.
function M.notchWidth(widths, screenW)
  local widest = 0
  for _, w in ipairs(widths or {}) do widest = math.max(widest, w) end
  local cap = math.min(M.MAX_WIDTH, math.floor(screenW * 0.5))
  return math.max(M.MIN_WIDTH, math.min(widest + M.PADDING, cap))
end

function M.notchFrame(full, w, h)
  return { x = full.x + math.floor((full.w - w) / 2), y = full.y, w = w, h = h }
end

return M
