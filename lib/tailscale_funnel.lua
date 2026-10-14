-- Pure funnel logic — no hs.* dependency, fully unit-testable. The wiring
-- lives in apps/tailscale_funnel.
--
-- This half owns everything worth asserting about a Tailscale Funnel without
-- publishing one: where the `tailscale` CLI lives, the argument lists, the two
-- facts hidden in `tailscale status --json` and `tailscale serve status
-- --json`, what the CLI's complaints mean, when a lease is dead, and what the
-- three HTTP endpoints answer. apps/tailscale_funnel adds the child processes,
-- the timer, the intake socket and the tile, and nothing else.
--
-- WHAT REPLACED WHAT. This module took over from lib/cloudflare_tunnel, and
-- the lease protocol is deliberately the same so a caller only changes the
-- mode it asks for. Three things are gone, because a funnel is not a child
-- process:
--
--   no supervised child   `tailscale funnel --bg` writes the route into
--                         tailscaled and returns. There is nothing to keep
--                         alive, nothing to restart, and so no backoff ladder:
--                         the 30s watchdog re-reads the truth from the CLI and
--                         a condition that a human fixed clears itself on the
--                         next tick instead of waiting for a Retry button.
--   no grace period       the last lease going away tears nothing down. The
--                         address is the point: it must survive the voice
--                         agent restarting, the Mac rebooting and this plugin
--                         being switched off. Only a human turns the funnel
--                         off, from the menu.
--   no quota              Cloudflare handed out quick tunnels on a quota and
--                         rate-limited the third one. A funnel is a route on a
--                         name you already own.
--
-- The vocabulary, once:
--   lease       a named reservation. One owner, one TTL, renewed on every
--               poll. It names the local port the funnel should carry traffic
--               to, and the probe that proves the far end is the right one.
--   generation  bumped every time the funnel is armed afresh. A caller detects
--               "my URL changed" by comparing this integer rather than by
--               comparing URL strings and hoping a changed string means a new
--               address. With Funnel it should stay still for months, which is
--               the whole reason for the move.
--   hostname    `<machine>.<tailnet>.ts.net`, read from `tailscale status`.
--               Known as soon as the Mac is logged in, whether or not anything
--               is published.
--   url         the public base URL, and only when the funnel is actually
--               carrying the leased port. A caller that pointed a webhook at
--               an address nothing serves has a webhook that is quietly dead,
--               so this module would rather answer null.
--   fatal       broken until a human acts: no CLI, logged out, Funnel not
--               allowed in the tailnet, the funnel pointed at the wrong port.
--               Rechecked every tick, so "until a human acts" costs nothing.

local M = {}

-- ── Constants ──────────────────────────────────────────────────────────────
M.PORT         = 8795      -- the intake, first free port after the phone server's 8794
M.LEASE_TTL_S  = 120       -- a lease nobody renews is gone after this
M.WATCH_S      = 30        -- the watchdog's period, which is also the renew period
M.PROBE_MISSES = 3         -- consecutive probe failures that count as a dead funnel
M.FUNNEL_PORT  = 443       -- Funnel serves 443, 8443 and 10000; 443 is the one Meta can reach
M.ORIGIN_HOST  = "127.0.0.1"

-- Where the CLI lives. The Mac App Store build of Tailscale has no Funnel and
-- no CLI at all, so only the standalone app and the Homebrew package are
-- looked for — in that order, because the standalone app is the one that
-- carries a tailscaled able to serve.
M.BINS = {
  "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
  "/opt/homebrew/bin/tailscale",
  "/usr/local/bin/tailscale",
}

M.MODES = { funnel = true, off = true }
-- Homebrew, where the plugin gets the client from when there is none. Apple
-- silicon first, then Intel, which is the order every other plugin here looks
-- in.
M.BREWS = {
  "/opt/homebrew/bin/brew",
  "/usr/local/bin/brew",
}

-- The cask that carries the standalone app. Homebrew renamed it from
-- `tailscale` to `tailscale-app` when the CLI-only formula took the shorter
-- name, so a config written against the old name installs the wrong thing: the
-- formula is tailscaled plus a CLI you have to run yourself, and the point of
-- the standalone app is that it brings its own daemon.
M.CASK = "tailscale-app"

-- Where a human finishes what the plugin cannot. Each one is the deepest page
-- that can be opened without knowing the tailnet's name.
M.DOWNLOAD_URL  = "https://tailscale.com/download/macos"
M.ADMIN_DNS_URL = "https://login.tailscale.com/admin/dns"
M.ADMIN_ACL_URL = "https://login.tailscale.com/admin/acls/file"
M.ADMIN_MACHINES_URL = "https://login.tailscale.com/admin/machines"
M.META_APPS_URL = "https://developers.facebook.com/apps/"

-- The path WhatsApp posts to, appended to the public address. Here rather than
-- in the voice agent because this is the module that owns the address, and the
-- string a human pastes into Meta's dashboard is the two joined.
M.WEBHOOK_PATH = "/whatsapp/webhook"


