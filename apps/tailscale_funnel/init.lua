-- Tailscale Funnel — one public address for this Mac, leased by whoever needs
-- it, reachable at http://127.0.0.1:8795.
--
-- WHY THIS IS A PLUGIN AND NOT A PYTHON DAEMON'S PRIVATE BUSINESS.
-- The voice agent used to start its own cloudflared so WhatsApp had somewhere
-- to post webhooks. That worked until the agent restarted: every restart spent
-- another quick-tunnel quota and handed out a different hostname, so the
-- webhook had to be re-registered, and the app-level callback URL in Meta's
-- dashboard was dead from that moment on. A public address outlives the
-- process that wanted one, so it belongs to the config that is always running.
--
-- WHY FUNNEL AND NOT CLOUDFLARE. A Cloudflare tunnel with a fixed hostname
-- needs a domain whose nameservers point at Cloudflare. Funnel gives the same
-- thing — HTTPS on a real certificate, nothing listening on a public interface
-- — on a name this Mac already has, `<machine>.<tailnet>.ts.net`, for free.
-- The address is tied to the machine and the tailnet, not to a process, so a
-- daemon restart, a Hammerspoon reload and a reboot all leave it alone. That
-- is the whole point: set the webhook in Meta's dashboard once, never again.
--
-- WHAT IT SETS UP, AND WHAT IT CANNOT. Installing the client, signing this Mac
-- in and arming the funnel used to be eight numbered steps in a document, and
-- a tile that said "no tailscale CLI" and stopped there. The menu now carries
-- the checklist and does the steps it can actually finish: Homebrew installs
-- the standalone app, `tailscale up` starts the sign-in and the page it prints
-- is opened, the Tailscale app is launched when tailscaled is not answering,
-- and the funnel is armed. Four steps are somebody else's to finish — MagicDNS
-- and HTTPS certificates, the funnel node attribute, the voice agent's .env,
-- and Meta's callback URL — because each is a change to something that is not
-- this Mac, behind a login this plugin does not have. For those it opens the
-- right page with the right text already on the clipboard and says in one line
-- what is left. It never claims a step it cannot see: Meta's callback URL is
-- counted separately and never ticks itself.
--
-- WHAT THIS PLUGIN WILL NOT DO. It never arms the funnel by itself. Publishing
-- a port to the public internet is a decision a human makes, from this menu,
-- once — `tailscale funnel --bg` writes the route into tailscaled, so it
-- survives a reboot and there is nothing to re-arm. And it never turns the
-- funnel off when the last lease goes: the address surviving the voice agent
-- restarting is the entire reason this exists.
--
-- HOW A CALLER USES IT.
--   POST /lease   {"owner":"voice-agent","mode":"funnel","port":8794,
--                  "probe_path":"/phone/ping","probe_expect":"<token>"}
--   GET  /funnel  the same answer, without touching the lease (/tunnel too)
--   POST /release {"owner":"voice-agent"}
-- Every endpoint answers a GET with query parameters too, because
-- hs.httpserver rejects a bodyless POST with 400 before this callback ever
-- runs — the same trap apps/tts hit with /stop.
--
-- The answer is always the same shape, every key present:
--   {"status":"ready","url":"https://mac.tail1234.ts.net",
--    "hostname":"mac.tail1234.ts.net","generation":1,"error":null,
--    "uptime_s":182,"mode":"funnel","port":8794,"funnel":true,"leases":[...]}
-- `url` is null until the funnel is actually carrying the leased port, so a
-- caller is never handed an address that nothing answers on. `hostname` is
-- there as soon as this Mac is logged in, because that is the string a human
-- pastes into Meta's dashboard, armed or not.
--
-- A LEASE IS A HEARTBEAT, NOT A REGISTRATION. It expires 120s after the last
-- /lease, so an owner that crashed stops being counted. Nothing is torn down
-- for it.
--
-- WHAT THE TILE SHOWS. A status light: green while the funnel carries the
-- leased port, amber while the CLI is being asked, red otherwise — off and
-- broken both. The menu under it carries the status in words, the public
-- address on a row you can read, a Copy URL beside it, who holds a lease and
-- for how much longer, and the two buttons that matter: turn the funnel on or
-- off, and check again now.
--
-- All the logic worth asserting on lives in lib/tailscale_funnel, which has no
-- hs.* in it. This file is the CLI calls, the timer, the port and the tile.

