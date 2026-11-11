_G.hs = require("hs")
local plugins = require("lib.plugins")
local menuhub = require("lib.menuhub")

describe("the claude chat plugin", function()
  local chat, p, task, realDecode, realAttrs

  before_each(function()
    hs.settings._v = {}
    hs.task._made = {}
    menuhub.widgets = {}
    realAttrs = hs.fs.attributes
    hs.fs.attributes = function(path) if path:match("/claude$") then return { mode = "file" } end end
    -- Each stdout line in these specs is a Lua table's key into this list.
    realDecode = hs.json.decode
    package.loaded["apps.claude_chat.init"] = nil
    local entry = require("apps.claude_chat.init")
    local manifest = assert(plugins.check("claude_chat", dofile("apps/claude_chat/plugin.lua")))
    chat, p = plugins.activate("claude_chat", entry, manifest)
    task = hs.task._made[#hs.task._made]
  end)

  after_each(function()
    hs.json.decode = realDecode
    hs.fs.attributes = realAttrs
    p.ctx:dispose()
  end)

  local function events(list)
    local lines = {}
    for i, ev in ipairs(list) do lines[i] = "ev" .. i end
    hs.json.decode = function(s) return list[tonumber(s:match("%d+"))] end
    task._stream(task, table.concat(lines, "\n") .. "\n", "")
  end

  local function console() return menuhub.glance(menuhub.widgets)[1] end

  it("starts claude warm at load, in the home folder, with a PATH", function()
    assert.is_true(task.running)
    assert.truthy(task._path:match("/claude$"))
    assert.equals(os.getenv("HOME"), task._dir)
    assert.truthy(task._env.PATH:find("/opt/homebrew/bin", 1, true))
    assert.equals("console", console().kind)
  end)

  it("writes a question to the running process and streams the answer back", function()
    console()
    menuhub.widgets[1].submit("What is 2+2?")
    assert.truthy(task._input[1]:find('"text":"What is 2+2?"', 1, true))
    assert.equals("Thinking…", console().status)
    events({
      { type = "system", subtype = "init", session_id = "s1" },
      { type = "stream_event", event = { type = "content_block_start", content_block = { type = "text" } } },
      { type = "stream_event", event = { type = "content_block_delta", delta = { type = "text_delta", text = "4" } } },
      { type = "result", session_id = "s1" },
    })
    local c = console()
    assert.same({ "you", "reply" }, { c.lines[1].who, c.lines[2].who })
    assert.equals("4", c.lines[2].text)
    assert.equals("Ready", c.status)
    assert.equals("s1", hs.settings.get("claude_chat.session"))
  end)

  it("resumes the saved session on the next start", function()
    hs.settings._v["claude_chat.session"] = "s9"
    chat.newChat()
    -- New chat forgets the session, so the fresh process starts clean.
    local args = table.concat(hs.task._made[#hs.task._made]._args, " ")
    assert.is_nil(args:find("--resume", 1, true))
    assert.is_false(task.running)
  end)

  it("starts a new session when claude dies, and ignores the one it stopped", function()
    hs.settings._v["claude_chat.session"] = "s1"
    task._cb(1, "", "No conversation found")
    local lines = console().lines
    assert.truthy(lines[#lines].text:find("starting a new session", 1, true))
    assert.is_nil(hs.settings.get("claude_chat.session"))
    chat.newChat()
    task._cb(143, "", "")   -- the old process, terminated on purpose
    assert.same({}, console().lines)
  end)

  it("switches model by restarting the process", function()
    p.settings.set("model", "haiku")
    local last = hs.task._made[#hs.task._made]
    assert.truthy(table.concat(last._args, " "):find("--model haiku", 1, true))
    assert.is_false(task.running)
  end)
end)
