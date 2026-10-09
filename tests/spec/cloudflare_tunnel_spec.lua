-- The tunnel, both halves.
--
-- lib/cloudflare_tunnel is pure, so it is driven directly: the command line,
-- the banner, the ladder, the leases and the three endpoints.
--
-- apps/cloudflare_tunnel is the part that could only be checked by running
-- cloudflared, so the three things it talks to are replaced: hs.task hands back
-- a child whose output a spec writes itself, the clock is a number this file
-- moves, and the probe answers whatever the test wants. What is left to assert
-- on is the decision — start, keep, restart, back off, give up — which is the
-- only part that was ever worth testing.

_G.hs = require("hs")

local T       = require("lib.cloudflare_tunnel")
local context = require("lib.context")
local utils   = require("lib.utils")

-- ════════════════════════════════════════════════════════════════════════════
-- The pure half
-- ════════════════════════════════════════════════════════════════════════════

describe("cloudflare_tunnel.command", function()
  it("builds a quick tunnel pointed at the local port", function()
    assert.same({ T.DEFAULT_BIN, "tunnel", "--no-autoupdate",
                  "--url", "http://127.0.0.1:8088" },
                T.command({ owner = "a", mode = "quick", port = 8088 }))
  end)

  it("names the tunnel in named mode", function()
    assert.same({ T.DEFAULT_BIN, "tunnel", "--no-autoupdate", "run",
                  "--url", "http://127.0.0.1:9000", "phone" },
                T.command({ owner = "a", mode = "named", port = 9000, name = "phone" }))
  end)

  it("builds nothing for off: the caller already has a URL", function()
    assert.is_nil(T.command({ owner = "a", mode = "off" }))
  end)

  it("honours an explicit binary", function()
    assert.equals("/usr/bin/cloudflared",
                  T.command({ owner = "a", mode = "quick", port = 1, bin = "/usr/bin/cloudflared" })[1])
  end)
end)

describe("cloudflare_tunnel.parseQuickUrl", function()
  it("finds the hostname in the banner", function()
    local banner = [[
      +---------------------------------------+
      |  https://odd-sheep-ride.trycloudflare.com |
      +---------------------------------------+
    ]]
    assert.equals("https://odd-sheep-ride.trycloudflare.com", T.parseQuickUrl(banner))
  end)

  it("never mistakes the API endpoint for a tunnel", function()
    -- This line shows up when cloudflared cannot reach Cloudflare at all.
    -- Handing it back would give a caller a URL that 404s all day.
    assert.is_nil(T.parseQuickUrl(
      "failed to request quick Tunnel: Post https://api.trycloudflare.com/tunnel"))
  end)

  it("skips the API endpoint and takes the real one from the same chunk", function()
    assert.equals("https://good-one.trycloudflare.com", T.parseQuickUrl(
      "https://api.trycloudflare.com\nhttps://good-one.trycloudflare.com"))
  end)

  it("answers nil for anything that is not a string", function()
    assert.is_nil(T.parseQuickUrl(nil))
    assert.is_nil(T.parseQuickUrl(42))
  end)
end)

describe("cloudflare_tunnel.classify", function()
  it("reads a missing cert as fatal, and says what to do", function()
    local kind, why = T.classify("ERR failed to open: no file cert.pem")
    assert.equals("fatal", kind)
    assert.truthy(why:find("cloudflared login", 1, true))
  end)

  it("reads an unknown tunnel name as fatal", function()
    local kind, why = T.classify("ERR couldn't find tunnel phone")
    assert.equals("fatal", kind)
    assert.truthy(why:find("tunnel name", 1, true))
  end)

  it("reads a quota as a rate limit, not a fault", function()
    assert.equals("rate_limit", (T.classify("error 429 Too Many Requests")))
  end)

  it("keeps a fatal fatal even when the same line mentions 429", function()
    assert.equals("fatal", (T.classify("429 too many requests; no file cert.pem")))
  end)

  it("does not read a port that contains 429 as a rate limit", function()
    assert.is_false(T.rateLimited("listening on 127.0.0.1:4290"))
    assert.equals("ok", (T.classify("INF connection established on port 14291")))
  end)
end)

describe("cloudflare_tunnel.badRequest", function()
  it("insists on an owner, because a lease without one can never be renewed", function()
    assert.equals("owner is required", T.badRequest(T.normalize({ mode = "quick", port = 1 })))
  end)

  it("insists on a port for anything that runs a tunnel", function()
    assert.truthy(T.badRequest(T.normalize({ owner = "a", mode = "quick" })):find("port"))
  end)

  it("needs no port for off", function()
    assert.is_nil(T.badRequest(T.normalize({ owner = "a", mode = "off" })))
  end)

  it("rejects a mode it does not have", function()
    assert.truthy(T.badRequest(T.normalize({ owner = "a", mode = "sideways", port = 1 })))
  end)
end)