local T     = require("lib.tailscale_funnel")
local utils = require("lib.utils")

local ctx = require("lib.context").new("Tailscale Funnel")

local LOG = "/tmp/hs-tailscale-funnel.log"

-- With no lease, nothing depends on the answer and a tile nobody is looking at
-- is not worth two processes every thirty seconds. Every tenth tick — five
-- minutes — keeps it from telling a lie for long.
local IDLE_EVERY = 10

local M = {
  leases     = {},    -- owner -> { expires, taken, req }
  binPath    = nil,   -- the tailscale CLI, found at run time
  candidates = T.BINS,
  brewPath   = nil,   -- Homebrew, which is how the CLI gets here when it is not

  -- A job this plugin started and is still waiting on, in words. Not an error
  -- and not a state: installing the client happens while `fatal` is true, and
  -- a red light under a progress line would be reporting the very thing the
  -- plugin is in the middle of fixing.
  busy       = nil,
  installing = false,
  signingIn  = false,
  authOpened = nil,   -- the sign-in page already opened, so it opens once

  -- What the last two read-only commands said. Observations only: nothing is
  -- decided here, so a stale one is a stale fact and not a stale decision.
  statusInfo = nil,   -- lib.parseStatus of `tailscale status --json`
  serveInfo  = nil,   -- lib.parseServe of `tailscale serve status --json`
  cliErr     = nil,   -- why the last command failed, in words

  -- What settle() derives from them.
  hostname   = nil,   -- <machine>.<tailnet>.ts.net
  url        = nil,   -- the public base URL, only while the funnel carries our port
  funnel     = false, -- the funnel is on and proxying something
  generation = 0,     -- bumped each time the funnel comes up, so a caller can spot it
  err        = nil,   -- the one line the tile and the callers see
  fatal      = false, -- a human has to act; the next tick says so again
  mode       = nil,
  port       = nil,
  owner      = nil,   -- whose lease is currently naming the port
  startedAt  = nil,   -- when the funnel was first seen up

  pending    = nil,   -- a CLI call is in flight
  misses     = 0,     -- consecutive probe failures
  seq        = 0,     -- lease arrival order, so `primary` is stable
  ticks      = 0,     -- watchdog rounds, for the idle poll
  wasUp      = false, -- the previous funnel reading, to spot the transition
  menu       = nil,
  intake     = nil,
  timer      = nil,
  tileKey    = nil,   -- what the tile last drew, so a real change is spottable
  tileDraws  = 0,     -- how many times that has actually changed
  runs       = {},    -- the argument lists run so far, for the log and for specs
  brewRuns   = {},    -- the same for Homebrew, which is a different binary
  opened     = {},    -- the pages handed to the browser, for the log and for specs
  scripts    = {},    -- the AppleScripts run, same reason
  launched   = {},    -- the apps asked for, same reason
  copied     = nil,   -- what last went on the clipboard
}

-- Seams. A spec drives the clock and the filesystem rather than waiting on
-- them, and neither is worth a mock of its own.
function M.now() return os.time() end

function M.exists(path)
  if not (hs.fs and hs.fs.attributes) then return false end
  return hs.fs.attributes(path) ~= nil
end

local function logf(fmt, ...) utils.logf(LOG, fmt, ...) end

local function firstLine(text)
  local line = tostring(text or ""):match("[^\r\n]+")
  return line and line:gsub("^%s+", ""):gsub("%s+$", "") or "no output"
end

-- ── State ──────────────────────────────────────────────────────────────────
-- The shape lib/tailscale_funnel reads.
function M.raw()
  return {
    fatal = M.fatal, mode = M.mode, url = M.url, hostname = M.hostname,
    funnel = M.funnel, pending = M.pending, generation = M.generation,
    err = M.err, startedAt = M.startedAt, port = M.port, leases = M.leases,
    busy = M.busy,
  }
end

function M.state() return T.snapshot(M.raw(), M.now()) end

-- What makes two lease requests the same job, so a renewal that changed
-- nothing does not spend two processes re-reading what is already known.
function M.reqKey(req)
  req = req or {}
  return table.concat({ tostring(req.mode), tostring(req.port),
                        tostring(req.public_url), tostring(req.probe_path) }, "|")
end

