-- OCR — OvisOCR2 on this Mac, for other tools and from the hub.
--
-- One warm Python server (apps/ovis_ocr/server.py, :8797) runs OvisOCR2 through
-- mlx-vlm and turns an image or a PDF into Markdown. Everything else reaches it
-- over HTTP:
--   • LLM tools   apps/ovis_ocr/mcp.py, an MCP stdio bridge with one tool,
--                 ocr_to_markdown(path, pages?)
--   • scripts     curl --data-binary @scan.pdf http://127.0.0.1:8797/ocr
--   • a browser   http://127.0.0.1:8797/ — drop a file, get the Markdown back
--   • this tile   OCR a file (writes <name>.ocr.md beside it), OCR the clipboard
--                 image, open the drop page
--   • a URL       open 'hammerspoon://ocr?path=/abs/scan.pdf'
--
-- The server loads the model on the first request and drops it after ten idle
-- minutes, so keeping it on all day costs ~60 MB rather than ~1.8 GB. That is why
-- it starts with Hammerspoon instead of waiting to be asked: an MCP client that
-- finds the port closed has no way to open it. The Server switch persists, for
-- anyone who would rather it did not.
--
-- The server is this plugin's child, owned by its context, so M.dispose() stops
-- it with the tile and the poll.

local O     = require("lib.ovis_ocr")
local utils = require("lib.utils")

local ctx = require("lib.context").new("OCR")

local HOME   = os.getenv("HOME")
local PY     = HOME .. "/.local/share/uv/tools/mlx-vlm/bin/python"
local SERVER = HOME .. "/.hammerspoon/apps/ovis_ocr/server.py"
local LOG    = "/tmp/hs-ovis-ocr.log"
local SERVER_LOG = "/tmp/hs-ovis-ocr-server.log"
local CLIP_IMAGE = "/tmp/hs-ovis-ocr-clipboard.png"
local SETTING = "ovis_ocr.server"
local POLL_SECS = 15
local MAX_TIME  = 1800   -- a 100-page PDF at ~5 s a page, with room to spare

local M = {
  menu    = nil,
  port    = O.DEFAULT_PORT,
  running = false,
  loaded  = false,
  busy    = false,     -- the server says it is reading (for anyone)
  working = 0,         -- requests this tile has in flight
  moving  = nil,       -- "Starting…" / "Stopping…"
  last    = nil,       -- one line about the last result
  server  = nil,
  serverRelease = nil,
  kill    = nil,
  reqs    = {},        -- curl tasks, held so they are not collected mid-read
}

local function logf(fmt, ...) utils.logf(LOG, fmt, ...) end

local function installed() return hs.fs.attributes(PY) ~= nil end

local function wanted()
  local v = hs.settings.get(SETTING)
  return v == nil or v == true
end

local function state()
  return { running = M.running, loaded = M.loaded, busy = M.busy,
           working = M.working, moving = M.moving }
end

local function redraw()
  if not M.menu then return end
  M.menu:setTitle(O.title(state()))
  M.menu:setTooltip("OCR · " .. O.status(state()))
end

local function notify(title, text, onClick)
  ctx:ui():notify(text, { title = title, onClick = onClick })
end

-- hs.json.decode throws on anything that is not JSON, and an error page is not.
local function decode(s)
  if type(s) ~= "string" or s == "" then return nil end
  local ok, v = pcall(hs.json.decode, s)
  return ok and type(v) == "table" and v or nil
end

-- ── Health ─────────────────────────────────────────────────────────────────
function M.poll()
  hs.http.asyncGet(O.base(M.port) .. "/health", nil, function(status, body)
    local up = status == 200
    if up ~= M.running then logf("server %s", up and "up" or "down") end
    M.running = up
    local h = up and decode(body) or nil
    M.loaded = (h and h.loaded) and true or false
    M.busy   = (h and h.busy) and true or false
    if up and M.moving == "Starting…" then M.moving = nil end
    redraw()
  end)
end

-- ── Server lifecycle ───────────────────────────────────────────────────────
local function launch()
  local task, done
  task, done = ctx:task("/bin/sh", function(code)
    done()
    logf("server exited code=%s (output in %s)", tostring(code), SERVER_LOG)
    if M.server == task then
      M.server, M.serverRelease, M.running, M.loaded = nil, nil, false, false
      if M.moving == "Starting…" then M.moving = nil end
      redraw()
    end
  end, { "-c", O.launchCmd(PY, SERVER, SERVER_LOG) })
  M.server, M.serverRelease = task, done
  task:setEnvironment({
    HOME = HOME,
    PATH = "/opt/homebrew/bin:/usr/bin:/bin",
    PYTHONUNBUFFERED = "1",
    OVIS_OCR_PORT = tostring(M.port),
  })
  task:start()
  logf("launching %s (port %d, output in %s)", SERVER, M.port, SERVER_LOG)
  for _, d in ipairs({ 1, 3, 6, 12 }) do ctx:after(d, M.poll) end
end

local function freePort(after)
  local pid = hs.processInfo and hs.processInfo.processID or 0
  local kill, done
  kill, done = ctx:task("/bin/sh", function()
    done()
    M.kill = nil
    if after then after() end
  end, { "-c", O.killCmd(M.port, pid) })
  M.kill = kill
  kill:start()
end

function M.start()
  if not installed() or M.moving then return end
  hs.settings.set(SETTING, true)
  M.moving = "Starting…"
  redraw()
  if M.serverRelease then M.serverRelease() end
  M.server, M.serverRelease = nil, nil
  freePort(launch)
end

