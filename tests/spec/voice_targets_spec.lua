-- Pure routing logic for lib/voice_targets: target resolution across both
-- transports, which chord picks which supervisor, the per-transport delivery
-- steps, and the refusals that keep dictation out of a crewmate pane.
-- No hs.* here — the module deliberately has no Hammerspoon dependency.

local vt = require("lib.voice_targets")

-- Minimal config shaped like lib/config.lua's voice keys: the Orchestrator on
-- zellij, the firstmate primary on tmux.
local function cfg(overrides)
  local c = {
    VOICE_TARGETS = {
      orchestrator = { transport = "zellij", session = "Orchestrator",
                       label = "Orchestrator", chord = "a",
                       input = "write-chars", submit = "write13" },
      firstmate    = { transport = "tmux", target = "firstmate:0.0",
                       label = "firstmate", chord = "p" },
    },
    VOICE_TRANSPORTS = {
      zellij = { bin = "/cargo/bin/zellij", env = { HOME = "/home", PATH = "/zbin" } },
      tmux   = { bin = "/opt/homebrew/bin/tmux", env = { HOME = "/home", PATH = "/tbin" } },
    },
    VOICE_TARGET_DEFAULT    = "orchestrator",
    VOICE_TMUX_BUFFER       = "hs-voice",
    FIRSTMATE_CREW_SESSIONS = { "firstmate" },
  }
  for k, v in pairs(overrides or {}) do c[k] = v end
  return c
end

-- Collapse a step list to { name, argv…, stdin } shapes for readable asserts.
local function argvOf(steps)
  local out = {}
  for i, s in ipairs(steps) do out[i] = s.argv end
  return out
end
local function namesOf(steps)
  local out = {}
  for i, s in ipairs(steps) do out[i] = s.name end
  return out
end

describe("voice_targets.resolve", function()
  it("resolves the orchestrator route onto the zellij transport", function()
    local t = vt.resolve(cfg(), "orchestrator")
    assert.equals("orchestrator", t.key)
    assert.equals("zellij", t.transport)
    assert.equals("Orchestrator", t.address)
    assert.equals("Orchestrator", t.session)
    assert.is_nil(t.target)
    assert.equals("Orchestrator", t.label)
    assert.equals("a", t.chord)
    assert.equals("write-chars", t.input)
    assert.equals("write13", t.submit)
    assert.is_nil(t.paneId)
  end)

  it("resolves the firstmate route onto the tmux transport", function()
    local t = vt.resolve(cfg(), "firstmate")
    assert.equals("tmux", t.transport)
    assert.equals("firstmate:0.0", t.address)
    assert.equals("firstmate:0.0", t.target)
    assert.is_nil(t.session)
    assert.equals("firstmate", t.label)
    assert.equals("p", t.chord)
  end)

  it("defaults a target that names no transport to zellij", function()
    local c = cfg()
    c.VOICE_TARGETS.legacy = { session = "Legacy" }
    local t = vt.resolve(c, "legacy")
    assert.equals("zellij", t.transport)
    assert.equals("Legacy", t.address)
  end)

  it("refuses an unknown transport", function()
    local c = cfg()
    c.VOICE_TARGETS.weird = { transport = "screen", session = "x" }
    local t, why = vt.resolve(c, "weird")
    assert.is_nil(t)
    assert.truthy(why:find("unknown transport"))
  end)

  it("reads the address from the field its transport owns", function()
    local c = cfg()
    -- a tmux entry carrying only `session` has no address at all
    c.VOICE_TARGETS.firstmate = { transport = "tmux", session = "firstmate:0.0" }
    local t, why = vt.resolve(c, "firstmate")
    assert.is_nil(t)
    assert.truthy(why:find("no target"))
  end)

  it("falls back to the route key when no label is given", function()
    local c = cfg()
    c.VOICE_TARGETS.bare = { session = "Bare" }
    assert.equals("bare", vt.resolve(c, "bare").label)
  end)

  it("defaults a zellij target naming no input/submit to the historical pair", function()
    local c = cfg()
    c.VOICE_TARGETS.bare = { session = "Bare" }
    local t = vt.resolve(c, "bare")
    assert.equals("write-chars", t.input)
    assert.equals("write13", t.submit)
  end)

  it("carries an explicit zellij paneId through", function()
    local c = cfg()
    c.VOICE_TARGETS.orchestrator.paneId = "terminal_3"
    assert.equals("terminal_3", vt.resolve(c, "orchestrator").paneId)
  end)

  it("treats a blank paneId as unset", function()
    local c = cfg()
    c.VOICE_TARGETS.orchestrator.paneId = ""
    assert.is_nil(vt.resolve(c, "orchestrator").paneId)
  end)

  it("refuses an unknown route", function()
    local t, why = vt.resolve(cfg(), "nope")
    assert.is_nil(t)
    assert.truthy(why:find("unknown route"))
  end)

  it("refuses a nil or empty route", function()
    assert.is_nil(vt.resolve(cfg(), nil))
    assert.is_nil(vt.resolve(cfg(), ""))
  end)

  it("refuses a config with no VOICE_TARGETS table", function()
    assert.is_nil(vt.resolve({}, "orchestrator"))
    assert.is_nil(vt.resolve(nil, "orchestrator"))
  end)
end)

