-- Cloudflare tunnel — one cloudflared child, leased by whoever needs a public
-- URL, reachable at http://127.0.0.1:8795.
--
-- WHY THIS IS A PLUGIN AND NOT A PYTHON DAEMON'S PRIVATE BUSINESS.
-- The voice agent used to start its own cloudflared so WhatsApp had somewhere
-- to post webhooks. That worked until a second thing wanted a public URL, and
-- until the agent restarted: every restart spent another quick-tunnel quota and
-- handed out a different hostname, so the webhook had to be re-registered. A
-- tunnel outlives the process that asked for one, so it belongs to the config
-- that is always running rather than to any one app.
--
-- HOW A CALLER USES IT.
--   POST /lease   {"owner":"voice-agent","mode":"quick","port":8088,
--                  "probe_path":"/phone/ping","probe_expect":"<token>"}
--   GET  /tunnel  the same answer, without touching the lease
--   POST /release {"owner":"voice-agent"}
-- Every endpoint answers a GET with query parameters too, because
-- hs.httpserver rejects a bodyless POST with 400 before this callback ever
-- runs — the same trap apps/tts hit with /stop.
--
-- The answer is always the same shape, every key present:
--   {"status":"ready","url":"https://x.trycloudflare.com","generation":3,
--    "error":null,"uptime_s":182,"mode":"quick","port":8088,"leases":[...]}
-- A caller watches `generation`, not `url`: an integer that changed is a new
-- tunnel, where a changed string is a guess.
--
-- A LEASE IS A HEARTBEAT, NOT A REGISTRATION. It expires 120s after the last
-- /lease, so an owner that crashed releases its tunnel by failing to ask again.
-- The child stops 60s after the last lease goes, which is long enough that a
-- caller restarting does not lose its URL.
--
-- WHAT THE TILE SHOWS. A status light: green while a tunnel is up and handing
-- out a URL, amber while one is coming up, red when there is none — stopped and
-- broken both. The menu under it carries the status in words, the public URL on
-- a row you can read, a Copy URL beside it, who holds a lease and for how much
-- longer, and the two buttons for a tunnel that went wrong: Retry now and Open
-- log. The tile is redrawn after every decision, so it never lags the tunnel.
--
-- All the logic worth asserting on lives in lib/cloudflare_tunnel, which has no
-- hs.* in it. This file is the child process, the timer, the port and the tile.

local T     = require("lib.cloudflare_tunnel")
local utils = require("lib.utils")

local ctx = require("lib.context").new("Cloudflare tunnel")

local LOG = "/tmp/hs-cloudflare-tunnel.log"

local M = {
  leases     = {},    -- owner -> { expires, taken, req }
  child      = nil,   -- the running cloudflared, or nil
  release    = nil,   -- ctx release for that child
  token      = 0,     -- bumped per spawn; an exit carrying a stale one is ignored
  live       = nil,   -- the token of the child we currently want
  url        = nil,   -- the public URL callers are given
  generation = 0,     -- bumped per fresh child, so a caller can spot a new one
  err        = nil,   -- the one line the tile and the callers see
  fatal      = false, -- broken until a human acts; retrying has stopped
  fatalKey   = nil,   -- the request that broke, so a different one may try again
  mode       = nil,
  port       = nil,
  name       = nil,
  req        = nil,   -- the normalized request the child was started for
  startedAt  = nil,
  pending    = nil,   -- a backoff retry is armed
  pendingAt  = nil,   -- when it fires, for the tile
  pendingRelease = nil,
  pendingTimer   = nil,
  step       = 0,     -- where we are on the backoff ladder
  misses     = 0,     -- consecutive probe failures
  idleSince  = nil,   -- when the last lease went, for the grace period
  seq        = 0,     -- lease arrival order, so `primary` is stable
  owner      = nil,   -- whose lease is currently driving the child
  menu       = nil,
  intake     = nil,
  timer      = nil,
  tileKey    = nil,  -- what the tile last drew, so a real change is spottable
  tileDraws  = 0,    -- how many times that has actually changed
}

-- Seams. A spec drives the clock and the filesystem rather than waiting on
-- them, and neither is worth a mock of its own.
function M.now() return os.time() end

