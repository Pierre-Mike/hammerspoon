-- LM Studio — start/stop the local MLX server, switch the loaded model, and see
-- what each model costs in memory before you load it.
--
-- The tile reads the install three ways, because no single source has it all
-- (lib/lmstudio explains the join). What matters here is the cost of asking:
-- `lms` is a node CLI at ~0.2 s a call, and menuhub rebuilds an app's menu on
-- every open and every redraw behind it. So nothing is queried on the menu path.
-- A background poll keeps M.rows current and the menu renders that, instantly.
--
-- Clicking a model switches to it: the loaded model of the same kind is
-- unloaded first, then the new one loads. An embedding model keeps serving
-- while the chat model changes, since the two don't compete for the same slot.

local L     = require("lib.lmstudio")
local utils = require("lib.utils")

local M = {
  menu    = nil,
  rows    = {},      -- lib.lmstudio catalog rows, what the menu draws
  running = false,   -- is the local server answering?
  port    = 1234,
  busy    = nil,     -- one-line "Loading X…" while a model moves; blocks the list
  mem     = nil,     -- { total, used, free } from hs.host.vmStat()
  disk    = nil,     -- last `lms ls --json`
  live    = nil,     -- last GET /api/v0/models
  ps      = nil,     -- last `lms ps --json`
  ttl     = 0,       -- auto-unload after this many idle seconds; 0 = never
  timer   = nil,
}

local HOME = os.getenv("HOME")
local LMS  = HOME .. "/.lmstudio/bin/lms"
local LOG  = "/tmp/hs-lmstudio.log"

-- The HTTP poll is cheap (8 ms, no process spawn) so it runs often. Everything
-- that costs a process spawn runs rarely: the disk catalog only changes when a
-- model is downloaded, and the down-state probe only matters when the server is
-- already off and nothing is going to change on its own.
local POLL_SECS    = 15
local CATALOG_SECS = 300
local DOWN_SECS    = 45

local TTL_KEY = "lmstudio.ttl"
local TTL_CHOICES = {
  { "Never",      0 },
  { "10 minutes", 600 },
  { "30 minutes", 1800 },
  { "1 hour",     3600 },
}

local ENV = {
  HOME = HOME,
  PATH = HOME .. "/.lmstudio/bin:/opt/homebrew/bin:/usr/bin:/bin",
}

local function logf(fmt, ...) utils.logf(LOG, fmt, ...) end

local function haveLms() return hs.fs.attributes(LMS) ~= nil end

local function decode(s)
  local ok, v = pcall(hs.json.decode, s or "")
  return (ok and type(v) == "table") and v or nil
end

-- lms writes its failures across several lines; the first is the one worth
-- putting in a notification.
local function firstLine(s)
  local line = (utils.trim(s) or ""):match("^[^\n]*") or ""
  return utils.truncate(line, 140)
end

local function notify(subtitle, text)
  hs.notify.new({ title = "LM Studio", subTitle = subtitle,
                  informativeText = text or "" }):send()
end

-- Every lms call is async: a blocking one would freeze the menu, and a load can
-- take minutes.
local function lms(args, cb)
  local t = hs.task.new(LMS, function(code, out, err)
    if cb then cb(code == 0, out or "", err or "") end
  end, args)
  t:setEnvironment(ENV)
  t:start()
  return t
end

-- ── State ──────────────────────────────────────────────────────────────────
local function redraw()
  if not M.menu then return end
  local state = { running = M.running, port = M.port, rows = M.rows, busy = M.busy }
  M.menu:setTitle(L.title(state))
  local tip = L.tooltip(state)
  if M.mem then
    tip = tip .. string.format("\n%s free of %s",
                               L.humanBytes(M.mem.free), L.humanBytes(M.mem.total))
  end
  M.menu:setTooltip(tip)
end

local function rebuild()
  M.rows = L.catalog(M.disk, M.live, M.ps)
  M.mem = L.memory(hs.host.vmStat())
  redraw()
end

local function setBusy(msg)
  M.busy = msg
  redraw()
end

local lastDownProbe, lastCatalog = 0, 0
local pollLive, probeDown

