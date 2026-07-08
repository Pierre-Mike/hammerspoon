-- Floating panels for Claude Code Stop-hook events.
-- Triggered by: open "hammerspoon://claude-done?session=...&title=...&summary=...&is_bg=0|1&cwd=..."
-- Reply routes back to the originating zellij session (fg) or into Orchestrator with a prefix (bg).

local M = { panels = {}, panelWidth = 380, panelHeight = 110, gap = 10 }

local DASHBOARD_URL = "http://localhost:5173"
local ZELLIJ = "/opt/homebrew/bin/zellij"
local ZELLIJ_ENV = {
  HOME = os.getenv("HOME"),
  PATH = "/opt/homebrew/bin:/usr/bin:/bin",
  ZELLIJ_SOCKET_DIR = "/var/z",
}
local ORCHESTRATOR = "Orchestrator"
local LOG = "/tmp/hs-claude-done.log"
local AUTO_DISMISS_S = 300

local function logf(fmt, ...)
  local f = io.open(LOG, "a")
  if f then f:write(os.date("%H:%M:%S "), string.format(fmt, ...), "\n"); f:close() end
end

local function urldecode(s)
  if not s then return "" end
  s = s:gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function zellijSend(session, text)
  if not session or session == "" or not text or text == "" then return end
  local t = hs.task.new(ZELLIJ, function(c, _, e)
    if c ~= 0 then logf("write-chars %s failed: %s", session, tostring(e)); return end
    local enter = hs.task.new(ZELLIJ, function() end,
      { "--session", session, "action", "write", "13" })
    enter:setEnvironment(ZELLIJ_ENV); enter:start()
  end, { "--session", session, "action", "write-chars", text })
  t:setEnvironment(ZELLIJ_ENV); t:start()
  logf("→ %s: %s", session, text:sub(1, 80))
end

local function relayout()
  local frame = hs.screen.mainScreen():frame()
  for i, p in ipairs(M.panels) do
    if p.canvas then
      local x = frame.x + frame.w - M.panelWidth - 20
      local y = frame.y + 60 + (i - 1) * (M.panelHeight + M.gap)
      p.canvas:topLeft({ x = x, y = y })
    end
  end
end

local function dismiss(panel)
  for i, p in ipairs(M.panels) do
    if p == panel then table.remove(M.panels, i); break end
  end
  if panel.canvas then panel.canvas:delete(); panel.canvas = nil end
  if panel.timer then panel.timer:stop(); panel.timer = nil end
  relayout()
end

local function sendAndDismiss(panel, text)
  if panel.is_bg then
    zellijSend(ORCHESTRATOR, "[reply for " .. panel.session .. "] " .. text)
  else
    zellijSend(panel.session, text)
  end
  dismiss(panel)
end

local function reply(panel)
  local button, txt = hs.dialog.textPrompt(
    "Reply → " .. panel.session,
    panel.subject or "",
    "", "Send", "Cancel")
  if button == "Send" and txt and txt ~= "" then sendAndDismiss(panel, txt) end
end

-- Reuse an existing Safari tab already on the dashboard host; else open one.
local DASHBOARD_HOST = DASHBOARD_URL:gsub("^https?://", "")

local function openInSafari(url)
  local script = ([[
    tell application "Safari"
      set tgtURL to "%s"
      set dashHost to "%s"
      set wasFound to false
      repeat with w in windows
        repeat with t in tabs of w
          if (URL of t) contains dashHost then
            set URL of t to tgtURL
            set current tab of w to t
            set index of w to 1
            set wasFound to true
            exit repeat
          end if
        end repeat
        if wasFound then exit repeat
      end repeat
      if not wasFound then
        if (count of windows) = 0 then
          make new document with properties {URL:tgtURL}
        else
          tell window 1 to set current tab to (make new tab with properties {URL:tgtURL})
        end if
      end if
      activate
    end tell
  ]]):format(url, DASHBOARD_HOST)
  local ok, _, err = hs.osascript.applescript(script)
  if not ok then logf("safari open failed: %s", hs.inspect(err)) end
  return ok
end

local function openDashboard(panel)
  local url
  if panel.short and panel.short ~= "" then
    url = DASHBOARD_URL .. "/sessions/" .. panel.short
  elseif panel.project and panel.project ~= "" then
    url = DASHBOARD_URL .. "/projects/" .. panel.project
  else
    url = DASHBOARD_URL
  end
  if not openInSafari(url) then hs.urlevent.openURL(url) end
  logf("open %s", url)
  dismiss(panel)
end