describe("voice_targets tmux target guard", function()
  -- The safety property on the tmux side: the target must be explicit, never
  -- ambient, so delivery can't follow "whatever window is current".
  it("accepts session:window and session:window.pane", function()
    assert.is_true(vt.isExplicitTmuxTarget("firstmate:0"))
    assert.is_true(vt.isExplicitTmuxTarget("firstmate:0.0"))
    assert.is_true(vt.isExplicitTmuxTarget("fm-primary:captain"))
  end)

  it("refuses a bare session — that would be the session's CURRENT window", function()
    assert.is_false(vt.isExplicitTmuxTarget("firstmate"))
    local c = cfg()
    c.VOICE_TARGETS.firstmate.target = "firstmate"
    local t, why = vt.resolve(c, "firstmate")
    assert.is_nil(t)
    assert.truthy(why:find("not an explicit session:window"))
  end)

  it("refuses empty, whitespace-bearing, and flag-like targets", function()
    assert.is_false(vt.isExplicitTmuxTarget(""))
    assert.is_false(vt.isExplicitTmuxTarget(nil))
    assert.is_false(vt.isExplicitTmuxTarget("firstmate:0 extra"))
    assert.is_false(vt.isExplicitTmuxTarget("-t:0"))
  end)

  it("refuses malformed colon/dot shapes", function()
    assert.is_false(vt.isExplicitTmuxTarget("firstmate:"))
    assert.is_false(vt.isExplicitTmuxTarget(":0"))
    assert.is_false(vt.isExplicitTmuxTarget("a:b:c"))
    assert.is_false(vt.isExplicitTmuxTarget("firstmate:0."))
    assert.is_false(vt.isExplicitTmuxTarget("firstmate:.0"))
  end)

  it("builds no steps for a refused tmux target", function()
    local c = cfg()
    c.VOICE_TARGETS.firstmate.target = "firstmate"
    local t = vt.resolve(c, "firstmate")   -- nil
    assert.is_nil(vt.deliverySteps(c, t, "hello"))
  end)

  it("arms no chord at all when a target is ambient", function()
    local c = cfg()
    c.VOICE_TARGETS.firstmate.target = "firstmate"
    assert.same({}, vt.chordKeycodeMap(c, { a = 0, c = 8, p = 35 }))
  end)
end)