-- Is anything actually waiting on a funnel? Decides whether a missing CLI is
-- worth a red tile: a config that never leases one should not be told off for
-- not having Tailscale installed.
function M.wanted()
  local req = T.primary(M.leases, M.now())
  return req ~= nil and req.mode == "funnel"
end

-- ── The tile ───────────────────────────────────────────────────────────────
-- Everything that changes the funnel ends here, so the glyph and the status
-- line never lag it. The menu follows for free — it is a function, so it is
-- rebuilt from the state it finds at the moment it opens.
--
-- Most calls redraw what was already on screen. The ones that do not are
-- logged, because "when did it go red" is the first question asked about an
-- address that stopped working.
function M.redraw()
  if not M.menu then return end
  local raw = M.raw()
  local key = T.tileKey(raw)
  if key ~= M.tileKey then
    M.tileKey, M.tileDraws = key, M.tileDraws + 1
    logf("[funnel] tile: %s", T.statusLine(raw, M.now()))
  end
  M.menu:setTitle(T.title(raw))
  M.menu:setTooltip(T.tooltip(raw, M.now()))
end

-- ── Deciding ───────────────────────────────────────────────────────────────
-- The one place that turns the observations into what the tile shows and what
-- a caller is told. Called after every CLI answer, every lease and every
-- probe, so a condition a human fixed clears itself on the next round instead
-- of waiting for somebody to press Retry.
function M.settle()
  local now = M.now()
  -- A sign-in that landed while `tailscale up` is still finishing. The read is
  -- the authority on whether this Mac is in a tailnet, so the moment it says
  -- Running the plugin stops saying "waiting for you".
  if M.signingIn and M.statusInfo and M.statusInfo.backend == "Running" then
    M.signingIn, M.busy = false, nil
  end
  local req, owner = T.primary(M.leases, now)
  M.owner = owner
  M.mode  = req and req.mode or nil
  M.port  = (req and req.mode == "funnel") and req.port or nil
  if M.statusInfo then M.hostname = M.statusInfo.hostname end

  -- An `off` lease means its owner has a public URL of its own and wants this
  -- plugin to be a noticeboard and nothing else.
  if M.mode == "off" then
    M.url, M.fatal, M.err = req.public_url, false, nil
    return M.redraw()
  end

  local up = (M.serveInfo and M.serveInfo.on) == true
  if up ~= M.wasUp then
    if up then
      M.generation, M.startedAt, M.misses = M.generation + 1, now, 0
      logf("[funnel] on at %s carrying %s (generation %d)",
           tostring(T.hostUrl(M.serveInfo.host) or T.hostUrl(M.hostname)),
           tostring(M.serveInfo.target), M.generation)
    else
      M.startedAt = nil
      logf("[funnel] off")
    end
    M.wasUp = up
  end
  M.funnel = up

  local live = up and (T.hostUrl(M.serveInfo.host) or T.hostUrl(M.hostname)) or nil

  local problem = (not M.binPath and M.wanted() and T.NOT_INSTALLED)
               or M.cliErr
               or (M.statusInfo and T.statusProblem(M.statusInfo))
               or T.portProblem(M.serveInfo, M.port)
               or (up and T.probeFailed(M.misses) and T.PROBE_DEAD)
               or nil

  if problem then
    M.fatal, M.err = true, problem
    -- The address still exists when the only complaint is that it stopped
    -- answering, and the probe has to keep running to notice it come back.
    -- Every other fault means there is no usable address, so there is none.
    M.url = (problem == T.PROBE_DEAD) and live or nil
    return M.redraw()
  end

  M.fatal = false
  M.url = live
  -- Not a fault, but the caller still needs to be told why there is no URL.
  M.err = (not up and req) and T.FUNNEL_OFF or nil
  M.redraw()
end

