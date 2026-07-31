-- Voice routing targets: which zellij session a dictated transcript goes to.
--
-- Why this module exists: apps/dictation used to hardcode its own copy of the
-- Orchestrator session name, so adding a second destination meant a second
-- hardcoded string and a second place to get wrong. Every destination now lives
-- in lib/config.VOICE_TARGETS and is resolved through here. Pure: no hs.*, no
-- side effects, so the routing decision and the zellij argv are unit-testable.
--
-- ── SAFETY: never write into a crewmate pane ────────────────────────────────
-- firstmate runs one zellij TAB PER CREWMATE TASK inside one shared session
-- (default "firstmate", overridable with FM_ZELLIJ_SESSION). Without an explicit
-- --pane-id, `zellij --session <name> action …` targets whichever pane is
-- FOCUSED there — so routing to the shared session would deliver the captain's
-- dictation into whatever worker tab happened to be focused.
--
-- zellij 0.44 does let you name a pane (`--pane-id terminal_3`, supported on
-- write-chars / paste / write / send-keys — verified against 0.44.3), and a
-- target may set `paneId` to use it. But the primary's pane id isn't known when
-- a chord is pressed and changes across restarts, so pane-id can't be the
-- primary defence.
--
-- The assumption this module enforces instead: the firstmate PRIMARY runs in its
-- own dedicated session (config.FIRSTMATE_PRIMARY_SESSION, default
-- "firstmate-primary") holding nothing but the primary, so the focused pane is
-- always the right pane; the shared session is crewmates-only. resolve()
-- REFUSES any target whose session appears in config.FIRSTMATE_CREW_SESSIONS,
-- and the argv builders refuse an unresolved target — so no code path can
-- construct a delivery aimed at the crew session, even if VOICE_TARGETS is later
-- edited to point at it.
--
-- Comparison is case-insensitive on purpose: zellij session names are
-- case-sensitive, so "Firstmate" is a *different* session than "firstmate" and
-- would not be a real crew session — but a near-miss like that is far more
-- likely a typo aimed at the crew session than a deliberate third session, and
-- refusing to speak is always the safe failure.

local M = {}

-- Reserved chord letters that a voice target may not claim, because
-- apps/dictation already binds them while Fn is held.
M.RESERVED_CHORDS = { "c" }   -- Fn+C = cancel recording & recall last result

local function lower(s)
  if type(s) ~= "string" then return nil end
  return s:lower()
end

-- true when `session` is one of the shared crewmate sessions in cfg.
function M.isCrewSession(cfg, session)
  local want = lower(session)
  if not want then return false end
  local crew = cfg and cfg.FIRSTMATE_CREW_SESSIONS
  if type(crew) ~= "table" then return false end
  for _, name in ipairs(crew) do
    if lower(name) == want then return true end
  end
  return false
end

-- How a target types text and submits it. Unknown/absent values fall back to
-- the pair apps/dictation has always used, so an older VOICE_TARGETS entry that
-- names neither keeps working unchanged.
M.INPUT_METHODS  = { ["write-chars"] = true, paste = true }
M.SUBMIT_METHODS = { write13 = true, enter = true }
M.INPUT_DEFAULT  = "write-chars"
M.SUBMIT_DEFAULT = "write13"

-- Resolve a route key ("orchestrator", "firstmate", …) to a target.
--
-- Returns, on success:
--   { key = <route>, session = <zellij session>, label = <human name>,
--     chord = <letter or nil>, input = <method>, submit = <method>,
--     paneId = <string or nil> }, nil
-- Returns nil plus a short reason otherwise. Callers must treat nil as "do not
-- send anything" — there is no fallback destination, because guessing which
-- supervisor should receive speech is worse than dropping it.
function M.resolve(cfg, key)
  if type(cfg) ~= "table" then return nil, "no config" end
  if type(key) ~= "string" or key == "" then return nil, "no route" end
  local targets = cfg.VOICE_TARGETS
  if type(targets) ~= "table" then return nil, "no VOICE_TARGETS" end
  local t = targets[key]
  if type(t) ~= "table" then return nil, "unknown route: " .. key end
  local session = t.session
  if type(session) ~= "string" or session == "" then
    return nil, "route " .. key .. " has no session"
  end
  if M.isCrewSession(cfg, session) then
    -- Hard stop: this session holds crewmate tabs, so delivery could land in a
    -- worker's prompt. See the safety note at the top of this file.
    return nil, "route " .. key .. " points at crewmate session " .. session
  end
  local input  = M.INPUT_METHODS[t.input]   and t.input  or M.INPUT_DEFAULT
  local submit = M.SUBMIT_METHODS[t.submit] and t.submit or M.SUBMIT_DEFAULT
  return {
    key     = key,
    session = session,
    label   = (type(t.label) == "string" and t.label ~= "") and t.label or key,
    chord   = type(t.chord) == "string" and t.chord or nil,
    input   = input,
    submit  = submit,
    paneId  = (type(t.paneId) == "string" and t.paneId ~= "") and t.paneId or nil,
  }, nil