describe("voice_targets crewmate-session guard (zellij)", function()
  -- firstmate's crewmates are zellij tabs in one shared session, and write-chars
  -- without --pane-id lands in whichever pane is focused there.
  it("refuses a zellij route aimed at the shared firstmate session", function()
    local c = cfg()
    c.VOICE_TARGETS.orchestrator.session = "firstmate"
    local t, why = vt.resolve(c, "orchestrator")
    assert.is_nil(t)
    assert.truthy(why:find("crewmate session"))
  end)

  it("refuses case variants of the crew session", function()
    local c = cfg()
    c.VOICE_TARGETS.orchestrator.session = "FirstMate"
    assert.is_nil(vt.resolve(c, "orchestrator"))
  end)

  it("refuses an FM_ZELLIJ_SESSION-style override listed as crew", function()
    local c = cfg({ FIRSTMATE_CREW_SESSIONS = { "firstmate", "fm-test-abc" } })
    c.VOICE_TARGETS.orchestrator.session = "fm-test-abc"
    assert.is_nil(vt.resolve(c, "orchestrator"))
  end)

  it("does not apply the zellij crew guard to a tmux target", function()
    -- "firstmate" is a crew ZELLIJ session; a tmux session of the same name is a
    -- different namespace entirely, and crewmates are never tmux panes.
    local c = cfg()
    c.VOICE_TARGETS.firstmate.target = "firstmate:0.0"
    assert.truthy(vt.resolve(c, "firstmate"))
  end)

  it("isCrewSession is false for nil and unknown sessions", function()
    assert.is_false(vt.isCrewSession(cfg(), nil))
    assert.is_false(vt.isCrewSession(cfg(), "Orchestrator"))
    assert.is_false(vt.isCrewSession({}, "firstmate"))
  end)

  it("builds no steps for a refused zellij route", function()
    local c = cfg()
    c.VOICE_TARGETS.orchestrator.session = "firstmate"
    local t = vt.resolve(c, "orchestrator")   -- nil
    assert.is_nil(vt.deliverySteps(c, t, "hello"))
  end)
end)

describe("voice_targets.resolveDefault", function()
  it("uses VOICE_TARGET_DEFAULT", function()
    assert.equals("Orchestrator", vt.resolveDefault(cfg()).address)
  end)

  it("honours a changed default", function()
    assert.equals("firstmate:0.0",
      vt.resolveDefault(cfg({ VOICE_TARGET_DEFAULT = "firstmate" })).address)
  end)

  it("falls back to orchestrator when the key is absent", function()
    local c = cfg(); c.VOICE_TARGET_DEFAULT = nil
    assert.equals("Orchestrator", vt.resolveDefault(c).address)
  end)
end)

describe("voice_targets.binary / .environment", function()
  it("picks the CLI for the target's transport", function()
    assert.equals("/cargo/bin/zellij", vt.binary(cfg(), vt.resolve(cfg(), "orchestrator")))
    assert.equals("/opt/homebrew/bin/tmux", vt.binary(cfg(), vt.resolve(cfg(), "firstmate")))
  end)

  it("picks the environment for the target's transport", function()
    assert.equals("/zbin", vt.environment(cfg(), vt.resolve(cfg(), "orchestrator")).PATH)
    assert.equals("/tbin", vt.environment(cfg(), vt.resolve(cfg(), "firstmate")).PATH)
  end)

  it("returns nil when the transport has no entry, so nothing is spawned", function()
    local c = cfg(); c.VOICE_TRANSPORTS.tmux = nil
    assert.is_nil(vt.binary(c, vt.resolve(c, "firstmate")))
    assert.is_nil(vt.environment(c, vt.resolve(c, "firstmate")))
  end)

  it("returns nil for a nil target or missing VOICE_TRANSPORTS", function()
    assert.is_nil(vt.binary(cfg(), nil))
    assert.is_nil(vt.binary({}, vt.resolve(cfg(), "firstmate")))
    assert.is_nil(vt.environment(cfg(), nil))
  end)
end)

describe("voice_targets.chordRoute", function()
  it("maps a to orchestrator and p to firstmate", function()
    assert.equals("orchestrator", vt.chordRoute(cfg(), "a"))
    assert.equals("firstmate",    vt.chordRoute(cfg(), "p"))
  end)

  it("is case-insensitive", function()
    assert.equals("firstmate", vt.chordRoute(cfg(), "P"))
  end)

  it("returns nil for an unbound letter", function()
    assert.is_nil(vt.chordRoute(cfg(), "z"))
    assert.is_nil(vt.chordRoute(cfg(), nil))
  end)

  it("never yields a route for the reserved cancel chord", function()
    local c = cfg()
    c.VOICE_TARGETS.sneaky = { session = "Sneaky", chord = "c" }
    assert.is_nil(vt.chordRoute(c, "c"))
  end)

  it("never yields a route for the reserved speak-selection chord", function()
    local c = cfg()
    c.VOICE_TARGETS.sneaky = { session = "Sneaky", chord = "s" }
    assert.is_nil(vt.chordRoute(c, "s"))
  end)
end)

