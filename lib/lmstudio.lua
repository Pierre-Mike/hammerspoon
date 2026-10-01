-- Pure helpers behind the LM Studio tile — no hs.* dependency, fully testable.
--
-- Three payloads describe the local install, and none of them is enough alone:
--   `lms ls --json`          every model on disk, with the only byte count
--                            anything reports (sizeBytes)
--   GET /api/v0/models       which of them are loaded right now, and at what
--                            context — one 8 ms HTTP call, no process spawn,
--                            but it answers only while the server is up
--   `lms ps --json`          the fallback for a model loaded from the LM Studio
--                            window with the server switched off, and the only
--                            source of the identifier `lms unload` wants
-- catalog() joins them on the model key, which all three spell the same way.

local M = {}

-- Weights are not the whole cost of a load: the KV cache, the runtime and the
-- framework's scratch buffers sit on top, and on a unified-memory Mac they all
-- come out of the same pool. fits() keeps this much clear so a model that only
-- just fits on paper doesn't push the machine into swap.
M.HEADROOM = 2 * 1024 ^ 3

local GB, MB = 1024 ^ 3, 1024 ^ 2

-- Model sizes are read at a glance, so one decimal of a gigabyte is the useful
-- precision; embedding models are small enough to want whole megabytes.
function M.humanBytes(n)
  if type(n) ~= "number" or n <= 0 then return "—" end
  if n >= GB then return string.format("%.1f GB", n / GB) end
  return string.format("%.0f MB", n / MB)
end

-- Activity Monitor's "Memory Used" — app memory + wired + compressed, where app
-- memory is the anonymous pages less the purgeable ones. Everything left out
-- (the file-backed cache, speculative reads) is memory the kernel hands back
-- under pressure, so it counts as room for a model rather than as used.
function M.memory(vm)
  if type(vm) ~= "table" then return nil end
  local total = vm.memSize
  if not total or total <= 0 then return nil end
  local page = vm.pageSize or 4096
  local app = math.max(0, (vm.anonymousPages or 0) - (vm.pagesPurgeable or 0))
  local used = (app + (vm.pagesWiredDown or 0) + (vm.pagesUsedByVMCompressor or 0)) * page
  used = math.min(used, total)
  return { total = total, used = used, free = total - used }
end

local function indexBy(list, field)
  local t = {}
  for _, v in ipairs(list or {}) do
    if v[field] then t[v[field]] = v end
  end
  return t
end

local function row(key, m, l, p)
  m, l, p = m or {}, l or {}, p or {}
  local loaded = (l.state == "loaded") or (p.modelKey ~= nil)
  return {
    key        = key,
    name       = m.displayName or key,
    kind       = ((m.type or l.type) == "embedding" or l.type == "embeddings")
                 and "embedding" or "llm",
    params     = m.paramsString,
    quant      = (m.quantization and m.quantization.name) or l.quantization,
    bytes      = m.sizeBytes or 0,
    mlx        = (l.compatibility_type or m.format) ~= "gguf",
    loaded     = loaded,
    -- `lms unload` takes the runtime identifier, which is the model key unless
    -- the same model was loaded twice under a chosen name.
    identifier = p.identifier or (loaded and key) or nil,
    context    = p.contextLength or l.loaded_context_length,
    maxContext = m.maxContextLength or l.max_context_length,
  }
end

-- Join the three payloads into one list: loaded models first, then largest
-- first, so the memory picture reads top-down.
function M.catalog(disk, live, ps)
  local byId, byKey = indexBy(live, "id"), indexBy(ps, "modelKey")
  local rows, seen = {}, {}
  for _, m in ipairs(disk or {}) do
    local key = m.modelKey
    if key and not seen[key] then
      seen[key] = true
      rows[#rows + 1] = row(key, m, byId[key], byKey[key])
    end
  end
  -- A model pulled down since the last `lms ls` is live but not yet on our disk
  -- listing. Show it with an unknown size rather than pretending it is not there.
  for _, l in ipairs(live or {}) do
    if l.id and not seen[l.id] then
      seen[l.id] = true
      rows[#rows + 1] = row(l.id, nil, l, byKey[l.id])
    end
  end
  table.sort(rows, function(a, b)
    if a.loaded ~= b.loaded then return a.loaded end
    if a.bytes ~= b.bytes then return a.bytes > b.bytes end
    return a.name < b.name
  end)
  return rows
end

function M.loaded(rows)
  local out = {}
  for _, r in ipairs(rows or {}) do
    if r.loaded then out[#out + 1] = r end
  end
  return out
end

function M.loadedBytes(rows)
  local n = 0
  for _, r in ipairs(M.loaded(rows)) do n = n + (r.bytes or 0) end
  return n
end

-- Switching model means the new one takes the old one's place: two 15 GB chat
-- models do not coexist on a 32 GB machine. Only same-kind models are evicted,
-- so an embedding model keeps serving while the chat model changes under it.
function M.replaced(rows, key)
  local kind
  for _, r in ipairs(rows or {}) do
    if r.key == key then kind = r.kind end
  end
  local out = {}
  for _, r in ipairs(rows or {}) do
    if r.loaded and r.kind == kind and r.key ~= key then out[#out + 1] = r end
  end
  return out
end

function M.swapTargets(rows, key)
  local out = {}
  for _, r in ipairs(M.replaced(rows, key)) do
    out[#out + 1] = r.identifier or r.key
  end
  return out
end

-- Whether `key` has room once the models it replaces are unloaded. Unknown free
-- memory answers yes: the menu warns, it does not stand in the way.
function M.fits(rows, key, free)
  if type(free) ~= "number" then return true end
  local want
  for _, r in ipairs(rows or {}) do
    if r.key == key then want = r.bytes or 0 end
  end
  if not want or want == 0 then return true end
  local reclaim = 0
  for _, r in ipairs(M.replaced(rows, key)) do reclaim = reclaim + (r.bytes or 0) end
  return (free + reclaim) >= (want + M.HEADROOM)
end

-- "Qwen3.8 27B · 27B 4bit 15.0 GB"
function M.label(r)
  local shape = {}
  if r.params and r.params ~= "" then shape[#shape + 1] = r.params end
  if r.quant and r.quant ~= "" then shape[#shape + 1] = r.quant end
  shape[#shape + 1] = M.humanBytes(r.bytes)
  return string.format("%s · %s", r.name, table.concat(shape, " "))
end

-- ── Tile ───────────────────────────────────────────────────────────────────
function M.title(state)
  if state.busy then return "🧠⏳" end
  return state.running and "🧠" or "🧠💤"
end

function M.tooltip(state)
  if state.busy then return state.busy end
  local loaded = M.loaded(state.rows)
  if not state.running then
    if #loaded == 0 then return "Server off" end
    return string.format("Server off · %d model%s loaded",
                         #loaded, #loaded == 1 and "" or "s")
  end
  if #loaded == 0 then
    return string.format("No model loaded · port %d", state.port or 1234)
  end
  local names = {}
  for _, r in ipairs(loaded) do names[#names + 1] = r.name end
  return string.format("%s · %s", table.concat(names, ", "),
                       M.humanBytes(M.loadedBytes(state.rows)))
end

return M
