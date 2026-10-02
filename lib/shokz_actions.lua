-- Pure: which action each Shokz chord runs, and the hub menu that picks it. No
-- hs.* dependency, so the choice logic is unit-tested; apps/shokz owns the
-- actions themselves and where the choice is saved.
--
-- A catalog is the list of things a chord can do. Each entry is
--   { id, label, fn, available = fn() -> bool (optional) }
-- `available` lets an action that depends on another plugin (dictation, TTS,
-- noise) drop out of the picker while that plugin is switched off, instead of
-- offering a choice that would only say "not loaded" when it fires.

local M = {}

-- The two chords apps/shokz recognises, in menu order. Both are net-zero, so
-- the volume ends where it started.
M.CHORDS = {
  { id = "down_up", label = "Volume − then +" },
  { id = "up_down", label = "Volume + then −" },
}

M.DEFAULT = "alert"

function M.newCatalog()
  return { order = {}, byId = {} }
end

-- Adding an id that already exists replaces it in place, so a plugin that
-- re-registers on reload keeps its position in the picker.
function M.add(catalog, entry)
  if not catalog.byId[entry.id] then catalog.order[#catalog.order + 1] = entry.id end
  catalog.byId[entry.id] = entry
end

local function usable(entry)
  if not entry then return false end
  if entry.available then
    local ok, yes = pcall(entry.available)
    return ok and yes == true
  end
  return true
end

-- The action id a chord runs. A saved choice wins while its action exists and
-- is usable. Otherwise an app that wired this chord in code (registered as
-- "code:<chord>") takes it, and failing that the catalog default.
function M.choice(catalog, saved, chord)
  local id = saved and saved[chord]
  if id and usable(catalog.byId[id]) then return id end
  local code = "code:" .. chord
  if usable(catalog.byId[code]) then return code end
  return M.DEFAULT
end

function M.labelOf(catalog, id)
  local e = catalog.byId[id]
  return e and e.label or id
end

-- The hub menu rows for the chord pickers: one drill-in row per chord, titled
-- with its current action, holding a ✓ list of every usable action.
-- `pick(chord, id)` is called when a row is chosen.
function M.menu(catalog, saved, pick)
  local rows = {}
  for _, c in ipairs(M.CHORDS) do
    local current = M.choice(catalog, saved, c.id)
    local sub = {}
    for _, id in ipairs(catalog.order) do
      local e = catalog.byId[id]
      if usable(e) then
        sub[#sub + 1] = {
          title = e.label, checked = (id == current),
          fn = function() pick(c.id, id) end,
        }
      end
    end
    rows[#rows + 1] = {
      title = c.label .. ":  " .. M.labelOf(catalog, current),
      menu = sub,
    }
  end
  return rows
end

return M