-- nil means "cannot tell", which is not the same as "missing": lib treats only
-- an explicit false as the fatal no-binary case.
function M.binExists(path)
  if not (hs.fs and hs.fs.attributes) then return nil end
  return hs.fs.attributes(path) ~= nil
end

local function logf(fmt, ...) utils.logf(LOG, fmt, ...) end

-- ── State ──────────────────────────────────────────────────────────────────
-- The shape lib/cloudflare_tunnel reads. `child` is a boolean there: the lib
-- only ever asks whether one is running, and handing it an hs.task would let
-- it grow an opinion about one.
function M.raw()
  return {
    fatal = M.fatal, mode = M.mode, url = M.url, child = M.child ~= nil,
    pending = M.pending, generation = M.generation, err = M.err,
    startedAt = M.startedAt, port = M.port, leases = M.leases,
  }
end

function M.state() return T.snapshot(M.raw(), M.now()) end

-- What makes two requests the same tunnel. Two jobs: deciding whether a running
-- child is still serving what the primary lease asks for, and deciding whether
-- a fatal still applies — a caller that fixed its request has acted, so the
-- ladder starts again instead of staying broken until a reload.
--
-- public_url is in the key because two of the fatals are about it: "named mode
-- needs a public hostname" has to stop being fatal the moment one arrives.
-- `bin` is not, because start() fills in the default and the lease keeps the
-- caller's nil, so a key that included it would never match itself and every
-- renewal would retry a tunnel that is supposed to have given up.
function M.reqKey(req)
  req = req or {}
  return table.concat({ tostring(req.mode), tostring(req.port),
                        tostring(req.name), tostring(req.public_url) }, "|")
end

-- ── The tile ───────────────────────────────────────────────────────────────
-- Everything that changes the tunnel ends here, so the glyph and the status
-- line never lag it: a child starting, a URL arriving, a probe giving up, a
-- fatal, a tunnel going away. The menu follows for free — it is a function, so
-- it is rebuilt from the state it finds at the moment it opens.
--
-- Most calls redraw what was already on screen. The ones that do not are
-- logged, because "when did it go red" is the first question asked about a
-- tunnel that stopped working.
function M.redraw()
  if not M.menu then return end
  local raw = M.raw()
  local key = T.tileKey(raw)
  if key ~= M.tileKey then
    M.tileKey, M.tileDraws = key, M.tileDraws + 1
    logf("[cloudflare] tile: %s", T.statusLine(raw, M.now()))
  end
  M.menu:setTitle(T.title(raw))
  M.menu:setTooltip(T.tooltip(raw, M.now()))
end

-- ── The child ──────────────────────────────────────────────────────────────
function M.goFatal(reason, req)
  M.fatal, M.err = true, reason
  -- A fatal raised by a running child carries no request, so the one it was
  -- started for stands in. Rebuilding it from M.mode/M.port/M.name here would
  -- drop public_url and make the key disagree with the one reconcile computes.
  M.fatalKey = M.reqKey(req or M.req)
  M.cancelPending()
  M.stopChild("fatal: " .. reason)
  M.url = nil
  logf("[cloudflare] fatal: %s", reason)
  M.redraw()
end

function M.stopChild(why)
  if not M.child then return end
  logf("[cloudflare] stopping cloudflared: %s", why or "no reason given")
  M.live = nil                      -- so the exit callback knows it was wanted
  if M.release then M.release() else M.child:terminate() end
  M.child, M.release = nil, nil
  M.url, M.startedAt = nil, nil
  M.misses = 0
end

function M.start(req)
  M.cancelPending()
  M.stopChild("starting a new one")

  req = T.normalize(req)
  req.bin = req.bin or T.DEFAULT_BIN
  req.binExists = M.binExists(req.bin)

  -- The two fatal cases that happen before the child runs: no binary, and
  -- `named` mode with nothing to name.
  local fatal = T.fatalReason(req)
  if fatal then return M.goFatal(fatal, req) end

  M.mode, M.port, M.name, M.req = req.mode, req.port, req.name, req
  M.err, M.misses = nil, 0

  if req.mode == "off" then
    -- Nothing to run: the caller already has a public URL and only wants this
    -- plugin to stop starting tunnels on its behalf.
    M.url = req.public_url
    return M.redraw()
  end

  M.generation = M.generation + 1
  M.startedAt = M.now()
  -- A named tunnel's hostname is known before it starts; a quick one's arrives
  -- on stdout, so it stays nil until the banner shows up.
  M.url = (req.mode == "named") and req.public_url or nil

  local cmd = T.command(req)
  local bin = table.remove(cmd, 1)
  M.token = M.token + 1
  local token = M.token
  M.live = token
  logf("[cloudflare] generation %d: %s %s", M.generation, bin, table.concat(cmd, " "))

  M.child, M.release = ctx:task(bin,
    function(code) M.onExit(token, code) end,
    function(_, out, errOut)
      M.onOutput((out or "") .. (errOut or ""))
      return true                   -- keep the stream open
    end,
    cmd)
  M.child:start()
  M.redraw()