-- No answer on the port we know. Either the server is off, or it was restarted
-- somewhere else — `lms server status` is the only thing that knows which, and
-- `lms ps` is the only way to see a model loaded from the LM Studio window with
-- the server switched off.
function probeDown()
  if not haveLms() or os.time() - lastDownProbe < DOWN_SECS then rebuild(); return end
  lastDownProbe = os.time()
  lms({ "server", "status", "--json" }, function(ok, out)
    local st = ok and decode(out)
    if st and st.running and st.port and st.port ~= M.port then
      logf("server moved to port %d", st.port)
      M.port = st.port
      pollLive()
      return
    end
    lms({ "ps", "--json" }, function(psOk, psOut)
      M.ps = psOk and decode(psOut) or nil
      rebuild()
    end)
  end)
end

function pollLive()
  hs.http.asyncGet(string.format("http://127.0.0.1:%d/api/v0/models", M.port), nil,
    function(status, body)
      if status == 200 then
        local j = decode(body)
        M.running = true
        M.live = j and j.data or nil
        M.ps = nil              -- the server's own answer supersedes lms ps
        rebuild()
      else
        M.running, M.live = false, nil
        probeDown()
      end
    end)
end

local function refreshCatalog()
  if not haveLms() then rebuild(); return end
  lastCatalog = os.time()
  lms({ "ls", "--json" }, function(ok, out)
    if ok then M.disk = decode(out) end
    rebuild()
  end)
end

function M.poll()
  if os.time() - lastCatalog >= CATALOG_SECS then refreshCatalog() end
  pollLive()
end

-- A load or a server start reports done before the state has settled, so look
-- once immediately and once more a moment later.
local function settle()
  M.poll()
  hs.timer.doAfter(1.5, M.poll)
end

-- ── Actions ────────────────────────────────────────────────────────────────
function M.startServer()
  if not haveLms() or M.busy then return end
  setBusy("Starting server…")
  lms({ "server", "start" }, function(ok, _, err)
    logf("server start ok=%s %s", tostring(ok), firstLine(err))
    setBusy(nil)
    if not ok then notify("Could not start the server", firstLine(err)) end
    settle()
  end)
end

function M.stopServer()
  if not haveLms() or M.busy then return end
  setBusy("Stopping server…")
  lms({ "server", "stop" }, function(ok, _, err)
    logf("server stop ok=%s %s", tostring(ok), firstLine(err))
    setBusy(nil)
    if not ok then notify("Could not stop the server", firstLine(err)) end
    settle()
  end)
end

function M.toggleServer()
  if M.running then M.stopServer() else M.startServer() end
end

-- Unload one at a time rather than all at once: the point of unloading first is
-- that the memory is actually back before the next weights start reading.
local function unloadEach(ids, done, i)
  i = i or 1
  if i > #ids then done(); return end
  lms({ "unload", ids[i] }, function(ok, _, err)
    logf("unload %s ok=%s %s", ids[i], tostring(ok), firstLine(err))
    unloadEach(ids, done, i + 1)
  end)
end

local function rowFor(key)
  for _, r in ipairs(M.rows) do
    if r.key == key then return r end
  end
end

