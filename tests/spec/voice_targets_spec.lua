-- Pure routing logic for lib/voice_targets: target resolution, which chord
-- picks which supervisor, the zellij argv, and the crewmate-session refusal.
-- No hs.* here — the module deliberately has no Hammerspoon dependency.

local vt = require("lib.voice_targets")

-- Minimal config shaped like lib/config.lua's voice keys.
local function cfg(overrides)
  local c = {
    VOICE_TARGETS = {
      orchestrator = { session = "Orchestrator",     label = "Orchestrator", chord = "a" },
      firstmate    = { session = "firstmate-primary", label = "firstmate",   chord = "p" },
    },
    VOICE_TARGET_DEFAULT    = "orchestrator",
    FIRSTMATE_CREW_SESSIONS = { "firstmate" },
  }
  for k, v in pairs(overrides or {}) do c[k] = v end
  return c
end

describe("voice_targets.resolve", function()
  it("resolves the orchestrator route to its zellij session", function()
    local t = vt.resolve(cfg(), "orchestrator")
    assert.equals("Orchestrator", t.session)
    assert.equals("Orchestrator", t.label)
    assert.equals("orchestrator", t.key)
    assert.equals("a", t.chord)
  end)

  it("resolves the firstmate route to the dedicated primary session", function()
    local t = vt.resolve(cfg(), "firstmate")
    assert.equals("firstmate-primary", t.session)
    assert.equals("firstmate", t.label)
    assert.equals("p", t.chord)
  end)

  it("falls back to the route key when no label is given", function()
    local c = cfg()
    c.VOICE_TARGETS.bare = { session = "Bare" }
    assert.equals("bare", vt.resolve(c, "bare").label)
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

  it("refuses a target with no session", function()
    local c = cfg()
    c.VOICE_TARGETS.broken = { label = "Broken" }
    local t, why = vt.resolve(c, "broken")
    assert.is_nil(t)
    assert.truthy(why:find("no session"))
  end)

  it("refuses a config with no VOICE_TARGETS table", function()
    assert.is_nil(vt.resolve({}, "orchestrator"))
    assert.is_nil(vt.resolve(nil, "orchestrator"))
  end)
end)

describe("voice_targets crewmate-session guard", function()
  -- The safety property: dictation must never be deliverable into firstmate's
  -- shared session, because write-chars lands in whatever crewmate tab is
  -- focused there.
  it("refuses a route aimed at the shared firstmate session", function()
    local c = cfg()
    c.VOICE_TARGETS.firstmate.session = "firstmate"
    local t, why = vt.resolve(c, "firstmate")
    assert.is_nil(t)
    assert.truthy(why:find("crewmate session"))
  end)

  it("refuses case variants of the crew session", function()
    local c = cfg()
    c.VOICE_TARGETS.firstmate.session = "FirstMate"
    assert.is_nil(vt.resolve(c, "firstmate"))
  end)

  it("refuses an FM_ZELLIJ_SESSION-style override listed as crew", function()
    local c = cfg({ FIRSTMATE_CREW_SESSIONS = { "firstmate", "fm-test-abc" } })
    c.VOICE_TARGETS.firstmate.session = "fm-test-abc"
    assert.is_nil(vt.resolve(c, "firstmate"))
  end)

  it("still allows the dedicated primary session", function()
    assert.is_false(vt.isCrewSession(cfg(), "firstmate-primary"))
    assert.truthy(vt.resolve(cfg(), "firstmate"))
  end)

  it("isCrewSession is false for nil and unknown sessions", function()
    assert.is_false(vt.isCrewSession(cfg(), nil))
    assert.is_false(vt.isCrewSession(cfg(), "Orchestrator"))
    assert.is_false(vt.isCrewSession({}, "firstmate"))
  end)

  it("builds no argv for a refused route", function()
    local c = cfg()
    c.VOICE_TARGETS.firstmate.session = "firstmate"
    local t = vt.resolve(c, "firstmate")
    assert.is_nil(vt.writeCharsArgs(t, "hello"))
    assert.is_nil(vt.submitArgs(t))
  end)
end)

describe("voice_targets.resolveDefault", function()
  it("uses VOICE_TARGET_DEFAULT", function()
    assert.equals("Orchestrator", vt.resolveDefault(cfg()).session)
  end)

  it("honours a changed default", function()
    assert.equals("firstmate-primary",
      vt.resolveDefault(cfg({ VOICE_TARGET_DEFAULT = "firstmate" })).session)
  end)

  it("falls back to orchestrator when the key is absent", function()
    local c = cfg(); c.VOICE_TARGET_DEFAULT = nil
    assert.equals("Orchestrator", vt.resolveDefault(c).session)
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
    c.VOICE_TARGETS.firstmate.session = "firstmate"   -- crewmate session
    local map, problems = vt.chordKeycodeMap(c, KEYCODES)
    assert.same({}, map)                    -- including the healthy orchestrator route
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

  it("flags a target aimed at a crewmate session", function()
    local c = cfg()
    c.VOICE_TARGETS.firstmate.session = "firstmate"
    assert.truthy(vt.conflicts(c)[1]:find("crewmate session"))
  end)

  it("flags a missing session", function()
    local c = cfg()
    c.VOICE_TARGETS.firstmate.session = nil
    assert.truthy(vt.conflicts(c)[1]:find("missing session"))
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

describe("voice_targets argv builders", function()
  local orch = vt.resolve(cfg(), "orchestrator")
  local fm   = vt.resolve(cfg(), "firstmate")

  it("builds the same write-chars argv the old hardcoded call used", function()
    assert.same({ "--session", "Orchestrator", "action", "write-chars", "hello" },
      vt.writeCharsArgs(orch, "hello"))
  end)

  it("builds write-chars for the firstmate primary session", function()
    assert.same({ "--session", "firstmate-primary", "action", "write-chars", "hello" },
      vt.writeCharsArgs(fm, "hello"))
  end)

  it("trims the text it sends", function()
    assert.equals("hello", vt.writeCharsArgs(orch, "  hello  ")[5])
  end)

  it("builds the Enter (byte 13) submit argv", function()
    assert.same({ "--session", "Orchestrator", "action", "write", "13" },
      vt.submitArgs(orch))
    assert.same({ "--session", "firstmate-primary", "action", "write", "13" },
      vt.submitArgs(fm))
  end)

  it("refuses blank text so nothing is spawned", function()
    assert.is_nil(vt.writeCharsArgs(orch, "   "))
    assert.is_nil(vt.writeCharsArgs(orch, nil))
  end)

  it("refuses a nil or session-less target", function()
    assert.is_nil(vt.writeCharsArgs(nil, "hello"))
    assert.is_nil(vt.writeCharsArgs({ label = "x" }, "hello"))
    assert.is_nil(vt.submitArgs(nil))
    assert.is_nil(vt.submitArgs({ label = "x" }))
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
  -- conflict-free and must not point the firstmate route at the crew session.
  local real = require("lib.config")

  it("has no routing conflicts", function()
    assert.same({}, vt.conflicts(real))
  end)

  it("still routes Fn+A to the Orchestrator session", function()
    assert.equals("Orchestrator", vt.resolve(real, "orchestrator").session)
    assert.equals("orchestrator", vt.chordRoute(real, "a"))
  end)

  it("defaults to the orchestrator route", function()
    assert.equals("Orchestrator", vt.resolveDefault(real).session)
  end)

  it("routes Fn+P to the dedicated firstmate primary session", function()
    assert.equals("firstmate", vt.chordRoute(real, "p"))
    assert.equals(real.FIRSTMATE_PRIMARY_SESSION, vt.resolve(real, "firstmate").session)
  end)

  it("treats the shared firstmate session as crew, never a destination", function()
    assert.is_true(vt.isCrewSession(real, "firstmate"))
    assert.is_false(vt.isCrewSession(real, real.FIRSTMATE_PRIMARY_SESSION))
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