-- ── Running the CLI ────────────────────────────────────────────────────────
-- One short-lived child per call, released as it finishes: a context that kept
-- a handle for every `tailscale status` since the config loaded would grow a
-- teardown list for the life of the session.
--
-- `stream` is for the one command that answers before it exits: `tailscale up`
-- prints the sign-in URL and then waits for a human to visit it, so reading it
-- only on exit would mean opening the page after it was no longer needed.
function M.run(args, done, stream)
  local bin = M.binPath
  if not bin then return done(nil, "") end
  M.runs[#M.runs + 1] = args
  local task, release
  local function finished(code, out, errOut)
    if release then release() end
    local text = (out or "") .. (errOut or "")
    if code ~= 0 then logf("[tailscale] %s -> %s: %s", args[1], tostring(code), firstLine(text)) end
    done(code, text)
  end
  if stream then
    task, release = ctx:task(bin, finished, stream, args)
  else
    task, release = ctx:task(bin, finished, args)
  end
  M.task = task
  task:start()
  return task
end

-- Homebrew is a different binary in a different place with a different
-- environment, so it gets its own runner rather than a flag on M.run. Keeping
-- its calls out of M.runs also keeps "what did this plugin ask tailscale" a
-- question with an unambiguous answer.
function M.brew(args, done)
  if not M.brewPath then return done(nil, "") end
  M.brewRuns[#M.brewRuns + 1] = args
  local task, release
  task, release = ctx:task(M.brewPath, function(code, out, errOut)
    if release then release() end
    done(code, (out or "") .. (errOut or ""))
  end, args)
  M.brewTask = task
  if task.setEnvironment then task:setEnvironment(T.brewEnv(os.getenv("HOME"))) end
  task:start()
  return task
end

-- Both binaries, because "is Tailscale here" and "is there anything that could
-- put it here" are asked at the same moment and neither costs a process.
function M.findBinary()
  M.binPath  = T.findBin(M.exists, M.candidates)
  M.brewPath = T.findBin(M.exists, T.BREWS)
  return M.binPath
end

-- The two read-only commands, in order: who this Mac is, then what it is
-- serving. Nothing here publishes anything.
function M.ask(after)
  local function finish()
    M.pending = nil
    M.settle()
    if after then after() end
  end

  if M.pending then return after and after() end
  if not M.findBinary() then return finish() end

  M.pending, M.cliErr = true, nil
  M.redraw()

  M.run(T.statusCommand(), function(code, out)
    local info = T.parseStatus(out)
    if code ~= 0 or not info then
      local _, why = T.classify(out)
      M.statusInfo, M.cliErr = nil, why or T.NO_STATUS
      return finish()
    end
    M.statusInfo = info

    M.run(T.serveCommand(), function(_, serveOut)
      local _, why = T.classify(serveOut)
      if why then
        M.cliErr = why
      else
        -- A client with nothing published says so with an exit code as often
        -- as with a body, so the code is not read: an empty answer is "off".
        M.serveInfo = T.parseServe(serveOut)
      end
      finish()
    end)
  end)
end

-- ── Arming it ──────────────────────────────────────────────────────────────
-- The only two commands here that change anything, and both are human-driven.
function M.turnOn()
  local req = T.primary(M.leases, M.now())
  local port = (req and req.mode == "funnel" and req.port) or M.port
  if not port then
    M.cliErr = "nothing has leased a port for the funnel to carry"
    return M.settle()
  end
  if not M.findBinary() then
    M.cliErr = T.NOT_INSTALLED
    return M.settle()
  end
  M.pending = true
  M.redraw()
  M.run(T.onCommand(port), function(code, out)
    M.pending = nil
    if code ~= 0 then
      local _, why = T.classify(out)
      M.cliErr = why or ("tailscale funnel refused: " .. firstLine(out))
      return M.settle()
    end
    M.cliErr = nil
    logf("[funnel] armed for port %d", port)
    M.ask()        -- read back what tailscaled now holds rather than assume it
  end)
end

function M.turnOff()
  if not M.findBinary() then
    M.cliErr = T.NOT_INSTALLED
    return M.settle()
  end
  M.pending = true
  M.redraw()
  M.run(T.offCommand(), function(code, out)
    M.pending = nil
    if code ~= 0 then
      local _, why = T.classify(out)
      M.cliErr = why or ("tailscale funnel refused: " .. firstLine(out))
      return M.settle()
    end
    M.cliErr = nil
    logf("[funnel] turned off by hand")
    M.ask()
  end)
end

-- ── Getting Tailscale onto this Mac ────────────────────────────────────────
-- Everything above here assumed a Mac that was already installed, signed in
-- and allowed. This is the part that gets it there, and the rule it keeps is
-- the same one the funnel keeps: the plugin does every step it can actually
-- finish, and for the rest it opens the right page with the right text already
-- on the clipboard and says, in one line, what is left for a person.
--
-- Three seams, so a spec can watch what was opened, run and copied without a
-- browser, a Terminal or a pasteboard.
function M.openUrl(url)
  M.opened[#M.opened + 1] = url
  if hs.urlevent and hs.urlevent.openURL then hs.urlevent.openURL(url) end
  return url
end

function M.copy(text)
  M.copied = text
  if hs.pasteboard and hs.pasteboard.setContents then hs.pasteboard.setContents(text) end
  return text
end

function M.runScript(script)
  M.scripts[#M.scripts + 1] = script
  if not (hs.osascript and hs.osascript.applescript) then return false end
  local ok, _, err = hs.osascript.applescript(script)
  if not ok then logf("[install] Terminal refused it: %s", tostring(err)) end
  return ok
end

-- How long to keep looking for a binary somebody else's process is installing.
-- Five minutes is longer than the download and shorter than giving up matters.
M.INSTALL_POLL_S = 5
M.INSTALL_TRIES  = 60

-- Installing. One click when Homebrew is here, one page when it is not.
function M.install()
  if M.findBinary() then return M.settle() end
  if M.installing then return end

  if not M.brewPath then
    -- Nothing here can drive an install, and bootstrapping Homebrew is a
    -- bigger decision than a menu bar tile gets to make on someone's behalf.
    -- The download page is as far as this goes, and it says so.
    M.openUrl(T.DOWNLOAD_URL)
    M.cliErr = T.NO_BREW
    return M.settle()
  end

  M.installing, M.busy, M.cliErr = true, T.INSTALLING, nil
  M.redraw()
  logf("[install] %s", T.installLine(M.brewPath))

  M.brew(T.installCommand(), function(code, out)
    M.installing = false
    if M.findBinary() then
      M.busy, M.cliErr = nil, nil
      logf("[install] tailscale landed at %s", M.binPath)
      return M.ask()
    end

    -- The cask is a .pkg, so Homebrew shells out to `sudo installer`, and a
    -- menu bar plugin has no terminal for sudo to ask a password on. That is
    -- not a dead end: the same line in a Terminal window is one, the human
    -- types one password, and the binary turning up finishes the job from
    -- here either way.
    if T.needsPassword(out) then
      M.runScript(T.terminalScript(T.installLine(M.brewPath)))
      M.busy, M.cliErr = T.INSTALL_TERMINAL, nil
      M.settle()
      return M.awaitBinary()
    end

    M.busy = nil
    M.cliErr = T.installProblem(out)
                 or (code == 0 and T.INSTALL_LOST)
                 or ("Homebrew refused: " .. firstLine(out))
    logf("[install] failed: %s", M.cliErr)
    M.settle()
  end)
end

-- Waiting on an install that is happening in somebody else's process. There is
-- no child to watch and no exit code to read, so the only honest signal is the
-- binary appearing, and the only thing to do is keep looking for a while.
function M.awaitBinary(tries)
  tries = tries or M.INSTALL_TRIES
  if M.findBinary() then
    M.busy, M.cliErr = nil, nil
    logf("[install] tailscale landed at %s", M.binPath)
    return M.ask()
  end
  if tries <= 1 then
    M.busy, M.cliErr = nil, T.INSTALL_LOST
    return M.settle()
  end
  ctx:after(M.INSTALL_POLL_S, function() M.awaitBinary(tries - 1) end)
end

-- Opens the page `tailscale up` is waiting on, once per URL. The command
-- reprints it while it waits, and a browser tab per reprint is not help.
function M.openAuth(text)
  local url = T.authUrl(text)
  if not url or url == M.authOpened then return nil end
  M.authOpened = url
  M.busy = T.SIGNIN_OPENED
  logf("[signin] %s", url)
  M.openUrl(url)
  M.redraw()
  return url
end

-- Signing in. The plugin starts it, catches the URL off the stream and opens
-- it; which account to use and the password for it are not things a config
-- holds. `tailscale up` does not exit until the human is done, so this runs on
-- its own flag and never on M.pending — the watchdog has to keep reading
-- status while it waits, because that read is what notices the sign-in landed.
function M.signIn()
  if not M.findBinary() then
    M.cliErr = T.NOT_INSTALLED
    return M.settle()
  end
  if M.signingIn then return end

  -- A sign-in somebody walked away from leaves its page in `tailscale status`.
  -- Reopening that beats starting a second `tailscale up`, which would hand
  -- out a different URL and leave the first one dangling.
  local pending = M.statusInfo and M.statusInfo.authUrl

  M.signingIn, M.busy, M.cliErr, M.authOpened = true, T.SIGNING_IN, nil, nil
  M.redraw()
  if pending then M.openAuth(pending) end

  M.run(T.loginCommand(), function(code, out)
    M.signingIn, M.busy = false, nil
    if code ~= 0 then
      local _, why = T.classify(out)
      M.cliErr = why or ("tailscale up refused: " .. firstLine(out))
      return M.settle()
    end
    M.cliErr = nil
    logf("[signin] this Mac is signed in")
    M.ask()
  end, function(_, out, errOut)
    M.openAuth((out or "") .. (errOut or ""))
    return true              -- keep reading: it runs until a human is finished
  end)
end

-- tailscaled not answering is usually the app not being open, and opening an
-- app is something a plugin can just do.
function M.openApp()
  M.launched[#M.launched + 1] = "Tailscale"
  if hs.application and hs.application.launchOrFocus then
    hs.application.launchOrFocus("Tailscale")
  end
  logf("[funnel] opened the Tailscale app")
  M.ask()
end

-- ── The three a person finishes ────────────────────────────────────────────
-- MagicDNS, the funnel node attribute and Meta's callback URL are all changes
-- to something that is not this Mac, behind a login this plugin does not have.
-- What it can do is make each of them a paste instead of a transcription.
function M.openAdminDns()  return M.openUrl(T.ADMIN_DNS_URL) end
function M.openMachines()  return M.openUrl(T.ADMIN_MACHINES_URL) end

function M.grantFunnel()
  M.copy(T.POLICY_SNIPPET)
  logf("[funnel] policy snippet copied; opening the policy file")
  return M.openUrl(T.ADMIN_ACL_URL)
end

function M.copyEnv()
  local lines = T.envLines(M.hostname)
  M.copy(lines)
  logf("[funnel] copied the voice agent's settings")
  return lines
end

-- No page is opened for this one. The place a human actually has to be is
-- inside one Meta app's WhatsApp configuration, and the plugin knows neither
-- the app nor the login, so a tab on a generic app list would be noise.
function M.copyWebhook()
  local url = T.webhookUrl(M.hostname)
  if not url then return nil end
  M.copy(url)
  logf("[funnel] copied %s", url)
  return url
end

-- ── The checklist ──────────────────────────────────────────────────────────
-- What the plugin knows right now, in the shape lib/tailscale_funnel reads.
function M.env()
  return {
    bin = M.binPath, brew = M.brewPath, status = M.statusInfo,
    hostname = M.hostname, port = M.port, funnel = M.funnel, url = M.url,
    installing = M.installing, signingIn = M.signingIn, busy = M.busy,
  }
end

-- Two stats before every answer, because nothing is timing them and a client
-- a human installed by hand between two ticks should be noticed the moment the
-- menu is opened rather than on the next watchdog round. A client that did turn
-- up changes what the rows above the checklist say as well, and settle is the
-- only thing that decides those.
function M.setup()
  local was = M.binPath
  M.findBinary()
  if was ~= M.binPath then M.settle() end
  return T.setupSteps(M.env())
end

-- A step names its action; this is the only place that knows what the name
-- means. Declared after every one of them, because a Lua table literal reads
-- the values as it is built.
M.ACTIONS = {
  install       = function() M.install() end,
  openapp       = function() M.openApp() end,
  signin        = function() M.signIn() end,
  check         = function() M.ask() end,
  admindns      = function() M.openAdminDns() end,
  adminmachines = function() M.openMachines() end,
  adminacl      = function() M.grantFunnel() end,
  copyenv       = function() M.copyEnv() end,
  arm           = function() M.turnOn() end,
  copyhook      = function() M.copyWebhook() end,
}

-- ── The watchdog ───────────────────────────────────────────────────────────
-- Every 30s: drop dead leases, re-read the truth from the CLI, and check that
-- the funnel still reaches the origin. This is also the renew period, so a
-- lease TTL of 120s gives an owner four ticks of slack.
function M.watch()
  M.ticks = M.ticks + 1
  for _, owner in ipairs(T.expire(M.leases, M.now())) do
    logf("[funnel] lease expired: %s", owner)
  end

  local req = T.primary(M.leases, M.now())
  if req and req.mode == "off" then return M.settle() end
  if not req and (M.ticks % IDLE_EVERY) ~= 0 then return M.settle() end

  M.ask(function()
    if M.funnel and M.url then M.probe() end
  end)
end

-- Does the funnel still reach the origin its owner meant? The owner supplies
-- both halves of the answer: the voice agent's /phone/ping returns a token
-- chosen at daemon start, so a different daemon answering through the same
-- funnel does not count as healthy.
--
-- Three misses make the tile red and tell the caller. Nothing is restarted for
-- it: there is no child to replace, and re-running `tailscale funnel` would
-- write the route tailscaled already holds. An answer clears it again.
function M.probe()
  local req = T.primary(M.leases, M.now())
  if not req or not req.probe_path or not M.url then return end
  if not (hs.http and hs.http.asyncGet) then return end

  local gen = M.generation
  hs.http.asyncGet(M.url .. req.probe_path, nil, function(code, body)
    if gen ~= M.generation then return end     -- a different funnel answered
    if code == 200 and T.probeOk(body, req.probe_expect) then
      if M.misses > 0 then logf("[funnel] %s answers again", M.url) end
      M.misses = 0
      return M.settle()
    end
    M.misses = M.misses + 1
    logf("[funnel] probe miss %d (http %s)", M.misses, tostring(code))
    M.settle()
  end)
end

-- ── What the endpoints call ────────────────────────────────────────────────
-- lib/tailscale_funnel.route drives these three by name, so the routing can be
-- tested against a table of stubs with no Hammerspoon anywhere.
function M.lease(req)
  local now = M.now()
  T.expire(M.leases, now)

  local had = M.leases[req.owner]

  -- One funnel serves one origin. A second owner asking for a different port
  -- would otherwise be handed a URL that reaches somebody else's service,
  -- which is worse than being told no. Checked on every request and not just
  -- the first, because an owner that renews with a changed port is the same
  -- problem arriving a minute later. The owner naming the port is exempt.
  local _, primaryOwner = T.primary(M.leases, now)
  if primaryOwner and primaryOwner ~= req.owner then
    local clash = T.conflict({ port = M.port, mode = M.mode }, req)
    if clash then
      logf("[funnel] refused %s: %s", tostring(req.owner), clash)
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
  local fresh = not had or M.reqKey(had.req) ~= M.reqKey(req)
  if not had then
    logf("[funnel] lease taken by %s (%s:%s)",
         tostring(req.owner), tostring(req.mode), tostring(req.port))
  end

  M.settle()
  -- A renewal that asked for the same thing is answered from what the watchdog
  -- already knows; only a new or changed lease is worth asking the CLI again.
  if fresh and req.mode == "funnel" then M.ask() end

  local snap = M.state()
  snap.code = M.fatal and 503 or 200
  return snap
end

function M.releaseLease(owner)
  if M.leases[owner] then
    M.leases[owner] = nil
    logf("[funnel] lease released by %s", tostring(owner))
  end
  M.settle()
  return M.state()
end

M.endpoints = {
  lease   = function(req)   return M.lease(req) end,
  release = function(owner) return M.releaseLease(owner) end,
  state   = function()      return M.state() end,
}

-- ── Intake ─────────────────────────────────────────────────────────────────
-- Through the context, which both holds the server alive (an unreferenced
-- hs.httpserver is collected and silently stops listening) and gives :8795
-- back when the plugin is switched off.
M.intake = ctx:httpserver(T.PORT, function(method, headers, path, body)
  -- hs.httpserver passes (method, path, headers, body) in some versions and
  -- (method, headers, path, body) in others; find the one that is a path.
  if type(path) ~= "string" or path:sub(1, 1) ~= "/" then
    path, headers = headers, path
  end
  local ok, out, code, hdrs = pcall(T.route, M.endpoints, method, path, body)
  if not ok then
    logf("[funnel] request failed: %s", tostring(out))
    return T.encode({ error = tostring(out) }) .. "\n", 500,
           { ["Content-Type"] = "application/json" }
  end
  return out, code, hdrs
end)
logf("[funnel] intake listening on http://127.0.0.1:%d", T.PORT)

-- ── Shell and URL surface ──────────────────────────────────────────────────
ctx:global("funnelState", function() return T.encodeState(M.state()) end)
ctx:global("funnelCheck", function() M.ask() end)
ctx:global("funnelOn",    function() M.turnOn() end)
ctx:global("funnelOff",   function() M.turnOff() end)
ctx:global("funnelInstall", function() M.install() end)
ctx:global("funnelSignIn",  function() M.signIn() end)

-- The checklist as lines rather than JSON, because the thing a shell does with
-- it is read it: `hs -c 'funnelSetup()'` is the same answer the menu gives.
ctx:global("funnelSetup", function()
  local steps = M.setup()
  local out = { T.setupLine(steps) }
  for _, step in ipairs(steps) do
    out[#out + 1] = T.stepLine(step)
    if step.detail then out[#out + 1] = "        " .. step.detail end
  end
  return table.concat(out, "\n") .. "\n"
end)

ctx:url("funnelCheck", function() M.ask() end)

-- ── Menu ───────────────────────────────────────────────────────────────────
-- The clipboard, from the menu. Answers the URL it copied, so the console —
-- and a spec — can tell "copied" from "there was nothing to copy".
function M.copyUrl()
  local url = T.copyable(M.raw())
  if not url then return nil end
  M.copy(url)
  logf("[funnel] copied %s to the clipboard", url)
  return url
end

-- One row per prerequisite, and a second greyed row under the ones that are
-- not finished saying who finishes them. A step the plugin can act on is the
-- button for its own action, so the checklist is also the thing that works it
-- through rather than a list to read and then go elsewhere.
function M.setupMenu(steps)
  local items = {}
  for _, step in ipairs(steps or M.setup()) do
    local act = step.action and M.ACTIONS[step.action] or nil
    items[#items + 1] = { title = T.stepLine(step), disabled = act == nil, fn = act }
    if step.detail then
      items[#items + 1] = { title = "        " .. step.detail, disabled = true }
    end
  end
  return items
end

-- Rebuilt every time it opens, so it shows the funnel as it is now rather than
-- as it was when the tile was last drawn.
function M.buildMenu()
  -- The checklist first: reading it is what re-finds the binaries, and every
  -- row below has to agree with what it found.
  local steps = M.setup()
  local now  = M.now()
  local raw  = M.raw()
  local snap = M.state()
  local items = {
    { title = T.statusLine(raw, now), disabled = true },
    { title = "-" },
    -- The address gets a row of its own, readable without hovering the tile
    -- for a tooltip, and a Copy action next to it that does not move: both
    -- rows are always there, greyed when there is nothing behind them.
    { title = T.urlLine(raw), disabled = true },
    { title = "Copy URL", disabled = T.copyable(raw) == nil,
      fn = function() M.copyUrl() end },
    { title = "-" },
  }

  -- The checklist, and under it the one thing to do next as a button. Which is
  -- the whole point: "install Tailscale" was a paragraph in a report nobody
  -- had open, and it is now a row that says what it will do and does it.
  items[#items + 1] = { title = T.setupLine(steps), menu = M.setupMenu(steps) }
  local nextStep = T.nextStep(steps)
  -- Two of the actions already have a row of their own further down, and the
  -- same row twice in one menu is worse than no shortcut at all.
  if nextStep and nextStep.action and not T.MENU_ACTIONS[nextStep.action] then
    items[#items + 1] = { title = T.ACTION_LABEL[nextStep.action],
                          fn = M.ACTIONS[nextStep.action] }
  end
  items[#items + 1] = { title = "-" }

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
  if M.funnel then
    items[#items + 1] = { title = "Turn the funnel off", fn = function() M.turnOff() end }
  else
    -- Greyed with nothing to carry: arming a funnel at a port no one serves
    -- publishes a name that answers 502.
    items[#items + 1] = { title = "Turn the funnel on",
                          disabled = M.port == nil,
                          fn = function() M.turnOn() end }
  end
  items[#items + 1] = { title = "Check now", fn = function() M.ask() end }
  items[#items + 1] = { title = "Open log",
                        fn = function() hs.execute("open " .. LOG) end }
  return items
end

-- ── init ───────────────────────────────────────────────────────────────────
M.menu = ctx:tile("Tailscale Funnel")
if M.menu then M.menu:setMenu(M.buildMenu) end
M.findBinary()
M.redraw()

-- Nothing is published on a config reload: the funnel is either already
-- written into tailscaled or it is not, and the first tick reads which.
M.timer = ctx:timer(T.WATCH_S, function() M.watch() end)

-- Switch the plugin off: the port, the timer, the tile, the globals and any
-- CLI call still in flight, in one call. The funnel itself stays up, because
-- it belongs to tailscaled and not to this config.
function M.dispose() ctx:dispose() end

return M
