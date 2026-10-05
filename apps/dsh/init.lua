-- DeepSeek Harness — start, stop and restart the web profile's server, and open
-- its browser UI, from the hub.
--
-- The server is a plain node process that holds one port. It runs detached
-- from Hammerspoon (lib/dsh.detachCmd), so a reload, a restart or a Hammerspoon
-- crash leaves it serving; as an hs.task child it went down with every reload.
-- The tile never holds a handle to it. Stop is a SIGTERM to whatever listens on
-- the port (lib/dsh.killCmd), which node shuts down cleanly on, and every start
-- frees the port first, so a server started in a terminal does not collide.
-- "Is it up?" is answered by asking the address — a 15 s HTTP poll, which is
-- also what notices a server that died on its own.
--
-- Nothing starts on a config reload. The Server switch and "Open the web UI"
-- are the only things that turn it on, and a server that is already up is
-- picked up again by the first poll, its address read back from SERVER_LOG.
--
-- Every timer, task and tile below belongs to this plugin's context, so
-- M.dispose() takes the tile and the poll away. It leaves the server running:
-- its lifetime is the user's call, not Hammerspoon's.

local D     = require("lib.dsh")
local utils = require("lib.utils")

local ctx = require("lib.context").new("DSH")

local M = {
  menu    = nil,
  running = false,   -- is something answering on the port?
  url     = nil,     -- the address the server reported on stdout
  host    = D.DEFAULT_HOST,
  port    = D.DEFAULT_PORT,
  busy    = nil,     -- one-line "Starting…" while the server moves
  launch  = 0,       -- bumped per start, so a stale start timeout stands down
  booting = false,   -- a start is waiting for the port to answer
  fast    = nil,     -- release() for the quick poll that runs while booting
  spawn   = nil,     -- the detaching shell, held so it is not collected
  kill    = nil,     -- the port-freeing shell, held so it is not collected
  timer   = nil,
  open    = false,   -- open a browser as soon as the server answers
}

local HOME    = os.getenv("HOME")
local LOG     = "/tmp/hs-dsh.log"
-- The detached server's own stdout and stderr, truncated per launch.
local SERVER_LOG = "/tmp/hs-dsh-server.log"
local PROFILE = "web"

local POLL_SECS = 15
-- While booting, look every second so the tile flips the moment the port opens.
local FAST_SECS = 1
-- A boot that never announces an address would otherwise leave the tile busy
-- for good, with the Server switch dead behind it. A cold boot has taken 20 s,
-- so this is only ever reached by a start that has gone wrong.
local START_TIMEOUT = 45
-- A start that never answers should not leave a browser window waiting to open
-- on the next one. Longer than START_TIMEOUT, so a slow start that does come up
-- still opens the UI that was asked for.
local OPEN_TIMEOUT = 50

local ENV = {
  HOME = HOME,
  PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
}

-- `dsh` is a node script behind `#!/usr/bin/env node`, so it is found the same
-- way a shell would find it rather than by asking npm where it installed.
local CANDIDATES = {
  "/opt/homebrew/bin/dsh",
  "/usr/local/bin/dsh",
  HOME .. "/.local/bin/dsh",
}

local function dshBin()
  for _, p in ipairs(CANDIDATES) do
    if hs.fs.attributes(p) then return p end
  end
end

local function logf(fmt, ...) utils.logf(LOG, fmt, ...) end

-- The address the running server announced, from its output file.
local function readAddress()
  return D.addressFrom(utils.readFile(SERVER_LOG))
end

-- ── State ──────────────────────────────────────────────────────────────────
local function state()
  return { running = M.running, busy = M.busy,
           url = M.url, host = M.host, port = M.port }
end

local function redraw()
  if not M.menu then return end
  M.menu:setTitle(D.title(state()))
  M.menu:setTooltip(D.tooltip(state()))
end

local function setBusy(msg)
  M.busy = msg
  redraw()
end

local function openNow()
  M.open = false
  -- The port can answer a beat before the address line is written.
  if not M.url then M.url = readAddress() end
  hs.urlevent.openURL(D.url(state()))
end

local function notifyStopped()
  hs.notify.new({ title = "DeepSeek Harness",
                  subTitle = "The web server stopped",
                  informativeText = "See " .. SERVER_LOG }):send()
end

function M.poll()
  hs.http.asyncGet(D.url(state()), nil, function(status)
    -- Any status at all means something answered; a refused connection comes
    -- back negative.
    local up = (status or -1) > 0
    local was = M.running
    if up ~= was then logf("server %s", up and "up" or "down") end
    M.running = up
    if up then
      -- A starting server announces its address a moment after it binds, and
      -- one found up after a reload has never been seen by this tile at all.
      if not M.url then M.url = readAddress() end
      if M.booting then
        M.booting = false
        if M.fast then M.fast(); M.fast = nil end
        M.busy = nil
        logf("serving %s", D.url(state()))
      end
    else
      M.url = nil
      -- Down without anyone asking: it crashed or was killed elsewhere.
      if was and not M.busy then notifyStopped() end
    end
    redraw()
    if up and M.open then openNow() end
  end)
