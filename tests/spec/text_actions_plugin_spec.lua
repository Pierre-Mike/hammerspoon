-- apps/text_actions driven through its public surface: run() spawns claude -p
-- with the text on stdin, the bar delivers what the user picks, a bar holding
-- text that is nowhere else never drops it, and dispose takes everything back.

_G.hs = require("hs")

package.loaded["lib.menuhub"] = {
  item = function(_)
    return { setTitle = function() end, setMenu = function() end, delete = function() end }
  end,
}

local CLAUDE = (os.getenv("HOME") or "") .. "/.local/bin/claude"
hs.fs.attributes = function(p) if p == CLAUDE then return { mode = "file" } end end

-- One-shot timers that only fire when the spec says so.
local after
hs.timer.doAfter = function(delay, fn)
  local t = { delay = delay, fn = fn, stopped = false }
  t.stop = function(self) self.stopped = true end
  after[#after + 1] = t
  return t
end
local function fire(delay)
  for _, t in ipairs(after) do
    if (delay == nil or t.delay == delay) and not t.stopped and not t.fired then t.fired = true; t.fn() end
  end
end

-- claude processes: the spec answers them by calling .finish(stdout).
local tasks
hs.task.new = function(path, cb, args)
  local t = { path = path, cb = cb, args = args, terminated = false }
  -- What claude would read on stdin: the file /bin/sh redirects from.
  function t:start()
    self.started = true
    self.inputPath = args[4]
    local f = io.open(args[4], "r")
    if f then self.input = f:read("*a"); f:close() end
    return self
  end
  function t:setWorkingDirectory(d) self.cwd = d; return self end
  function t:terminate() self.terminated = true; return self end
  function t.finish(out) cb(0, out, "") end
  tasks[#tasks + 1] = t
  return t
end

-- JSON: bodies are keys into this table.
local JSON = {}
hs.json = {
  encode = function(_) return "{}" end,
  decode = function(s) if JSON[s] == nil then error("bad json") end; return JSON[s] end,
}
JSON.ok = { type = "result", subtype = "success", is_error = false, result = "Short and plain.",
            total_cost_usd = 0.0004 }
JSON.err = { type = "result", subtype = "success", is_error = true, result = "Not logged in" }

local pb = { text = "", count = 1 }
hs.pasteboard.getContents = function() return pb.text end
hs.pasteboard.setContents = function(s) pb.text = s; pb.count = pb.count + 1 end
hs.pasteboard.changeCount = function() return pb.count end

-- Hotkeys by "mods+key", so a spec can press one.
local keys
hs.hotkey.bind = function(mods, key, pressed)
  local h = { mods = mods, key = key, fn = pressed, deleted = false }
  function h:delete() self.deleted = true end
  function h:enable() return self end
  function h:disable() return self end
  keys[#keys + 1] = h
  return h
end
local function press(mods, key)
  for i = #keys, 1, -1 do
    local h = keys[i]
    if not h.deleted and h.key == key and table.concat(h.mods, "+") == mods then return h.fn() end
  end
  error("no live hotkey " .. mods .. "+" .. key)
end
local function live(key)
  for _, h in ipairs(keys) do if not h.deleted and h.key == key then return true end end
  return false
end

-- Canvases that remember their mouse callback and whether they are gone.
local canvases
hs.canvas.new = function(frame)
  local c = { frame_ = frame, deleted = false }
  for _, m in ipairs({ "behavior", "level", "show", "clickActivating", "canvasMouseEvents" }) do
    c[m] = function(self, v) if m == "clickActivating" then self.activating = v end; return self end
  end
  function c:frame(f) if f then self.frame_ = f end; return self.frame_ end
  function c:replaceElements(...) self.elements = { ... }; return self end
  function c:mouseCallback(fn) self.mouse = fn; return self end
  function c:delete() self.deleted = true end
  canvases[#canvases + 1] = c
  return c
end

local plugins = require("lib.plugins")
local typed
local fakeTyper = { type = function(text) typed[#typed + 1] = text end,
                    pending = function() return 0 end, cancel = function() end }

local ta
local function load()
  -- The last test's instance goes first, so a rewrite it left running does not
  -- leave its temp file behind.
  if ta then ta.dispose() end
  after, tasks, keys, canvases, typed = {}, {}, {}, {}, {}
  hs.eventtap._sent = {}
  pb.text, pb.count = "user clipboard", 1
  package.loaded["apps.text_actions.init"] = nil
  plugins.loaded["keystroke_typer"] = fakeTyper
  ta = require("apps.text_actions.init")
end

local function arg(t, flag)
  for i, v in ipairs(t.args) do if v == flag then return t.args[i + 1] end end
end

describe("run", function()
  before_each(load)

  it("pipes the text into claude -p and hands back the rewrite", function()
    local got
    ta.run("so um basically move it", "simplify", function(r) got = r end)
    local t = tasks[1]
    assert.equals("/bin/sh", t.path)
    assert.equals(CLAUDE, t.args[5])
    assert.is_true(t.started)
    assert.equals("so um basically move it", t.input)
    assert.equals("claude-haiku-5-5", arg(t, "--model"))
    for _, v in ipairs(t.args) do assert.is_nil(v:find("basically", 1, true)) end
    t.finish("ok")
    assert.equals("Short and plain.", got)
    -- The temp file holding the text does not outlive the call.
    assert.is_nil(io.open(t.inputPath, "r"))
  end)

  it("removes the temp file when the call is cancelled", function()
    local cancel = ta.run("private words", "improve", function() end)
    local path = tasks[1].inputPath
    cancel()
    assert.is_nil(io.open(path, "r"))
    assert.is_true(tasks[1].terminated)
  end)

  it("reports claude's own error and keeps nothing", function()
    local got, why = "unset", nil
    ta.run("hello there", "improve", function(r, w) got, why = r, w end)
    tasks[1].finish("err")
    assert.is_nil(got)
    assert.is_truthy(why:find("Not logged in", 1, true))
  end)

  it("gives up after the timeout, kills claude and ignores a late reply", function()
    local calls, got = 0, "unset"
    ta.run("hello there", "improve", function(r) calls = calls + 1; got = r end, { timeout = 10 })
    fire(10)
    assert.equals(1, calls)
    assert.is_nil(got)
    assert.is_true(tasks[1].terminated)
    tasks[1].finish("ok")
    assert.equals(1, calls)
  end)

  it("refuses an unknown preset or empty text without spawning anything", function()
    local why1, why2
    ta.run("text", "nope", function(_, w) why1 = w end)
    ta.run("   ", "simplify", function(_, w) why2 = w end)
    assert.is_truthy(why1:find("unknown", 1, true))
    assert.is_truthy(why2:find("nothing", 1, true))
    assert.equals(0, #tasks)
  end)
end)

describe("the bar", function()
  before_each(load)

  it("never takes focus, and ⌥2 runs the second preset onto the clipboard", function()
    local result
    ta.showBar("so um move it", { onResult = function(r) result = r end })
    assert.is_false(canvases[1].activating)
    press("alt", "2")
    assert.equals("so um move it", tasks[1].input)
    assert.truthy(arg(tasks[1], "--system-prompt"):find("plainer", 1, true))
    tasks[1].finish("ok")
    assert.equals("Short and plain.", pb.text)
    assert.equals("Short and plain.", result)
    fire(ta.DONE_SECONDS)
    assert.is_nil(ta.bar)
    assert.is_true(canvases[1].deleted)
    assert.is_false(live("2"))
    assert.is_false(live("escape"))
  end)

  it("runs a preset from a click", function()
    ta.showBar("so um move it")
    canvases[1].mouse(canvases[1], "mouseDown", "btn:bullets")
    assert.equals(1, #tasks)
    assert.truthy(arg(tasks[1], "--system-prompt"):find("bullet", 1, true))
  end)

  it("closes untouched after its countdown, leaving the clipboard alone", function()
    ta.showBar("words")
    fire(ta.BAR_SECONDS)
    assert.is_nil(ta.bar)
    assert.equals("user clipboard", pb.text)
  end)

  it("holds the countdown while the pointer is over it", function()
    ta.showBar("words")
    canvases[1].mouse(canvases[1], "mouseEnter", "_canvas_")
    fire(ta.BAR_SECONDS)
    assert.is_truthy(ta.bar)
  end)

  it("types the result when asked to", function()
    ta.showBar("words", { deliver = "type" })
    press("alt", "1")
    tasks[1].finish("ok")
    assert.equals("Short and plain.", typed[1])
  end)

  it("says why when the rewrite fails and keeps the clipboard", function()
    ta.showBar("words")
    press("alt", "3")
    tasks[1].finish("err")
    assert.equals("failed", ta.bar.mode)
    assert.equals("user clipboard", pb.text)
  end)

  it("Esc closes it and kills a rewrite still running", function()
    ta.showBar("words")
    press("alt", "1")
    press("", "escape")
    assert.is_nil(ta.bar)
    assert.is_true(tasks[1].terminated)
  end)
end)

-- Dictation's Fn+R take: the transcript has not been typed anywhere yet, so the
-- bar is the only thing holding it.
describe("a bar holding text that is nowhere else", function()
  before_each(load)
  local function hold(onResult)
    ta.showBar("raw take", { deliver = "type", keep = "Type as is", fallback = true, onResult = onResult })
  end

  it("types it unchanged on ⌥0", function()
    hold()
    press("alt", "0")
    assert.equals("raw take", typed[1])
  end)

  it("types it unchanged when the countdown runs out", function()
    local got
    hold(function(r) got = r end)
    fire(ta.BAR_SECONDS)
    assert.equals("raw take", typed[1])
    assert.equals("raw take", got)
  end)

  it("types the original when the rewrite fails", function()
    hold()
    press("alt", "2")
    tasks[1].finish("err")
    assert.equals("raw take", typed[1])
  end)

  it("leaves it on the clipboard when dismissed", function()
    hold()
    ta.hideBar("new take")
    assert.equals(0, #typed)
    assert.equals("raw take", pb.text)
  end)
end)

describe("presets", function()
  before_each(load)

  it("lists the built-ins in bar order", function()
    local a = ta.actions()
    assert.equals("cleanup", a[1].id)
    assert.equals("Clean up", a[1].label)
  end)
end)

describe("dispose", function()
  before_each(load)

  it("takes back the bar, its keys, the hotkey and a running claude", function()
    ta.showBar("words")
    press("alt", "1")
    local path = tasks[1].inputPath
    ta.dispose()
    assert.is_true(canvases[1].deleted)
    assert.is_true(tasks[1].terminated)
    assert.is_nil(io.open(path, "r"))
    for _, h in ipairs(keys) do assert.is_true(h.deleted, h.key) end
  end)
end)