-- The node attribute a tailnet policy file must grant before Funnel will run.
M.FUNNEL_CAP = "tailscale.com/cap/funnel"

-- ── What is wrong, in words a human can act on ─────────────────────────────
M.NOT_INSTALLED = "no tailscale CLI — install the standalone app from tailscale.com/download"
M.NOT_RUNNING   = "tailscaled is not answering — open the Tailscale app"
M.NOT_LOGGED_IN = "this Mac is not logged in to a tailnet — run `tailscale up`"
M.NEEDS_AUTH    = "this Mac is waiting to be approved in the tailnet"
M.NO_HOSTNAME   = "no .ts.net name yet — turn on MagicDNS and HTTPS certificates for the tailnet"
M.NOT_ALLOWED   = "Funnel is not allowed in this tailnet — add the funnel node attribute to the policy file"
M.NO_HTTPS      = "HTTPS certificates are off for this tailnet — turn them on in the admin console"
M.BAD_PORT      = "Funnel only serves ports 443, 8443 and 10000"
M.NO_STATUS     = "tailscale status did not answer"
M.FUNNEL_OFF    = "the funnel is off — turn it on from this menu"
M.PROBE_DEAD    = "the funnel stopped answering its own probe"
-- The same vocabulary for the half of the job that is getting Tailscale onto
-- this Mac at all. A line here is what the tile shows, so each one says who
-- does what next rather than only what is wrong.
M.NO_BREW          = "Homebrew is not here — the download page is open; running the installer is yours"
M.NO_CASK          = "Homebrew has no " .. M.CASK .. " cask — install from tailscale.com/download"
M.BREW_BUSY        = "Homebrew is busy with another install — try again in a minute"
M.INSTALLING       = "installing Tailscale with Homebrew…"
M.INSTALL_TERMINAL = "macOS wants your Mac password — finish the install in the Terminal window"
M.INSTALL_LOST     = "Homebrew finished and there is still no tailscale CLI — install from tailscale.com/download"
M.SIGNING_IN       = "waiting for you to finish signing in, in the browser"
M.SIGNIN_OPENED    = "the sign-in page is open — choosing an account and approving this Mac is yours"


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

-- Form-encoded bodies, for a caller that posts `owner=x&mode=funnel`.
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
-- to it and `https://x.ts.net//phone/ping` is a 404.
function M.normalize(req)
  req = req or {}
  local out = {
    owner        = req.owner,
    mode         = req.mode or "funnel",
    port         = tonumber(req.port),
    public_url   = req.public_url,
    ttl_s        = tonumber(req.ttl_s) or M.LEASE_TTL_S,
    probe_path   = req.probe_path,
    probe_expect = req.probe_expect,
  }
  if out.public_url == "" then out.public_url = nil end
  if out.public_url then out.public_url = out.public_url:gsub("/+$", "") end
  if out.probe_path == "" then out.probe_path = nil end
  if out.ttl_s <= 0 then out.ttl_s = M.LEASE_TTL_S end
  return out
end

-- What makes a request unanswerable, as opposed to what makes a funnel broken.
-- Returns a 400's worth of explanation, or nil.
function M.badRequest(req)
  if type(req.owner) ~= "string" or req.owner == "" then
    return "owner is required"
  end
  if not M.MODES[req.mode] then
    return "mode must be funnel or off (got " .. tostring(req.mode) .. ")"
  end
  if req.mode ~= "off" and not req.port then
    return "port is required: the local port the funnel should carry traffic to"
  end
  return nil
end

-- ── The commands ───────────────────────────────────────────────────────────
-- Argument lists only. The binary is found at run time (findBin), so putting
-- it in here would mean every one of these took a path it does not care about.
function M.origin(port)
  return string.format("http://%s:%d", M.ORIGIN_HOST, tonumber(port) or 0)
end

-- Read-only, both of them, and the only two the watchdog runs.
function M.statusCommand() return { "status", "--json" } end
function M.serveCommand()  return { "serve", "status", "--json" } end

-- The one command that publishes a port to the public internet. `--bg` is what
-- makes it outlive the shell that ran it and survive a reboot: without it the
-- route lives inside one foreground process, which is the thing this plugin
-- exists to stop doing.
function M.onCommand(port)
  return { "funnel", "--bg", "--https=" .. M.FUNNEL_PORT, M.origin(port) }
end

function M.offCommand()
  return { "funnel", "--https=" .. M.FUNNEL_PORT, "off" }
end

-- Signing in. `tailscale up` blocks until a human has authenticated in a
-- browser and prints the URL to go to while it waits, which is why the plugin
-- reads this one's output as it arrives instead of after it exits.
function M.loginCommand() return { "up" } end

-- Installing. `--force` because the plugin only offers this when there is no
-- CLI on the Mac, so a Homebrew receipt that claims the cask is already there
-- is stale — an app deleted out of /Applications leaves exactly that behind,
-- and a plain `brew install` would answer "already installed" and change
-- nothing.
function M.installCommand(cask)
  return { "install", "--cask", "--force", cask or M.CASK }
end

