-- Claude: a Claude Code session that keeps running in the background, as a
-- small terminal on the hub panel's Widgets page. Open the panel (click the notch
-- or Cmd+`), press Tab or click the prompt, type a question, press Return.
-- The answer streams in under it, and a toast says so if the panel was closed
-- by then.
--
-- One `claude -p` process stays up between questions (lib/claude_chat has the
-- arguments and reads its events), so asking costs no start-up and the
-- conversation carries on. Its session id and the last lines of the
-- transcript are kept across reloads, and the next process resumes the same
-- session. "New chat" in the tile starts over.
--
-- It can read files and search the web, nothing more: there is no one at the
-- panel to approve an edit or a command.

local C    = require("lib.claude_chat")
local hub  = require("lib.menuhub")
local menu = require("lib.ui").menu

local HOME        = os.getenv("HOME") or "/tmp"
local SESSION_KEY = "claude_chat.session"
local LINES_KEY   = "claude_chat.lines"
local KEEP_LINES  = 60      -- of the transcript, across reloads
local MAX_RESTART = 3       -- deaths in a row before it stops trying
local LOG         = "/tmp/hs-claude-chat.log"

local CANDIDATES = { HOME .. "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude" }

local function findClaude()
  for _, p in ipairs(CANDIDATES) do
    if hs.fs.attributes(p) then return p end
  end
  return nil
end

-- Hammerspoon starts from Finder with almost no PATH, and Claude Code's tools
-- (rg for Grep) need one.
local function environment()
  return {
    HOME = HOME, USER = os.getenv("USER") or "", LANG = os.getenv("LANG") or "en_US.UTF-8",
    TMPDIR = os.getenv("TMPDIR") or "/tmp",
    PATH = HOME .. "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
  }
end

return function(plugin)
  local ctx, ui = plugin.ctx, plugin.ui
  local M = { state = C.new(), task = nil, deaths = 0, claude = findClaude() }

  local function logf(fmt, ...)
    local f = io.open(LOG, "a")
    if f then f:write(os.date("%H:%M:%S "), string.format(fmt, ...), "\n"); f:close() end
  end

  -- The transcript from before the reload, so the panel does not come back empty.
  local saved = hs.settings.get(LINES_KEY)
  if type(saved) == "table" then
    for _, l in ipairs(saved) do
      if type(l) == "table" and type(l.text) == "string" then M.state.lines[#M.state.lines + 1] = l end
    end
  end

  local function save()
    local keep = {}
    for i = math.max(1, #M.state.lines - KEEP_LINES + 1), #M.state.lines do keep[#keep + 1] = M.state.lines[i] end
    hs.settings.set(LINES_KEY, keep)
    hs.settings.set(SESSION_KEY, M.state.session)
  end

  M.tile = plugin.tile()
  M.tile:setTitle("✻")

  local function status() return C.status(M.state, M.task ~= nil) end

  local function redraw()
    M.tile:setTooltip(status())
    if M.widget then M.widget:update() end
  end

  local start

  local function onLine(line)
    local ok, ev = pcall(hs.json.decode, line)
    if not ok or type(ev) ~= "table" then return end
    local answered = ev.type == "result"
    if C.apply(M.state, ev) then redraw() end
    if answered then
      M.deaths = 0
      save()
      if not hub.isOpen() then
        ui:toast(ev.is_error and "Claude couldn't answer" or "Claude answered · Cmd+` to read",
                 { tone = ev.is_error and "danger" or "success" })
      end
    end
  end

  local function onExit(code, err)
    M.task, M.release = nil, nil
    logf("claude exited %s: %s", tostring(code), tostring(err))
    M.deaths = M.deaths + 1
    -- A session that cannot be resumed fails the same way every time, so the
    -- next try starts a new one.
    M.state.session = nil
    hs.settings.set(SESSION_KEY, nil)
    M.state.busy = false
    if M.deaths > MAX_RESTART then
      C.note(M.state, "Claude Code keeps stopping · log: " .. LOG)
    else
      C.note(M.state, "Claude Code stopped · starting a new session")
      ctx:after(2 * M.deaths, function() if not M.task then start() end end)
    end
    redraw()
  end

  function start()
    if M.task then return end
    if not M.claude then
      C.note(M.state, "Claude Code isn't installed · see claude.ai/code")
      return redraw()
    end
    local args = C.args(plugin.settings.get("model"), hs.settings.get(SESSION_KEY))
    local task, release
    -- Callbacks from a task this plugin has already let go of are ignored:
    -- the exit of a process stopped on purpose is not a crash.
    task, release = ctx:task(M.claude, function(code, _, err)
      if M.task == task then onExit(code, err) end
    end, function(_, out, err)
      if M.task ~= task then return false end
      for _, line in ipairs(C.split(M.state, out)) do onLine(line) end
      if err and err ~= "" then logf("stderr: %s", err) end
      return true
    end, args)
    task:setWorkingDirectory(HOME)
    task:setEnvironment(environment())
    task:start()
    M.task, M.release = task, release
    M.state.buffer = ""
    logf("started %s %s", M.claude, table.concat(args, " "))
    redraw()
  end

  local function stop()
    local release = M.release
    M.task, M.release = nil, nil
    if release then release() end
    M.state.busy, M.state.open = false, nil
  end

  function M.ask(text)
    if not M.task then start() end
    if not M.task then return end
    C.ask(M.state, text)
    M.task:setInput(C.message(text))
    redraw()
  end

  function M.newChat()
    stop()
    M.state = C.new()
    M.deaths = 0
    save()
    start()
  end

  M.widget = plugin.widget(function()
    local lines = {}
    for i = math.max(1, #M.state.lines - 40), #M.state.lines do lines[#lines + 1] = M.state.lines[i] end
    return { lines = lines, busy = M.state.busy, status = status(),
             prompt = M.state.busy and "Thinking…" or "Ask Claude anything · Return sends" }
  end, { submit = M.ask })

  -- A new model takes a new process; the conversation carries on.
  plugin.on("settings", function(key)
    if key == "model" then stop(); start() end
  end)

  M.tile:setMenu(function()
    local model = plugin.settings.get("model")
    local rows = {
      menu.text(status() .. (M.state.model and (" · " .. M.state.model) or "")),
      menu.action("New chat", M.newChat),
      menu.separator(),
      menu.text("Model"),
    }
    for _, m in ipairs({ "haiku", "sonnet", "opus", "default" }) do
      local label = m == "default" and "Claude Code's default" or (m:sub(1, 1):upper() .. m:sub(2))
      rows[#rows + 1] = menu.choice(label, model == m, function() plugin.settings.set("model", m) end)
    end
    rows[#rows + 1] = menu.separator()
    rows[#rows + 1] = menu.text("Ask from the panel: Cmd+` then Tab")
    return rows
  end)

  start()

  function M.stop()
    save()
    stop()
  end

  return M
end
