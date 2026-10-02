-- Pure helpers behind the DeepSeek Harness tile — no hs.* dependency.
--
-- The web profile serves a browser UI from a node process that announces its
-- bound address on one line of stdout, `dsh web: http://127.0.0.1:3080`. That
-- line is worth parsing rather than assuming, because `--port 0` is legal and
-- lets the OS pick.
--
-- There is no `dsh status`, so "is it up?" is answered by asking the address,
-- not the CLI — which is also the only way to notice a server someone started
-- in a terminal.

local M = {}

M.DEFAULT_HOST = "127.0.0.1"
M.DEFAULT_PORT = 3080

-- argv for the launcher, its own flags first: the first token `dsh` does not
-- recognize starts the arguments it hands to the booted app, so `--profile` has
-- to lead. `--no-open` because the tile decides when a browser opens — a start
-- from the menu bar should not hijack the front window.
function M.args(profile, port)
  return { "--profile", profile or "web",
           "--no-open", "--port", tostring(port or M.DEFAULT_PORT) }
end

-- Pull the bound address out of a chunk of the server's stdout. A streaming
-- read hands over arbitrary slices, so this matches anywhere in the chunk
-- instead of anchoring, and trims the punctuation a sentence would end on.
function M.parseUrl(chunk)
  if type(chunk) ~= "string" then return nil end
  local url = chunk:match("(https?://[^%s]+)")
  if not url then return nil end
  url = url:gsub("[%.,;%)%]]+$", "")
  return url ~= "" and url or nil
end

-- Free the port before starting, so a server left over from a terminal — or
-- from a Hammerspoon reload that threw away our task handle — does not collide
-- with the one about to launch.
--
-- `-sTCP:LISTEN` is what makes this safe. A bare `lsof -ti :PORT` also matches
-- sockets whose *remote* port is PORT, and Hammerspoon holds one of those every
-- time the tile polls the server's health; the same pattern took Hammerspoon
-- down from apps/voice_agent before it was fixed there. The pid guard is belt
-- and braces over that. The sleep gives node its SIGTERM shutdown — under a
-- second in practice — before anything tries to bind the port again.
function M.killCmd(port, selfPid)
  return string.format(
    "lsof -tiTCP:%d -sTCP:LISTEN | grep -vx %d | xargs kill 2>/dev/null; sleep 0.6; true",
    port or M.DEFAULT_PORT, selfPid or 0)
end

-- The address to open: what the server reported, else where it was told to bind.
function M.url(state)
  state = state or {}
  if state.url and state.url ~= "" then return state.url end
  return string.format("http://%s:%d",
                       state.host or M.DEFAULT_HOST, state.port or M.DEFAULT_PORT)
end

-- ── Tile ───────────────────────────────────────────────────────────────────
function M.title(state)
  state = state or {}
  if state.busy then return "🐋⏳" end
  return state.running and "🐋" or "🐋💤"
end

function M.tooltip(state)
  state = state or {}
  if state.busy then return state.busy end
  if not state.running then return "Server off" end
  return "Serving " .. M.url(state)
end

return M
