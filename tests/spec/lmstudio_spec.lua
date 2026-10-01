local L = require("lib.lmstudio")

-- Shapes below are trimmed copies of the real payloads:
--   disk  = `lms ls --json`
--   live  = the `data` array of GET /api/v0/models
--   ps    = `lms ps --json`
local function disk()
  return {
    { type = "llm", modelKey = "qwen3.8-27b-mlx", format = "safetensors",
      displayName = "Qwen3.8 27B", sizeBytes = 16081498220, paramsString = "27B",
      quantization = { name = "4bit" }, maxContextLength = 262144 },
    { type = "llm", modelKey = "google/gemma-4-e4b", format = "safetensors",
      displayName = "Gemma 4 E4B", sizeBytes = 6861935101, paramsString = "4B",
      quantization = { name = "4bit" }, maxContextLength = 131072 },
    { type = "embedding", modelKey = "text-embedding-nomic-embed-text-v1.5",
      format = "gguf", displayName = "Nomic Embed Text v1.5", sizeBytes = 84106624,
      quantization = { name = "Q4_K_M" }, maxContextLength = 2048 },
  }
end

local function live()
  return {
    { id = "qwen3.8-27b-mlx", state = "loaded", compatibility_type = "mlx",
      max_context_length = 262144, loaded_context_length = 32768 },
    { id = "google/gemma-4-e4b", state = "not-loaded", compatibility_type = "mlx",
      max_context_length = 131072 },
    { id = "text-embedding-nomic-embed-text-v1.5", state = "not-loaded",
      compatibility_type = "gguf", max_context_length = 2048 },
  }
end

describe("lmstudio.humanBytes", function()
  it("uses GB above a gigabyte", function()
    assert.equals("15.0 GB", L.humanBytes(16081498220))
  end)

  it("uses MB below a gigabyte", function()
    assert.equals("80 MB", L.humanBytes(84106624))
  end)

  it("renders a dash for nothing measurable", function()
    assert.equals("—", L.humanBytes(nil))
    assert.equals("—", L.humanBytes(0))
  end)
end)

describe("lmstudio.memory", function()
  -- Numbers are a real hs.host.vmStat() sample at 16 KiB pages.
  local vm = {
    pageSize = 16384, memSize = 34359738368,
    anonymousPages = 599714, pagesPurgeable = 11597,
    pagesWiredDown = 152061, pagesUsedByVMCompressor = 1123263,
  }

  it("counts app, wired and compressed pages as used", function()
    local m = L.memory(vm)
    local page = 16384
    local want = (599714 - 11597 + 152061 + 1123263) * page
    assert.equals(want, m.used)
    assert.equals(34359738368, m.total)
    assert.equals(m.total - m.used, m.free)
  end)

  it("never reports more used than the machine has", function()
    local m = L.memory({ pageSize = 16384, memSize = 1024, anonymousPages = 99999 })
    assert.equals(1024, m.used)
    assert.equals(0, m.free)
  end)

  it("returns nil when vmStat is unusable", function()
    assert.is_nil(L.memory(nil))
    assert.is_nil(L.memory({ pageSize = 16384 }))
  end)
end)

