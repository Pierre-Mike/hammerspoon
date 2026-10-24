-- Which design is in use, and where designs live.
--
-- A design is one file in designs/: a Lua table that overrides only the
-- tokens it wants to change from lib/theme's defaults. designs/default.lua
-- overrides nothing. The active one is a name in hs.settings, so it survives
-- reloads, and switching means writing the name and reloading: plugins read
-- their tokens once at load, so a reload is the one moment every plugin and
-- the hub panel agree on the new look.
--
-- lib/theme asks this module for the overrides while it builds its tokens, so
-- this file must never require lib/theme.

local M = {}

M.KEY     = "ui.design"
M.PREVIEW = "ui.design.preview"   -- set by use(): show the gallery after the reload
M.DIR     = "designs"
M.DEFAULT = "default"

local function hsOr(name)
  local h = rawget(_G, "hs")
  return h and h[name]
end

function M.dir()
  return (hsOr("configdir") or ".") .. "/" .. M.DIR
end

-- Where a warning goes. A seam, so a spec can listen.
function M.warn(msg) print(msg) end

-- Every design on disk, "default" first, the rest alphabetically. A file whose
-- name starts with "_" is a draft and is left out.
function M.list(dir)
  dir = dir or M.dir()
  local names, seen = { M.DEFAULT }, { [M.DEFAULT] = true }
  local p = io.popen("ls " .. string.format("%q", dir) .. " 2>/dev/null")
  local found = {}
  if p then
    for f in p:lines() do
      local n = f:match("^([%w_%-]+)%.lua$")
      if n and not n:match("^_") and not seen[n] then found[#found + 1] = n; seen[n] = true end
    end
    p:close()
  end
  table.sort(found)
  for _, n in ipairs(found) do names[#names + 1] = n end
  return names
end

-- "dark" or "light": the macOS appearance right now. Dark when it cannot be
-- asked, which is a spec or an older Hammerspoon.
function M.appearance()
  local host = hsOr("host")
  if not (host and host.interfaceStyle) then return "dark" end
  local ok, style = pcall(host.interfaceStyle)
  return (ok and style == "Dark") and "dark" or ((ok and style == nil) and "light" or "dark")
end

function M.current()
  local settings = hsOr("settings")
  local n = settings and settings.get(M.KEY)
  return (type(n) == "string" and n ~= "") and n or M.DEFAULT
end

-- The override table for `name` (default: the active design) and the name it
-- really loaded. A design that is missing, does not compile, or does not
-- return a table falls back to the default with a warning, so a typo in a
-- design being drafted costs the look, never the config.
function M.overrides(name, dir)
  name = name or M.current()
  local path = (dir or M.dir()) .. "/" .. name .. ".lua"
  local chunk, err = loadfile(path)
  if not chunk then
    if name ~= M.DEFAULT then M.warn("[design] " .. name .. " did not load: " .. tostring(err)) end
    return {}, M.DEFAULT
  end
  local ok, t = pcall(chunk)
  if not ok or type(t) ~= "table" then
    M.warn("[design] " .. name .. " did not return a table: " .. tostring(t))
    return {}, M.DEFAULT
  end
  return t, name
end

-- Switch to `name` and reload. The gallery runs once the new look is up, so
-- trying a design is one call.
function M.use(name)
  hs.settings.set(M.KEY, name)
  hs.settings.set(M.PREVIEW, true)
  hs.reload()
end

-- True once, after a reload that use() asked for.
function M.takePreview()
  local settings = hsOr("settings")
  if not (settings and settings.get(M.PREVIEW)) then return false end
  settings.set(M.PREVIEW, nil)
  return true
end

return M