describe("cloudflare_tunnel.normalize", function()
  it("strips the trailing slash a caller would append a path to", function()
    assert.equals("https://x.com",
                  T.normalize({ public_url = "https://x.com//" }).public_url)
  end)

  it("defaults the TTL and refuses a useless one", function()
    assert.equals(T.LEASE_TTL_S, T.normalize({}).ttl_s)
    assert.equals(T.LEASE_TTL_S, T.normalize({ ttl_s = 0 }).ttl_s)
    assert.equals(45, T.normalize({ ttl_s = "45" }).ttl_s)
  end)

  it("treats an empty string as absent", function()
    assert.is_nil(T.normalize({ name = "", public_url = "", probe_path = "" }).name)
  end)
end)

describe("cloudflare_tunnel.request", function()
  it("reads a JSON body", function()
    local r = T.request('{"owner":"voice","mode":"quick","port":8088}')
    assert.equals("voice", r.owner)
    assert.equals(8088, r.port)
  end)

  it("reads a form body", function()
    assert.equals("voice", T.request("owner=voice&mode=quick&port=1").owner)
  end)

  it("falls back to query parameters, so a bodyless GET still works", function()
    -- hs.httpserver answers 400 to a bodyless POST before the callback runs,
    -- so every endpoint has to work as a GET too.
    local r = T.request(nil, T.params("/lease?owner=voice&port=8088"))
    assert.equals("voice", r.owner)
    assert.equals(8088, r.port)
  end)

  it("lets the body win over the query string", function()
    assert.equals("body", T.request('{"owner":"body"}', { owner = "query" }).owner)
  end)
end)

describe("cloudflare_tunnel.backoff", function()
  it("climbs 30s, 2m, then 10m forever", function()
    assert.equals(30,  T.backoff(1))
    assert.equals(120, T.backoff(2))
    assert.equals(600, T.backoff(3))
    assert.equals(600, T.backoff(9))
  end)

  it("clamps a step below the ladder", function()
    assert.equals(30, T.backoff(0))
    assert.equals(30, T.backoff(nil))
  end)
end)

describe("cloudflare_tunnel leases", function()
  it("drops the ones nobody renewed and says whose they were", function()
    local leases = { a = { expires = 10 }, b = { expires = 50 }, c = { expires = 5 } }
    assert.same({ "a", "c" }, T.expire(leases, 20))
    assert.is_nil(leases.a)
    assert.truthy(leases.b)
  end)

  it("gives the tunnel to whoever took it first, and keeps giving it", function()
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
    local leases = { amy = { expires = 100 } }
    assert.same({}, T.activeList(leases, 100))
    assert.equals(0, T.activeCount(leases, 100))
  end)

  it("refuses a second origin on one child", function()
    assert.truthy(T.conflict({ port = 8088, mode = "quick" },
                             { port = 9000, mode = "quick" }))
    assert.is_nil(T.conflict({ port = 8088, mode = "quick" },
                             { port = 8088, mode = "quick" }))
  end)
end)

describe("cloudflare_tunnel.computeStatus", function()
  it("is error when it is fatal, whatever else is true", function()
    assert.equals("error", T.computeStatus({ fatal = true, child = true, url = "https://x" }))
  end)

  it("is ready only with both a URL and a child", function()
    assert.equals("ready", T.computeStatus({ url = "https://x", child = true }))
    -- A URL with nothing serving it is a leftover string, not a tunnel, and
    -- calling it "starting" would tell a caller to keep waiting for a child
    -- that nobody is going to start.
    assert.equals("off", T.computeStatus({ url = "https://x" }))
  end)

  it("is starting while a backoff runs, so a caller holds its old URL", function()
    assert.equals("starting", T.computeStatus({ pending = true }))
  end)

  it("is off with nothing going on", function()
    assert.equals("off", T.computeStatus({}))
    assert.equals("off", T.computeStatus({ mode = "off", child = true, url = "https://x" }))
  end)
end)

