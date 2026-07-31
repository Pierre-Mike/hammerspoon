-- Voice routing targets: where a dictated transcript is delivered, and how.
--
-- Why this module exists: apps/dictation used to hardcode its own copy of the
-- Orchestrator session name, so adding a second destination meant a second
-- hardcoded string and a second place to get wrong. Every destination now lives
-- in lib/config.VOICE_TARGETS and is resolved through here. Pure: no hs.*, no
-- side effects, so the routing decision and the argv are unit-testable.
--
-- ── Two transports, because firstmate is a hybrid ───────────────────────────
-- The firstmate captain/primary runs in a **tmux** pane while its crewmate tasks
-- spawn as **zellij** tabs. firstmate's away-mode supervisor daemon refuses at
-- startup for any supervisor backend other than tmux or herdr, and resolves the
-- supervisor pane's backend independently of the runtime backend that spawns
-- crewmates. So voice-in speaks tmux to reach the captain and zellij for the
-- Orchestrator, and each target names its own transport.
--
-- Adding a third multiplexer = one entry in M.TRANSPORTS here plus one in
-- config.VOICE_TRANSPORTS. Adding a destination = one entry in VOICE_TARGETS.
-- Neither needs a new branch in apps/dictation.
--
-- ── SAFETY: never deliver into a crewmate pane ──────────────────────────────
-- Both transports address "whatever the target resolves to", so an ambient or
-- under-specified target can land dictation in a worker's prompt.
--
--   tmux — `send-keys -t <target>` follows the target exactly, so the target must
--     name session AND window explicitly. A bare "firstmate" goes to that
--     session's CURRENT window — ambient — and is refused. (Crewmates are zellij
--     tabs, so a tmux target cannot reach a crewmate at all; the explicit target
--     is what stops delivery reaching the wrong tmux pane.)
--
--   zellij — without an explicit --pane-id, `zellij --session <name> action …`
--     delivers to whichever pane is FOCUSED. firstmate's crewmates share one
--     session (default "firstmate", overridable with FM_ZELLIJ_SESSION), so a
--     zellij-transport route pointing at one of config.FIRSTMATE_CREW_SESSIONS
--     is refused outright. zellij 0.44 CAN name a pane (`--pane-id terminal_3`,
--     verified against 0.44.3) and a target may set `paneId`, but the primary's
--     pane id isn't known when a chord is pressed and changes across restarts,
--     so pane-id can't be the primary defence.
--
-- resolve() returns nil for any of these, and the argv builders refuse an
-- unresolved target — so no code path can construct a delivery aimed at a
-- crewmate, even if VOICE_TARGETS is later edited to point at one.
--
-- Crew-session comparison is case-insensitive on purpose: zellij session names
-- are case-sensitive, so "Firstmate" is technically a different session — but a
-- near-miss like that is far more likely a typo aimed at the crew session than a
-- deliberate third session, and refusing to speak is the safe failure.

local M = {}

-- Reserved chord letters that a voice target may not claim, because
-- apps/dictation already binds them while Fn is held.
M.RESERVED_CHORDS = { "c" }   -- Fn+C = cancel recording & recall last result

-- zellij-only delivery methods. Unknown/absent values fall back to the pair
-- apps/dictation has always used, so an older target naming neither still works.
M.INPUT_METHODS  = { ["write-chars"] = true, paste = true }
M.SUBMIT_METHODS = { write13 = true, enter = true }
M.INPUT_DEFAULT  = "write-chars"
M.SUBMIT_DEFAULT = "write13"

M.TRANSPORT_DEFAULT = "zellij"

local function lower(s)
  if type(s) ~= "string" then return nil end
  return s:lower()
end

local function nonEmptyString(v)
  return type(v) == "string" and v ~= ""
end

-- Trim; returns nil for nil/blank so callers can treat nil as "nothing to send".
function M.normalize(text)
  if type(text) ~= "string" then return nil end
  local t = text:gsub("^%s+", ""):gsub("%s+$", "")
  if t == "" then return nil end
  return t
end

-- true when `session` is one of the shared crewmate zellij sessions in cfg.
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

-- ── tmux helpers ───────────────────────────────────────────────────────────

-- Is this an explicit tmux target — "session:window" or "session:window.pane"?
-- A bare "session" is REFUSED: tmux would deliver to that session's current
-- window, which is exactly the ambient targeting we must not allow.
function M.isExplicitTmuxTarget(target)
  if not nonEmptyString(target) then return false end
  if target:find("%s") then return false end          -- no whitespace in a target
  if target:sub(1, 1) == "-" then return false end    -- never parseable as a flag
  local session, rest = target:match("^([^:]+):([^:]+)$")
  if not session or not rest then return false end    -- needs exactly one colon
  -- rest is "window" or "window.pane"; both halves must be non-empty.
  local window, pane = rest:match("^([^.]+)%.([^.]+)$")
  if window then return pane ~= "" end
  return rest:find("%.") == nil                       -- "window" with no stray dot
