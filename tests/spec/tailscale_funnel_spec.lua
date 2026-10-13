-- The funnel, both halves.
--
-- lib/tailscale_funnel is pure, so it is driven directly: the argument lists,
-- the two JSON documents the CLI prints, what its complaints mean, the leases
-- and the three endpoints.
--
-- apps/tailscale_funnel is the part that could only be checked by publishing a
-- port to the public internet, so the three things it talks to are replaced:
-- hs.task hands back a child that answers with output this file wrote, the
-- clock is a number it moves, and the probe answers whatever the test wants.
-- No `tailscale` runs and nothing is published. What is left to assert on is
-- the decision — ask, arm, refuse, report — which is the only part that was
-- ever worth testing.

_G.hs = require("hs")

local T       = require("lib.tailscale_funnel")
local context = require("lib.context")
local utils   = require("lib.utils")

local HOST = "pm-mac.yak-bebop.ts.net"

-- `tailscale status --json`, trimmed to the keys this plugin reads. The
-- capability values really are null: that is why funnelAllowed reads the text
-- rather than the decoded document.
local STATUS = [[{
  "Version": "1.78.1",
  "BackendState": "Running",
  "MagicDNSSuffix": "yak-bebop.ts.net",
  "Self": {
    "ID": "nodeid-1234",
    "HostName": "pm-mac",
    "DNSName": "pm-mac.yak-bebop.ts.net.",
    "OS": "macOS",
    "Online": true,
    "CapMap": {
      "https://tailscale.com/cap/funnel": null,
      "https://tailscale.com/cap/ssh": null
    }
  }
}]]

local LOGGED_OUT = [[{"Version":"1.78.1","BackendState":"NeedsLogin","Self":{"CapMap":{}}}]]

local NO_FUNNEL_CAP = [[{
  "BackendState": "Running",
  "Self": { "DNSName": "pm-mac.yak-bebop.ts.net.", "CapMap": { "https://tailscale.com/cap/ssh": null } }
}]]

-- `tailscale serve status --json`, carrying 8794 behind the funnel.
local function serveOn(port)
  return string.format([[{
    "TCP": {"443": {"HTTPS": true}},
    "Web": {"%s:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:%d"}}}},
    "AllowFunnel": {"%s:443": true}
  }]], HOST, port, HOST)
end

local SERVE_ON  = serveOn(8794)
local SERVE_OFF = "{}"

-- ════════════════════════════════════════════════════════════════════════════
-- The pure half
-- ════════════════════════════════════════════════════════════════════════════

describe("tailscale_funnel commands", function()
  it("reads the machine and the serve config with two read-only commands", function()
    assert.same({ "status", "--json" }, T.statusCommand())
    assert.same({ "serve", "status", "--json" }, T.serveCommand())
  end)

  it("arms the funnel in the background, on 443, pointed at the local port", function()
    -- --bg is what makes the route outlive the shell and survive a reboot.
    assert.same({ "funnel", "--bg", "--https=443", "http://127.0.0.1:8794" },
                T.onCommand(8794))
  end)

  it("turns it off on the same port it was turned on", function()
    assert.same({ "funnel", "--https=443", "off" }, T.offCommand())
  end)

  it("builds the origin from the leased port", function()
    assert.equals("http://127.0.0.1:9000", T.origin(9000))
    assert.equals("http://127.0.0.1:9000", T.origin("9000"))
  end)
end)