describe("cloudflare_tunnel.encodeState", function()
  it("always writes every key, even the empty ones", function()
    local json = T.encodeState(T.snapshot({ generation = 0, leases = {} }, 100))
    for _, key in ipairs(T.STATE_KEYS) do
      assert.truthy(json:find('"' .. key .. '"', 1, true), "missing key " .. key)
    end
    -- A caller reading state["error"] must not have to know the key vanishes
    -- when nothing is wrong.
    assert.truthy(json:find('"error":null', 1, true))
    assert.truthy(json:find('"leases":[]', 1, true))
  end)

  it("round-trips through its own decoder", function()
    local snap = T.snapshot({ url = "https://x.trycloudflare.com", child = true,
                              generation = 4, mode = "quick", port = 8088,
                              startedAt = 40, leases = {} }, 100)
    local back = T.decode(T.encodeState(snap))
    assert.equals("ready", back.status)
    assert.equals(4, back.generation)
    assert.equals(60, back.uptime_s)
  end)
end)

describe("cloudflare_tunnel.probeOk", function()
  it("passes anything when the owner named no expectation", function()
    assert.is_true(T.probeOk("whatever", nil))
    assert.is_true(T.probeOk(nil, ""))
  end)

  it("matches the token the owner chose, ignoring surrounding space", function()
    assert.is_true(T.probeOk("  tok-9 \n", "tok-9"))
    assert.is_false(T.probeOk("tok-8", "tok-9"))
  end)
end)

describe("cloudflare_tunnel.route", function()
  local calls, target

  before_each(function()
    calls = {}
    target = {
      lease   = function(req) calls.lease = req;     return { status = "ready", code = 200 } end,
      release = function(owner) calls.release = owner; return { status = "off" } end,
      state   = function() calls.state = true;       return { status = "off" } end,
    }
  end)

  it("answers /lease from the body", function()
    local body, code = T.route(target, "POST", "/lease",
                               '{"owner":"voice","mode":"quick","port":8088}')
    assert.equals(200, code)
    assert.equals("voice", calls.lease.owner)
    assert.truthy(body:find('"status":"ready"', 1, true))
  end)

  it("answers /lease from a query string too", function()
    T.route(target, "GET", "/lease?owner=voice&port=8088")
    assert.equals("voice", calls.lease.owner)
  end)

  it("refuses a lease with no owner, without calling through", function()
    local body, code = T.route(target, "POST", "/lease", '{"mode":"quick","port":1}')
    assert.equals(400, code)
    assert.is_nil(calls.lease)
    assert.equals("owner is required", T.decode(body).error)
  end)

  it("passes the lease's own status code on", function()
    target.lease = function() return { status = "error", code = 503 } end
    local _, code = T.route(target, "POST", "/lease", '{"owner":"a","mode":"quick","port":1}')
    assert.equals(503, code)
  end)

  it("reads /tunnel without touching the lease", function()
    local _, code = T.route(target, "GET", "/tunnel")
    assert.equals(200, code)
    assert.is_true(calls.state)
    assert.is_nil(calls.lease)
  end)

  it("releases by owner", function()
    T.route(target, "POST", "/release", "owner=voice")
    assert.equals("voice", calls.release)
  end)

  it("refuses a release with no owner", function()
    local _, code = T.route(target, "POST", "/release", "{}")
    assert.equals(400, code)
  end)

  it("says which endpoint it does not have", function()
    local body, code = T.route(target, "GET", "/nope")
    assert.equals(404, code)
    assert.truthy(T.decode(body).error:find("/nope", 1, true))
  end)
end)

describe("cloudflare_tunnel status light", function()
  it("is green only while a tunnel is actually up", function()
    assert.equals(T.DOT.ready, T.title({ url = "https://x", child = true }))
    assert.equals("Running", T.statusLabel({ url = "https://x", child = true }))
  end)

  it("is red when nothing is serving, stopped and broken alike", function()
    assert.equals(T.DOT.off, T.title({}))
    assert.equals(T.DOT.error, T.title({ fatal = true }))
    -- One colour for both, because the question the light answers is "is there
    -- a tunnel right now", and the answer is no either way.
    assert.equals(T.DOT.off, T.DOT.error)
    assert.equals("Stopped", T.statusLabel({}))
    assert.equals("Error", T.statusLabel({ fatal = true }))
  end)

  it("is amber in between: a child is up, no URL yet", function()
    assert.equals(T.DOT.starting, T.title({ child = true }))
    assert.equals(T.DOT.starting, T.title({ pending = true }))
    assert.is_true(T.DOT.starting ~= T.DOT.ready)
    assert.is_true(T.DOT.starting ~= T.DOT.off)
    assert.equals("Starting", T.statusLabel({ pending = true }))
  end)

  it("is red for a URL with nothing serving it", function()
    -- A leftover string is not a tunnel, and a green light over one would send
    -- somebody to an address that answers nothing.
    assert.equals(T.DOT.off, T.title({ url = "https://x" }))
  end)
end)