end

-- `tmux send-keys` has NO `--` option terminator (verified against tmux 3.7b:
-- `send-keys -l "-x…"` fails with "unknown flag -x"), so a transcript starting
-- with a dash would be parsed as flags. A single leading space makes it an
-- unambiguous operand and is invisible in a prompt — better than dropping the
-- take or mangling the words.
function M.tmuxSafeText(text)
  local t = M.normalize(text)
  if not t then return nil end
  if t:sub(1, 1) == "-" then return " " .. t end
  return t
end

-- ── Transport dispatch table ───────────────────────────────────────────────
-- Each entry owns: which config field carries the address, how to validate it,
-- and how to build the type / submit argv. apps/dictation never branches on
-- transport — it calls M.inputArgs / M.submitArgs / M.binary / M.environment.
M.TRANSPORTS = {
  zellij = {
    addressField = "session",
    -- Refuse a zellij target pointing at a shared crewmate session.
    validate = function(cfg, address)
      if M.isCrewSession(cfg, address) then
        return "points at crewmate session " .. address
      end
      return nil
    end,
    -- `zellij --session <s> action <verb> [--pane-id <id>] …`
    -- pane-id goes before the operands: zellij's parser takes it as an option on
    -- the action subcommand.
    action = function(target, verb)
      local argv = { "--session", target.address, "action", verb }
      if target.paneId then
        argv[#argv + 1] = "--pane-id"
        argv[#argv + 1] = target.paneId
      end
      return argv
    end,
    inputArgs = function(self, target, text)
      local t = M.normalize(text)
      if not t then return nil end
      local verb = target.input == "paste" and "paste" or "write-chars"
      local argv = self.action(target, verb)
      -- `--` terminates options so a leading-dash transcript stays text.
      -- write-chars keeps its historical bare form: the Orchestrator route's
      -- argv must stay byte-for-byte what it has always been.
      if verb == "paste" then argv[#argv + 1] = "--" end
      argv[#argv + 1] = t
      return argv
    end,
    submitArgs = function(self, target)
      if target.submit == "enter" then
        local argv = self.action(target, "send-keys")
        argv[#argv + 1] = "Enter"
        return argv
      end
      local argv = self.action(target, "write")
      argv[#argv + 1] = "13"
      return argv
    end,
  },

  tmux = {
    addressField = "target",
    -- Refuse anything but an explicit session:window[.pane] target.
    validate = function(_, address)
      if not M.isExplicitTmuxTarget(address) then
        return "tmux target '" .. tostring(address)
               .. "' is not an explicit session:window[.pane]"
      end
      return nil
    end,
    -- `tmux send-keys -t <target> -l <text>` then `send-keys -t <target> Enter`
    -- — the same literal-then-Enter pair firstmate uses for tmux panes
    -- (bin/fm-tmux-lib.sh:426,398), so voice-in speaks to the captain exactly
    -- the way firstmate's own away-mode daemon does.
    inputArgs = function(_, target, text)
      local t = M.tmuxSafeText(text)
      if not t then return nil end
      return { "send-keys", "-t", target.address, "-l", t }
    end,
    submitArgs = function(_, target)
      return { "send-keys", "-t", target.address, "Enter" }
    end,
  },
}

-- Resolve a route key ("orchestrator", "firstmate", …) to a target.
--
-- Returns, on success:
--   { key, transport, address, label, chord,
--     session = <zellij only>, target = <tmux only>,
--     input, submit, paneId }, nil
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

  local transportName = nonEmptyString(t.transport) and t.transport or M.TRANSPORT_DEFAULT
  local transport = M.TRANSPORTS[transportName]
  if not transport then
    return nil, "route " .. key .. " has unknown transport " .. transportName
  end

  local address = t[transport.addressField]
  if not nonEmptyString(address) then
    return nil, "route " .. key .. " has no " .. transport.addressField
  end
  local why = transport.validate(cfg, address)
  if why then
    -- Hard stop. See the safety note at the top of this file.
    return nil, "route " .. key .. " " .. why
  end

  return {
    key       = key,
    transport = transportName,
    address   = address,
    label     = nonEmptyString(t.label) and t.label or key,
    chord     = type(t.chord) == "string" and t.chord or nil,
    session   = transportName == "zellij" and address or nil,
    target    = transportName == "tmux" and address or nil,
    input     = M.INPUT_METHODS[t.input]   and t.input  or M.INPUT_DEFAULT,
    submit    = M.SUBMIT_METHODS[t.submit] and t.submit or M.SUBMIT_DEFAULT,
    paneId    = nonEmptyString(t.paneId) and t.paneId or nil,
  }, nil
end

-- Resolve the route used when a caller just wants "the supervisor" (headset
-- MFB, apps/volume_tap). Falls back to the "orchestrator" key so an older
-- config without VOICE_TARGET_DEFAULT still routes the way it always did.
function M.resolveDefault(cfg)
  local key = (type(cfg) == "table" and cfg.VOICE_TARGET_DEFAULT) or "orchestrator"
  return M.resolve(cfg, key)
end

local function transportEntry(cfg, target)
  if type(target) ~= "table" then return nil end
  local transports = (type(cfg) == "table" and cfg.VOICE_TRANSPORTS) or nil
  if type(transports) ~= "table" then return nil end
  local entry = transports[target.transport]
  if type(entry) ~= "table" then return nil end
  return entry
end

-- The CLI binary for a resolved target's transport, from config.VOICE_TRANSPORTS.
function M.binary(cfg, target)
  local entry = transportEntry(cfg, target)
  if not entry or not nonEmptyString(entry.bin) then return nil end
  return entry.bin
end

-- The environment a target's transport CLI should run with.
function M.environment(cfg, target)
  local entry = transportEntry(cfg, target)
  if not entry or type(entry.env) ~= "table" then return nil end
  return entry.env
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
  -- routeKeys is sorted, so a duplicate chord resolves deterministically rather
  -- than by pairs() order. conflicts() is what actually flags the duplicate.
  for _, key in ipairs(M.routeKeys(cfg)) do
    local t = targets[key]
    if type(t) == "table" and lower(t.chord) == want then return key end
  end
  return nil
end

-- Config audit: returns a list of human-readable problems (empty when clean).
-- Catches the mistakes that would silently misroute or mis-deliver speech: two
-- targets sharing a chord, a target stealing a reserved chord, an unknown
-- transport, a missing or ambient address, a zellij target aimed at a crewmate
-- session, and a misspelled input/submit method (which resolve() would otherwise
-- quietly replace with the default).
function M.conflicts(cfg)
  local problems = {}
  local targets = (type(cfg) == "table" and cfg.VOICE_TARGETS) or nil
  if type(targets) ~= "table" then return { "no VOICE_TARGETS table" } end

  local seenChord = {}
  for _, key in ipairs(M.routeKeys(cfg)) do
    local t = targets[key]

    -- Transport + address, resolved exactly the way resolve() does it.
    local transportName = nonEmptyString(t.transport) and t.transport or M.TRANSPORT_DEFAULT
    local transport = M.TRANSPORTS[transportName]
    if not transport then
      problems[#problems + 1] = key .. ": unknown transport '" .. tostring(t.transport) .. "'"
    else
      local address = t[transport.addressField]
      if not nonEmptyString(address) then
        problems[#problems + 1] = key .. ": missing " .. transport.addressField
      else
        local why = transport.validate(cfg, address)
        if why then problems[#problems + 1] = key .. ": " .. why end
      end
      -- input/submit/paneId are zellij-only knobs. Flag them on any other
      -- transport so a copy-paste mistake is loud rather than silently ignored.
      if transportName ~= "zellij" then
        if t.input ~= nil or t.submit ~= nil or t.paneId ~= nil then
          problems[#problems + 1] = key ..
            ": input/submit/paneId apply to the zellij transport only"
        end
      else
        if t.input ~= nil and not M.INPUT_METHODS[t.input] then
          problems[#problems + 1] = key .. ": unknown input method '" .. tostring(t.input) .. "'"
        end
        if t.submit ~= nil and not M.SUBMIT_METHODS[t.submit] then
          problems[#problems + 1] = key .. ": unknown submit method '" .. tostring(t.submit) .. "'"
        end
        if t.paneId ~= nil and not nonEmptyString(t.paneId) then
          problems[#problems + 1] = key .. ": paneId must be a non-empty string"
        end
      end
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
  end
  return problems
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

-- ── argv, per transport ────────────────────────────────────────────────────

local function transportOf(target)
  if type(target) ~= "table" then return nil end
  if not nonEmptyString(target.address) then return nil end
  return M.TRANSPORTS[target.transport]
end

-- argv that types the transcript WITHOUT submitting it. nil when the target is
-- unresolved or the text is blank — the caller must not spawn a task then.
function M.inputArgs(target, text)
  local transport = transportOf(target)
  if not transport then return nil end
  return transport:inputArgs(target, text)
end

-- argv that submits the typed text. Kept separate from inputArgs because none of
-- these multiplexers has an atomic type-and-submit: the text is typed once, and
-- the newline follows only after the type is confirmed — never retyped on a
-- failed submit, since a duplicated instruction is worse than an unsubmitted one.
function M.submitArgs(target)
  local transport = transportOf(target)
  if not transport then return nil end
  return transport:submitArgs(target)
end

-- ── display strings ────────────────────────────────────────────────────────

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