end

-- Resolve the route used when a caller just wants "the supervisor" (headset
-- MFB, apps/volume_tap). Falls back to the "orchestrator" key so an older
-- config without VOICE_TARGET_DEFAULT still routes the way it always did.
function M.resolveDefault(cfg)
  local key = (type(cfg) == "table" and cfg.VOICE_TARGET_DEFAULT) or "orchestrator"
  return M.resolve(cfg, key)
end

-- Which route does holding Fn plus `letter` select? Returns the route key, or
-- nil when no target claims that letter. Case-insensitive; reserved letters
-- never match, so Fn+C can't be stolen by a target.
function M.chordRoute(cfg, letter)
  local want = lower(letter)
  if not want then return nil end
  for _, reserved in ipairs(M.RESERVED_CHORDS) do
    if lower(reserved) == want then return nil end
  end
  local targets = (type(cfg) == "table" and cfg.VOICE_TARGETS) or nil
  if type(targets) ~= "table" then return nil end
  -- Sorted so a duplicate chord resolves deterministically rather than by
  -- pairs() order. conflicts() is what actually flags the duplicate.
  local keys = {}
  for key in pairs(targets) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local t = targets[key]
    if type(t) == "table" and lower(t.chord) == want then return key end
  end
  return nil
end

-- Build the keycode → route-key table the Fn-chord eventtap dispatches on.
-- `keycodeMap` is hs.keycodes.map (letter → keycode), passed in so this stays
-- pure. Returns the map plus a list of problems; when `conflicts(cfg)` finds
-- anything the map comes back EMPTY, so a misconfigured target arms no chord at
-- all rather than arming the wrong destination.
function M.chordKeycodeMap(cfg, keycodeMap)
  local problems = M.conflicts(cfg)
  local map = {}
  if #problems > 0 then return map, problems end
  if type(keycodeMap) ~= "table" then
    return map, { "no keycode map" }
  end
  for _, key in ipairs(M.routeKeys(cfg)) do
    local target = M.resolve(cfg, key)
    if target and target.chord then
      local kc = keycodeMap[target.chord]
      if kc == nil then
        problems[#problems + 1] = key .. ": no keycode for chord '" .. target.chord .. "'"
      else
        map[kc] = key
      end
    end
  end
  return map, problems
end

-- Route keys, sorted — for banners and menus that list every destination.
function M.routeKeys(cfg)
  local targets = (type(cfg) == "table" and cfg.VOICE_TARGETS) or nil
  if type(targets) ~= "table" then return {} end
  local keys = {}
  for key in pairs(targets) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

-- Config audit: returns a list of human-readable problems (empty when clean).
-- Catches the mistakes that would silently misroute or mis-deliver speech: two
-- targets sharing a chord, a target stealing a reserved chord, a missing
-- session, a target aimed at a crewmate session, and a misspelled input/submit
-- method (which resolve() would otherwise quietly replace with the default).
function M.conflicts(cfg)
  local problems = {}
  local targets = (type(cfg) == "table" and cfg.VOICE_TARGETS) or nil
  if type(targets) ~= "table" then return { "no VOICE_TARGETS table" } end

  local seenChord = {}
  for _, key in ipairs(M.routeKeys(cfg)) do
    local t = targets[key]
    if type(t.session) ~= "string" or t.session == "" then
      problems[#problems + 1] = key .. ": missing session"
    elseif M.isCrewSession(cfg, t.session) then
      problems[#problems + 1] = key .. ": session '" .. t.session .. "' is a firstmate crewmate session"
    end
    local chord = lower(t.chord)
    if chord then
      for _, reserved in ipairs(M.RESERVED_CHORDS) do
        if lower(reserved) == chord then
          problems[#problems + 1] = key .. ": chord '" .. chord .. "' is reserved"
        end
      end
      if seenChord[chord] then
        problems[#problems + 1] = key .. ": chord '" .. chord .. "' already used by " .. seenChord[chord]
      else
        seenChord[chord] = key
      end
    end
    if t.input ~= nil and not M.INPUT_METHODS[t.input] then
      problems[#problems + 1] = key .. ": unknown input method '" .. tostring(t.input) .. "'"
    end
    if t.submit ~= nil and not M.SUBMIT_METHODS[t.submit] then
      problems[#problems + 1] = key .. ": unknown submit method '" .. tostring(t.submit) .. "'"
    end
    if t.paneId ~= nil and (type(t.paneId) ~= "string" or t.paneId == "") then
      problems[#problems + 1] = key .. ": paneId must be a non-empty string"
    end
  end
  return problems
end

-- Trim; returns nil for nil/blank so callers can treat nil as "nothing to send".
function M.normalize(text)
  if type(text) ~= "string" then return nil end
  local t = text:gsub("^%s+", ""):gsub("%s+$", "")
  if t == "" then return nil end
  return t
end

local function sessionOf(target)
  if type(target) ~= "table" then return nil end
  local s = target.session
  if type(s) ~= "string" or s == "" then return nil end
  return s
end

-- `zellij --session <s> action <verb>` plus `--pane-id <id>` when the target
-- pins one. Pane-id goes before the trailing operands because zellij's clap
-- parser takes it as an option on the action subcommand.
local function actionArgs(target, verb)
  local session = sessionOf(target)
  if not session then return nil end
  local argv = { "--session", session, "action", verb }
  if target.paneId then
    argv[#argv + 1] = "--pane-id"
    argv[#argv + 1] = target.paneId
  end
  return argv
end

-- argv that types the transcript WITHOUT submitting it, per target.input:
--   "paste"       → `action paste -- <text>`   (bracketed paste; popup-safe)
--   "write-chars" → `action write-chars <text>` (per-character)
-- `--` terminates options for paste so a transcript starting with "-" is not
-- parsed as a flag. write-chars keeps its historical bare form so the
-- Orchestrator route's argv is byte-for-byte what it has always been.
-- nil when the target is unresolved or the text is blank — the caller must not
-- spawn a task in that case.
function M.inputArgs(target, text)
  local t = M.normalize(text)
  if not t then return nil end
  local verb = (target and target.input == "paste") and "paste" or "write-chars"
  local argv = actionArgs(target, verb)
  if not argv then return nil end
  if verb == "paste" then argv[#argv + 1] = "--" end
  argv[#argv + 1] = t
  return argv
end

-- argv that submits the typed text, per target.submit:
--   "enter"   → `action send-keys Enter`  (zellij's named key)
--   "write13" → `action write 13`         (raw CR byte)
function M.submitArgs(target)
  if target and target.submit == "enter" then
    local argv = actionArgs(target, "send-keys")
    if not argv then return nil end
    argv[#argv + 1] = "Enter"
    return argv
  end
  local argv = actionArgs(target, "write")
  if not argv then return nil end
  argv[#argv + 1] = "13"
  return argv
end

-- "→ Orchestrator (voice): first sixty chars…" for the on-screen notify.
function M.notifyText(target, text, maxLen)
  local label = (type(target) == "table" and target.label) or "supervisor"
  local t = M.normalize(text) or ""
  local max = maxLen or 60
  local preview = t:sub(1, max)
  if #t > max then preview = preview .. "…" end
  return "→ " .. label .. " (voice): " .. preview
end

-- "Fn+A → Orchestrator · Fn+P → firstmate" for the startup banner. Ordered by
-- chord letter so the banner reads the way the keyboard does.
function M.chordSummary(cfg)
  local rows = {}
  for _, key in ipairs(M.routeKeys(cfg)) do
    local target = M.resolve(cfg, key)
    if target and target.chord then
      rows[#rows + 1] = { chord = lower(target.chord), label = target.label }
    end
  end
  table.sort(rows, function(a, b) return a.chord < b.chord end)
  local parts = {}
  for _, r in ipairs(rows) do
    parts[#parts + 1] = "Fn+" .. r.chord:upper() .. " → " .. r.label
  end
  return table.concat(parts, " · ")
end

return M