describe("cloudflare_tunnel.statusLine", function()
  it("says how long it has been up and which generation it is", function()
    local line = T.statusLine({ url = "https://x", child = true, generation = 3,
                                startedAt = 40 }, 100)
    assert.truthy(line:find(T.DOT.ready, 1, true))
    assert.truthy(line:find("Running", 1, true))
    assert.truthy(line:find("1m 0s", 1, true))
    assert.truthy(line:find("generation 3", 1, true))
  end)

  it("keeps the URL off it, because the URL has its own row to be copied from", function()
    assert.is_nil(T.statusLine({ url = "https://x", child = true, generation = 1,
                                 startedAt = 100 }, 100):find("https://", 1, true))
  end)

  it("says what broke instead", function()
    local line = T.statusLine({ fatal = true, err = "no cert.pem" }, 100)
    assert.truthy(line:find(T.DOT.error, 1, true))
    assert.truthy(line:find("no cert.pem", 1, true))
  end)

  it("says why it is waiting while it waits", function()
    assert.truthy(T.statusLine({ pending = true, err = "cloudflared exited (1)" }, 100)
                   :find("exited", 1, true))
    assert.truthy(T.statusLine({ child = true }, 100):find("waiting for a URL", 1, true))
  end)

  it("says nobody has asked for a tunnel when nobody has", function()
    assert.truthy(T.statusLine({}, 100):find("nothing has leased", 1, true))
  end)
end)

describe("cloudflare_tunnel.urlLine", function()
  it("is the URL when there is one", function()
    assert.equals("https://x.trycloudflare.com",
                  T.urlLine({ url = "https://x.trycloudflare.com" }))
  end)

  it("still fills a row when there is none, so Copy URL does not move", function()
    assert.equals(T.NO_URL, T.urlLine({}))
    assert.equals(T.NO_URL, T.urlLine({ url = "" }))
    assert.equals(T.NO_URL, T.urlLine(nil))
  end)
end)

describe("cloudflare_tunnel.tileKey", function()
  local ready = { url = "https://a", child = true, generation = 1, startedAt = 0 }

  it("changes when a new tunnel hands out a new URL", function()
    local next_ = { url = "https://b", child = true, generation = 2, startedAt = 0 }
    assert.is_true(T.tileKey(ready) ~= T.tileKey(next_))
  end)

  it("changes when it breaks", function()
    assert.is_true(T.tileKey(ready) ~= T.tileKey({ fatal = true, err = "no cert.pem" }))
  end)

  it("ignores the clock, so a tile is not redrawn once a second for nothing", function()
    assert.equals(T.tileKey(ready), T.tileKey({ url = "https://a", child = true,
                                                generation = 1, startedAt = 999 }))
  end)
end)

