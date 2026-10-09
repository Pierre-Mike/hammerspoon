-- Pure tunnel logic — no hs.* dependency, fully unit-testable. The wiring
-- lives in apps/cloudflare_tunnel.
--
-- This half owns everything worth asserting about a Cloudflare tunnel without
-- running one: the cloudflared command line, the URL hidden in its banner, what
-- its complaints mean, how long to wait before trying again, when a lease is
-- dead, and what the three HTTP endpoints answer. apps/cloudflare_tunnel adds
-- the child process, the timer, the intake socket and the tile, and nothing
-- else.
--
-- The vocabulary, once:
--   lease       a named reservation. One owner, one TTL, renewed on every poll.
--               The lease table IS the liveness signal: no live lease means
--               nobody needs a tunnel, so the child can stop.
--   generation  bumped every time a fresh cloudflared child starts. A caller
--               detects "my URL changed" by comparing this integer, rather than
--               by comparing URL strings and hoping a changed string means a
--               new tunnel.
--   fatal       broken until a human acts: no binary, no cert.pem, a tunnel
--               name that does not exist. Retrying one of these forever is how
--               a config burns CPU all night and still does not work.
--   transient   no URL in time, the child exited, the probe missed three times.
--               These retry on 30s / 2m / 10m / 10m…
--   rate limit  its own case, because retrying fast makes it worse.

local M = {}

-- ── Constants ──────────────────────────────────────────────────────────────
M.PORT          = 8795      -- the intake, first free port after the phone server's 8794
M.LEASE_TTL_S   = 120       -- a lease nobody renews is gone after this
M.GRACE_S       = 60        -- …and the child stops this long after the last one
M.START_TIMEOUT_S = 30      -- a quick tunnel that printed no URL by now is stuck
M.WATCH_S       = 30        -- the watchdog's period, which is also the renew period
M.PROBE_MISSES  = 3         -- consecutive probe failures that count as a dead tunnel
M.DEFAULT_BIN   = "/opt/homebrew/bin/cloudflared"
M.DEFAULT_ORIGIN_HOST = "127.0.0.1"

-- 30s, 2m, then 10m forever. The same ladder voice_agent/phone/service.py
-- already climbs, so behaviour after moving the tunnel here matches behaviour
-- before it.
M.BACKOFF = { 30, 120, 600 }
-- Where a rate limit starts instead: trycloudflare hands out quick tunnels on a
-- quota, and asking again in 30 seconds spends the next one for nothing.
M.RATE_LIMIT_STEP = 3

M.MODES = { quick = true, named = true, off = true }

-- The address cloudflared prints when it cannot reach Cloudflare at all. It is
-- never the tunnel, and a regex that accepted it would hand a caller a URL that
-- answers 404 for the rest of the day.
M.NOT_A_TUNNEL = { ["https://api.trycloudflare.com"] = true }

M.RATE_LIMIT_ERROR = "rate limited by trycloudflare"

-- ── JSON ───────────────────────────────────────────────────────────────────
-- Written here rather than taken from hs.json so that route() stays pure: the
-- endpoints are the part a spec most wants to drive, and a module that needs
-- Hammerspoon to encode its own answer cannot be driven from busted.

local ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function quote(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

-- A table with only 1..n integer keys is a list; anything else is an object.
-- An empty table is a list, which is what the only empty table here — the lease
-- list — should be.
local function isList(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

function M.encode(v)
  local kind = type(v)
  if v == nil then return "null" end
  if kind == "boolean" then return tostring(v) end
  if kind == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if v == math.floor(v) then return string.format("%d", v) end
    return (string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", ""))
  end
  if kind == "string" then return quote(v) end
  if kind ~= "table" then return "null" end
  if isList(v) then
    local out = {}
    for _, item in ipairs(v) do out[#out + 1] = M.encode(item) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  -- Sorted, so two equal states encode to the same bytes and a spec can assert
  -- on the string instead of decoding it again.
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = quote(k) .. ":" .. M.encode(v[k]) end
  return "{" .. table.concat(out, ",") .. "}"
end

local SIMPLE = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
                 ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local parseValue

local function skipSpace(s, i)
  local j = s:find("[^ \t\r\n]", i)
  return j or (#s + 1)
end

local function parseString(s, i)
  local out, j = {}, i + 1
  while j <= #s do
    local c = s:sub(j, j)
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local e = s:sub(j + 1, j + 1)
      if e == "u" then
        local code = tonumber(s:sub(j + 2, j + 5), 16)
        -- Only the ASCII range is turned back into a character: an owner name
        -- is ASCII, and half-decoding UTF-16 pairs here would be a bug farm.
        out[#out + 1] = (code and code < 128) and string.char(code) or "?"
        j = j + 6
      else
        out[#out + 1] = SIMPLE[e] or e
        j = j + 2
      end
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
  return nil
end

function parseValue(s, i)
  i = skipSpace(s, i)
  local c = s:sub(i, i)
  if c == "" then return nil end
  if c == '"' then return parseString(s, i) end
  if c == "{" then
    local out = {}
    i = skipSpace(s, i + 1)
    if s:sub(i, i) == "}" then return out, i + 1 end
    while true do
      if s:sub(i, i) ~= '"' then return nil end
      local key, j = parseString(s, i)
      if key == nil then return nil end
      j = skipSpace(s, j)
      if s:sub(j, j) ~= ":" then return nil end
      local val
      val, j = parseValue(s, j + 1)
      if j == nil then return nil end
      out[key] = val
      j = skipSpace(s, j)
      local sep = s:sub(j, j)
      if sep == "}" then return out, j + 1 end
      if sep ~= "," then return nil end
      i = skipSpace(s, j + 1)
    end
  end
  if c == "[" then
    local out = {}
    i = skipSpace(s, i + 1)
    if s:sub(i, i) == "]" then return out, i + 1 end
    while true do
      local val
      val, i = parseValue(s, i)
      if i == nil then return nil end
      out[#out + 1] = val
      i = skipSpace(s, i)
      local sep = s:sub(i, i)
      if sep == "]" then return out, i + 1 end
      if sep ~= "," then return nil end
      i = i + 1
    end
  end
  if s:sub(i, i + 3) == "true"  then return true,  i + 4 end
  if s:sub(i, i + 4) == "false" then return false, i + 5 end
  if s:sub(i, i + 3) == "null"  then return nil,   i + 4 end
  local num, rest = s:match("^(%-?%d+%.?%d*[eE]?[%-+]?%d*)()", i)
  if num and tonumber(num) then return tonumber(num), rest end
  return nil
end

-- A JSON document as a Lua value, or nil when it is not JSON. Never raises: the
-- body on the wire is whatever a caller sent.
function M.decode(text)
  if type(text) ~= "string" or text == "" then return nil end
  local ok, value = pcall(parseValue, text, 1)
  if not ok then return nil end
  return value
end

-- ── Requests ───────────────────────────────────────────────────────────────
function M.urldecode(s)
  if not s then return nil end
  s = s:gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Query parameters out of a path, so every endpoint also works as a plain GET.
-- hs.httpserver answers 400 to a bodyless POST before the callback ever runs,
-- which is why apps/tts made /stop method-agnostic; the same rule applies here.
function M.params(path)
  local out = {}
  local query = type(path) == "string" and path:match("%?(.*)$") or nil
  for key, value in (query or ""):gmatch("([^&=?]+)=([^&]*)") do
    out[M.urldecode(key)] = M.urldecode(value)
  end
  return out
end

-- Form-encoded bodies, for a caller that posts `owner=x&mode=quick`.
function M.formDecode(body)
  if type(body) ~= "string" or not body:find("=", 1, true) then return nil end
  local out = {}
  for key, value in body:gmatch("([^&=]+)=([^&]*)") do
    out[M.urldecode(key)] = M.urldecode(value)
  end
  return next(out) and out or nil
end

-- One lease request, however it arrived: a JSON body, a form body, or a query
-- string. The body wins, because a caller that sent one meant it.
function M.request(body, params)
  local req = M.decode(body)
  if type(req) ~= "table" then req = M.formDecode(body) end
  if type(req) ~= "table" then req = {} end
  for k, v in pairs(params or {}) do
    if req[k] == nil then req[k] = v end
  end
  return M.normalize(req)
end

-- Defaults, types and the one piece of tidying every caller would otherwise do
-- for itself: a public URL with no trailing slash, because callers append paths
-- to it and `https://x.com//phone/ping` is a 404.
function M.normalize(req)
  req = req or {}
  local out = {
    owner      = req.owner,
    mode       = req.mode or "quick",
    port       = tonumber(req.port),
    name       = req.name,
    public_url = req.public_url,
    ttl_s      = tonumber(req.ttl_s) or M.LEASE_TTL_S,
    probe_path = req.probe_path,
    probe_expect = req.probe_expect,
    bin        = req.bin,
    binExists  = req.binExists,
  }
  if out.name == "" then out.name = nil end
  if out.public_url == "" then out.public_url = nil end
  if out.public_url then out.public_url = out.public_url:gsub("/+$", "") end
  if out.probe_path == "" then out.probe_path = nil end
  if out.ttl_s <= 0 then out.ttl_s = M.LEASE_TTL_S end
  return out
end

-- What makes a request unanswerable, as opposed to what makes a tunnel broken.
-- Returns a 400's worth of explanation, or nil.
function M.badRequest(req)
  if type(req.owner) ~= "string" or req.owner == "" then
    return "owner is required"
  end
  if not M.MODES[req.mode] then
    return "mode must be quick, named or off (got " .. tostring(req.mode) .. ")"
  end
  if req.mode ~= "off" and not req.port then
    return "port is required: the local port the tunnel should carry traffic to"
  end
  return nil
end

-- ── The command ────────────────────────────────────────────────────────────
-- Mirrors tunnel_command() in voice_agent/phone/tunnel.py, including the
-- argument order, so the two can be compared line for line while the move is
-- in flight. `off` builds nothing: the caller already has a public URL.
function M.command(req)
  req = M.normalize(req)
  if req.mode == "off" then return nil end
  local bin = req.bin or M.DEFAULT_BIN
  local origin = string.format("http://%s:%d", M.DEFAULT_ORIGIN_HOST, req.port or 0)
  if req.mode == "named" then
    return { bin, "tunnel", "--no-autoupdate", "run", "--url", origin, req.name }
  end
  return { bin, "tunnel", "--no-autoupdate", "--url", origin }
end

-- ── Reading cloudflared ────────────────────────────────────────────────────
-- The quick tunnel's hostname, out of whatever chunk of output just arrived.
-- Every match is considered, not just the first, because the line that carries
-- the address cloudflared failed to reach also carries nothing else useful.
function M.parseQuickUrl(text)
  if type(text) ~= "string" then return nil end
  for url in text:gmatch("https://[%w%-]+%.trycloudflare%.com") do
    if not M.NOT_A_TUNNEL[url] then return url end
  end
  return nil
end

-- Four ways to be broken until a human acts. The message is what the tile shows
-- and what the caller is told, so each one says what to do about it.
local FATAL_LINES = {
  { "no file cert.pem",                            "no cert.pem in ~/.cloudflared — run `cloudflared login`" },
  { "cannot determine default origin certificate", "no cert.pem in ~/.cloudflared — run `cloudflared login`" },
  { "error locating origin cert",                  "no cert.pem in ~/.cloudflared — run `cloudflared login`" },
  { "certificate has expired",                     "the cert.pem in ~/.cloudflared has expired — run `cloudflared login` again" },
  { "cert.pem has expired",                        "the cert.pem in ~/.cloudflared has expired — run `cloudflared login` again" },
  { "tunnel credentials file not found",           "no credentials file for that tunnel in ~/.cloudflared" },
  { "couldn't find tunnel",                        "cloudflared cannot find that tunnel name" },
  { "failed to find tunnel",                       "cloudflared cannot find that tunnel name" },
  { "tunnel not found",                            "cloudflared cannot find that tunnel name" },
}

-- Takes either a line of cloudflared's output or a normalized request: the two
-- fatal cases that happen before the child ever runs — no binary, and `named`
-- mode with nothing to name — would otherwise have no home.
function M.fatalReason(subject)
  if type(subject) == "table" then
    local req = subject
    if req.binExists == false then
      return "no cloudflared at " .. tostring(req.bin or M.DEFAULT_BIN)
    end
    if req.mode == "named" then
      if not req.name then return "named mode needs a tunnel name" end
      if not req.public_url then return "named mode needs a public hostname (public_url)" end
    end
    return nil
  end
  if type(subject) ~= "string" then return nil end
  local low = subject:lower()
  for _, pair in ipairs(FATAL_LINES) do
    if low:find(pair[1], 1, true) then return pair[2] end
  end
  return nil
end

-- A quota, not a fault. `429` is matched as a whole number so a port or a byte
-- count that happens to contain those digits does not read as a rate limit.
function M.rateLimited(text)
  if type(text) ~= "string" then return false end
  local low = text:lower()
  return low:find("too many requests", 1, true) ~= nil
      or low:find("%f[%d]429%f[%D]") ~= nil
end

-- What a chunk of cloudflared output means: "fatal", "rate_limit" or "ok",
-- plus the reason to show. Checked in that order — a 429 inside a line that
-- also says the cert is missing is still a missing cert.
function M.classify(text)
  local fatal = M.fatalReason(text)
  if fatal then return "fatal", fatal end
  if M.rateLimited(text) then return "rate_limit", M.RATE_LIMIT_ERROR end
  return "ok", nil
end

-- cloudflared's output, as lines worth logging. Blank lines are dropped so the
-- log does not double in size for nothing.
function M.logLines(chunk)
  local out = {}
  if type(chunk) ~= "string" then return out end
  for line in chunk:gmatch("[^\r\n]+") do
    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed ~= "" then out[#out + 1] = trimmed end
  end
  return out
end

-- ── Waiting ────────────────────────────────────────────────────────────────
-- 30s, 2m, then 10m for as long as it stays broken.
function M.backoff(step)
  step = tonumber(step) or 1
  if step < 1 then step = 1 end
  if step > #M.BACKOFF then step = #M.BACKOFF end
  return M.BACKOFF[step]
end

function M.nextAttempt(now, step) return now + M.backoff(step) end

-- A quick tunnel prints its URL within a couple of seconds. Thirty is the same
-- budget the Python side gives it, and a child still silent after that is stuck
-- rather than slow.
function M.startTimedOut(startedAt, now, url)
  if url and url ~= "" then return false end
  if not startedAt then return false end
  return (now - startedAt) >= M.START_TIMEOUT_S
end

function M.probeFailed(misses) return (tonumber(misses) or 0) >= M.PROBE_MISSES end

-- Did the origin answer with what its owner said proves it is the origin? The
-- caller supplies both halves, because only it knows what healthy looks like:
-- the voice agent's /phone/ping returns a token chosen at daemon start, so a
-- different daemon answering through the same tunnel does not count as healthy.
function M.probeOk(body, expect)
  if expect == nil or expect == "" then return true end
  if type(body) ~= "string" then return false end
  return body:gsub("^%s+", ""):gsub("%s+$", "") == expect
end

-- ── Leases ─────────────────────────────────────────────────────────────────
function M.leaseExpiry(req, now) return now + (req.ttl_s or M.LEASE_TTL_S) end

-- Drop the leases nobody renewed, and say whose they were. Renewal is the
-- liveness signal: an owner that stopped polling stopped needing a tunnel,
-- whether it said so or crashed.
function M.expire(leases, now)
  local gone = {}
  for owner, lease in pairs(leases or {}) do
    if (lease.expires or 0) <= now then gone[#gone + 1] = owner end
  end
  table.sort(gone)
  for _, owner in ipairs(gone) do leases[owner] = nil end
  return gone
end

function M.activeCount(leases, now)
  local n = 0
  for _, lease in pairs(leases or {}) do
    if not now or (lease.expires or 0) > now then n = n + 1 end
  end
  return n
end

-- The leases a caller or the tile can read, oldest owner name first so the menu
-- does not reshuffle itself between two opens.
function M.activeList(leases, now)
  local out = {}
  for owner, lease in pairs(leases or {}) do
    if not now or (lease.expires or 0) > now then
      out[#out + 1] = { owner = owner,
                        expires_in = math.max(0, math.floor((lease.expires or 0) - (now or 0))) }
    end
  end
  table.sort(out, function(a, b) return a.owner < b.owner end)
  return out
end

-- Which lease decides what the child does. The first one taken wins and keeps
-- winning while it is renewed, so a second caller cannot move the tunnel out
-- from under the first by asking for a different port.
function M.primary(leases, now)
  local best
  for owner, lease in pairs(leases or {}) do
    if not now or (lease.expires or 0) > now then
      if not best or (lease.taken or 0) < (best.taken or 0)
         or ((lease.taken or 0) == (best.taken or 0) and owner < best.owner) then
        best = { owner = owner, taken = lease.taken, req = lease.req }
      end
    end
  end
  return best and best.req or nil, best and best.owner or nil
end

-- One child serves one origin. A second caller asking for a different port
-- would otherwise be handed a URL that reaches somebody else's service, which
-- is worse than being told no.
function M.conflict(live, req)
  if not live or not live.port or not req.port then return nil end
  if live.port == req.port and (live.mode or "quick") == req.mode then return nil end
  return string.format(
    "tunnel already serving %s mode on port %d; this request asked for %s mode on port %d",
    tostring(live.mode or "quick"), live.port, tostring(req.mode), req.port)
end

-- ── Status ─────────────────────────────────────────────────────────────────
-- Four states, from the fields apps/cloudflare_tunnel keeps:
--   off       nothing to do: no live lease, or the only lease asked for `off`
--   starting  a lease is live and there is no usable URL yet — including while
--             a backoff runs, because a caller must hold its old URL rather
--             than repoint at nothing
--   ready     a URL that a caller can point a webhook at
--   error     fatal; retrying has stopped
function M.computeStatus(s)
  if s.fatal then return "error" end
  if s.mode == "off" then return "off" end
  if s.url and s.url ~= "" and s.child then return "ready" end
  if s.child or s.pending then return "starting" end
  return "off"
end

function M.uptime(s, now)
  if not s.startedAt then return 0 end
  return math.max(0, math.floor((now or os.time()) - s.startedAt))
end

-- The answer every endpoint gives, and the only shape a caller sees.
function M.snapshot(s, now)
  now = now or os.time()
  local status = M.computeStatus(s)
  return {
    status     = status,
    url        = (s.url ~= "" and s.url) or nil,
    generation = s.generation or 0,
    error      = s.err,
    uptime_s   = M.uptime(s, now),
    mode       = s.mode,
    port       = s.port,
    leases     = M.activeList(s.leases, now),
  }
end

-- Always every key, including the ones that are nil. A caller reading
-- state["error"] must not have to know that the key disappears when there is
-- nothing wrong.
M.STATE_KEYS = { "status", "url", "generation", "error", "uptime_s", "mode", "port", "leases" }

function M.encodeState(s)
  local parts = {}
  for _, key in ipairs(M.STATE_KEYS) do
    parts[#parts + 1] = quote(key) .. ":" .. M.encode(s[key])
  end
  return "{" .. table.concat(parts, ",") .. "}\n"
end

-- ── Routing ────────────────────────────────────────────────────────────────
-- `target` is apps/cloudflare_tunnel itself: lease(req), release(owner) and
-- state() are the three things this needs from it, so a spec can drive every
-- endpoint against a table of stubs with no Hammerspoon anywhere.
--
-- Every endpoint also answers a GET with query parameters. hs.httpserver
-- rejects a bodyless POST with 400 before the callback runs, so an endpoint
-- that only worked as a POST would be one `curl` away from looking broken.
local JSON = { ["Content-Type"] = "application/json" }

function M.route(target, method, path, body)
  path = (type(path) == "string" and path ~= "") and path or "/"
  local route = path:match("^[^?]*")
  local params = M.params(path)

  if route == "/lease" then
    local req = M.request(body, params)
    local bad = M.badRequest(req)
    if bad then return M.encode({ error = bad }) .. "\n", 400, JSON end
    local st = target.lease(req)
    return M.encodeState(st), st.code or 200, JSON
  end

  if route == "/tunnel" then
    return M.encodeState(target.state()), 200, JSON
  end

  if route == "/release" then
    local req = M.request(body, params)
    if type(req.owner) ~= "string" or req.owner == "" then
      return M.encode({ error = "owner is required" }) .. "\n", 400, JSON
    end
    return M.encodeState(target.release(req.owner)), 200, JSON
  end

  return M.encode({ error = "no such endpoint: " .. route }) .. "\n", 404, JSON
end

-- ── Tile ───────────────────────────────────────────────────────────────────
-- Quiet in the normal case, loud only when it matters. `ready` and `starting`
-- are the same cloud; the emoji presentation selector makes the ready one
-- coloured and leaves the other monochrome, which is as close to "dimmed" as a
-- menu-bar title gets.
M.GLYPH = {
  off      = "\u{2601}\u{FE0E}",
  starting = "\u{2601}\u{FE0E}",
  ready    = "\u{2601}\u{FE0F}",
  error    = "\u{26A0}\u{FE0F}",
}

function M.title(s)
  return M.GLYPH[M.computeStatus(s)] or M.GLYPH.off
end

function M.humanDuration(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  if seconds < 60 then return string.format("%ds", seconds) end
  if seconds < 3600 then return string.format("%dm %ds", seconds // 60, seconds % 60) end
  return string.format("%dh %dm", seconds // 3600, (seconds % 3600) // 60)
end

-- First line only: lib/menuhub takes it as the tile's status and strips the
-- leading "Cloudflare tunnel: " because it shares the name's first four
-- letters. It also upper-cases the first letter of what is left, which is why
-- `ready` leads with a word rather than with "https".
function M.tooltip(s, now)
  local status = M.computeStatus(s)
  if status == "error" then
    return "Cloudflare tunnel: " .. (s.err or "error")
  end
  if status == "ready" then
    return string.format("Cloudflare tunnel: up at %s\n%s, generation %d",
                         s.url, M.humanDuration(M.uptime(s, now)), s.generation or 0)
  end
  if status == "starting" then
    return "Cloudflare tunnel: " .. (s.err or "starting a tunnel…")
  end
  return "Cloudflare tunnel: ready for leases"
end

return M
