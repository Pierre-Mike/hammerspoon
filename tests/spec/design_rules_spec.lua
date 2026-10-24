-- The look is shared only while no plugin draws its own. These rules are what
-- keeps it that way: a plugin that writes a color table, a corner radius, a
-- raw point size or an hs.alert fails here, and the message says which
-- component to reach for instead.
--
-- Only this repo's apps are read. A plugin symlinked in from elsewhere
-- (apps/voice_agent) is someone else's file, and `find` does not follow it.

_G.hs = require("hs")

local RULES = {
  { pattern = "hs%.alert",           use = "ctx:ui():toast(text, { tone = ... })" },
  { pattern = "hs%.notify%.new",     use = "ctx:ui():notify(text, opts)" },
  { pattern = "ctx:canvas%(",        use = "ctx:ui():surface(name, frame, opts), or a component" },
  { pattern = "alpha%s*=",           use = "a color role from lib/theme (theme.color.*, theme.tone(name))" },
  { pattern = "roundedRectRadii",    use = "ui.backdrop(w, h, { radius = \"md\" }) or theme.radius.*" },
  { pattern = "textSize%s*=%s*%d",   use = "ui.label(text, frame, { style = \"body\" }) or theme.text.*" },
  { pattern = "fillColor%s*=%s*{",   use = "theme.color.* or ui.dot / ui.button" },
}

local function files()
  local out, p = {}, io.popen("find apps templates -name '*.lua' -type f 2>/dev/null")
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  table.sort(out)
  return out
end

-- Comments may name what they replaced; only code is policed.
local function code(line)
  return (line:gsub("%-%-.*$", ""))
end

describe("design rules", function()
  local list = files()

  it("finds the apps to check", function()
    assert.is_true(#list > 5)
  end)

  for _, rule in ipairs(RULES) do
    it("no plugin uses " .. rule.pattern:gsub("%%", ""), function()
      local hits = {}
      for _, path in ipairs(list) do
        local n = 0
        for line in io.lines(path) do
          n = n + 1
          if code(line):find(rule.pattern) then hits[#hits + 1] = path .. ":" .. n end
        end
      end
      assert(#hits == 0, "use " .. rule.use .. " instead, at:\n  " .. table.concat(hits, "\n  "))
    end)
  end
end)

describe("the plugin template", function()
  local menuhub = require("lib.menuhub")
  local plugin

  before_each(function()
    package.loaded["templates.plugin.init"] = nil
    plugin = require("templates.plugin.init")
  end)

  after_each(function() plugin.dispose() end)

  it("loads as a plugin with a tile built from ui.menu rows", function()
    local entry = plugin.tile._e
    local rows = menuhub.items(entry.menu())
    local kinds = {}
    for _, r in ipairs(rows) do kinds[#kinds + 1] = r.kind end
    assert.same({ "switch", "info", "sep", "act", "act" }, kinds)
  end)

  it("says hello through the shared toast", function()
    plugin.hello()
    assert.equals(1, plugin.count)
  end)

  it("goes away completely when switched off", function()
    plugin.busy()
    local before = #menuhub.entries
    plugin.dispose()
    assert.equals(before - 1, #menuhub.entries)
  end)
end)