describe("cloudflare_tunnel tooltip", function()
  it("leads the ready line with a word, because the hub upper-cases it", function()
    local line = T.tooltip({ url = "https://x", child = true, generation = 2,
                             startedAt = 0 }, 90):match("^[^\n]*")
    assert.equals("Cloudflare tunnel: up at https://x", line)
  end)

  it("shows the reason when it is broken", function()
    assert.truthy(T.tooltip({ fatal = true, err = "no cert.pem" }):find("no cert.pem", 1, true))
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

describe("apps/cloudflare_tunnel", function()
  local app, clock, tasks, afters, hub, probe, contexts, copied
  local realMenuhub, realTaskNew, realDoAfter, realAsyncGet, realLogf, realNew
  local realSetContents

  local function child() return tasks[#tasks] end

  -- The plugin's context is a local inside its file, so there is no handle to
  -- ask for. context.new is wrapped instead and the answer is the sum over
  -- every context the plugin built.
  local function held()
    local n = 0
    for _, c in ipairs(contexts) do n = n + c:count() end
    return n
  end

  -- cloudflared writing to its own stdout, the way hs.task streams it.
  local function says(text)
    local t = child()
    t.stream(t, text, "")
  end

  local function lease(t)
    return app.lease(T.normalize(t))
  end

  local function tick() app.timer.fn() end

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
    realDoAfter  = hs.timer.doAfter
    realAsyncGet = hs.http.asyncGet
    realLogf     = utils.logf
    realNew      = context.new
    realSetContents = hs.pasteboard.setContents
  end)

  teardown(function()
    -- Put back everything this file swapped: menuhub_spec sorts after this one
    -- and must not inherit the recording stub.
    package.loaded["lib.menuhub"] = realMenuhub
    hs.task.new, hs.timer.doAfter = realTaskNew, realDoAfter
    hs.http.asyncGet, utils.logf = realAsyncGet, realLogf
    context.new = realNew
    hs.pasteboard.setContents = realSetContents
  end)

  before_each(function()
    clock = 1000
    tasks, afters, contexts = {}, {}, {}
    context.new = function(name)
      local c = realNew(name)
      contexts[#contexts + 1] = c
      return c
    end
    hub = { made = {}, deleted = {} }
    probe = { code = 200, body = "tok", urls = {} }
    copied = nil
    -- The stock mock takes the text as its *second* argument, which
    -- keystroke_typer_spec relies on; the plugin calls the real one-argument
    -- API, so this records that instead of changing the mock under another spec.
    hs.pasteboard.setContents = function(text) copied = text end

    utils.logf = function() end   -- the plugin logs on every decision

    -- A tile that remembers what it was last told to draw, so a test can read
    -- the glyph, the status line and the menu the way a human would see them.
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

    -- A child whose output the test writes and whose exit the test chooses.
    hs.task.new = function(path, done, stream, args)
      local t = { path = path, done = done, stream = stream, args = args or {},
                  started = false, terminated = false }
      t.start     = function(self) self.started = true; return self end
      t.terminate = function(self) self.terminated = true; return self end
      t.isRunning = function(self) return self.started and not self.terminated end
      tasks[#tasks + 1] = t
      return t
    end

    -- The stock mock drops the delay, and the delay is the assertion.
    hs.timer.doAfter = function(delay, fn)
      local t = { delay = delay, fn = fn, stop = function() end }
      t.start = fn
      afters[#afters + 1] = t
      return t
    end

    hs.http.asyncGet = function(url, _, cb)
      probe.urls[#probe.urls + 1] = url
      cb(probe.code, probe.body, {})
    end

    hs.httpserver._servers = {}
    hs.fs._files[T.DEFAULT_BIN] = { mode = "file" }
    context.resetAtExit()

    package.loaded["apps.cloudflare_tunnel"] = nil
    app = require("apps.cloudflare_tunnel")
    app.now = function() return clock end
  end)

  after_each(function()
    if app then app.dispose() end
    app = nil
    _G.tunnelState, _G.tunnelRetry = nil, nil
    hs.fs._files[T.DEFAULT_BIN] = nil
  end)

  -- ── The port ─────────────────────────────────────────────────────────────
  it("listens on 8795 and answers an idle /tunnel", function()
    local intake = hs.httpserver._servers[1]
    assert.equals(8795, intake.port)
    assert.is_true(intake.running)

    local body, code = intake.callback("GET", {}, "/tunnel", nil)
    assert.equals(200, code)
    local state = T.decode(body)
    assert.equals("off", state.status)
    assert.same({}, state.leases)
    assert.equals(0, state.generation)
  end)

  it("starts nothing on load: a tunnel exists because something leased one", function()
    assert.equals(0, #tasks)
    assert.same({ "Cloudflare tunnel" }, hub.made)
  end)

  it("takes a lease through the intake, as a bodyless GET", function()
    local intake = hs.httpserver._servers[1]
    local body = intake.callback("GET", {}, "/lease?owner=voice&mode=quick&port=8088", nil)
    assert.equals("starting", T.decode(body).status)
    assert.equals(1, #tasks)
  end)

  -- ── Starting ─────────────────────────────────────────────────────────────
  it("runs cloudflared against the port the owner asked for", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    assert.equals(T.DEFAULT_BIN, child().path)
    assert.same({ "tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:8088" },
                child().args)
    assert.is_true(child().started)
  end)

  it("turns the banner into a ready URL and a generation", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    assert.equals("starting", app.state().status)

    says("INF |  https://odd-sheep.trycloudflare.com  |")

    local s = app.state()
    assert.equals("ready", s.status)
    assert.equals("https://odd-sheep.trycloudflare.com", s.url)
    assert.equals(1, s.generation)
  end)

  it("ignores the API address in a failure banner", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("ERR failed to request quick Tunnel: Post https://api.trycloudflare.com/tunnel")
    assert.equals("starting", app.state().status)
    assert.is_nil(app.state().url)
  end)

  it("reports a named tunnel's hostname before cloudflared says anything", function()
    lease({ owner = "voice", mode = "named", port = 9000,
            name = "phone", public_url = "https://phone.example.com/" })
    local s = app.state()
    assert.equals("ready", s.status)
    assert.equals("https://phone.example.com", s.url)   -- trailing slash gone
  end)

  it("records an off lease and runs nothing", function()
    lease({ owner = "voice", mode = "off", public_url = "https://already.example.com" })
    assert.equals(0, #tasks)
    local s = app.state()
    assert.equals("off", s.status)
    assert.equals(1, #s.leases)
  end)

  -- ── Renewing and sharing ─────────────────────────────────────────────────
  it("renews without starting a second tunnel", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("https://odd-sheep.trycloudflare.com")
    clock = clock + 30
    lease({ owner = "voice", mode = "quick", port = 8088 })

    assert.equals(1, #tasks)
    assert.equals(1, app.state().generation)
    assert.equals("ready", app.state().status)
  end)

  it("hands the same tunnel to a second owner on the same port", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("https://odd-sheep.trycloudflare.com")
    local snap = lease({ owner = "notifier", mode = "quick", port = 8088 })

    assert.equals(200, snap.code)
    assert.equals(1, #tasks)
    assert.equals(2, #snap.leases)
  end)

  it("refuses a second owner that wants a different port", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("https://odd-sheep.trycloudflare.com")
    local snap = lease({ owner = "other", mode = "quick", port = 9000 })

    -- Being told no beats being handed a URL that reaches somebody else.
    assert.equals(409, snap.code)
    assert.truthy(snap.error:find("8088", 1, true))
    assert.equals(1, #tasks)
    assert.equals(1, #app.state().leases)
  end)

  it("lets the owner driving the tunnel move it, on a new generation", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("https://odd-sheep.trycloudflare.com")
    local first = child()

    lease({ owner = "voice", mode = "quick", port = 9000 })
    assert.is_true(first.terminated)
    assert.equals(2, #tasks)
    assert.same({ "tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:9000" },
                child().args)
    assert.equals(2, app.state().generation)
  end)

  -- ── Letting go ───────────────────────────────────────────────────────────
  it("keeps the tunnel through the grace period after the last lease", function()
    lease({ owner = "voice", mode = "quick", port = 8088, ttl_s = 10 })
    says("https://odd-sheep.trycloudflare.com")

    clock = clock + 11
    tick()
    -- The lease is gone, the tunnel is not: a caller restarting must not lose
    -- its URL and spend another quick-tunnel quota coming back.
    assert.same({}, app.state().leases)
    assert.is_false(child().terminated)
    assert.equals("ready", app.state().status)
  end)

  it("stops the tunnel once the grace period is over", function()
    lease({ owner = "voice", mode = "quick", port = 8088, ttl_s = 10 })
    says("https://odd-sheep.trycloudflare.com")

    clock = clock + 11
    tick()
    clock = clock + T.GRACE_S + 1
    tick()

    assert.is_true(child().terminated)
    assert.equals("off", app.state().status)
  end)

  it("releases on request, and still waits out the grace period", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("https://odd-sheep.trycloudflare.com")
    local snap = app.releaseLease("voice")

    assert.same({}, snap.leases)
    assert.is_false(child().terminated)
    clock = clock + T.GRACE_S + 1
    tick()
    assert.is_true(child().terminated)
  end)

  -- ── Going wrong ──────────────────────────────────────────────────────────
  it("stops for good when the cert is missing", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("ERR cannot determine default origin certificate: no file cert.pem")

    local s = app.state()
    assert.equals("error", s.status)
    assert.truthy(s.error:find("cloudflared login", 1, true))
    assert.is_true(child().terminated)
    -- The point of fatal: no retry is armed, so this does not burn CPU all
    -- night and still not work.
    assert.same({}, afters)
  end)

  it("will not start a named tunnel with no hostname to hand out", function()
    lease({ owner = "voice", mode = "named", port = 9000, name = "phone" })
    assert.equals(0, #tasks)
    assert.truthy(app.state().error:find("public hostname", 1, true))
  end)

  it("will not start when cloudflared is not installed", function()
    hs.fs._files[T.DEFAULT_BIN] = nil
    lease({ owner = "voice", mode = "quick", port = 8088 })
    assert.equals(0, #tasks)
    assert.truthy(app.state().error:find("no cloudflared", 1, true))
  end)

  it("keeps trying after a fatal if the request itself changed", function()
    lease({ owner = "voice", mode = "named", port = 9000, name = "phone" })
    assert.equals("error", app.state().status)

    lease({ owner = "voice", mode = "named", port = 9000, name = "phone",
            public_url = "https://phone.example.com" })
    -- The human acted, so the ladder starts again rather than staying broken
    -- until a reload.
    assert.equals(1, #tasks)
    assert.equals("ready", app.state().status)
  end)

  it("backs off ten minutes on a rate limit, not thirty seconds", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("ERR 429 Too Many Requests")

    assert.equals("starting", app.state().status)   -- a caller holds its old URL
    assert.equals(600, app.pendingTimer.delay)
    assert.is_true(child().terminated)
  end)

  it("retries a child that exited under a live lease", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("https://odd-sheep.trycloudflare.com")
    child().done(1)

    assert.equals(30, app.pendingTimer.delay)
    assert.equals("starting", app.state().status)
    assert.truthy(app.state().error:find("exited", 1, true))

    app.pendingTimer.start()
    assert.equals(2, #tasks)
    assert.equals(2, app.state().generation)
  end)

  it("climbs the ladder while it keeps failing", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    child().done(1)
    assert.equals(30, app.pendingTimer.delay)

    app.pendingTimer.start()
    child().done(1)
    assert.equals(120, app.pendingTimer.delay)

    app.pendingTimer.start()
    child().done(1)
    assert.equals(600, app.pendingTimer.delay)
  end)

  it("treats an exit with no lease left as a stop, not a failure", function()
    lease({ owner = "voice", mode = "quick", port = 8088, ttl_s = 10 })
    clock = clock + 11
    tick()               -- the lease expires, the child is still in its grace
    child().done(0)

    assert.same({}, afters)
    assert.equals("off", app.state().status)
  end)

  it("restarts a child that printed no URL in thirty seconds", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    local first = child()

    clock = clock + T.START_TIMEOUT_S
    tick()

    assert.is_true(first.terminated)
    assert.truthy(app.state().error:find("no URL", 1, true))
    assert.equals(30, app.pendingTimer.delay)
  end)

  -- ── Probing ──────────────────────────────────────────────────────────────
  it("asks the origin whether it is still the origin", function()
    lease({ owner = "voice", mode = "quick", port = 8088,
            probe_path = "/phone/ping", probe_expect = "tok" })
    says("https://odd-sheep.trycloudflare.com")
    tick()

    assert.equals("https://odd-sheep.trycloudflare.com/phone/ping", probe.urls[1])
    assert.equals(0, app.misses)
    assert.equals("ready", app.state().status)
  end)

  it("counts a wrong answer as a miss, even on a 200", function()
    lease({ owner = "voice", mode = "quick", port = 8088,
            probe_path = "/ping", probe_expect = "tok" })
    says("https://odd-sheep.trycloudflare.com")

    -- A different daemon answering through the same tunnel is not healthy.
    probe.body = "some-other-token"
    tick()
    assert.equals(1, app.misses)
  end)

  it("forgives a miss once the tunnel answers again", function()
    lease({ owner = "voice", mode = "quick", port = 8088,
            probe_path = "/ping", probe_expect = "tok" })
    says("https://odd-sheep.trycloudflare.com")

    probe.code = 502
    tick(); tick()
    assert.equals(2, app.misses)

    probe.code, probe.body = 200, "tok"
    tick()
    assert.equals(0, app.misses)
  end)

  it("restarts the tunnel after three misses in a row", function()
    lease({ owner = "voice", mode = "quick", port = 8088,
            probe_path = "/ping", probe_expect = "tok" })
    says("https://odd-sheep.trycloudflare.com")
    local first = child()

    probe.code = 502
    tick(); tick(); tick()

    assert.is_true(first.terminated)
    assert.truthy(app.state().error:find("probe", 1, true))
    assert.equals(30, app.pendingTimer.delay)
  end)

  it("does not probe a tunnel whose owner named no probe path", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("https://odd-sheep.trycloudflare.com")
    tick()
    assert.same({}, probe.urls)
  end)

  -- ── Operating it by hand ─────────────────────────────────────────────────
  it("retries on demand after a fatal", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("ERR no file cert.pem")
    assert.equals("error", app.state().status)

    app.retryNow()
    assert.equals(2, #tasks)
    assert.equals("starting", app.state().status)
  end)

  it("publishes the state to the shell", function()
    assert.is_function(_G.tunnelState)
    assert.equals("off", T.decode(_G.tunnelState()).status)
  end)

  -- ── The tile ─────────────────────────────────────────────────────────────
  it("shows a red light and an empty URL row while nothing is leased", function()
    assert.equals(T.DOT.off, hub.title)
    assert.truthy(row("nothing has leased"))
    assert.truthy(row(T.NO_URL))
  end)

  it("goes amber while the tunnel comes up and green once it is up", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    assert.equals(T.DOT.starting, hub.title)

    says("https://odd-sheep.trycloudflare.com")
    assert.equals(T.DOT.ready, hub.title)
    assert.truthy(hub.tooltip:find("odd-sheep.trycloudflare.com", 1, true))
  end)

  it("goes red the moment it breaks, and says why", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("ERR cannot determine default origin certificate: no file cert.pem")

    assert.equals(T.DOT.error, hub.title)
    assert.truthy(row("cloudflared login"))
  end)

  it("goes back to red once the last lease is gone", function()
    lease({ owner = "voice", mode = "quick", port = 8088, ttl_s = 10 })
    says("https://odd-sheep.trycloudflare.com")
    assert.equals(T.DOT.ready, hub.title)

    clock = clock + 11
    tick()                         -- the lease expires, the child waits out its grace
    assert.equals(T.DOT.ready, hub.title)

    clock = clock + T.GRACE_S + 1
    tick()
    assert.equals(T.DOT.off, hub.title)
    assert.truthy(row(T.NO_URL))
  end)

  it("redraws on a new child, on the URL and on an error — and not on a quiet tick",
     function()
    local idle = app.tileDraws
    lease({ owner = "voice", mode = "quick", port = 8088 })
    local started = app.tileDraws
    assert.is_true(started > idle)              -- a child is up

    says("https://odd-sheep.trycloudflare.com")
    local ready = app.tileDraws
    assert.is_true(ready > started)             -- the URL arrived

    clock = clock + T.WATCH_S
    tick()
    -- Nothing about the tunnel changed, so nothing about the tile did: the
    -- watchdog runs every 30s and must not count as a change.
    assert.equals(ready, app.tileDraws)

    says("ERR no file cert.pem")
    assert.is_true(app.tileDraws > ready)       -- it broke
  end)

  it("follows the URL across a restart onto the new one", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("https://first.trycloudflare.com")
    assert.truthy(row("https://first.trycloudflare.com"))

    lease({ owner = "voice", mode = "quick", port = 9000 })   -- same owner, new target
    assert.equals(T.DOT.starting, hub.title)
    assert.truthy(row(T.NO_URL))

    says("https://second.trycloudflare.com")
    assert.equals(T.DOT.ready, hub.title)
    assert.truthy(row("https://second.trycloudflare.com"))
    assert.is_nil(row("https://first.trycloudflare.com"))
  end)

  -- ── The menu ─────────────────────────────────────────────────────────────
  it("puts the URL on a row of its own and copies it on demand", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("https://odd-sheep.trycloudflare.com")

    assert.truthy(row("https://odd-sheep.trycloudflare.com"))
    local copy = row("Copy URL")
    assert.is_false(copy.disabled)
    copy.fn()
    assert.equals("https://odd-sheep.trycloudflare.com", copied)
    assert.equals("https://odd-sheep.trycloudflare.com", app.copyUrl())
  end)

  it("greys Copy URL out when there is nothing to copy", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })

    local copy = row("Copy URL")
    assert.is_true(copy.disabled)
    copy.fn()                      -- the hub still calls it; it must do nothing
    assert.is_nil(copied)
    assert.is_nil(app.copyUrl())
  end)

  it("shows the status, who holds a lease, and when the next attempt is", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("https://odd-sheep.trycloudflare.com")
    assert.truthy(row("Running"))
    assert.truthy(row("voice — 2m 0s left"))

    child().done(1)
    assert.truthy(row("Next attempt in 30s"))
    assert.truthy(row("Retry now"))
  end)

  it("shows the owner's own URL when the lease asked for off", function()
    lease({ owner = "voice", mode = "off", public_url = "https://already.example.com" })

    -- Nothing of ours is serving it, so the light stays red; the address is
    -- still the one traffic arrives on, so it is still worth copying.
    assert.equals(T.DOT.off, hub.title)
    assert.truthy(row("https://already.example.com"))
    assert.is_false(row("Copy URL").disabled)
  end)

  -- ── Switching it off ─────────────────────────────────────────────────────
  it("gives back the port, the tile, the globals and the child", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    says("https://odd-sheep.trycloudflare.com")
    local intake, running = hs.httpserver._servers[1], child()

    app.dispose()
    app = nil

    -- Without the port, the plugin cannot be switched on again: its own
    -- replacement would find :8795 held by the instance that is supposed to
    -- be gone. Without the terminate, cloudflared outlives the config.
    assert.is_false(intake.running)
    assert.is_true(running.terminated)
    assert.same({ "Cloudflare tunnel" }, hub.deleted)
    assert.is_nil(_G.tunnelState)
  end)

  it("leaves no effect behind", function()
    lease({ owner = "voice", mode = "quick", port = 8088 })
    child().done(1)                      -- a retry armed, a timer, a tile, a port

    assert.is_true(held() > 0)
    app.dispose()
    app = nil

    -- Nothing left that could fire into a plugin that is no longer there: a
    -- timer whose module is gone still ticks, and an armed retry would start
    -- a cloudflared that nothing owns.
    assert.equals(0, held())
    assert.is_nil(_G.tunnelRetry)
  end)
end)