describe("lmstudio.catalog", function()
  it("marks the model the server reports as loaded", function()
    local rows = L.catalog(disk(), live(), nil)
    assert.equals("qwen3.8-27b-mlx", rows[1].key)
    assert.is_true(rows[1].loaded)
    assert.equals(32768, rows[1].context)
    assert.is_false(rows[2].loaded)
  end)

  it("sorts loaded first, then by size descending", function()
    local rows = L.catalog(disk(), live(), nil)
    assert.same({ "Qwen3.8 27B", "Gemma 4 E4B", "Nomic Embed Text v1.5" },
                { rows[1].name, rows[2].name, rows[3].name })
  end)

  it("still lists the disk catalog when the server is down", function()
    local rows = L.catalog(disk(), nil, nil)
    assert.equals(3, #rows)
    for _, r in ipairs(rows) do assert.is_false(r.loaded) end
  end)

  it("reads a model loaded with no server from lms ps", function()
    local ps = { { modelKey = "google/gemma-4-e4b", identifier = "gemma-4-e4b-2",
                   contextLength = 8192 } }
    local rows = L.catalog(disk(), nil, ps)
    assert.equals("google/gemma-4-e4b", rows[1].key)
    assert.is_true(rows[1].loaded)
    assert.equals("gemma-4-e4b-2", rows[1].identifier)
    assert.equals(8192, rows[1].context)
  end)

  it("separates embeddings from chat models", function()
    local rows = L.catalog(disk(), live(), nil)
    assert.equals("llm", rows[1].kind)
    assert.equals("embedding", rows[3].kind)
  end)

  it("keeps a model the server knows but the disk listing has not caught up on", function()
    local rows = L.catalog({}, live(), nil)
    assert.equals(3, #rows)
    assert.equals("qwen3.8-27b-mlx", rows[1].key)
    assert.equals(0, rows[1].bytes)
  end)
end)

describe("lmstudio.loadedBytes", function()
  it("adds up only what is resident", function()
    assert.equals(16081498220, L.loadedBytes(L.catalog(disk(), live(), nil)))
  end)

  it("is zero with nothing loaded", function()
    assert.equals(0, L.loadedBytes(L.catalog(disk(), nil, nil)))
  end)
end)

describe("lmstudio.replaced", function()
  it("evicts the loaded model of the same kind", function()
    local rows = L.catalog(disk(), live(), nil)
    local out = L.replaced(rows, "google/gemma-4-e4b")
    assert.equals(1, #out)
    assert.equals("qwen3.8-27b-mlx", out[1].key)
  end)

  it("leaves an embedding model serving while the chat model changes", function()
    local d, lv = disk(), live()
    lv[3].state = "loaded"
    local rows = L.catalog(d, lv, nil)
    local out = L.replaced(rows, "google/gemma-4-e4b")
    assert.equals(1, #out)
    assert.equals("qwen3.8-27b-mlx", out[1].key)
  end)

  it("never evicts the model being switched to", function()
    local rows = L.catalog(disk(), live(), nil)
    assert.same({}, L.replaced(rows, "qwen3.8-27b-mlx"))
  end)

  it("returns the identifier lms unload wants", function()
    local ps = { { modelKey = "qwen3.8-27b-mlx", identifier = "qwen-a" } }
    local rows = L.catalog(disk(), live(), ps)
    assert.same({ "qwen-a" }, L.swapTargets(rows, "google/gemma-4-e4b"))
  end)
end)

describe("lmstudio.fits", function()
  local GB = 1024 ^ 3

  it("counts the memory the swap gives back", function()
    local rows = L.catalog(disk(), live(), nil)
    -- 1 GB free, but switching frees the 15 GB Qwen holds.
    assert.is_true(L.fits(rows, "google/gemma-4-e4b", 1 * GB))
  end)

  it("is false when even the freed memory is not enough", function()
    local rows = L.catalog(disk(), nil, nil)   -- nothing loaded, nothing to reclaim
    assert.is_false(L.fits(rows, "qwen3.8-27b-mlx", 4 * GB))
  end)

  it("keeps headroom for the KV cache on top of the weights", function()
    local rows = L.catalog(disk(), nil, nil)
    -- Gemma's weights are 6.4 GB; 7 GB free is not enough once headroom counts.
    assert.is_false(L.fits(rows, "google/gemma-4-e4b", 7 * GB))
    assert.is_true(L.fits(rows, "google/gemma-4-e4b", 12 * GB))
  end)

  it("says yes when memory is unknown rather than blocking the load", function()
    local rows = L.catalog(disk(), nil, nil)
    assert.is_true(L.fits(rows, "qwen3.8-27b-mlx", nil))
  end)
end)

describe("lmstudio.label", function()
  it("reads name, then size and shape", function()
    local rows = L.catalog(disk(), live(), nil)
    assert.equals("Qwen3.8 27B · 27B 4bit 15.0 GB", L.label(rows[1]))
  end)

  it("drops the parameter count when the model has none", function()
    local rows = L.catalog(disk(), live(), nil)
    assert.equals("Nomic Embed Text v1.5 · Q4_K_M 80 MB", L.label(rows[3]))
  end)
end)

describe("lmstudio.title", function()
  it("shows an hourglass while a model moves", function()
    assert.equals("🧠⏳", L.title({ busy = "Loading Gemma 4 E4B…" }))
  end)

  it("sleeps when the server is off", function()
    assert.equals("🧠💤", L.title({ running = false, rows = {} }))
  end)

  it("is awake when the server is up", function()
    assert.equals("🧠", L.title({ running = true, rows = {} }))
  end)
end)

describe("lmstudio.tooltip", function()
  it("names what is loaded and what it costs", function()
    local rows = L.catalog(disk(), live(), nil)
    assert.equals("Qwen3.8 27B · 15.0 GB",
                  L.tooltip({ running = true, port = 1234, rows = rows }))
  end)

  it("says so when the server is up with nothing loaded", function()
    local rows = L.catalog(disk(), live(), nil)
    rows[1].loaded = false
    assert.equals("No model loaded · port 1234",
                  L.tooltip({ running = true, port = 1234, rows = rows }))
  end)

  it("reports a model still resident after the server stops", function()
    local ps = { { modelKey = "qwen3.8-27b-mlx", identifier = "qwen-a" } }
    local rows = L.catalog(disk(), nil, ps)
    assert.equals("Server off · 1 model loaded",
                  L.tooltip({ running = false, rows = rows }))
  end)

  it("is plain off when nothing is resident", function()
    assert.equals("Server off", L.tooltip({ running = false, rows = {} }))
  end)

  it("lets a move in progress speak for itself", function()
    assert.equals("Loading Gemma 4 E4B…", L.tooltip({ busy = "Loading Gemma 4 E4B…" }))
  end)
end)
