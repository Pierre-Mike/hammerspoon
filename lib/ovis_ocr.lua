-- Pure helpers behind the OCR tile — no hs.* dependency.
--
-- The OCR itself lives in apps/ovis_ocr/server.py, a Python process on :8797 that
-- runs OvisOCR2 through mlx-vlm and answers with Markdown. This module builds the
-- shell lines that start and free it, the curl call the tile reads a file
-- through, and the words the tile shows.

local M = {}

M.DEFAULT_PORT = 8797

function M.base(port)
  return string.format("http://127.0.0.1:%d", port or M.DEFAULT_PORT)
end

local function quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- `exec` matters: without it terminate() kills the shell and leaves Python
-- holding the port and the model.
function M.launchCmd(py, script, log)
  return string.format("exec %s %s >> %s 2>&1", quote(py), quote(script), quote(log))
end

-- Free the port before a start, so a server left by a reload, or started in a
-- terminal, does not collide with the new one. `-sTCP:LISTEN` keeps it from
-- matching the socket Hammerspoon itself holds while polling /health. Full
-- lsof path because /usr/sbin is not on the task's PATH.
function M.killCmd(port, selfPid)
  return string.format(
    "/usr/sbin/lsof -tiTCP:%d -sTCP:LISTEN | grep -vx %d | xargs kill 2>/dev/null; sleep 0.6; true",
    port or M.DEFAULT_PORT, selfPid or 0)
end

-- curl rather than hs.http: a 40-page PDF takes minutes, and hs.http's requests
-- give up long before that. --fail-with-body exits non-zero on a 4xx/5xx and
-- still prints the server's reason, which is the message worth showing.
function M.curlArgs(base, body, maxTime)
  return {
    "-sS", "--fail-with-body", "--max-time", tostring(maxTime or 900),
    "-H", "Content-Type: application/json",
    "-d", body,
    base .. "/ocr",
  }
end

local SUPPORTED = {
  png = true, jpg = true, jpeg = true, webp = true, gif = true, bmp = true,
  tif = true, tiff = true, heic = true, heif = true, pdf = true,
}
M.FILE_TYPES = { "png", "jpg", "jpeg", "webp", "gif", "bmp", "tif", "tiff",
                 "heic", "heif", "pdf" }

function M.isSupported(path)
  if type(path) ~= "string" then return false end
  local ext = path:match("%.([^./]+)$")
  return ext ~= nil and SUPPORTED[ext:lower()] == true
end

-- Where the server writes a file it was asked to save: beside the source, so
-- scan.pdf gets scan.ocr.md and never overwrites a scan.md someone wrote.
function M.savedPath(path)
  return (path:match("^(.*)%.[^/.]+$") or path) .. ".ocr.md"
end

-- ── Tile ───────────────────────────────────────────────────────────────────
-- state: running (server answers), loaded (model resident), busy (server is
-- reading), working (requests this tile has in flight), moving (start/stop).
function M.title(state)
  state = state or {}
  if state.busy or state.moving or (state.working or 0) > 0 then return "📄⏳" end
  return state.running and "📄" or "📄💤"
end

function M.status(state)
  state = state or {}
  if state.moving then return state.moving end
  if not state.running then return "Server off" end
  if state.busy or (state.working or 0) > 0 then return "Reading…" end
  if state.loaded then return "Model loaded" end
  return "Ready · model loads on first use"
end

function M.summary(res)
  res = res or {}
  local n = tonumber(res.pages) or 0
  local s = string.format("%d page%s", n, n == 1 and "" or "s")
  if res.seconds then s = s .. string.format(" · %.1fs", res.seconds) end
  return s
end

return M