function M.load(key)
  if not haveLms() or M.busy then return end
  local row = rowFor(key)
  local name = row and row.name or key
  local targets = L.swapTargets(M.rows, key)

  local function go()
    setBusy("Loading " .. name .. "…")
    local args = { "load", key, "-y" }
    -- TTL is a load-time flag, so this only binds the model being loaded now.
    if M.ttl > 0 then
      args[#args + 1] = "--ttl"
      args[#args + 1] = tostring(M.ttl)
    end
    lms(args, function(ok, _, err)
      logf("load %s ok=%s %s", key, tostring(ok), firstLine(err))
      setBusy(nil)
      if not ok then notify("Could not load " .. name, firstLine(err)) end
      settle()
    end)
  end

  if #targets == 0 then go(); return end
  setBusy("Making room for " .. name .. "…")
  unloadEach(targets, go)
end

function M.unload(id, name)
  if not haveLms() or M.busy then return end
  setBusy("Unloading " .. (name or id) .. "…")
  lms({ "unload", id }, function(ok, _, err)
    logf("unload %s ok=%s %s", id, tostring(ok), firstLine(err))
    setBusy(nil)
    if not ok then notify("Could not unload " .. (name or id), firstLine(err)) end
    settle()
  end)
end

function M.unloadAll()
  if not haveLms() or M.busy then return end
  setBusy("Unloading everything…")
  lms({ "unload", "--all" }, function(ok, _, err)
    logf("unload all ok=%s %s", tostring(ok), firstLine(err))
    setBusy(nil)
    settle()
  end)
end

function M.setTtl(secs)
  M.ttl = secs
  hs.settings.set(TTL_KEY, secs)
  redraw()
end

-- ── Menu ───────────────────────────────────────────────────────────────────
local function ctxLabel(n)
  if not n then return nil end
  if n >= 1024 then return string.format("%dk", math.floor(n / 1024)) end
  return tostring(n)
end

local function modelItems()
  if #M.rows == 0 then
    return { { title = haveLms() and "No models on disk" or "", disabled = true } }
  end
  local free = M.mem and M.mem.free
  local out = {}
  for _, r in ipairs(M.rows) do
    local label = L.label(r)
    if r.loaded and r.context then
      label = label .. " · " .. ctxLabel(r.context) .. " ctx"
    elseif not r.loaded and not L.fits(M.rows, r.key, free) then
      -- Not a block, a warning: the weights plus their working memory are more
      -- than this machine has free, even after the switch gives memory back.
      label = label .. "  ⚠︎"
    end
    out[#out + 1] = {
      title = label,
      checked = r.loaded,
      disabled = M.busy ~= nil,
      fn = function()
        if r.loaded then M.unload(r.identifier or r.key, r.name) else M.load(r.key) end
      end,
    }
  end
  return out
end

local function memoryItems()
  local out = {
    { title = "Memory", disabled = true },
    { title = "Models loaded · " .. L.humanBytes(L.loadedBytes(M.rows)), disabled = true },
  }
  if M.mem then
    out[#out + 1] = { title = string.format("This Mac · %s used of %s",
                      L.humanBytes(M.mem.used), L.humanBytes(M.mem.total)), disabled = true }
    out[#out + 1] = { title = "Free for a model · " .. L.humanBytes(M.mem.free),
                      disabled = true }
  end
  return out
end

local function ttlMenu()
  local out = {
    { title = "Applies to the next model you load", disabled = true },
    { title = "-" },
  }
  for _, c in ipairs(TTL_CHOICES) do
    out[#out + 1] = { title = c[1], checked = M.ttl == c[2],
                      fn = function() M.setTtl(c[2]) end }
  end
  return out
end

local function buildMenu()
  if not haveLms() then
    return {
      { title = "lms CLI not found at ~/.lmstudio/bin/lms", disabled = true },
      { title = "Install it from LM Studio → Developer → CLI", disabled = true },
      { title = "-" },
      { title = "Open lmstudio.ai",
        fn = function() hs.urlevent.openURL("https://lmstudio.ai") end },
    }
  end

  local items = {
    { title = "Server", switch = true, checked = M.running,
      fn = function() M.toggleServer() end },
  }
  if M.running then
    items[#items + 1] = { title = string.format("Listening on 127.0.0.1:%d", M.port),
                          disabled = true }
  end
  if M.busy then
    items[#items + 1] = { title = M.busy, disabled = true }
  end

  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Models", disabled = true }
  for _, it in ipairs(modelItems()) do items[#items + 1] = it end

  items[#items + 1] = { title = "-" }
  for _, it in ipairs(memoryItems()) do items[#items + 1] = it end

  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Auto-unload when idle", menu = ttlMenu() }
  items[#items + 1] = { title = "Unload all models",
                        disabled = M.busy ~= nil or #L.loaded(M.rows) == 0,
                        fn = function() M.unloadAll() end }

  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Refresh now",
                        fn = function() refreshCatalog(); pollLive() end }
  items[#items + 1] = { title = "Open LM Studio",
                        fn = function() hs.application.launchOrFocus("LM Studio") end }
  items[#items + 1] = { title = "Open log",
                        fn = function() hs.execute("open " .. LOG) end }
  return items
end

-- ── init ───────────────────────────────────────────────────────────────────
M.menu = require("lib.menuhub").item("LM Studio")
M.ttl = hs.settings.get(TTL_KEY) or 0
M.menu:setMenu(buildMenu)
redraw()

-- Observe only: nothing is started or loaded on a config reload. The Server
-- switch is the one thing that turns anything on.
refreshCatalog()
pollLive()
M.timer = hs.timer.doEvery(POLL_SECS, function() M.poll() end)

return M