function M.stop()
  if M.moving then return end
  hs.settings.set(SETTING, false)
  M.moving = "Stopping…"
  redraw()
  if M.serverRelease then M.serverRelease() end
  M.server, M.serverRelease = nil, nil
  freePort(function()
    M.moving, M.running, M.loaded = nil, false, false
    redraw()
    M.poll()
  end)
end

function M.toggle()
  if M.running or M.server then M.stop() else M.start() end
end

function M.unload()
  hs.http.asyncPost(O.base(M.port) .. "/unload", "", nil, function() M.poll() end)
end

-- ── Reading files ──────────────────────────────────────────────────────────
-- `onDone(result)` gets the server's JSON answer: markdown, pages, seconds, and
-- saved when save was asked for.
function M.ocr(path, opts, onDone)
  opts = opts or {}
  if not M.running then
    notify("OCR", "The server is off. Turn it on in the OCR tile.")
    return
  end
  local body = hs.json.encode({ path = path, save = opts.save or nil,
                                pages = opts.pages, format = "json" })
  M.working = M.working + 1
  redraw()
  logf("reading %s", path)
  local task, done
  task, done = ctx:task("/usr/bin/curl", function(code, out, err)
    done()
    M.reqs[task] = nil
    M.working = math.max(0, M.working - 1)
    local res = code == 0 and decode(out) or nil
    if not res or not res.markdown then
      local why = utils.trim((out and out ~= "" and out) or err or "") or ""
      logf("failed %s: code=%s %s", path, tostring(code), why)
      M.last = "Failed: " .. utils.truncate(why ~= "" and why or "no answer", 80)
      notify("OCR failed", why ~= "" and why or ("curl exited " .. tostring(code)))
    else
      M.last = O.summary(res)
      logf("read %s: %s", path, M.last)
      if onDone then onDone(res) end
    end
    redraw()
  end, O.curlArgs(O.base(M.port), body, MAX_TIME))
  M.reqs[task] = true
  task:start()
end

-- Markdown to the clipboard and to <name>.ocr.md beside the file; the
-- notification opens the file.
function M.ocrFile(path)
  if not O.isSupported(path) then
    notify("OCR", "Not an image or PDF: " .. tostring(path))
    return
  end
  M.ocr(path, { save = true }, function(res)
    hs.pasteboard.setContents(res.markdown)
    local saved = res.saved or O.savedPath(path)
    notify("OCR · " .. O.summary(res),
           "Copied, and saved to " .. saved:match("[^/]+$"),
           function() hs.execute("open " .. string.format("%q", saved)) end)
  end)
end

function M.chooseFile()
  local picked = hs.dialog.chooseFileOrFolder("Choose images or PDFs to read",
                                              HOME .. "/Downloads", true, false, true,
                                              O.FILE_TYPES)
  hs.focus()
  if not picked then return end
  for _, p in pairs(picked) do M.ocrFile(p) end
end

function M.ocrClipboard()
  local img = hs.pasteboard.readImage()
  if not img then
    notify("OCR", "There is no image on the clipboard.")
    return
  end
  img:saveToFile(CLIP_IMAGE)
  M.ocr(CLIP_IMAGE, {}, function(res)
    hs.pasteboard.setContents(res.markdown)
    notify("OCR · " .. O.summary(res), "The Markdown is on the clipboard.")
  end)
end

function M.openPage()
  if M.running then
    hs.urlevent.openURL(O.base(M.port) .. "/")
  else
    notify("OCR", "The server is off. Turn it on in the OCR tile.")
  end
end

-- ── Menu ───────────────────────────────────────────────────────────────────
local function buildMenu()
  if not installed() then
    return {
      { title = "mlx-vlm not installed", disabled = true },
      { title = "uv tool install mlx-vlm --with pypdfium2", disabled = true },
    }
  end
  local off = not M.running
  local items = {
    { title = "Server", switch = true, checked = M.running or M.moving == "Starting…",
      fn = function() M.toggle() end },
    { title = O.status(state()), disabled = true },
  }
  if M.last then items[#items + 1] = { title = "Last: " .. M.last, disabled = true } end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "OCR a file…", disabled = off,
                        fn = function() M.chooseFile() end }
  items[#items + 1] = { title = "OCR the clipboard image", disabled = off,
                        fn = function() M.ocrClipboard() end }
  items[#items + 1] = { title = "Open the drop page", disabled = off,
                        fn = function() M.openPage() end }
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "Unload the model now", disabled = off or not M.loaded,
                        fn = function() M.unload() end }
  items[#items + 1] = { title = "Copy the MCP command",
                        fn = function()
                          hs.pasteboard.setContents(
                            "claude mcp add --scope user ovis-ocr -- python3 " ..
                            HOME .. "/.hammerspoon/apps/ovis_ocr/mcp.py")
                        end }
  items[#items + 1] = { title = "Open server output",
                        fn = function() hs.execute("open " .. SERVER_LOG) end }
  return items
end

-- ── init ───────────────────────────────────────────────────────────────────
M.menu = ctx:tile("OCR")
M.menu:setMenu(buildMenu)
redraw()

-- open 'hammerspoon://ocr?path=/Users/me/scan.pdf'
ctx:url("ocr", function(_evt, params)
  if params and params.path then M.ocrFile(params.path) end
end)

if installed() and wanted() then M.start() else M.poll() end
ctx:timer(POLL_SECS, function() M.poll() end)

-- Switch the plugin off: server, curl requests, poll, URL handler and tile.
function M.dispose()
  ctx:dispose()
  M.server, M.serverRelease, M.kill, M.reqs = nil, nil, nil, {}
  M.running, M.working, M.moving = false, 0, nil
end

return M