local function buildPanel(params)
  local session = urldecode(params.session or "unknown")
  local title   = urldecode(params.title or "")
  local summary = urldecode(params.summary or "")
  local short   = urldecode(params.short or "")
  local project = urldecode(params.project or "")
  local is_bg   = params.is_bg == "1"

  local subject = title ~= "" and title or summary
  if subject == "" then subject = "(done)" end
  if #subject > 90 then subject = subject:sub(1, 90) .. "…" end

  local panel = {
    session = session, subject = subject, is_bg = is_bg,
    short = short, project = project,
  }

  local w, h = M.panelWidth, M.panelHeight
  local frame = hs.screen.mainScreen():frame()
  local x = frame.x + frame.w - w - 20
  local y = frame.y + 60 + (#M.panels) * (h + M.gap)

  local bandColor = is_bg
    and { red = 1.0,  green = 0.62, blue = 0.10, alpha = 1.0 }
    or  { red = 0.28, green = 0.85, blue = 0.42, alpha = 1.0 }

  local cv = hs.canvas.new({ x = x, y = y, w = w, h = h })
    :behavior({ "canJoinAllSpaces", "stationary" })
  cv:level(hs.canvas.windowLevels.overlay)
  cv:clickActivating(false)
  cv:canvasMouseEvents(true, false, false, false)

  cv:appendElements(
    { id = "bg", type = "rectangle", action = "fill",
      fillColor = { red = 0.07, green = 0.07, blue = 0.09, alpha = 0.93 },
      strokeColor = { white = 1, alpha = 0.10 }, strokeWidth = 1,
      roundedRectRadii = { xRadius = 14, yRadius = 14 } },
    { id = "band", type = "rectangle", action = "fill",
      fillColor = bandColor,
      frame = { x = 0, y = 8, w = 5, h = h - 16 },
      roundedRectRadii = { xRadius = 2, yRadius = 2 } },
    { id = "session", type = "text",
      text = (is_bg and "● bg · " or "◉ ") .. session,
      textColor = { white = 1, alpha = 1 },
      textSize = 15, textFont = "Menlo-Bold",
      frame = { x = 18, y = 9, w = w - 36, h = 22 } },
    { id = "subject", type = "text",
      text = subject,
      textColor = { white = 1, alpha = 0.72 },
      textSize = 12,
      frame = { x = 18, y = 32, w = w - 36, h = 36 } },
    { id = "close", type = "text",
      text = "✕",
      textColor = { white = 1, alpha = 0.55 },
      textSize = 14, textAlignment = "center",
      frame = { x = w - 26, y = 6, w = 18, h = 18 },
      trackMouseDown = true }
  )

  local bw, gap = 80, 8
  local by = h - 32
  local x0 = 18
  local function btn(idx, label, color)
    local bx = x0 + (idx - 1) * (bw + gap)
    cv:appendElements(
      { id = "btn" .. idx, type = "rectangle", action = "fill",
        fillColor = color,
        frame = { x = bx, y = by, w = bw, h = 24 },
        roundedRectRadii = { xRadius = 6, yRadius = 6 },
        trackMouseDown = true },
      { id = "btn" .. idx .. "_t", type = "text",
        text = label,
        textColor = { white = 1, alpha = 1 },
        textSize = 13, textAlignment = "center",
        frame = { x = bx, y = by + 4, w = bw, h = 20 },
        trackMouseDown = true }
    )
  end
  btn(1, "✓ Yes",    { red = 0.16, green = 0.55, blue = 0.32, alpha = 1.0 })
  btn(2, "✗ No",     { red = 0.55, green = 0.20, blue = 0.20, alpha = 1.0 })
  btn(3, "✎ Reply",  { red = 0.25, green = 0.30, blue = 0.48, alpha = 1.0 })
  btn(4, "🔗 Open",  { red = 0.18, green = 0.40, blue = 0.55, alpha = 1.0 })

  cv:mouseCallback(function(_, eventType, elementId, _, _)
    if eventType ~= "mouseDown" then return end
    if elementId == "btn1" or elementId == "btn1_t" then sendAndDismiss(panel, "yes")
    elseif elementId == "btn2" or elementId == "btn2_t" then sendAndDismiss(panel, "no")
    elseif elementId == "btn3" or elementId == "btn3_t" then reply(panel)
    elseif elementId == "btn4" or elementId == "btn4_t" then openDashboard(panel)
    elseif elementId == "close" then dismiss(panel)
    end
  end)

  cv:show()
  panel.canvas = cv
  panel.timer = hs.timer.doAfter(AUTO_DISMISS_S, function() dismiss(panel) end)
  table.insert(M.panels, panel)
  logf("panel + session=%s is_bg=%s subject=%q", session, tostring(is_bg), subject)
  return panel
end

hs.urlevent.bind("claude-done", function(_, params)
  buildPanel(params or {})
end)

hs.hotkey.bind({ "cmd", "shift" }, "y", function()
  local p = M.panels[#M.panels]; if p then sendAndDismiss(p, "yes") end
end)
hs.hotkey.bind({ "cmd", "shift" }, "n", function()
  local p = M.panels[#M.panels]; if p then sendAndDismiss(p, "no") end
end)
hs.hotkey.bind({ "cmd", "shift" }, "r", function()
  local p = M.panels[#M.panels]; if p then reply(p) end
end)
hs.hotkey.bind({ "cmd", "shift" }, "escape", function()
  local p = M.panels[#M.panels]; if p then dismiss(p) end
end)

return M
