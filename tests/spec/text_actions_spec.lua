-- lib/text_actions holds the rewrite presets, merges the user's own over them,
-- builds the claude -p command line and judges its reply. Pure: the plugin runs
-- the process and decodes the JSON.
local ta = require("lib.text_actions")

local function ids(presets)
  local out = {}
  for _, p in ipairs(presets) do out[#out + 1] = p.id end
  return table.concat(out, ",")
end

describe("text_actions.config", function()
  it("is the built-ins when there is no user file", function()
    local cfg = ta.config(nil)
    assert.equals("cleanup,simplify,improve,formal,bullets,shorten", ids(cfg.presets))
    assert.equals(ta.MODEL, cfg.model)
    assert.equals(ta.CLAUDE, cfg.claude)
    assert.equals(0, #cfg.warnings)
  end)

  it("does not let a caller's edit leak into the built-ins", function()
    local cfg = ta.config(nil)
    cfg.presets[1].prompt = "changed"
    assert.are_not.equal("changed", ta.config(nil).presets[1].prompt)
  end)

  it("overrides a built-in's fields by id", function()
    local cfg = ta.config({ { id = "simplify", prompt = "My own words.", model = "claude-sonnet-5-5" } })
    local p = ta.find(cfg.presets, "simplify")
    assert.equals("My own words.", p.prompt)
    assert.equals("claude-sonnet-5-5", p.model)
    assert.equals("Simplify", p.label)              -- untouched fields stay
  end)

  it("adds a new preset after the built-ins, labelled by id when no label", function()
    local cfg = ta.config({ { id = "commit", prompt = "Write a commit message." } })
    assert.equals("cleanup,simplify,improve,formal,bullets,shorten,commit", ids(cfg.presets))
    assert.equals("commit", ta.find(cfg.presets, "commit").label)
  end)

  it("hides a preset switched off with enabled = false", function()
    local cfg = ta.config({ { id = "formal", enabled = false } })
    assert.is_nil(ta.find(cfg.presets, "formal"))
  end)

  it("accepts the object form with a global model and claude path", function()
    local cfg = ta.config({ model = "claude-sonnet-5-5", claude = "/opt/claude",
                            presets = { { id = "x", label = "X", prompt = "p" } } })
    assert.equals("claude-sonnet-5-5", cfg.model)
    assert.equals("/opt/claude", cfg.claude)
    assert.is_truthy(ta.find(cfg.presets, "x"))
  end)

  -- A broken entry costs that entry, never the plugin.
  it("skips invalid entries and says why", function()
    local cfg = ta.config({
      { prompt = "no id" },
      { id = "bad id!", prompt = "p" },
      { id = "new" },                                  -- new preset, no prompt
      { id = "simplify", maxGrowth = "lots" },         -- wrong type
      "not a table",
    })
    assert.equals("cleanup,simplify,improve,formal,bullets,shorten", ids(cfg.presets))
    assert.equals(5, #cfg.warnings)
    assert.equals(1.5, ta.find(cfg.presets, "simplify").maxGrowth)
  end)

  it("falls back to the built-ins when the file is not a list or object", function()
    local cfg = ta.config("garbage")
    assert.equals(6, #cfg.presets)
    assert.equals(1, #cfg.warnings)
  end)
end)

describe("text_actions.argv", function()
  local cfg = ta.config(nil)

  it("runs claude headless, with no tools, no settings and no session", function()
    local a = ta.argv(ta.find(cfg.presets, "simplify"), cfg)
    local s = table.concat(a, " ")
    assert.equals("-p", a[1])
    for _, flag in ipairs({ "--safe-mode", "--strict-mcp-config", "--no-session-persistence" }) do
      assert.is_truthy(s:find(flag, 1, true), flag)
    end
    local function after(flag)
      for i, v in ipairs(a) do if v == flag then return a[i + 1] end end
    end
    assert.equals("", after("--tools"))
    assert.equals("", after("--setting-sources"))
    assert.equals("json", after("--output-format"))
    assert.equals(ta.MODEL, after("--model"))
    assert.is_truthy(after("--system-prompt"):find("plainer words", 1, true))
    assert.equals(tostring(ta.BUDGET), after("--max-budget-usd"))
  end)

  -- The text to rewrite goes in on stdin. Nothing the user selected can reach
  -- the argument list, so nothing in it can change the command.
  it("never carries the text itself", function()
    local a = ta.argv(ta.find(cfg.presets, "cleanup"), cfg)
    for _, v in ipairs(a) do assert.is_nil(v:find("SECRET", 1, true)) end
  end)

  it("prefers the preset's model, then the file's, then the default", function()
    local c2 = ta.config({ model = "global-m", presets = { { id = "improve", model = "preset-m" } } })
    local function model(id)
      local a = ta.argv(ta.find(c2.presets, id), c2)
      for i, v in ipairs(a) do if v == "--model" then return a[i + 1] end end
    end
    assert.equals("preset-m", model("improve"))
    assert.equals("global-m", model("formal"))
  end)
end)

describe("text_actions.shellArgv", function()
  -- Paths are positional parameters, so a quote in one cannot become shell code.
  it("redirects the input file into claude without splicing paths into the script", function()
    local a = ta.shellArgv("/x/claude", "/tmp/in'put", { "-p", "ask" })
    assert.same({ "-c", ta.STDIN_SCRIPT, "sh", "/tmp/in'put", "/x/claude", "-p", "ask" }, a)
    assert.is_nil(ta.STDIN_SCRIPT:find("/tmp", 1, true))
  end)

  it("really feeds the file to the command's stdin", function()
    local path = os.tmpname()
    local f = assert(io.open(path, "w")); f:write("hello stdin"); f:close()
    local a = ta.shellArgv("/bin/cat", path, {})
    local cmd = "/bin/sh"
    for _, v in ipairs(a) do cmd = cmd .. " '" .. v:gsub("'", "'\\''") .. "'" end
    local p = io.popen(cmd); local out = p:read("*a"); p:close()
    os.remove(path)
    assert.equals("hello stdin", out)
  end)
end)

describe("text_actions.parse", function()
  local cfg = ta.config(nil)
  local simplify = ta.find(cfg.presets, "simplify")
  local function reply(result, extra)
    local r = { type = "result", subtype = "success", is_error = false, result = result }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
  end

  it("returns the rewritten text, trimmed", function()
    assert.equals("Move it to Thursday.",
      ta.parse(reply("\nMove it to Thursday.\n"), "so um move the meeting to like thursday", simplify))
  end)

  it("drops a <think> block before the answer", function()
    assert.equals("Done.", ta.parse(reply("<think>hmm</think>\nDone."), "done done", simplify))
  end)

  it("reports claude's own error, such as a lost login", function()
    local out, why = ta.parse(reply("Not logged in · Please run /login", { is_error = true }), "hi", simplify)
    assert.is_nil(out)
    assert.is_truthy(why:find("Not logged in", 1, true))
  end)

  it("rejects an empty or malformed reply", function()
    assert.is_nil(ta.parse(reply("   "), "hello", simplify))
    assert.is_nil(ta.parse({}, "hello", simplify))
    assert.is_nil(ta.parse(nil, "hello", simplify))
  end)

  -- A model that answers the text instead of rewriting it writes far more than
  -- it was given. That is not a rewrite, so the caller keeps the original.
  it("rejects a reply far longer than the preset allows", function()
    local out, why = ta.parse(reply(string.rep("word ", 80)), "what is the capital of France", simplify)
    assert.is_nil(out)
    assert.is_truthy(why:find("longer", 1, true))
  end)

  it("lets a preset that expands text grow further", function()
    local bullets = ta.find(cfg.presets, "bullets")
    local orig = string.rep("x", 100)
    assert.is_truthy(ta.parse(reply(string.rep("y", 230)), orig, bullets))
    assert.is_nil(ta.parse(reply(string.rep("y", 230)), orig, simplify))
  end)
end)

describe("text_actions.barItems", function()
  it("is the first nine presets, numbered for the ⌥ keys", function()
    local list = {}
    for i = 1, 12 do list[i] = { id = "p" .. i, label = "P" .. i } end
    local items = ta.barItems(list)
    assert.equals(9, #items)
    assert.equals(1, items[1].key)
    assert.equals("p9", items[9].id)
  end)
end)