end

-- Whatever cloudflared just printed. Classified before it is read for a URL: a
-- banner that also says the cert is missing is a missing cert, not a tunnel.
function M.onOutput(chunk)
  for _, line in ipairs(T.logLines(chunk)) do logf("[cloudflared] %s", line) end

  local kind, reason = T.classify(chunk)
  if kind == "fatal" then return M.goFatal(reason) end
  if kind == "rate_limit" then
    M.err = reason
    M.stopChild("rate limited")
    -- Starts further up the ladder than a normal failure: asking again in 30
    -- seconds spends the next quota for nothing.
    return M.retry(T.RATE_LIMIT_STEP)
  end

  if M.url and M.url ~= "" then return end
  local url = T.parseQuickUrl(chunk)
  if not url then return end
  M.url, M.err, M.step = url, nil, 0
  logf("[cloudflare] ready at %s (generation %d)", url, M.generation)
  M.redraw()
end

function M.onExit(token, code)
  if token ~= M.live then return end   -- a child we already replaced or stopped
  M.child, M.release, M.live = nil, nil, nil
  M.url, M.startedAt = nil, nil
  if M.fatal then return M.redraw() end
  if T.activeCount(M.leases, M.now()) == 0 then
    -- Nobody is waiting for it, so its exit is not a failure.
    return M.redraw()
  end
  M.err = string.format("cloudflared exited (%s)", tostring(code))
  logf("[cloudflare] %s", M.err)
  M.retry(M.step + 1)
end

-- ── Waiting ────────────────────────────────────────────────────────────────
function M.cancelPending()
  if M.pendingRelease then M.pendingRelease() end
  M.pending, M.pendingRelease, M.pendingTimer, M.pendingAt = nil, nil, nil, nil
end