describe("tailscale_funnel.findBin", function()
  it("prefers the standalone app, which is the build that has Funnel", function()
    local there = { ["/opt/homebrew/bin/tailscale"] = true,
                    ["/Applications/Tailscale.app/Contents/MacOS/Tailscale"] = true }
    assert.equals("/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                  T.findBin(function(p) return there[p] end))
  end)

  it("falls back to Homebrew", function()
    local there = { ["/opt/homebrew/bin/tailscale"] = true }
    assert.equals("/opt/homebrew/bin/tailscale", T.findBin(function(p) return there[p] end))
  end)

  it("answers nil when the CLI is nowhere", function()
    assert.is_nil(T.findBin(function() return false end))
  end)
end)

describe("tailscale_funnel.parseStatus", function()
  it("takes the hostname without the trailing dot a URL would carry", function()
    local s = T.parseStatus(STATUS)
    assert.equals(HOST, s.hostname)
    assert.equals("Running", s.backend)
    assert.is_true(s.online)
  end)

  it("sees the funnel capability even though its value is null", function()
    -- A JSON decoder that turns null into "absent" drops the key, so the
    -- capability is read off the text instead.
    assert.is_true(T.parseStatus(STATUS).funnel)
    assert.is_nil(T.decode(STATUS).Self.CapMap["https://tailscale.com/cap/funnel"])
  end)

  it("says the capability is missing when the map is there without it", function()
    assert.is_false(T.parseStatus(NO_FUNNEL_CAP).funnel)
  end)

  it("answers 'cannot tell' for a client that prints no capabilities", function()
    assert.is_nil(T.parseStatus('{"BackendState":"Running","Self":{"DNSName":"x.ts.net."}}').funnel)
  end)

  it("answers nil for anything that is not JSON", function()
    assert.is_nil(T.parseStatus("command not found"))
    assert.is_nil(T.parseStatus(nil))
  end)
end)

describe("tailscale_funnel.statusProblem", function()
  it("is nothing when this Mac is logged in, named and allowed", function()
    assert.is_nil(T.statusProblem(T.parseStatus(STATUS)))
  end)

  it("says to log in", function()
    assert.equals(T.NOT_LOGGED_IN, T.statusProblem(T.parseStatus(LOGGED_OUT)))
  end)

  it("says to turn MagicDNS on when there is no name yet", function()
    assert.equals(T.NO_HOSTNAME, T.statusProblem({ backend = "Running" }))
  end)

  it("says to grant the node attribute when Funnel is not allowed", function()
    assert.equals(T.NOT_ALLOWED, T.statusProblem(T.parseStatus(NO_FUNNEL_CAP)))
  end)

  it("gives a client that is still coming up the benefit of the doubt", function()
    assert.is_nil(T.statusProblem({ backend = "Starting", hostname = HOST }))
  end)

  it("says so when nothing answered at all", function()
    assert.equals(T.NO_STATUS, T.statusProblem(nil))
  end)
end)

describe("tailscale_funnel.parseServe", function()
  it("reads the host and the port behind a live funnel", function()
    local s = T.parseServe(SERVE_ON)
    assert.is_true(s.on)
    assert.equals(HOST, s.host)
    assert.equals(443, s.funnelPort)
    assert.equals("http://127.0.0.1:8794", s.target)
    assert.equals(8794, s.port)
  end)

  it("is off for an empty serve config, however it says so", function()
    assert.is_false(T.parseServe(SERVE_OFF).on)
    assert.is_false(T.parseServe("").on)
    assert.is_false(T.parseServe("No serve config\n").on)
    assert.is_false(T.parseServe(nil).on)
  end)

  it("is off when the funnel is open on a host with nothing behind it", function()
    -- An open funnel with no handler reaches nothing; calling that "on" would
    -- hand a caller an address that answers 502.
    assert.is_false(T.parseServe(
      string.format('{"AllowFunnel":{"%s:443":true},"Web":{}}', HOST)).on)
  end)

  it("is off when something is served but the funnel is not open on it", function()
    assert.is_false(T.parseServe(string.format(
      '{"Web":{"%s:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8794"}}}}}', HOST)).on)
  end)

  it("also reads the human-readable form, for a client whose JSON it misses", function()
    local text = "https://" .. HOST .. " (Funnel on)\n|-- / proxy http://127.0.0.1:8794\n"
    local s = T.parseServe(text)
    assert.is_true(s.on)
    assert.equals(HOST, s.host)
    assert.equals(8794, s.port)
  end)
end)

describe("tailscale_funnel.portProblem", function()
  it("says so when the funnel carries somebody else's port", function()
    local why = T.portProblem(T.parseServe(serveOn(9999)), 8794)
    assert.truthy(why:find("9999", 1, true))
    assert.truthy(why:find("8794", 1, true))
  end)

  it("is quiet when it carries the leased one", function()
    assert.is_nil(T.portProblem(T.parseServe(SERVE_ON), 8794))
  end)

  it("is quiet when there is no funnel and when there is no lease", function()
    assert.is_nil(T.portProblem(T.parseServe(SERVE_OFF), 8794))
    assert.is_nil(T.portProblem(T.parseServe(SERVE_ON), nil))
  end)
end)

describe("tailscale_funnel.classify", function()
  it("reads a tailnet without the node attribute as fatal, and says what to add", function()
    local kind, why = T.classify(
      "Funnel is not enabled on your tailnet.\nTo enable, add the attribute to nodeAttrs")
    assert.equals("fatal", kind)
    assert.equals(T.NOT_ALLOWED, why)
  end)

  it("reads a dead tailscaled as fatal", function()
    assert.equals(T.NOT_RUNNING,
                  select(2, T.classify("failed to connect to local tailscaled; is tailscaled running?")))
  end)

  it("reads a logged-out client as fatal", function()
    assert.equals(T.NOT_LOGGED_IN, select(2, T.classify("Logged out.")))
  end)

  it("reads a tailnet without HTTPS as fatal", function()
    assert.equals(T.NO_HTTPS, select(2, T.classify("error: HTTPS must be enabled")))
  end)

  it("leaves ordinary output alone", function()
    assert.equals("ok", (T.classify('{"BackendState":"Running"}')))
    assert.is_nil(T.fatalReason(42))
  end)
end)

describe("tailscale_funnel.badRequest", function()
  it("insists on an owner, because a lease without one can never be renewed", function()
    assert.equals("owner is required", T.badRequest(T.normalize({ mode = "funnel", port = 1 })))
  end)

  it("insists on a port for anything that runs a funnel", function()
    assert.truthy(T.badRequest(T.normalize({ owner = "a", mode = "funnel" })):find("port"))
  end)

  it("needs no port for off", function()
    assert.is_nil(T.badRequest(T.normalize({ owner = "a", mode = "off" })))
  end)

  it("refuses the modes that left with cloudflared", function()
    assert.truthy(T.badRequest(T.normalize({ owner = "a", mode = "quick", port = 1 })))
    assert.truthy(T.badRequest(T.normalize({ owner = "a", mode = "named", port = 1 })))
  end)
end)

describe("tailscale_funnel.normalize", function()
  it("defaults to funnel mode", function()
    assert.equals("funnel", T.normalize({ owner = "a" }).mode)
  end)

  it("strips the trailing slash a caller would append a path to", function()
    assert.equals("https://x.ts.net", T.normalize({ public_url = "https://x.ts.net//" }).public_url)
  end)

  it("defaults the TTL and refuses a useless one", function()
    assert.equals(T.LEASE_TTL_S, T.normalize({}).ttl_s)
    assert.equals(T.LEASE_TTL_S, T.normalize({ ttl_s = 0 }).ttl_s)
    assert.equals(45, T.normalize({ ttl_s = "45" }).ttl_s)
  end)
end)

describe("tailscale_funnel.request", function()
  it("reads a JSON body", function()
    local r = T.request('{"owner":"voice","mode":"funnel","port":8794}')
    assert.equals("voice", r.owner)
    assert.equals(8794, r.port)
  end)

  it("reads a form body", function()
    assert.equals("voice", T.request("owner=voice&mode=funnel&port=1").owner)
  end)

  it("falls back to query parameters, so a bodyless GET still works", function()
    local r = T.request(nil, T.params("/lease?owner=voice&port=8794"))
    assert.equals("voice", r.owner)
    assert.equals(8794, r.port)
  end)

  it("lets the body win over the query string", function()
    assert.equals("body", T.request('{"owner":"body"}', { owner = "query" }).owner)
  end)
end)

describe("tailscale_funnel leases", function()
  it("drops the ones nobody renewed and says whose they were", function()
    local leases = { a = { expires = 10 }, b = { expires = 50 }, c = { expires = 5 } }
    assert.same({ "a", "c" }, T.expire(leases, 20))
    assert.is_nil(leases.a)
    assert.truthy(leases.b)
  end)

  it("gives the port to whoever leased first, and keeps giving it", function()
    local leases = {
      late  = { expires = 99, taken = 2, req = { port = 2 } },
      early = { expires = 99, taken = 1, req = { port = 1 } },
    }
    local req, owner = T.primary(leases, 0)
    assert.equals("early", owner)
    assert.equals(1, req.port)
  end)

  it("lists the live ones by owner, so the menu does not reshuffle", function()
    local leases = { zed = { expires = 110 }, amy = { expires = 130 } }
    assert.same({ { owner = "amy", expires_in = 30 },
                  { owner = "zed", expires_in = 10 } },
                T.activeList(leases, 100))
  end)

  it("counts a lease that expires exactly now as gone, the way expire does", function()
    assert.same({}, T.activeList({ amy = { expires = 100 } }, 100))
    assert.equals(0, T.activeCount({ amy = { expires = 100 } }, 100))
  end)

  it("refuses a second origin on one funnel", function()
    assert.truthy(T.conflict({ port = 8794, mode = "funnel" }, { port = 9000, mode = "funnel" }))
    assert.is_nil(T.conflict({ port = 8794, mode = "funnel" }, { port = 8794, mode = "funnel" }))
  end)
end)

describe("tailscale_funnel.computeStatus", function()
  it("is error when it is fatal, whatever else is true", function()
    assert.equals("error", T.computeStatus({ fatal = true, funnel = true, url = "https://x" }))
  end)

  it("is ready only with both a URL and a funnel carrying it", function()
    assert.equals("ready", T.computeStatus({ url = "https://x", funnel = true }))
    -- A hostname with nothing published is a name, not an address.
    assert.equals("off", T.computeStatus({ url = "https://x" }))
  end)

  it("is checking while the CLI has been asked and has not answered", function()
    assert.equals("starting", T.computeStatus({ pending = true }))
  end)

  it("is off with nothing going on, and for a lease that brought its own URL", function()
    assert.equals("off", T.computeStatus({}))
    assert.equals("off", T.computeStatus({ mode = "off", funnel = true, url = "https://x" }))
  end)
end)

describe("tailscale_funnel.encodeState", function()
  it("always writes every key, even the empty ones", function()
    local json = T.encodeState(T.snapshot({ generation = 0, leases = {} }, 100))
    for _, key in ipairs(T.STATE_KEYS) do
      assert.truthy(json:find('"' .. key .. '"', 1, true), "missing key " .. key)
    end
    assert.truthy(json:find('"error":null', 1, true))
    assert.truthy(json:find('"url":null', 1, true))
    assert.truthy(json:find('"funnel":false', 1, true))
    assert.truthy(json:find('"leases":[]', 1, true))
  end)

  it("round-trips through its own decoder", function()
    local snap = T.snapshot({ url = "https://" .. HOST, hostname = HOST, funnel = true,
                              generation = 4, mode = "funnel", port = 8794,
                              startedAt = 40, leases = {} }, 100)
    local back = T.decode(T.encodeState(snap))
    assert.equals("ready", back.status)
    assert.equals(HOST, back.hostname)
    assert.equals(4, back.generation)
    assert.equals(60, back.uptime_s)
    assert.is_true(back.funnel)
  end)
end)

describe("tailscale_funnel.probeOk", function()
  it("passes anything when the owner named no expectation", function()
    assert.is_true(T.probeOk("whatever", nil))
    assert.is_true(T.probeOk(nil, ""))
  end)

  it("matches the token the owner chose, ignoring surrounding space", function()
    assert.is_true(T.probeOk("  tok-9 \n", "tok-9"))
    assert.is_false(T.probeOk("tok-8", "tok-9"))
  end)
end)

describe("tailscale_funnel.route", function()
  local calls, target

  before_each(function()
    calls = {}
    target = {
      lease   = function(req) calls.lease = req;        return { status = "ready", code = 200 } end,
      release = function(owner) calls.release = owner;  return { status = "off" } end,
      state   = function() calls.state = (calls.state or 0) + 1; return { status = "off" } end,
    }
  end)

  it("answers /lease from the body", function()
    local body, code = T.route(target, "POST", "/lease",
                               '{"owner":"voice","mode":"funnel","port":8794}')
    assert.equals(200, code)
    assert.equals("voice", calls.lease.owner)
    assert.truthy(body:find('"status":"ready"', 1, true))
  end)

  it("answers /lease from a query string too", function()
    T.route(target, "GET", "/lease?owner=voice&port=8794")
    assert.equals("voice", calls.lease.owner)
  end)

  it("refuses a lease with no owner, without calling through", function()
    local body, code = T.route(target, "POST", "/lease", '{"mode":"funnel","port":1}')
    assert.equals(400, code)
    assert.is_nil(calls.lease)
    assert.equals("owner is required", T.decode(body).error)
  end)

  it("passes the lease's own status code on", function()
    target.lease = function() return { status = "error", code = 503 } end
    local _, code = T.route(target, "POST", "/lease", '{"owner":"a","mode":"funnel","port":1}')
    assert.equals(503, code)
  end)

  it("reads /funnel without touching the lease, and answers /tunnel the same", function()
    assert.equals(200, select(2, T.route(target, "GET", "/funnel")))
    assert.equals(200, select(2, T.route(target, "GET", "/tunnel")))
    assert.equals(2, calls.state)
    assert.is_nil(calls.lease)
  end)

  it("releases by owner", function()
    T.route(target, "POST", "/release", "owner=voice")
    assert.equals("voice", calls.release)
  end)

  it("refuses a release with no owner", function()
    assert.equals(400, select(2, T.route(target, "POST", "/release", "{}")))
  end)

  it("says which endpoint it does not have", function()
    local body, code = T.route(target, "GET", "/nope")
    assert.equals(404, code)
    assert.truthy(T.decode(body).error:find("/nope", 1, true))
  end)
end)

describe("tailscale_funnel status light", function()
  it("is green only while the funnel is actually carrying the port", function()
    assert.equals(T.DOT.ready, T.title({ url = "https://x", funnel = true }))
    assert.equals("On", T.statusLabel({ url = "https://x", funnel = true }))
  end)

  it("is red when nothing is published, off and broken alike", function()
    assert.equals(T.DOT.off, T.title({}))
    assert.equals(T.DOT.error, T.title({ fatal = true }))
    assert.equals(T.DOT.off, T.DOT.error)
    assert.equals("Off", T.statusLabel({}))
    assert.equals("Error", T.statusLabel({ fatal = true }))
  end)

  it("is amber while the CLI is being asked", function()
    assert.equals(T.DOT.starting, T.title({ pending = true }))
    assert.is_true(T.DOT.starting ~= T.DOT.ready)
    assert.equals("Checking", T.statusLabel({ pending = true }))
  end)

  it("is red for a hostname with no funnel behind it", function()
    assert.equals(T.DOT.off, T.title({ hostname = HOST }))
  end)
end)

describe("tailscale_funnel.statusLine", function()
  it("says how long it has been up and which generation it is", function()
    local line = T.statusLine({ url = "https://x", funnel = true, generation = 3,
                                startedAt = 40 }, 100)
    assert.truthy(line:find(T.DOT.ready, 1, true))
    assert.truthy(line:find("On", 1, true))
    assert.truthy(line:find("1m 0s", 1, true))
    assert.truthy(line:find("generation 3", 1, true))
  end)

  it("keeps the URL off it, because the URL has its own row to be copied from", function()
    assert.is_nil(T.statusLine({ url = "https://x", funnel = true, generation = 1,
                                 startedAt = 100 }, 100):find("https://", 1, true))
  end)

  it("says what broke instead", function()
    local line = T.statusLine({ fatal = true, err = T.NOT_ALLOWED }, 100)
    assert.truthy(line:find(T.DOT.error, 1, true))
    assert.truthy(line:find("node attribute", 1, true))
  end)

  it("tells a waiting lease to turn the funnel on", function()
    local s = { hostname = HOST, leases = { voice = { expires = 200 } } }
    assert.truthy(T.statusLine(s, 100):find("turn it on from this menu", 1, true))
  end)

  it("names the lease's own URL when the lease brought one", function()
    assert.truthy(T.statusLine({ mode = "off", url = "https://already.example.com" }, 100)
                   :find("already.example.com", 1, true))
  end)

  it("says nobody has asked for a funnel when nobody has", function()
    assert.truthy(T.statusLine({}, 100):find("nothing has leased", 1, true))
  end)
end)

describe("tailscale_funnel.urlLine and copyable", function()
  it("is the URL when the funnel carries it", function()
    assert.equals("https://" .. HOST, T.urlLine({ url = "https://" .. HOST }))
  end)

  it("shows the address the Mac will answer on, and says it is not live yet", function()
    local line = T.urlLine({ hostname = HOST })
    assert.truthy(line:find("https://" .. HOST, 1, true))
    assert.truthy(line:find("funnel off", 1, true))
  end)

  it("still fills a row when there is nothing at all, so Copy URL does not move", function()
    assert.equals(T.NO_URL, T.urlLine({}))
    assert.equals(T.NO_URL, T.urlLine(nil))
  end)

  it("copies the stable address whether or not it is armed", function()
    -- It is the string that goes into Meta's dashboard, once, and it does not
    -- change when the funnel is turned off and on again.
    assert.equals("https://" .. HOST, T.copyable({ url = "https://" .. HOST }))
    assert.equals("https://" .. HOST, T.copyable({ hostname = HOST }))
    assert.is_nil(T.copyable({}))
  end)
end)

describe("tailscale_funnel.tileKey", function()
  local ready = { url = "https://a", hostname = "a", funnel = true, generation = 1, startedAt = 0 }

  it("changes when the funnel comes up on a new generation", function()
    assert.is_true(T.tileKey(ready) ~= T.tileKey({ url = "https://a", hostname = "a",
                                                   funnel = true, generation = 2 }))
  end)

  it("changes when it breaks", function()
    assert.is_true(T.tileKey(ready) ~= T.tileKey({ fatal = true, err = T.NOT_ALLOWED }))
  end)

  it("ignores the clock, so a tile is not redrawn once a second for nothing", function()
    assert.equals(T.tileKey(ready), T.tileKey({ url = "https://a", hostname = "a",
                                                funnel = true, generation = 1, startedAt = 999 }))
  end)
end)

describe("tailscale_funnel tooltip", function()
  it("leads the ready line with a word, because the hub upper-cases it", function()
    local line = T.tooltip({ url = "https://x", funnel = true, generation = 2,
                             startedAt = 0 }, 90):match("^[^\n]*")
    assert.equals("Tailscale Funnel: on at https://x", line)
  end)

  it("shares its first four letters with the tile name, so the hub strips it", function()
    local hub = require("lib.menuhub")
    assert.equals("On at https://x",
                  hub.statusOf("Tailscale Funnel",
                               T.tooltip({ url = "https://x", funnel = true, startedAt = 0 }, 0)))
  end)

  it("shows the reason when it is broken", function()
    assert.truthy(T.tooltip({ fatal = true, err = T.NOT_ALLOWED }):find("node attribute", 1, true))
  end)

  it("names the address even while the funnel is off", function()
    assert.truthy(T.tooltip({ hostname = HOST }):find(HOST, 1, true))
  end)

  it("names the owner's own URL when the lease asked for off", function()
    assert.truthy(T.tooltip({ mode = "off", url = "https://already.example.com" })
                   :find("https://already.example.com", 1, true))
  end)

  it("rounds a duration to something a human reads", function()
    assert.equals("45s", T.humanDuration(45))
    assert.equals("2m 5s", T.humanDuration(125))
    assert.equals("1h 1m", T.humanDuration(3660))
  end)
end)

-- ════════════════════════════════════════════════════════════════════════════
-- The plugin
-- ════════════════════════════════════════════════════════════════════════════

describe("apps/tailscale_funnel", function()
  local app, clock, runs, cli, hub, probe, contexts, copied
  local realMenuhub, realTaskNew, realAsyncGet, realLogf, realNew, realSetContents

  local STANDALONE = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

  -- The plugin's context is a local inside its file, so there is no handle to
  -- ask for. context.new is wrapped instead and the answer is the sum over
  -- every context the plugin built.
  local function held()
    local n = 0
    for _, c in ipairs(contexts) do n = n + c:count() end
    return n
  end

  local function lease(t) return app.lease(T.normalize(t)) end
  local function tick() app.timer.fn() end

  -- Which commands have been run, as plain strings, so a test can say "and
  -- nothing was published" in one line.
  local function ran()
    local out = {}
    for _, args in ipairs(runs) do out[#out + 1] = table.concat(args, " ") end
    return out
  end

  local function published()
    for _, line in ipairs(ran()) do
      if line:find("funnel --bg", 1, true) or line:find("funnel --https", 1, true) then
        return line
      end
    end
    return nil
  end

  -- The menu as the hub asks for it: a function, called fresh on every open.
  local function row(text)
    for _, it in ipairs(hub.menu()) do
      if type(it.title) == "string" and it.title:find(text, 1, true) then return it end
    end
    return nil
  end

  setup(function()
    realMenuhub  = package.loaded["lib.menuhub"]
    realTaskNew  = hs.task.new
    realAsyncGet = hs.http.asyncGet
    realLogf     = utils.logf
    realNew      = context.new
    realSetContents = hs.pasteboard.setContents
  end)

  teardown(function()
    package.loaded["lib.menuhub"] = realMenuhub
    hs.task.new = realTaskNew
    hs.http.asyncGet, utils.logf = realAsyncGet, realLogf
    context.new = realNew
    hs.pasteboard.setContents = realSetContents
  end)

  before_each(function()
    clock = 1000
    runs, contexts = {}, {}
    context.new = function(name)
      local c = realNew(name)
      contexts[#contexts + 1] = c
      return c
    end
    hub = { made = {}, deleted = {} }
    probe = { code = 200, body = "tok", urls = {} }
    copied = nil
    hs.pasteboard.setContents = function(text) copied = text end
    utils.logf = function() end   -- the plugin logs on every decision

    -- What a fake `tailscale` says to each subcommand. A test rewrites an
    -- entry and the next call answers with it.
    cli = {
      status = { code = 0, out = STATUS },
      serve  = { code = 0, out = SERVE_OFF },
      funnel = { code = 0, out = "" },
    }

    package.loaded["lib.menuhub"] = {
      item = function(name)
        hub.made[#hub.made + 1] = name
        local tile = {}
        function tile:setTitle(t)   hub.title = t;   return self end
        function tile:setIcon()     return self end
        function tile:setTooltip(t) hub.tooltip = t; return self end
        function tile:setMenu(fn)   hub.menu = fn;   return self end
        function tile:delete()      hub.deleted[#hub.deleted + 1] = name end
        return tile
      end,
    }

    -- A `tailscale` that answers out of `cli` as soon as it is started. The
    -- real one is async; nothing here depends on the gap, and a spec that had
    -- to pump a queue for every two-command refresh would be unreadable.
    hs.task.new = function(path, cb, args)
      local t = { path = path, cb = cb, args = args or {}, terminated = false }
      t.terminate = function(self) self.terminated = true; return self end
      t.start = function(self)
        self.started = true
        runs[#runs + 1] = self.args
        local reply = cli[self.args[1]] or { code = 0, out = "" }
        cb(reply.code, reply.out, "")
        return self
      end
      return t
    end

    hs.http.asyncGet = function(url, _, cb)
      probe.urls[#probe.urls + 1] = url
      cb(probe.code, probe.body, {})
    end

    hs.httpserver._servers = {}
    hs.fs._files[STANDALONE] = { mode = "file" }
    context.resetAtExit()

    package.loaded["apps.tailscale_funnel"] = nil
    app = require("apps.tailscale_funnel")
    app.now = function() return clock end
  end)

  after_each(function()
    if app then app.dispose() end
    app = nil
    _G.funnelState, _G.funnelOn, _G.funnelOff, _G.funnelCheck = nil, nil, nil, nil
    hs.fs._files[STANDALONE] = nil
  end)

  -- ── The port ─────────────────────────────────────────────────────────────
  it("listens on 8795 and answers an idle /funnel", function()
    local intake = hs.httpserver._servers[1]
    assert.equals(8795, intake.port)
    assert.is_true(intake.running)

    local body, code = intake.callback("GET", {}, "/funnel", nil)
    assert.equals(200, code)
    local state = T.decode(body)
    assert.equals("off", state.status)
    assert.same({}, state.leases)
    assert.equals(0, state.generation)
  end)

  it("runs nothing on load: a reload must not publish anything", function()
    assert.same({}, ran())
    assert.same({ "Tailscale Funnel" }, hub.made)
  end)

  it("takes a lease through the intake, as a bodyless GET", function()
    local intake = hs.httpserver._servers[1]
    cli.serve.out = SERVE_ON
    local body = intake.callback("GET", {}, "/lease?owner=voice&mode=funnel&port=8794", nil)
    assert.equals("ready", T.decode(body).status)
  end)

  -- ── Reading the Mac ──────────────────────────────────────────────────────
  it("asks tailscale who this Mac is and what it serves, and nothing else", function()
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    assert.same({ "status --json", "serve status --json" }, ran())
    assert.is_nil(published(), "a lease must never publish a port by itself")
    assert.equals(STANDALONE, app.task.path)
  end)

  it("hands out the URL once the funnel is carrying the leased port", function()
    cli.serve.out = SERVE_ON
    local snap = lease({ owner = "voice", mode = "funnel", port = 8794 })

    assert.equals("ready", snap.status)
    assert.equals("https://" .. HOST, snap.url)
    assert.equals(HOST, snap.hostname)
    assert.is_true(snap.funnel)
    assert.equals(1, snap.generation)
    assert.is_nil(snap.error)
  end)

  it("hands out no URL while the funnel is off, and says why", function()
    local snap = lease({ owner = "voice", mode = "funnel", port = 8794 })

    assert.equals("off", snap.status)
    assert.is_nil(snap.url, "a caller must never be given an address nothing answers on")
    assert.equals(HOST, snap.hostname, "the name is still worth knowing")
    assert.truthy(snap.error:find("turn it on", 1, true))
  end)

  it("keeps the same generation across a reload, which is the whole point", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    local first = app.state()

    app.dispose()
    package.loaded["apps.tailscale_funnel"] = nil
    app = require("apps.tailscale_funnel")
    app.now = function() return clock end
    local snap = lease({ owner = "voice", mode = "funnel", port = 8794 })

    assert.equals(first.url, snap.url)
    assert.equals("ready", snap.status)
  end)

  -- ── Arming it ────────────────────────────────────────────────────────────
  it("arms the funnel only when a human asks, on the leased port", function()
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    assert.is_nil(published())

    cli.serve.out = SERVE_ON        -- what tailscaled will hold afterwards
    row("Turn the funnel on").fn()

    assert.equals("funnel --bg --https=443 http://127.0.0.1:8794", published())
    assert.equals("ready", app.state().status)
    assert.equals("https://" .. HOST, app.state().url)
  end)

  it("will not arm a funnel with nothing behind it", function()
    assert.is_true(row("Turn the funnel on").disabled)
    row("Turn the funnel on").fn()
    assert.is_nil(published())
    assert.truthy(app.state().error:find("leased a port", 1, true))
  end)

  it("turns the funnel off on request, and only on request", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    assert.equals("ready", app.state().status)

    cli.serve.out = SERVE_OFF
    row("Turn the funnel off").fn()

    assert.equals("funnel --https=443 off", published())
    assert.equals("off", app.state().status)
  end)

  it("says what the tailnet is missing when tailscale refuses to arm it", function()
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    cli.funnel = { code = 1, out = "Funnel is not enabled on your tailnet.\n" ..
                                  "To enable, add the attribute to nodeAttrs in your policy file" }
    row("Turn the funnel on").fn()

    assert.equals("error", app.state().status)
    assert.equals(T.NOT_ALLOWED, app.state().error)
  end)

  -- ── Going wrong ──────────────────────────────────────────────────────────
  it("says so when the CLI is not installed, and runs nothing", function()
    hs.fs._files[STANDALONE] = nil
    local snap = lease({ owner = "voice", mode = "funnel", port = 8794 })

    assert.same({}, ran())
    assert.equals("error", snap.status)
    assert.equals(T.NOT_INSTALLED, snap.error)
    assert.equals(503, snap.code)
  end)

  it("says so when this Mac is logged out", function()
    cli.status.out = LOGGED_OUT
    local snap = lease({ owner = "voice", mode = "funnel", port = 8794 })
    assert.equals("error", snap.status)
    assert.equals(T.NOT_LOGGED_IN, snap.error)
  end)

  it("says so when Funnel is not allowed in the tailnet", function()
    cli.status.out = NO_FUNNEL_CAP
    local snap = lease({ owner = "voice", mode = "funnel", port = 8794 })
    assert.equals("error", snap.status)
    assert.equals(T.NOT_ALLOWED, snap.error)
  end)

  it("says so when tailscaled is not answering", function()
    cli.status = { code = 1, out = "failed to connect to local tailscaled; is tailscaled running?" }
    local snap = lease({ owner = "voice", mode = "funnel", port = 8794 })
    assert.equals("error", snap.status)
    assert.equals(T.NOT_RUNNING, snap.error)
  end)

  it("refuses to hand out a URL for a funnel pointed at somebody else", function()
    cli.serve.out = serveOn(9999)
    local snap = lease({ owner = "voice", mode = "funnel", port = 8794 })

    assert.equals("error", snap.status)
    assert.is_nil(snap.url)
    assert.truthy(snap.error:find("9999", 1, true))
  end)

  it("clears a fault by itself once the Mac is fixed", function()
    cli.status.out = LOGGED_OUT
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    assert.equals("error", app.state().status)

    -- No Retry button: the human logged in, and the next round notices.
    cli.status.out, cli.serve.out = STATUS, SERVE_ON
    tick()
    assert.equals("ready", app.state().status)
  end)

  -- ── Renewing and sharing ─────────────────────────────────────────────────
  it("answers a renewal from what it already knows, without asking again", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    local asked = #ran()

    clock = clock + 30
    local snap = lease({ owner = "voice", mode = "funnel", port = 8794 })

    assert.equals(asked, #ran(), "a renewal that changed nothing spends no processes")
    assert.equals("ready", snap.status)
    assert.equals(1, snap.generation)
  end)

  it("hands the same funnel to a second owner on the same port", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    local snap = lease({ owner = "notifier", mode = "funnel", port = 8794 })

    assert.equals(200, snap.code)
    assert.equals(2, #snap.leases)
  end)

  it("refuses a second owner that wants a different port", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    local snap = lease({ owner = "other", mode = "funnel", port = 9000 })

    assert.equals(409, snap.code)
    assert.truthy(snap.error:find("8794", 1, true))
    assert.equals(1, #app.state().leases)
  end)

  it("records an off lease, runs nothing, and shows the URL it brought", function()
    local snap = lease({ owner = "voice", mode = "off",
                         public_url = "https://already.example.com/" })
    assert.same({}, ran())
    assert.equals("off", snap.status)
    assert.equals("https://already.example.com", snap.url)
    assert.equals(1, #snap.leases)
  end)

  -- ── Letting go ───────────────────────────────────────────────────────────
  it("leaves the funnel up when the last lease goes, which is the whole point",
     function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794, ttl_s = 10 })
    assert.equals("ready", app.state().status)

    clock = clock + 11
    tick()

    -- The voice agent restarting must not cost the address, and nothing here
    -- may turn a published route off on its own.
    assert.same({}, app.state().leases)
    assert.is_nil(published())
    assert.equals("ready", app.state().status)
    assert.equals("https://" .. HOST, app.state().url)
  end)

  it("releases on request without publishing or unpublishing anything", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    local snap = app.releaseLease("voice")

    assert.same({}, snap.leases)
    assert.is_nil(published())
  end)

  -- ── The watchdog ─────────────────────────────────────────────────────────
  it("re-reads the truth on every tick while a lease is live", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    local asked = #ran()
    tick()
    assert.equals(asked + 2, #ran())
  end)

  it("notices a funnel that was turned off elsewhere", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    cli.serve.out = SERVE_OFF
    tick()

    assert.equals("off", app.state().status)
    assert.is_nil(app.state().url)
  end)

  it("stays quiet between idle polls when nothing has leased a funnel", function()
    for _ = 1, 9 do tick() end
    assert.same({}, ran(), "nothing depends on the answer, so nothing is spent on it")
    tick()
    assert.same({ "status --json", "serve status --json" }, ran())
  end)

  it("runs nothing at all for a lease that brought its own URL", function()
    lease({ owner = "voice", mode = "off", public_url = "https://already.example.com" })
    for _ = 1, 12 do tick() end
    assert.same({}, ran())
  end)

  -- ── Probing ──────────────────────────────────────────────────────────────
  it("asks the origin whether it is still the origin", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794,
            probe_path = "/phone/ping", probe_expect = "tok" })
    tick()

    assert.equals("https://" .. HOST .. "/phone/ping", probe.urls[1])
    assert.equals(0, app.misses)
    assert.equals("ready", app.state().status)
  end)

  it("counts a wrong answer as a miss, even on a 200", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794,
            probe_path = "/ping", probe_expect = "tok" })
    probe.body = "some-other-token"
    tick()
    assert.equals(1, app.misses)
    assert.equals("ready", app.state().status, "one miss is not a dead funnel")
  end)

  it("goes red after three misses in a row, and green again when it answers", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794,
            probe_path = "/ping", probe_expect = "tok" })

    probe.code = 502
    tick(); tick(); tick()
    assert.equals("error", app.state().status)
    assert.equals(T.PROBE_DEAD, app.state().error)
    -- Nothing is restarted for it: there is no child, and re-running the
    -- command would write the route tailscaled already holds.
    assert.is_nil(published())

    probe.code, probe.body = 200, "tok"
    tick()
    assert.equals("ready", app.state().status)
  end)

  it("does not probe a funnel whose owner named no probe path", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    tick()
    assert.same({}, probe.urls)
  end)

  -- ── Operating it by hand ─────────────────────────────────────────────────
  it("checks again on demand", function()
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    local asked = #ran()
    cli.serve.out = SERVE_ON
    row("Check now").fn()
    assert.equals(asked + 2, #ran())
    assert.equals("ready", app.state().status)
  end)

  it("publishes the state to the shell", function()
    assert.is_function(_G.funnelState)
    assert.is_function(_G.funnelOn)
    assert.is_function(_G.funnelOff)
    assert.equals("off", T.decode(_G.funnelState()).status)
  end)

  -- ── The tile ─────────────────────────────────────────────────────────────
  it("shows a red light and an empty address row while nothing is leased", function()
    assert.equals(T.DOT.off, hub.title)
    assert.truthy(row("nothing has leased"))
    assert.truthy(row(T.NO_URL))
  end)

  it("goes green once the funnel carries the port", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    assert.equals(T.DOT.ready, hub.title)
    assert.truthy(hub.tooltip:find(HOST, 1, true))
  end)

  it("goes red the moment it breaks, and says why", function()
    cli.status.out = NO_FUNNEL_CAP
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    assert.equals(T.DOT.error, hub.title)
    assert.truthy(row("node attribute"))
  end)

  it("redraws on the funnel coming up and on an error, not on a quiet tick", function()
    cli.serve.out = SERVE_ON
    local idle = app.tileDraws
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    local ready = app.tileDraws
    assert.is_true(ready > idle)

    clock = clock + T.WATCH_S
    tick()
    assert.equals(ready, app.tileDraws, "the watchdog runs every 30s and changed nothing")

    cli.status.out = LOGGED_OUT
    tick()
    assert.is_true(app.tileDraws > ready)
  end)

  -- ── The menu ─────────────────────────────────────────────────────────────
  it("puts the address on a row of its own and copies it on demand", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })

    assert.truthy(row("https://" .. HOST))
    local copy = row("Copy URL")
    assert.is_false(copy.disabled)
    copy.fn()
    assert.equals("https://" .. HOST, copied)
    assert.equals("https://" .. HOST, app.copyUrl())
  end)

  it("copies the address before it is armed, because that is when it is pasted", function()
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    assert.truthy(row("funnel off"))
    assert.is_false(row("Copy URL").disabled)
    row("Copy URL").fn()
    assert.equals("https://" .. HOST, copied)
  end)

  it("greys Copy URL out when this Mac has no name yet", function()
    cli.status.out = LOGGED_OUT
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    local copy = row("Copy URL")
    assert.is_true(copy.disabled)
    copy.fn()
    assert.is_nil(copied)
    assert.is_nil(app.copyUrl())
  end)

  it("shows the status and who holds a lease", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    assert.truthy(row("On"))
    assert.truthy(row("voice — 2m 0s left"))
    assert.truthy(row("Turn the funnel off"))
    assert.is_nil(row("Turn the funnel on"))
  end)

  -- ── Switching it off ─────────────────────────────────────────────────────
  it("gives back the port, the tile and the globals, and leaves the funnel up", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    local intake = hs.httpserver._servers[1]

    app.dispose()
    app = nil

    assert.is_false(intake.running)
    assert.same({ "Tailscale Funnel" }, hub.deleted)
    assert.is_nil(_G.funnelState)
    -- The funnel belongs to tailscaled, not to this config: switching the
    -- plugin off must not take the address down with it.
    assert.is_nil(published())
  end)

  it("leaves no effect behind", function()
    cli.serve.out = SERVE_ON
    lease({ owner = "voice", mode = "funnel", port = 8794 })

    assert.is_true(held() > 0)
    app.dispose()
    app = nil

    assert.equals(0, held())
    assert.is_nil(_G.funnelCheck)
  end)

  it("holds no handle for a CLI call that already finished", function()
    -- A context that kept one per `tailscale status` would grow a teardown
    -- list for the life of the session.
    lease({ owner = "voice", mode = "funnel", port = 8794 })
    local after = held()
    for _ = 1, 5 do tick() end
    assert.equals(after, held())
  end)
end)