-- The same install as a shell line, for the one case that cannot be a child
-- process: the cask is a .pkg, so Homebrew shells out to `sudo installer`, and
-- a menu bar plugin has no terminal for sudo to ask a password on.
function M.installLine(brew, cask)
  return string.format("%s install --cask --force %s", brew or "brew", cask or M.CASK)
end

-- Homebrew's own switches for "nobody is watching". NONINTERACTIVE is what
-- makes a missing password fail in a second instead of hanging on a prompt
-- nothing can answer, and the plugin reads that failure and opens a Terminal.
function M.brewEnv(home)
  return {
    HOME                    = home,
    PATH                    = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
    NONINTERACTIVE          = "1",
    HOMEBREW_NO_AUTO_UPDATE = "1",
    HOMEBREW_NO_ENV_HINTS   = "1",
  }
end

-- AppleScript quoting: backslash and double quote, and nothing else, because
-- an install line is a path and a cask name.
local function asQuote(s)
  return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

function M.terminalScript(line)
  return table.concat({
    'tell application "Terminal"',
    "  activate",
    "  do script " .. asQuote(line),
    "end tell",
  }, "\n")
end

-- The first of the candidate paths that is there, or nil. `exists` is a
-- predicate so this stays pure and a spec can lay out any Mac it likes.
function M.findBin(exists, candidates)
  for _, path in ipairs(candidates or M.BINS) do
    if exists(path) then return path end
  end
  return nil
end

-- ── Reading tailscale ──────────────────────────────────────────────────────
-- Is the funnel node attribute granted to this machine? Answered off the raw
-- text rather than off the decoded document on purpose: tailscale writes the
-- capability as an object key whose value is null, and a JSON decoder that
-- turns null into "absent" — this one does, and the lease protocol needs it to
-- — would drop the key and make a granted capability look denied.
--
-- nil means "cannot tell": an older client prints neither field, and refusing
-- to publish on the strength of a field that was never there would be a plugin
-- that never works on a Mac that would have been fine.
function M.funnelAllowed(text)
  if type(text) ~= "string" then return nil end
  if not (text:find("CapMap", 1, true) or text:find("Capabilities", 1, true)) then
    return nil
  end
  -- Go's encoder leaves "/" alone; some proxies escape it. Both forms count.
  return text:find(M.FUNNEL_CAP, 1, true) ~= nil
      or text:find((M.FUNNEL_CAP:gsub("/", "\\/")), 1, true) ~= nil
end

-- `tailscale status --json`, reduced to the three facts this plugin needs.
function M.parseStatus(text)
  local doc = M.decode(text)
  if type(doc) ~= "table" then return nil end
  local node = type(doc.Self) == "table" and doc.Self or {}
  -- DNSName comes back fully qualified, with the trailing dot: a URL built
  -- from it unchanged still resolves, and still looks broken to a human.
  local dns = type(node.DNSName) == "string" and (node.DNSName:gsub("%.+$", "")) or nil
  if dns == "" then dns = nil end
  return {
    backend  = type(doc.BackendState) == "string" and doc.BackendState or nil,
    hostname = dns,
    funnel   = M.funnelAllowed(text),
    online   = node.Online == true,
    -- Set while a login is waiting to be finished in a browser. A sign-in the
    -- human abandoned leaves it here, so the menu can offer the page again
    -- without starting a second `tailscale up`.
    authUrl  = type(doc.AuthURL) == "string" and doc.AuthURL ~= "" and doc.AuthURL or nil,
  }
end

-- The port behind a proxy target, so a funnel pointed somewhere else can be
-- told apart from a funnel pointed here.
function M.targetPort(target)
  if type(target) ~= "string" then return nil end
  return tonumber(target:match(":(%d+)/?$"))
end

