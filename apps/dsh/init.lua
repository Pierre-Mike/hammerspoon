-- DeepSeek Harness — start, stop and restart the web profile's server, and open
-- its browser UI, from the hub.
--
-- The server is a plain node process that holds one port, so the tile owns it
-- with an hs.task and stops it with SIGTERM, which node shuts down cleanly on.
-- Two things can still hold the port without the tile knowing: a server started
-- in a terminal, and one this tile started before a Hammerspoon reload threw
-- away the handle. So every start frees the port first (lib/dsh.killCmd), and
-- "is it up?" is answered by asking the address rather than by trusting our own
-- bookkeeping — a 15 s HTTP poll, which is also what notices a server that died
-- on its own.
--
-- Nothing starts on a config reload. The Server switch and "Open the web UI"
-- are the only things that turn it on.
--
-- Every timer, task and tile below belongs to this plugin's context, so
-- M.dispose() switches the whole thing off: the poll stops, the tile goes, and
-- the server we started is terminated rather than left holding the port with no
-- tile able to stop it.

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
  task    = nil,     -- the server, when this tile is the one that started it
  release = nil,     -- ctx handle on that task: terminates it and forgets it
  kill    = nil,     -- the port-freeing shell, held so it is not collected
  timer   = nil,
  open    = false,   -- open a browser as soon as the server answers
}

local HOME    = os.getenv("HOME")
local LOG     = "/tmp/hs-dsh.log"
local PROFILE = "web"

local POLL_SECS = 15
-- A boot that never announces an address would otherwise leave the tile busy
-- for good, with the Server switch dead behind it. It boots in about a second,
-- so this is only ever reached by a start that has gone wrong.
local START_TIMEOUT = 25
-- A start that never answers should not leave a browser window waiting to open
-- on the next one. Longer than START_TIMEOUT, so a slow start that does come up
-- still opens the UI that was asked for.
local OPEN_TIMEOUT = 30

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

-- The server's own output goes to the file only, never through utils.logf: that
-- also prints, and a chatty server would fill the Hammerspoon console.
local function append(text)
  local f = io.open(LOG, "a")
  if not f then return end
  f:write(text)
  f:close()
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
  hs.urlevent.openURL(D.url(state()))
end

function M.poll()
  hs.http.asyncGet(D.url(state()), nil, function(status)
    -- Any status at all means something answered; a refused connection comes
    -- back negative.
    local up = (status or -1) > 0
    if up ~= M.running then logf("server %s", up and "up" or "down") end
    M.running = up
    if not up then M.url = nil end
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
local function launch()
  local bin = dshBin()
  if not bin then setBusy(nil); return end

  local task, release
  task, release = ctx:task(bin, function(code)
    logf("server exited code=%s", tostring(code))
    if M.task ~= task then return end   -- superseded by a stop or a restart
    release()                           -- the process is gone; stop holding it
    M.task, M.release = nil, nil
    M.busy, M.running, M.url = nil, false, nil
    redraw()
    if code ~= 0 then
      hs.notify.new({ title = "DeepSeek Harness",
                      subTitle = "The web server stopped",
                      informativeText = string.format("Exit code %s · see %s",
                                                      tostring(code), LOG) }):send()
    end
  end, function(_t, out, err)
    local chunk = (out or "") .. (err or "")
    if chunk ~= "" then append(chunk) end
    local url = D.parseUrl(chunk)
    if url then
      M.url, M.busy, M.running = url, nil, true
      logf("serving %s", url)
      redraw()
      if M.open then openNow() end
    end
    return true
  end, D.args(PROFILE, M.port))

  M.task, M.release = task, release
  task:setEnvironment(ENV)
  task:start()
  logf("launching %s --profile %s --port %d", bin, PROFILE, M.port)
  settle()

  ctx:after(START_TIMEOUT, function()
    if M.task ~= task or not M.busy then return end
    setBusy(nil)
    logf("no address after %ds — the log has what the server is doing",
         START_TIMEOUT)
  end)
end

-- Terminate the server we own, then kill whatever else is still holding the
-- port, then run `after`. Everything that starts or stops goes through here:
-- a leftover listener holds the port just as firmly as one we own.
local function freePort(after)
  local release = M.release
  M.task, M.release = nil, nil       -- so the exit callback knows it is stale
  if release then release() end      -- terminates the server, drops the effect
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
  freePort(function() setBusy(nil); settle() end)
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
  return items
end

-- ── init ───────────────────────────────────────────────────────────────────
M.menu = ctx:tile("DSH")
M.menu:setMenu(buildMenu)
redraw()

M.poll()
M.timer = ctx:timer(POLL_SECS, function() M.poll() end)

-- Switch the plugin off: tile, poll, timeouts and server, in one call.
function M.dispose() ctx:dispose() end

return M