describe("voice_targets.chordKeycodeMap", function()
  -- This is the exact table apps/dictation's Fn-chord eventtap dispatches on.
  local KEYCODES = { a = 0, c = 8, p = 35 }

  it("maps the real keycodes to their routes", function()
    local map, problems = vt.chordKeycodeMap(cfg(), KEYCODES)
    assert.same({}, problems)
    assert.equals("orchestrator", map[0])   -- Fn+A
    assert.equals("firstmate",    map[35])  -- Fn+P
  end)

  it("leaves the cancel keycode unclaimed", function()
    local map = vt.chordKeycodeMap(cfg(), KEYCODES)
    assert.is_nil(map[8])                   -- Fn+C stays cancel-and-recall
  end)

  it("arms nothing at all when the config has a conflict", function()
    local c = cfg()
    c.VOICE_TARGETS.orchestrator.session = "firstmate"   -- crewmate session
    local map, problems = vt.chordKeycodeMap(c, KEYCODES)
    assert.same({}, map)                    -- including the healthy firstmate route
    assert.equals(1, #problems)
  end)

  it("reports a chord with no keycode and skips only that route", function()
    local c = cfg()
    c.VOICE_TARGETS.firstmate.chord = "\194\247"       -- not a letter in the map
    local map, problems = vt.chordKeycodeMap(c, KEYCODES)
    assert.equals("orchestrator", map[0])
    assert.equals(1, #problems)
    assert.truthy(problems[1]:find("no keycode"))
  end)

  it("returns an empty map without a keycode table", function()
    local map, problems = vt.chordKeycodeMap(cfg(), nil)
    assert.same({}, map)
    assert.equals(1, #problems)
  end)
end)

describe("voice_targets.routeKeys", function()
  it("lists every route, sorted", function()
    assert.same({ "firstmate", "orchestrator" }, vt.routeKeys(cfg()))
  end)

  it("is empty without a targets table", function()
    assert.same({}, vt.routeKeys({}))
    assert.same({}, vt.routeKeys(nil))
  end)
end)

describe("voice_targets.conflicts", function()
  it("passes the shipped shape", function()
    assert.same({}, vt.conflicts(cfg()))
  end)

  it("flags two targets sharing a chord", function()
    local c = cfg()
    c.VOICE_TARGETS.other = { session = "Other", chord = "a" }
    local problems = vt.conflicts(c)
    assert.equals(1, #problems)
    assert.truthy(problems[1]:find("already used by"))
  end)

  it("flags a target stealing the reserved cancel chord", function()
    local c = cfg()
    c.VOICE_TARGETS.orchestrator.chord = "c"
    assert.truthy(vt.conflicts(c)[1]:find("reserved"))
  end)

  it("flags a zellij target aimed at a crewmate session", function()
    local c = cfg()
    c.VOICE_TARGETS.orchestrator.session = "firstmate"
    assert.truthy(vt.conflicts(c)[1]:find("crewmate session"))
  end)

  it("flags an ambient tmux target", function()
    local c = cfg()
    c.VOICE_TARGETS.firstmate.target = "firstmate"
    assert.truthy(vt.conflicts(c)[1]:find("not an explicit"))
  end)

  it("flags a missing address, named per transport", function()
    local c = cfg()
    c.VOICE_TARGETS.orchestrator.session = nil
    assert.truthy(vt.conflicts(c)[1]:find("missing session"))
    local c2 = cfg()
    c2.VOICE_TARGETS.firstmate.target = nil
    assert.truthy(vt.conflicts(c2)[1]:find("missing target"))
  end)

  it("flags an unknown transport", function()
    local c = cfg()
    c.VOICE_TARGETS.firstmate.transport = "screen"
    assert.truthy(vt.conflicts(c)[1]:find("unknown transport"))
  end)

  it("flags a misspelled zellij input method rather than silently defaulting", function()
    local c = cfg()
    c.VOICE_TARGETS.orchestrator.input = "pate"
    assert.truthy(vt.conflicts(c)[1]:find("unknown input method"))
  end)

  it("flags a misspelled zellij submit method", function()
    local c = cfg()
    c.VOICE_TARGETS.orchestrator.submit = "retrun"
    assert.truthy(vt.conflicts(c)[1]:find("unknown submit method"))
  end)

  it("flags a non-string zellij paneId", function()
    local c = cfg()
    c.VOICE_TARGETS.orchestrator.paneId = 3
    assert.truthy(vt.conflicts(c)[1]:find("paneId"))
  end)

  it("flags zellij-only knobs set on a tmux target", function()
    local c = cfg()
    c.VOICE_TARGETS.firstmate.input = "paste"
    assert.truthy(vt.conflicts(c)[1]:find("zellij transport only"))
  end)

  it("accepts a target that omits the optional knobs entirely", function()
    local c = cfg()
    c.VOICE_TARGETS.bare = { session = "Bare", chord = "b" }
    assert.same({}, vt.conflicts(c))
  end)

  it("reports a missing targets table", function()
    assert.equals(1, #vt.conflicts({}))
  end)
end)

describe("voice_targets.normalize", function()
  it("trims surrounding whitespace", function()
    assert.equals("ship it", vt.normalize("  ship it \n"))
  end)

  it("returns nil for blank and non-string input", function()
    assert.is_nil(vt.normalize("   "))
    assert.is_nil(vt.normalize(""))
    assert.is_nil(vt.normalize(nil))
    assert.is_nil(vt.normalize(42))
  end)
end)

describe("voice_targets.deliverySteps — zellij transport", function()
  local c    = cfg()
  local orch = vt.resolve(c, "orchestrator")

  it("is two steps: type then submit", function()
    local steps = vt.deliverySteps(c, orch, "hello")
    assert.equals(2, #steps)
    assert.same({ "write-chars", "submit" }, namesOf(steps))
  end)

  it("builds byte-for-byte the argv the old hardcoded Orchestrator call used", function()
    assert.same({
      { "--session", "Orchestrator", "action", "write-chars", "hello" },
      { "--session", "Orchestrator", "action", "write", "13" },
    }, argvOf(vt.deliverySteps(c, orch, "hello")))
  end)

  it("never asks for stdin — zellij carries the text in argv", function()
    for _, s in ipairs(vt.deliverySteps(c, orch, "hello")) do
      assert.is_nil(s.stdin)
    end
  end)

  it("builds bracketed paste + send-keys Enter when the target asks for them", function()
    local c2 = cfg()
    c2.VOICE_TARGETS.orchestrator.input  = "paste"
    c2.VOICE_TARGETS.orchestrator.submit = "enter"
    assert.same({
      { "--session", "Orchestrator", "action", "paste", "--", "hello" },
      { "--session", "Orchestrator", "action", "send-keys", "Enter" },
    }, argvOf(vt.deliverySteps(c2, vt.resolve(c2, "orchestrator"), "hello")))
  end)

  it("passes a leading-dash transcript as an operand under paste", function()
    local c2 = cfg()
    c2.VOICE_TARGETS.orchestrator.input = "paste"
    local argv = vt.deliverySteps(c2, vt.resolve(c2, "orchestrator"), "-- not a flag")[1].argv
    assert.equals("--", argv[5])
    assert.equals("-- not a flag", argv[6])
  end)

  it("adds --pane-id before the operands on every step when a pane is pinned", function()
    local c2 = cfg()
    c2.VOICE_TARGETS.orchestrator.paneId = "terminal_1"
    assert.same({
      { "--session", "Orchestrator", "action", "write-chars", "--pane-id", "terminal_1", "hello" },
      { "--session", "Orchestrator", "action", "write", "--pane-id", "terminal_1", "13" },
    }, argvOf(vt.deliverySteps(c2, vt.resolve(c2, "orchestrator"), "hello")))
  end)

  it("trims the text it sends", function()
    assert.equals("hello", vt.deliverySteps(c, orch, "  hello  ")[1].argv[5])
  end)
end)

describe("voice_targets.deliverySteps — tmux transport", function()
  local c  = cfg()
  local fm = vt.resolve(c, "firstmate")

  it("is three steps: stage a buffer, bracketed-paste it, submit", function()
    local steps = vt.deliverySteps(c, fm, "hello")
    assert.equals(3, #steps)
    assert.same({ "load-buffer", "paste-buffer", "submit" }, namesOf(steps))
  end)

  it("builds the flags verified against tmux 3.7b", function()
    assert.same({
      { "load-buffer", "-b", "hs-voice", "-" },
      { "paste-buffer", "-b", "hs-voice", "-p", "-d", "-t", "firstmate:0.0" },
      { "send-keys", "-t", "firstmate:0.0", "Enter" },
    }, argvOf(vt.deliverySteps(c, fm, "hello")))
  end)

  it("carries the transcript on stdin, never in argv", function()
    local steps = vt.deliverySteps(c, fm, "hello")
    assert.equals("hello", steps[1].stdin)
    for _, s in ipairs(steps) do
      for _, a in ipairs(s.argv) do
        assert.not_equal("hello", a)
      end
    end
    assert.is_nil(steps[2].stdin)
    assert.is_nil(steps[3].stdin)
  end)

  it("needs no dash escaping, because the text is not an argument", function()
    -- `tmux send-keys` has no `--` terminator, so an argv-carried transcript
    -- starting with a dash would parse as flags. On stdin it simply cannot.
    local steps = vt.deliverySteps(c, fm, "-- dashes ahead")
    assert.equals("-- dashes ahead", steps[1].stdin)   -- verbatim, no space added
    assert.same({ "load-buffer", "-b", "hs-voice", "-" }, steps[1].argv)
  end)

  it("uses the configured buffer name", function()
    local c2 = cfg({ VOICE_TMUX_BUFFER = "other-buf" })
    local steps = vt.deliverySteps(c2, vt.resolve(c2, "firstmate"), "hi")
    assert.equals("other-buf", steps[1].argv[3])
    assert.equals("other-buf", steps[2].argv[3])
  end)

  it("falls back to a dedicated buffer name when none is configured", function()
    local c2 = cfg(); c2.VOICE_TMUX_BUFFER = nil
    local steps = vt.deliverySteps(c2, vt.resolve(c2, "firstmate"), "hi")
    assert.equals("hs-voice", steps[1].argv[3])
  end)

  it("trims the text it stages", function()
    assert.equals("hello", vt.deliverySteps(c, fm, "  hello  ")[1].stdin)
  end)

  it("follows a retargeted pane on both targeted steps", function()
    local c2 = cfg()
    c2.VOICE_TARGETS.firstmate.target = "fm:2.1"
    local steps = vt.deliverySteps(c2, vt.resolve(c2, "firstmate"), "hi")
    assert.same({ "paste-buffer", "-b", "hs-voice", "-p", "-d", "-t", "fm:2.1" }, steps[2].argv)
    assert.same({ "send-keys", "-t", "fm:2.1", "Enter" }, steps[3].argv)
  end)
end)

describe("voice_targets.deliverySteps — shared refusals", function()
  local c    = cfg()
  local orch = vt.resolve(c, "orchestrator")
  local fm   = vt.resolve(c, "firstmate")

  it("refuses blank text on both transports so nothing is spawned", function()
    assert.is_nil(vt.deliverySteps(c, orch, "   "))
    assert.is_nil(vt.deliverySteps(c, orch, nil))
    assert.is_nil(vt.deliverySteps(c, fm, ""))
    assert.is_nil(vt.deliverySteps(c, fm, nil))
  end)

  it("refuses a nil or address-less target", function()
    assert.is_nil(vt.deliverySteps(c, nil, "hello"))
    assert.is_nil(vt.deliverySteps(c, { label = "x" }, "hello"))
    assert.is_nil(vt.deliverySteps(c, { transport = "tmux" }, "hello"))
    assert.is_nil(vt.deliverySteps(c, { transport = "zellij" }, "hello"))
  end)

  it("refuses a target naming a transport that does not exist", function()
    assert.is_nil(vt.deliverySteps(c, { transport = "screen", address = "x" }, "hello"))
  end)

  it("every step has a name and a non-empty argv", function()
    for _, target in ipairs({ orch, fm }) do
      for _, s in ipairs(vt.deliverySteps(c, target, "hello")) do
        assert.is_string(s.name)
        assert.is_true(#s.argv > 0)
      end
    end
  end)
end)

describe("voice_targets display strings", function()
  it("keeps the notify wording per target", function()
    assert.equals("→ Orchestrator (voice): hi",
      vt.notifyText(vt.resolve(cfg(), "orchestrator"), "hi"))
    assert.equals("→ firstmate (voice): hi",
      vt.notifyText(vt.resolve(cfg(), "firstmate"), "hi"))
  end)

  it("ellipsises past maxLen", function()
    assert.equals("→ firstmate (voice): abcde…",
      vt.notifyText(vt.resolve(cfg(), "firstmate"), "abcdefgh", 5))
  end)

  it("summarises the chords for the ready banner, ordered by chord", function()
    assert.equals("Fn+A → Orchestrator · Fn+P → firstmate", vt.chordSummary(cfg()))
  end)

  it("omits chordless targets from the banner", function()
    local c = cfg()
    c.VOICE_TARGETS.hidden = { session = "Hidden", label = "Hidden" }
    assert.equals("Fn+A → Orchestrator · Fn+P → firstmate", vt.chordSummary(c))
  end)
end)

describe("lib/config voice wiring", function()
  -- Guards the real shipped config, not a fixture: the live table must be
  -- conflict-free, keep Orchestrator exactly as it was, and reach the firstmate
  -- primary over tmux at an explicit target.
  local real = require("lib.config")

  it("has no routing conflicts", function()
    assert.same({}, vt.conflicts(real))
  end)

  it("still routes Fn+A to the Orchestrator zellij session", function()
    local orch = vt.resolve(real, "orchestrator")
    assert.equals("zellij", orch.transport)
    assert.equals("Orchestrator", orch.session)
    assert.equals("orchestrator", vt.chordRoute(real, "a"))
  end)

  it("keeps the Orchestrator delivery exactly as it was before this change", function()
    local orch = vt.resolve(real, "orchestrator")
    assert.same({
      { "--session", "Orchestrator", "action", "write-chars", "hello" },
      { "--session", "Orchestrator", "action", "write", "13" },
    }, argvOf(vt.deliverySteps(real, orch, "hello")))
  end)

  it("still drives Orchestrator with the cargo zellij binary", function()
    local orch = vt.resolve(real, "orchestrator")
    assert.truthy(vt.binary(real, orch):find("/%.cargo/bin/zellij$"))
  end)

  it("defaults to the orchestrator route", function()
    assert.equals("Orchestrator", vt.resolveDefault(real).session)
  end)

  it("routes Fn+P to the firstmate primary over tmux", function()
    assert.equals("firstmate", vt.chordRoute(real, "p"))
    local fm = vt.resolve(real, "firstmate")
    assert.equals("tmux", fm.transport)
    assert.equals(real.FIRSTMATE_PRIMARY_TMUX_TARGET, fm.target)
    assert.equals("/opt/homebrew/bin/tmux", vt.binary(real, fm))
  end)

  it("targets the firstmate primary explicitly, never an ambient window", function()
    assert.is_true(vt.isExplicitTmuxTarget(real.FIRSTMATE_PRIMARY_TMUX_TARGET))
  end)

  it("delivers to firstmate by bracketed paste, staged on stdin", function()
    local fm = vt.resolve(real, "firstmate")
    local t  = real.FIRSTMATE_PRIMARY_TMUX_TARGET
    local b  = real.VOICE_TMUX_BUFFER
    local steps = vt.deliverySteps(real, fm, "hello")
    assert.same({
      { "load-buffer", "-b", b, "-" },
      { "paste-buffer", "-b", b, "-p", "-d", "-t", t },
      { "send-keys", "-t", t, "Enter" },
    }, argvOf(steps))
    assert.equals("hello", steps[1].stdin)
  end)

  it("treats the shared firstmate zellij session as crew, never a destination", function()
    assert.is_true(vt.isCrewSession(real, "firstmate"))
  end)

  it("arms both chords against the real hs.keycodes map", function()
    local keycodes = require("hs").keycodes.map   -- tests/mocks/hs.lua
    local map, problems = vt.chordKeycodeMap(real, keycodes)
    assert.same({}, problems)
    assert.equals("orchestrator", map[keycodes.a])
    assert.equals("firstmate",    map[keycodes.p])
    assert.is_nil(map[keycodes.c])
  end)
end)