-- `tailscale serve status --json`: the serve config as tailscaled holds it.
--   {"TCP":{"443":{"HTTPS":true}},
--    "Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8794"}}}},
--    "AllowFunnel":{"mac.tail1234.ts.net:443":true}}
-- `on` means both halves are there: the funnel is open on a host:port AND
-- something is proxied behind it. A funnel open on nothing reaches nothing.
function M.serveFromJson(doc)
  local allow = type(doc.AllowFunnel) == "table" and doc.AllowFunnel or {}
  local open = {}
  for key, on in pairs(allow) do
    if on then open[#open + 1] = key end
  end
  table.sort(open)              -- one answer, whatever order pairs() walked in
  local hostport = open[1]
  if not hostport then return { on = false } end

  local host, port = hostport:match("^(.-):(%d+)$")
  local web = type(doc.Web) == "table" and doc.Web or {}
  local entry = type(web[hostport]) == "table" and web[hostport] or {}
  local handlers = type(entry.Handlers) == "table" and entry.Handlers or {}

  local paths = {}
  for path in pairs(handlers) do paths[#paths + 1] = path end
  table.sort(paths)
  local proxy
  if type(handlers["/"]) == "table" then proxy = handlers["/"].Proxy end
  for _, path in ipairs(paths) do
    if proxy then break end
    if type(handlers[path]) == "table" then proxy = handlers[path].Proxy end
  end

  return {
    on         = proxy ~= nil,
    host       = host or hostport,
    funnelPort = tonumber(port),
    target     = proxy,
    port       = M.targetPort(proxy),
  }
end

-- `tailscale funnel status`, the human-readable form, as a fallback for a
-- client whose --json the decoder did not recognise:
--   https://mac.tail1234.ts.net (Funnel on)
--   |-- / proxy http://127.0.0.1:8794
function M.serveFromText(text)
  local target = text:match("proxy%s+(https?://[%w%.%-]+:%d+)")
  local host = text:match("https://([%w%-%.]+%.ts%.net)")
  return {
    on         = text:find("Funnel on", 1, true) ~= nil and target ~= nil,
    host       = host,
    funnelPort = M.FUNNEL_PORT,
    target     = target,
    port       = M.targetPort(target),
  }
end

function M.parseServe(text)
  if type(text) ~= "string" or text:match("^%s*$") then return { on = false } end
  local doc = M.decode(text)
  if type(doc) == "table" and (doc.AllowFunnel or doc.Web or doc.TCP) then
    return M.serveFromJson(doc)
  end
  return M.serveFromText(text)
end

-- ── What the CLI's complaints mean ─────────────────────────────────────────
-- Each line says what to do about it, because this is what the tile shows and
-- what the caller is told.
local FATAL_LINES = {
  { "funnel is not enabled",                 M.NOT_ALLOWED },
  { "funnel node attribute",                 M.NOT_ALLOWED },
  { "nodeattrs",                             M.NOT_ALLOWED },
  { "tailscale.com/s/no-funnel",             M.NOT_ALLOWED },
  { "failed to connect to local tailscaled", M.NOT_RUNNING },
  { "is tailscaled running",                 M.NOT_RUNNING },
  { "cannot connect to tailscaled",          M.NOT_RUNNING },
  { "logged out",                            M.NOT_LOGGED_IN },
  { "needslogin",                            M.NOT_LOGGED_IN },
  { "not logged in",                         M.NOT_LOGGED_IN },
  { "https is not enabled",                  M.NO_HTTPS },
  { "https must be enabled",                 M.NO_HTTPS },
  { "magicdns is not enabled",               M.NO_HOSTNAME },
  { "only ports 443",                        M.BAD_PORT },
  { "invalid port",                          M.BAD_PORT },
}

function M.fatalReason(text)
  if type(text) ~= "string" then return nil end
  local low = text:lower()
  for _, pair in ipairs(FATAL_LINES) do
    if low:find(pair[1], 1, true) then return pair[2] end
  end
  return nil
end

-- What a chunk of CLI output means: "fatal" plus the reason to show, or "ok".
function M.classify(text)
  local reason = M.fatalReason(text)
  if reason then return "fatal", reason end
  return "ok", nil
end

-- The URL `tailscale up` prints while it waits. Taken off the stream rather
-- than off the exit, because the command does not exit until the human has
-- already been to the page — which they cannot do if nothing opened it.
function M.authUrl(text)
  if type(text) ~= "string" then return nil end
  -- `tailscale status --json` hands over the bare URL, the stream hands over a
  -- sentence with the URL in it, and both arrive here.
  if text:match("^https://%S+$") then return text end
  return text:match("https://login%.tailscale%.com/[%w%-%./_]+")
      or text:match("https://[%w%-%.]+/a/%x+")
end

-- Homebrew could not ask for a password. Not a failure to report and stop on:
-- it is the one fault the plugin recovers from by itself, by handing the same
-- command to a Terminal window where sudo has somewhere to ask.
local PASSWORD_LINES = {
  "a terminal is required to read the password",
  "no tty present",
  "askpass",
  "password is required",
}

function M.needsPassword(text)
  if type(text) ~= "string" then return false end
  local low = text:lower()
  for _, line in ipairs(PASSWORD_LINES) do
    if low:find(line, 1, true) then return true end
  end
  return false
end

-- What a Homebrew complaint means, in the same shape as fatalReason.
local INSTALL_LINES = {
  { "no available cask",       M.NO_CASK },
  { "no casks found",          M.NO_CASK },
  { "is unavailable",          M.NO_CASK },
  { "another active homebrew", M.BREW_BUSY },
  { "command not found",       M.NO_BREW },
}

function M.installProblem(text)
  if type(text) ~= "string" then return nil end
  local low = text:lower()
  for _, pair in ipairs(INSTALL_LINES) do
    if low:find(pair[1], 1, true) then return pair[2] end
  end
  return nil
end

-- Why this Mac cannot serve a funnel, from one `tailscale status --json`.
-- Returns nil when it can. "Logged in but no name yet" is its own case: it is
-- the one a human fixes in the admin console rather than on the Mac.
M.BACKEND_PROBLEMS = {
  NoState          = M.NOT_RUNNING,
  Starting         = nil,                 -- give it a moment; the next tick asks again
  NeedsLogin       = M.NOT_LOGGED_IN,
  NeedsMachineAuth = M.NEEDS_AUTH,
  Stopped          = M.NOT_LOGGED_IN,
}

function M.statusProblem(status)
  if not status then return M.NO_STATUS end
  local down = M.BACKEND_PROBLEMS[status.backend or ""]
  if down then return down end
  if not status.hostname then return M.NO_HOSTNAME end
  if status.funnel == false then return M.NOT_ALLOWED end
  return nil
end

-- A funnel that is up but carrying somebody else's port is worse than no
-- funnel: the caller is handed an address that answers, with the wrong thing
-- behind it. Only ever a problem while a funnel lease names a port.
function M.portProblem(serve, port)
  serve = serve or {}
  if not serve.on or not port or not serve.port then return nil end
  if serve.port == port then return nil end
  return string.format("the funnel carries %s, not port %d — turn it off and on again",
                       serve.target or ("port " .. tostring(serve.port)), port)
end

function M.hostUrl(host)
  if type(host) ~= "string" or host == "" then return nil end
  return "https://" .. host
end

-- ── Waiting ────────────────────────────────────────────────────────────────
function M.probeFailed(misses) return (tonumber(misses) or 0) >= M.PROBE_MISSES end

-- Did the origin answer with what its owner said proves it is the origin? The
-- caller supplies both halves, because only it knows what healthy looks like:
-- the voice agent's /phone/ping returns a token chosen at daemon start, so a
-- different daemon answering through the same funnel does not count as healthy.
function M.probeOk(body, expect)
  if expect == nil or expect == "" then return true end
  if type(body) ~= "string" then return false end
  return body:gsub("^%s+", ""):gsub("%s+$", "") == expect
end

-- ── Leases ─────────────────────────────────────────────────────────────────
function M.leaseExpiry(req, now) return now + (req.ttl_s or M.LEASE_TTL_S) end

-- Drop the leases nobody renewed, and say whose they were. Renewal is the
-- liveness signal: an owner that stopped polling stopped needing the funnel,
-- whether it said so or crashed. Nothing is torn down for it — see the header.
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

-- Which lease decides which port the funnel should carry. The first one taken
-- wins and keeps winning while it is renewed, so a second caller cannot move
-- the funnel out from under the first by asking for a different port.
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

-- One funnel serves one origin. A second caller asking for a different port
-- would otherwise be handed a URL that reaches somebody else's service, which
-- is worse than being told no.
function M.conflict(live, req)
  if not live or not live.port or not req.port then return nil end
  if live.port == req.port and (live.mode or "funnel") == req.mode then return nil end
  return string.format(
    "the funnel already serves %s mode on port %d; this request asked for %s mode on port %d",
    tostring(live.mode or "funnel"), live.port, tostring(req.mode), req.port)
end

-- ── Status ─────────────────────────────────────────────────────────────────
-- Four states, from the fields apps/tailscale_funnel keeps:
--   off       nothing published: the funnel is off, or the only lease asked
--             for `off` because its owner has a public URL of its own
--   starting  a CLI call is in flight and the answer is not in yet
--   ready     the funnel carries the leased port, and there is a URL to point
--             a webhook at
--   error     a human has to do something; the next tick says so again
function M.computeStatus(s)
  -- A job this plugin started and is still waiting on comes first. Installing
  -- the client is exactly the moment `fatal` is true — there is no CLI yet —
  -- and a red light under a progress line would be reporting the thing the
  -- plugin is in the middle of fixing.
  if s.busy and s.busy ~= "" then return "starting" end
  if s.fatal then return "error" end
  if s.mode == "off" then return "off" end
  if s.funnel and s.url and s.url ~= "" then return "ready" end
  if s.pending then return "starting" end
  return "off"
end

function M.uptime(s, now)
  if not s.startedAt then return 0 end
  return math.max(0, math.floor((now or os.time()) - s.startedAt))
end

-- The answer every endpoint gives, and the only shape a caller sees.
function M.snapshot(s, now)
  now = now or os.time()
  return {
    status     = M.computeStatus(s),
    url        = (s.url ~= "" and s.url) or nil,
    hostname   = (s.hostname ~= "" and s.hostname) or nil,
    generation = s.generation or 0,
    error      = s.err,
    uptime_s   = M.uptime(s, now),
    mode       = s.mode,
    port       = s.port,
    funnel     = s.funnel == true,
    leases     = M.activeList(s.leases, now),
  }
end

-- Always every key, including the ones that are nil. A caller reading
-- state["error"] must not have to know that the key disappears when there is
-- nothing wrong.
M.STATE_KEYS = { "status", "url", "hostname", "generation", "error",
                 "uptime_s", "mode", "port", "funnel", "leases" }

function M.encodeState(s)
  local parts = {}
  for _, key in ipairs(M.STATE_KEYS) do
    parts[#parts + 1] = quote(key) .. ":" .. M.encode(s[key])
  end
  return "{" .. table.concat(parts, ",") .. "}\n"
end

-- ── Routing ────────────────────────────────────────────────────────────────
-- `target` is apps/tailscale_funnel itself: lease(req), release(owner) and
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

  -- /funnel is the name that fits; /tunnel still answers, because the point of
  -- this plugin is that a caller's address does not change under it, and that
  -- courtesy is cheap to extend to the caller's own endpoint.
  if route == "/funnel" or route == "/tunnel" then
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

-- ── Setting it up ──────────────────────────────────────────────────────────
-- The checklist, and the only place that knows what order the prerequisites
-- happen in. Pure, so the whole of "what is this Mac still missing" can be
-- asserted on without a tailnet, a browser or a Homebrew.
--
-- Every step says who finishes it. Three of them the plugin does on its own;
-- three of them it can only carry a human to the right page with the right
-- text already on the clipboard; and one of them — Meta's dashboard — it
-- cannot even see the answer to. Saying which is which is the point: a
-- checklist that pretends it can do the last mile is worse than no checklist,
-- because the human stops reading it.
--
--   done    checked, and the plugin can see it is
--   todo    the plugin does this one; the row is a button
--   manual  the plugin gets you to the page, you finish it
--   wait    blocked on a step above it

M.MARK = {
  done   = "\u{2705}",
  todo   = "\u{2B1C}",
  manual = "\u{1F464}",
  wait   = "\u{23F3}",
}

M.ACTION_LABEL = {
  install       = "Install Tailscale",
  openapp       = "Open the Tailscale app",
  signin        = "Sign in to Tailscale",
  check         = "Check now",
  admindns      = "Open DNS settings",
  adminmachines = "Open the machines page",
  adminacl      = "Copy the snippet and open the policy file",
  copyenv       = "Copy the voice agent's settings",
  arm           = "Turn the funnel on",
  copyhook      = "Copy the webhook URL",
}

-- Two actions the top-level menu already carries a row for. Hoisting the next
-- step to the top is what makes the one thing to do next a button; doing it
-- for these two would put the same row in the menu twice.
M.MENU_ACTIONS = { arm = true, check = true }

-- What a human pastes, built here because this is the module that owns the
-- address and the port.
function M.webhookUrl(hostname)
  local base = M.hostUrl(hostname)
  return base and (base .. M.WEBHOOK_PATH) or nil
end

-- The tailnet policy file grants Funnel per node. This is the smallest thing
-- that works, straight out of Tailscale's own docs, and it goes on the
-- clipboard so the admin console is a paste rather than a transcription.
M.POLICY_SNIPPET = table.concat({
  '"nodeAttrs": [',
  "  {",
  '    "target": ["autogroup:member"],',
  '    "attr":   ["funnel"]',
  "  }",
  "],",
}, "\n")

-- The voice agent's four settings, with this Mac's real address already in
-- them. The plugin does not write another repo's .env for it: that file also
-- holds the five WHATSAPP_ secrets only a human can fetch, so a plugin editing
-- it behind their back would be editing a file they are halfway through.
function M.envLines(hostname)
  return table.concat({
    "PHONE_TUNNEL=plugin",
    "PHONE_TUNNEL_PLUGIN=http://127.0.0.1:" .. M.PORT,
    "PHONE_PUBLIC_URL=" .. (M.hostUrl(hostname) or "https://<machine>.<tailnet>.ts.net"),
    "WHATSAPP_ENABLED=1",
  }, "\n") .. "\n"
end

-- `env` is what apps/tailscale_funnel knows right now: bin, brew, the decoded
-- status, the leased port, whether the funnel is up, and whether a job this
-- plugin started is still running.
function M.setupSteps(env)
  env = env or {}
  local st       = env.status
  local bin      = env.bin ~= nil
  local back     = st and st.backend or nil
  local signedIn = back == "Running"
  local host     = env.hostname or (st and st.hostname) or nil

  local steps = {}
  local function add(step) steps[#steps + 1] = step; return step end

  -- 1. The client. The one step that has to come first, and the one the whole
  --    tile used to say nothing useful about.
  local install = { key = "install", label = "Tailscale installed" }
  if bin then
    install.state = "done"
  elseif env.installing then
    install.state, install.detail = "wait", env.busy or M.INSTALLING
  elseif env.brew then
    install.state, install.action = "todo", "install"
    install.detail = "the plug-in installs the standalone app with Homebrew; macOS asks for your Mac password"
  else
    install.state, install.action = "manual", "install"
    install.detail = "Homebrew is not here — the plug-in opens tailscale.com/download; running the installer is yours"
  end
  add(install)

  -- 2. Signing in. The plugin starts it and opens the page; which account to
  --    use, and the password for it, are not things a config can hold.
  local signin = { key = "signin", label = "Signed in to a tailnet" }
  if not bin then
    signin.state, signin.detail = "wait", "waiting for the client"
  elseif env.signingIn then
    signin.state, signin.detail = "wait", env.busy or M.SIGNING_IN
  elseif signedIn then
    signin.state = "done"
  elseif back == "NeedsMachineAuth" then
    signin.state, signin.action = "manual", "adminmachines"
    signin.detail = "this Mac is waiting to be approved — a tailnet admin approves it in the admin console"
  elseif back == "Starting" then
    signin.state, signin.detail = "wait", "tailscaled is starting"
  elseif back == "NoState" then
    signin.state, signin.action = "todo", "openapp"
    signin.detail = "tailscaled is not answering — the plug-in opens the Tailscale app"
  elseif st == nil then
    signin.state, signin.action = "wait", "check"
    signin.detail = "nothing has been read from the CLI yet"
  else
    signin.state, signin.action = "todo", "signin"
    signin.detail = (st.authUrl and "a sign-in is half-finished — the plug-in reopens the page"
                                 or "the plug-in opens the sign-in page")
                    .. "; choosing an account and approving this Mac is yours"
  end
  add(signin)

  -- 3. MagicDNS and HTTPS certificates. Tailnet-wide switches in the admin
  --    console: there is no CLI for either, and there could not be, because
  --    they are decisions about the tailnet and not about this Mac.
  local dns = { key = "dns", label = "MagicDNS and HTTPS certificates on" }
  if not signedIn then
    dns.state, dns.detail = "wait", "waiting for this Mac to be signed in"
  elseif host then
    dns.state = "done"
  else
    dns.state, dns.action = "manual", "admindns"
    dns.detail = "turn both on in the admin console — a tailnet setting is not one a Mac can change for itself"
  end
  add(dns)

  -- 4. The funnel node attribute. Same shape: the policy file is the tailnet's,
  --    so the plugin brings the snippet to it rather than the other way round.
  local cap = { key = "funnel", label = "Funnel allowed in this tailnet" }
  if not signedIn then
    cap.state, cap.detail = "wait", "waiting for this Mac to be signed in"
  elseif st.funnel == true then
    cap.state = "done"
  elseif st.funnel == false then
    cap.state, cap.action = "manual", "adminacl"
    cap.detail = "the plug-in copies the policy snippet and opens the policy file — pasting and saving it is yours"
  else
    cap.state, cap.action = "wait", "adminacl"
    cap.detail = "this client does not report it; turning the funnel on will say"
  end
  add(cap)

  -- 5. Something to carry. A funnel in front of a port nobody serves is an
  --    address that answers 502, so this is a real prerequisite and not a
  --    detail of the voice agent's.
  local lease = { key = "lease", label = "A local port to carry" }
  if env.port then
    lease.state = "done"
  else
    lease.state, lease.action = "manual", "copyenv"
    lease.detail = "nothing has leased the funnel — the plug-in copies the voice agent's settings; starting the daemon is yours"
  end
  add(lease)

  -- 6. Arming it. One click, once, and deliberately still a click: publishing
  --    a port to the public internet is not a decision a checklist makes.
  local arm = { key = "arm", label = "The funnel is on" }
  if env.funnel and env.url then
    arm.state = "done"
  elseif not (bin and signedIn and host and env.port) then
    arm.state, arm.detail = "wait", "waiting for the steps above"
  else
    arm.state, arm.action = "todo", "arm"
    arm.detail = "one click, once — the route is written into tailscaled and survives a reboot"
  end
  add(arm)

  -- 7. Meta. Behind a login this plugin does not have, on a dashboard it
  --    cannot read, so it is never ticked and never pretends to be.
  local meta = { key = "meta", label = "Meta's callback URL set", checkable = false }
  if not host then
    meta.state, meta.detail = "wait", "waiting for this Mac's .ts.net name"
  else
    meta.state, meta.action = "manual", "copyhook"
    meta.detail = "the plug-in copies " .. M.webhookUrl(host) ..
                  " — setting it in Meta's App Dashboard is yours, and is the one step the plug-in cannot check"
  end
  add(meta)

  return steps
end

function M.stepLine(step)
  step = step or {}
  return (M.MARK[step.state] or M.MARK.wait) .. "  " .. tostring(step.label or "")
end

-- The row the submenu hangs off. The steps the plugin cannot check are counted
-- separately rather than held against the total, because a checklist that can
-- never reach the end is one nobody finishes.
function M.setupLine(steps)
  local done, total, blind = 0, 0, 0
  for _, step in ipairs(steps or {}) do
    if step.checkable == false then
      blind = blind + 1
    else
      total = total + 1
      if step.state == "done" then done = done + 1 end
    end
  end
  local line = string.format("Setup — %d of %d done", done, total)
  if blind > 0 then line = line .. string.format(", %d only you can confirm", blind) end
  return line
end

-- The one thing to do next, which is what the top-level menu hoists to a
-- button so the answer to "what now" is a click and not a read.
function M.nextStep(steps)
  for _, step in ipairs(steps or {}) do
    if step.state ~= "done" then return step end
  end
  return nil
end

-- Is every step the plugin can see finished? The ones it cannot check do not
-- count against it, for the same reason they do not count in setupLine.
function M.setupDone(steps)
  for _, step in ipairs(steps or {}) do
    if step.checkable ~= false and step.state ~= "done" then return false end
  end
  return true
end

-- ── Tile ───────────────────────────────────────────────────────────────────
-- The tile's glyph is a status light. Green means the funnel is carrying the
-- leased port; red means it is not, which covers both "off" and "broken";
-- amber is the in-between, where the CLI has been asked and has not answered.
M.DOT = {
  off      = "\u{1F534}",   -- red
  starting = "\u{1F7E1}",   -- amber
  ready    = "\u{1F7E2}",   -- green
  error    = "\u{1F534}",   -- red
}

-- The same four states as a word, for a menu row that has space for one.
M.LABEL = {
  off = "Off", starting = "Checking", ready = "On", error = "Error",
}

function M.statusDot(s)   return M.DOT[M.computeStatus(s)]   or M.DOT.off   end
function M.statusLabel(s) return M.LABEL[M.computeStatus(s)] or M.LABEL.off end

function M.title(s) return M.statusDot(s) end

function M.humanDuration(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  if seconds < 60 then return string.format("%ds", seconds) end
  if seconds < 3600 then return string.format("%dm %ds", seconds // 60, seconds % 60) end
  return string.format("%dh %dm", seconds // 3600, (seconds % 3600) // 60)
end

-- The menu's first row: the light, the word for it, and the one detail that
-- matters in that state. Nothing here repeats the URL — that has its own row,
-- because a row you can read is a row you can copy from.
function M.statusLine(s, now)
  local status = M.computeStatus(s)
  local head = M.statusDot(s) .. "  " .. M.statusLabel(s)
  -- Same reason as computeStatus: what the plugin is doing now beats what was
  -- wrong a second ago, and it is the line that will change on its own.
  if s.busy and s.busy ~= "" then return head .. " · " .. s.busy end
  if status == "ready" then
    return string.format("%s · up %s · generation %d", head,
                         M.humanDuration(M.uptime(s, now)), s.generation or 0)
  end
  if status == "error" then
    return head .. " · " .. (s.err or "something went wrong")
  end
  if status == "starting" then
    return head .. " · " .. (s.err or "asking tailscale")
  end
  if s.mode == "off" and s.url and s.url ~= "" then
    return head .. " · the lease supplies " .. s.url
  end
  if M.activeCount(s.leases, now) > 0 then
    return head .. " · " .. (s.err or M.FUNNEL_OFF)
  end
  return head .. " · nothing has leased the funnel"
end

-- The URL row. There is one even when there is no URL, so "Copy URL" keeps its
-- place in the menu instead of sliding under the pointer as a funnel comes up.
-- The hostname is shown before anything is published, because it is the
-- address either way and it is the one a human has to paste into Meta's
-- dashboard — and the only honest thing to say beside it is that nothing is
-- carrying it yet.
M.NO_URL = "No public address yet"

function M.urlLine(s)
  s = s or {}
  if s.url and s.url ~= "" then return s.url end
  local host = M.hostUrl(s.hostname)
  if host then return host .. "   (funnel off)" end
  return M.NO_URL
end

-- What Copy URL puts on the clipboard: the live address, or the one this Mac
-- will answer on once the funnel is armed. Both are the same string; only one
-- of them works today.
function M.copyable(s)
  s = s or {}
  if s.url and s.url ~= "" then return s.url end
  return M.hostUrl(s.hostname)
end

-- Everything the tile shows that can change on its own, as one string.
-- apps/tailscale_funnel redraws after every decision, and most of those
-- redraws draw what was already there; this is how it tells the one that is a
-- real change — the funnel coming up, a URL, an error — from the twenty that
-- are not. Uptime is deliberately absent: it moves every second and changes
-- nothing.
function M.tileKey(s)
  s = s or {}
  return table.concat({ M.computeStatus(s), s.url or "-", s.hostname or "-",
                        tostring(s.generation or 0), s.err or "-", s.busy or "-" }, "|")
end

-- First line only: lib/menuhub takes it as the tile's status and strips the
-- leading "Tailscale Funnel: " because it shares the name's first four
-- letters. It also upper-cases the first letter of what is left, which is why
-- `ready` leads with a word rather than with "https".
function M.tooltip(s, now)
  local status = M.computeStatus(s)
  if s.busy and s.busy ~= "" then return "Tailscale Funnel: " .. s.busy end
  if status == "error" then
    return "Tailscale Funnel: " .. (s.err or "error")
  end
  if status == "ready" then
    return string.format("Tailscale Funnel: on at %s\n%s, generation %d",
                         s.url, M.humanDuration(M.uptime(s, now)), s.generation or 0)
  end
  if status == "starting" then
    return "Tailscale Funnel: " .. (s.err or "asking tailscale…")
  end
  -- An `off` lease means the owner brought its own public URL. Showing it beats
  -- showing nothing: it is still the address traffic arrives on.
  if s.mode == "off" and s.url and s.url ~= "" then
    return "Tailscale Funnel: off; the lease supplies " .. s.url
  end
  if s.hostname and s.hostname ~= "" then
    return "Tailscale Funnel: off at " .. M.hostUrl(s.hostname)
  end
  return "Tailscale Funnel: ready for leases"
end

return M