end

-- A start reports done before the port is listening, so look again after.
local function settle()
  M.poll()
  ctx:after(1.5, M.poll)
  ctx:after(4, M.poll)
end

-- ── Actions ────────────────────────────────────────────────────────────────
-- The shell backgrounds the server and exits at once, so its exit says nothing
-- about the server; the polls in settle() and the address in SERVER_LOG do.
local function launch()
  local bin = dshBin()
  if not bin then setBusy(nil); return end

  M.launch = M.launch + 1
  local id = M.launch
  M.url, M.booting = nil, true

  local spawn, done
  spawn, done = ctx:task("/bin/sh", function()
    done()
    M.spawn = nil
    if M.launch ~= id then return end
    if M.fast then M.fast() end
    local _, release = ctx:timer(FAST_SECS, function() M.poll() end)
    M.fast = release
  end, { "-c", D.detachCmd(bin, D.args(PROFILE, M.port), SERVER_LOG) })
  M.spawn = spawn
  spawn:setEnvironment(ENV)
  spawn:start()
  logf("launching %s --profile %s --port %d (detached, output in %s)",
       bin, PROFILE, M.port, SERVER_LOG)

  ctx:after(START_TIMEOUT, function()
    if M.launch ~= id or not M.booting then return end
    M.booting = false
    if M.fast then M.fast(); M.fast = nil end
    setBusy(nil)
    logf("no answer after %ds — %s has what the server is doing",
         START_TIMEOUT, SERVER_LOG)
  end)
end

-- Kill whatever is holding the port, then run `after`. Everything that starts
-- or stops goes through here: the tile owns no handle on the server, and a
-- server from a terminal holds the port just as firmly as one we launched.
local function freePort(after)
  local kill, done
  kill, done = ctx:task("/bin/sh", function()
    done()
    M.kill = nil
    if after then after() end
  end, { "-c", D.killCmd(M.port, hs.processInfo.processID) })
  M.kill = kill
  kill:start()
end

-- `thenOpen` opens the browser once the server answers, so "Open the web UI"
-- works from a cold start instead of loading a dead address.
function M.start(thenOpen)
  if not dshBin() or M.busy then return end
  if M.running then
    if thenOpen then openNow() end
    return
  end
  if thenOpen then
    M.open = true
    ctx:after(OPEN_TIMEOUT, function() M.open = false end)
  end
  setBusy("Starting the server…")
  freePort(launch)
end

function M.stop()
  if M.busy then return end
  M.open = false
  setBusy("Stopping the server…")
  freePort(function() M.running, M.url = false, nil; setBusy(nil); settle() end)
end

function M.restart()
  if not dshBin() or M.busy then return end
  M.open = false
  setBusy("Restarting the server…")
  freePort(launch)
end

function M.toggle()
  if M.running then M.stop() else M.start(false) end
end

function M.openUI()
  if M.running then openNow() else M.start(true) end
end

-- ── Menu ───────────────────────────────────────────────────────────────────
local function buildMenu()
  if not dshBin() then
    return {
      { title = "dsh not found", disabled = true },
      { title = "Install it with: npm i -g @deepseek-ai/dsh", disabled = true },
    }
  end

  local items = {
    { title = "Server", switch = true, checked = M.running,
      fn = function() M.toggle() end },
  }
  if M.busy then
    items[#items + 1] = { title = M.busy, disabled = true }
  elseif M.running then
    items[#items + 1] = { title = "Serving " .. D.url(state()), disabled = true }
  end

  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Open the web UI", disabled = M.busy ~= nil,
                        fn = function() M.openUI() end }
  items[#items + 1] = { title = "Restart", disabled = M.busy ~= nil,
                        fn = function() M.restart() end }

  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "DeepSeek Harness · profile " .. PROFILE,
                        disabled = true }
  items[#items + 1] = { title = "Refresh now", fn = function() M.poll() end }
  items[#items + 1] = { title = "Open log",
                        fn = function() hs.execute("open " .. LOG) end }
  items[#items + 1] = { title = "Open server output",
                        fn = function() hs.execute("open " .. SERVER_LOG) end }
  return items
end

-- ── init ───────────────────────────────────────────────────────────────────
M.menu = ctx:tile("DSH")
M.menu:setMenu(buildMenu)
redraw()

M.poll()
M.timer = ctx:timer(POLL_SECS, function() M.poll() end)

-- Switch the plugin off: tile, poll and timeouts, in one call. The server stays.
function M.dispose() ctx:dispose() end

return M