function M.retry(step)
  M.cancelPending()
  M.step = math.min(math.max(step, 1), #T.BACKOFF)
  local wait = T.backoff(M.step)
  M.pendingAt = T.nextAttempt(M.now(), M.step)
  logf("[cloudflare] next attempt in %ds (step %d): %s", wait, M.step, tostring(M.err))
  M.pendingTimer, M.pendingRelease = ctx:after(wait, function()
    M.pending, M.pendingRelease, M.pendingTimer, M.pendingAt = nil, nil, nil, nil
    M.reconcile()
  end)
  M.pending = true
  M.redraw()
end

-- ── Reconciling ────────────────────────────────────────────────────────────
-- The one place that decides what the child should be doing. Everything else
-- changes a fact and calls this.
function M.reconcile()
  local now = M.now()
  for _, owner in ipairs(T.expire(M.leases, now)) do
    logf("[cloudflare] lease expired: %s", owner)
  end

  local req, owner = T.primary(M.leases, now)

  if not req then
    M.owner = nil
    if M.child then
      -- Grace, so a caller that is restarting does not lose its URL and spend
      -- another quick-tunnel quota coming back.
      M.idleSince = M.idleSince or now
      if (now - M.idleSince) >= T.GRACE_S then
        M.stopChild("no live lease")
        M.idleSince = nil
        M.mode, M.port, M.name, M.req, M.err = nil, nil, nil, nil, nil
      end
    else
      M.cancelPending()
      M.idleSince = nil
      M.mode, M.port, M.name, M.req = nil, nil, nil, nil
      M.url, M.err = nil, nil
      -- Everyone went away. A fatal is cleared with them, so the next owner to
      -- arrive gets one honest attempt rather than inheriting someone else's
      -- broken config.
      M.fatal, M.fatalKey, M.step = false, nil, 0
    end
    return M.redraw()
  end

  M.idleSince, M.owner = nil, owner

  if req.mode == "off" then
    if M.child then M.stopChild("the lease asked for off") end
    M.mode, M.port, M.url = "off", req.port, req.public_url
    M.fatal, M.fatalKey, M.err = false, nil, nil
    return M.redraw()
  end

  if M.fatal then
    if M.fatalKey == M.reqKey(req) then return M.redraw() end
    logf("[cloudflare] the request changed; trying again after a fatal")
    M.fatal, M.fatalKey, M.step = false, nil, 0
  end

  if M.child then
    -- Already serving. Restart only if the owner that is driving it now wants
    -- a different target.
    if M.reqKey(M.req) ~= M.reqKey(req) then
      logf("[cloudflare] %s changed the target; restarting", tostring(owner))
      return M.start(req)
    end
    return M.redraw()
  end

  if M.pending then return M.redraw() end   -- a backoff is already counting
  M.start(req)
end

-- ── The watchdog ───────────────────────────────────────────────────────────
-- Every 30s: drop dead leases, act on what is left, and check that the tunnel
-- still answers. This is also the renew period, so a lease TTL of 120s gives an
-- owner four ticks of slack.
function M.watch()
  local now = M.now()

  if M.child and not M.fatal and T.startTimedOut(M.startedAt, now, M.url) then
    M.err = string.format("cloudflared printed no URL in %ds", T.START_TIMEOUT_S)
    logf("[cloudflare] %s", M.err)
    M.stopChild("no URL in time")
    return M.retry(M.step + 1)
  end

  M.reconcile()
  if M.child and M.url and M.url ~= "" then M.probe() end
end

-- Does the tunnel still reach the origin its owner meant? The owner supplies
-- both halves of the answer: the voice agent's /phone/ping returns a token
-- chosen at daemon start, so a different daemon answering through the same
-- tunnel does not count as healthy.
function M.probe()
  local req = T.primary(M.leases, M.now())
  if not req or not req.probe_path then return end
  if not (hs.http and hs.http.asyncGet) then return end

  local gen = M.generation
  hs.http.asyncGet(M.url .. req.probe_path, nil, function(code, body)
    if gen ~= M.generation then return end    -- a different tunnel answered
    if code == 200 and T.probeOk(body, req.probe_expect) then
      M.misses = 0
      return
    end
    M.misses = M.misses + 1
    logf("[cloudflare] probe miss %d (http %s)", M.misses, tostring(code))
    if not T.probeFailed(M.misses) then return end
    M.err = "the tunnel stopped answering its own probe"
    M.stopChild("probe failed three times")
    M.retry(M.step + 1)
  end)
end

-- ── What the endpoints call ────────────────────────────────────────────────
-- lib/cloudflare_tunnel.route drives these three by name, so the routing can be
-- tested against a table of stubs with no Hammerspoon anywhere.
function M.lease(req)
  local now = M.now()
  T.expire(M.leases, now)

  local had = M.leases[req.owner]

  -- One child serves one origin. A second owner asking for a different port
  -- would otherwise be handed a URL that reaches somebody else's service, which
  -- is worse than being told no. Checked on every request and not just the
  -- first, because an owner that renews with a changed port is the same
  -- problem arriving a minute later. The owner driving the child is exempt:
  -- moving its own tunnel is what the restart below is for.
  local _, primaryOwner = T.primary(M.leases, now)
  if M.child and primaryOwner and primaryOwner ~= req.owner then
    local clash = T.conflict({ port = M.port, mode = M.mode }, req)
    if clash then
      logf("[cloudflare] refused %s: %s", tostring(req.owner), clash)
      local snap = M.state()
      snap.error, snap.code = clash, 409
      return snap
    end
  end

  M.seq = M.seq + 1
  M.leases[req.owner] = {
    expires = T.leaseExpiry(req, now),
    taken   = had and had.taken or M.seq,   -- renewing keeps your place in line
    req     = req,
  }
  if not had then logf("[cloudflare] lease taken by %s (%s:%s)",
                       tostring(req.owner), tostring(req.mode), tostring(req.port)) end

  M.reconcile()
  local snap = M.state()
  snap.code = M.fatal and 503 or 200
  return snap
end

function M.releaseLease(owner)
  if M.leases[owner] then
    M.leases[owner] = nil
    logf("[cloudflare] lease released by %s", tostring(owner))
  end
  M.reconcile()
  return M.state()
end

-- route() asks for `release`, but M.release already holds the child's teardown
-- closure. The endpoint target is its own small table so neither name has to
-- move.
M.endpoints = {
  lease   = function(req)   return M.lease(req) end,
  release = function(owner) return M.releaseLease(owner) end,
  state   = function()      return M.state() end,
}

-- ── Intake ─────────────────────────────────────────────────────────────────
-- Through the context, which both holds the server alive (an unreferenced
-- hs.httpserver is collected and silently stops listening) and gives :8795 back
-- when the plugin is switched off.
M.intake = ctx:httpserver(T.PORT, function(method, headers, path, body)
  -- hs.httpserver passes (method, path, headers, body) in some versions and
  -- (method, headers, path, body) in others; find the one that is a path.
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" then
    path, headers = headers, path
  end
  local ok, out, code, hdrs = pcall(T.route, M.endpoints, method, path, body)
  if not ok then
    logf("[cloudflare] request failed: %s", tostring(out))
    return T.encode({ error = tostring(out) }) .. "\n", 500,
           { ["Content-Type"] = "application/json" }
  end
  return out, code, hdrs
end)
logf("[cloudflare] intake listening on http://127.0.0.1:%d", T.PORT)

-- ── Shell and URL surface ──────────────────────────────────────────────────
ctx:global("tunnelState", function() return T.encodeState(M.state()) end)
ctx:global("tunnelRetry", function() M.retryNow() end)
ctx:url("tunnelRetry", function() M.retryNow() end)

-- The button for a fatal: the human acted, so the ladder starts again.
function M.retryNow()
  M.fatal, M.fatalKey, M.err, M.step, M.misses = false, nil, nil, 0, 0
  M.cancelPending()
  M.stopChild("asked to retry now")
  M.reconcile()
end

-- ── Menu ───────────────────────────────────────────────────────────────────
-- The clipboard, from the menu. Answers the URL it copied, so the console — and
-- a spec — can tell "copied" from "there was nothing to copy".
function M.copyUrl()
  local url = M.state().url
  if not url then return nil end
  if hs.pasteboard and hs.pasteboard.setContents then
    hs.pasteboard.setContents(url)
  end
  logf("[cloudflare] copied %s to the clipboard", url)
  return url
end

-- Rebuilt every time it opens, so it shows the tunnel as it is now rather than
-- as it was when the tile was last drawn.
function M.buildMenu()
  local now  = M.now()
  local raw  = M.raw()
  local snap = M.state()
  local items = {
    { title = T.statusLine(raw, now), disabled = true },
    { title = "-" },
    -- The URL gets a row of its own, readable without hovering the tile for a
    -- tooltip, and a Copy action next to it that does not move: both rows are
    -- always there, greyed when there is nothing behind them.
    { title = T.urlLine(snap), disabled = true },
    { title = "Copy URL", disabled = snap.url == nil,
      fn = function() M.copyUrl() end },
    { title = "-" },
  }

  local leases = snap.leases or {}
  if #leases == 0 then
    items[#items + 1] = { title = "No leases", disabled = true }
  else
    for _, l in ipairs(leases) do
      items[#items + 1] = { title = string.format("%s — %s left", l.owner,
                                                  T.humanDuration(l.expires_in)),
                            disabled = true }
    end
  end

  items[#items + 1] = { title = "-" }
  if M.pendingAt then
    items[#items + 1] = { title = string.format("Next attempt in %s",
                            T.humanDuration(M.pendingAt - now)), disabled = true }
  end
  items[#items + 1] = { title = "Retry now", fn = function() M.retryNow() end }
  items[#items + 1] = { title = "Open log",
                        fn = function() hs.execute("open " .. LOG) end }
  return items
end

-- ── init ───────────────────────────────────────────────────────────────────
M.menu = ctx:tile("Cloudflare tunnel")
if M.menu then M.menu:setMenu(M.buildMenu) end
M.redraw()

-- Nothing starts on a config reload: a tunnel exists because something leased
-- one, and the first tick notices if nothing has.
M.timer = ctx:timer(T.WATCH_S, function() M.watch() end)

-- Switch the plugin off: the port, the timer, the tile, the globals and the
-- cloudflared child, in one call.
function M.dispose() ctx:dispose() end

return M
