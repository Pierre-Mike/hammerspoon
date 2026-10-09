-- Minimal hs.* stub for running tests outside Hammerspoon.
-- Extend as needed when testing modules that use hs.canvas, hs.task, etc.

local hs = {}

-- doAfter/doEvery hand back a handle whose .start IS the callback, so a spec
-- fires the timer by calling it. Nothing runs on its own: a test that wants a
-- tick says so.
hs.timer = {
  _every = {},
  secondsSinceEpoch = function() return os.time() end,
  doAfter = function(_, fn) return { start = fn, stop = function() end } end,
  -- Repeating timers are also pushed onto hs.timer._every, so a spec can drive
  -- a loop whose handle the module kept to itself: call _every[n].fn() once per
  -- tick you want to happen.
  doEvery = function(_, fn)
    local t = { start = fn, stop = function() end, fn = fn }
    hs.timer._every[#hs.timer._every + 1] = t
    return t
  end,
  new = function(_, fn) return { start = function() end, stop = function() end, fn = fn } end,
  -- Same handle shape as doEvery: a spec fires the daily job by calling .fn.
  doAt = function(_, _, fn) return { start = fn, stop = function() end, fn = fn } end,
}

hs.hotkey = {
  bind = function(_, _, pressed)
    return { delete = function() end, enable = function(s) return s end,
             disable = function(s) return s end, fn = pressed }
  end,
}
hs.hotkey.new = hs.hotkey.bind

hs.pasteboard = {
  _contents = "",
  setContents = function(_, s) hs.pasteboard._contents = s end,
  getContents = function(_) return hs.pasteboard._contents end,
}

hs.eventtap = {
  new = function(_, _) return { start = function() end, stop = function() end } end,
  event = { types = { flagsChanged = 1, keyDown = 2, systemDefined = 3 } },
  -- Every synthetic keystroke lands here in order instead of going to the
  -- window server, so a spec can read back exactly what a module tried to type.
  -- Specs that care clear it first; the paste path only needs the call not to
  -- fail, and ignores it.
  _sent = {},
}

function hs.eventtap.keyStroke(mods, key, delay)
  hs.eventtap._sent[#hs.eventtap._sent + 1] =
    { kind = "key", mods = mods, key = key, delay = delay }
end

-- Nothing is physically held in a test, so a module waiting for the user's
-- hand to come off the keys proceeds at once.
function hs.eventtap.checkKeyboardModifiers() return {} end

-- A key event carrying a unicode string. The stub keeps the setters chainable
-- and only records on post(), because an event that is built and never posted
-- is not a keystroke.
-- Hammerspoon accepts both newKeyEvent(keycode, isdown) and the longer
-- newKeyEvent(mods, key, isdown), and keystroke_typer uses each for a different
-- job: the short form to carry a unicode string, the long form to ask the
-- layout what a key gives under Shift. The stub takes both.
function hs.eventtap.event.newKeyEvent(a, b, c)
  local mods, keycode, isdown
  if type(a) == "table" then mods, keycode, isdown = a, b, c
  else mods, keycode, isdown = {}, a, b end
  if type(keycode) == "string" then keycode = hs.keycodes.map[keycode] end

  local shift = false
  for _, m in ipairs(mods) do if m == "shift" then shift = true end end

  local e = { keycode = keycode, isdown = isdown, mods = mods }
  function e:setFlags(f) self.flags = f; return self end
  function e:setUnicodeString(s) self.unicode = s; return self end
  -- The layout's answer, which is what the real one returns for an event that
  -- was built and never posted.
  function e:getCharacters(_) return hs.keycodes.charFor(keycode, shift) end
  function e:post()
    hs.eventtap._sent[#hs.eventtap._sent + 1] =
      { kind = "text", down = self.isdown, text = self.unicode,
        flags = self.flags, keycode = self.keycode }
    return self
  end
  return e
end

-- Images resolve to an opaque handle: specs only ever pass it back to a menubar
-- stub, so the identity is all that matters.
hs.image = {
  imageFromName = function(name) return { _name = name } end,
  imageFromPath = function(path) return { _path = path } end,
}

-- A real US keyboard's virtual keycodes, in hs.keycodes.map's shape: the name
-- to its keycode and the keycode back to the name. The whole layout rather than
-- the few keys apps/dictation chords on, because apps/keystroke_typer resolves
-- every character it types through this table, and a stub with three keys in it
-- would let a typer that cannot spell "hello" pass.
hs.keycodes = { map = {} }
for name, code in pairs({
  a = 0,  s = 1,  d = 2,  f = 3,  h = 4,  g = 5,  z = 6,  x = 7,  c = 8,  v = 9,
  b = 11, q = 12, w = 13, e = 14, r = 15, y = 16, t = 17,
  ["1"] = 18, ["2"] = 19, ["3"] = 20, ["4"] = 21, ["6"] = 22, ["5"] = 23,
  ["="] = 24, ["9"] = 25, ["7"] = 26, ["-"] = 27, ["8"] = 28, ["0"] = 29,
  ["]"] = 30, o = 31, u = 32, ["["] = 33, i = 34, p = 35,
  ["return"] = 36, l = 37, j = 38, ["'"] = 39, k = 40, [";"] = 41,
  ["\\"] = 42, [","] = 43, ["/"] = 44, n = 45, m = 46, ["."] = 47,
  tab = 48, space = 49, ["`"] = 50, delete = 51, escape = 53,
}) do
  hs.keycodes.map[name] = code
  hs.keycodes.map[code] = name
end

-- What each key gives with Shift held on that same US keyboard. The mock models
-- this because the module asks the layout rather than assuming it, and a stub
-- that answered nothing would silently exercise only the fallback path.
hs.keycodes._shift = {
  ["1"] = "!", ["2"] = "@", ["3"] = "#", ["4"] = "$", ["5"] = "%",
  ["6"] = "^", ["7"] = "&", ["8"] = "*", ["9"] = "(", ["0"] = ")",
  ["-"] = "_", ["="] = "+", ["["] = "{", ["]"] = "}", ["\\"] = "|",
  [";"] = ":", ["'"] = '"', [","] = "<", ["."] = ">", ["/"] = "?", ["`"] = "~",
}

-- The character a keycode produces, given the modifiers held. Shared by the
-- newKeyEvent stub below and by any spec that wants to read back what a client
-- translating by keycode alone would have received.
function hs.keycodes.charFor(code, shift)
  local name = hs.keycodes.map[code]
  if type(name) ~= "string" or #name ~= 1 then return nil end
  if not shift then return name end
  return hs.keycodes._shift[name] or name:upper()
end

hs.screen = {
  mainScreen = function()
    return {
      frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end,
    }
  end,
}

hs.canvas = {
  new = function(_, _)
    local c = {}
    c.behavior = function(_, _) return c end
    c.level = function(_, _) return c end
    c.appendElements = function(_, ...) return c end
    c.replaceElements = function(_, ...) return c end
    c.show = function(_) return c end
    c.delete = function(_) end
    c.frame = function(_, f) if f then c._frame = f end; return c._frame or {} end
    return c
  end,
  windowLevels = { overlay = 25 },
}

hs.menubar = {
  new = function()
    return {
      setTitle = function() end, setMenu = function() end, setIcon = function() end,
      setClickCallback = function() end, setTooltip = function() end,
      delete = function() end,
    }
  end,
}

hs.task = {
  new = function(_, cb, args)
    return {
      start = function() end,
      terminate = function() end,
      setEnvironment = function() end,
      _cb = cb, _args = args,
    }
  end,
}

hs.http = {
  asyncPost = function(_, _, _, cb) if cb then cb(200, "", {}) end end,
  asyncGet  = function(_, _, cb)   if cb then cb(200, "", {}) end end,
}

-- An intake a spec can post to: hs.httpserver._servers collects every one
-- built, so a test calls .callback(method, headers, path, body) to stand in for
-- a request and reads .running to see whether the port was given back.
hs.httpserver = {
  _servers = {},
  new = function()
    local s = { running = false, port = nil, callback = nil }
    s.setPort     = function(self, p)  self.port = p;      return self end
    s.setCallback = function(self, fn) self.callback = fn; return self end
    s.start       = function(self) self.running = true;  return self end
    s.stop        = function(self) self.running = false; return self end
    hs.httpserver._servers[#hs.httpserver._servers + 1] = s
    return s
  end,
}

hs.pathwatcher = {
  new = function(path, fn)
    return { start = function(s) return s end, stop = function(s) return s end,
             path = path, fn = fn }
  end,
}

-- A socket that records what was sent and never connects on its own: a spec
-- opens it by calling .fn("open"), the way the real one calls back.
hs.websocket = {
  _sockets = {},
  new = function(url, fn)
    local s = { url = url, fn = fn, sent = {}, state = "connecting" }
    s.send   = function(self, msg) self.sent[#self.sent + 1] = msg; return self end
    s.close  = function(self) self.state = "closed"; return self end
    s.status = function(self) return self.state end
    hs.websocket._sockets[#hs.websocket._sockets + 1] = s
    return s
  end,
}

hs.alert = { show = function(_, _) end }

hs.styledtext = {
  new = function(text, _)
    local s = { _text = text }
    s.setStyle = function(self, _, _, _) return self end
    return s
  end,
}

hs.urlevent = {
  bind = function(_, _) end,
  openURL = function(_) end,
}

-- hs.sound stub. Tests that care about earcon playback substitute their own
-- getByName / getByFile so they can capture the call and assert on it.
-- stop() is here because lib/context stops a sound on teardown: a looping WAV
-- that outlives its plugin is the thing that wrapper exists to prevent.
local function fakeSound()
  local s = { playing = false }
  s.volume    = function(self, _) return self end
  s.play      = function(self) self.playing = true;  return self end
  s.stop      = function(self) self.playing = false; return self end
  s.loopSound = function(self, _) return self end
  return s
end

hs.sound = {
  getByName     = function(_) return fakeSound() end,
  getByFile     = function(_) return fakeSound() end,
  soundFromFile = function(_) return fakeSound() end,
}

-- Settings live in memory for the run. A spec that cares seeds hs.settings._v
-- directly rather than going through set().
hs.settings = {
  _v = {},
  get = function(k) return hs.settings._v[k] end,
  set = function(k, v) hs.settings._v[k] = v end,
  clear = function(k) hs.settings._v[k] = nil end,
}

-- A fake tree: hs.fs._tree maps a directory to its entries, and anything listed
-- as a path in hs.fs._files answers attributes(). Specs that walk apps/ set both.
hs.fs = {
  _tree = {},
  _files = {},
  -- Two return values, and an iterator that genuinely needs the second, because
  -- the real hs.fs.dir works that way: a caller that keeps only the function
  -- gets a stateless iterator and fails. A mock that closed over its own index
  -- hid exactly that bug.
  dir = function(path)
    local entries = hs.fs._tree[path]
    if not entries then error("no such directory: " .. tostring(path)) end
    return function(state)
      state.i = state.i + 1
      return state.entries[state.i]
    end, { i = 0, entries = entries }
  end,
  attributes = function(path) return hs.fs._files[path] or nil end,
}

hs.configdir = "/fake/.hammerspoon"

-- A 32 GB Mac with about half of it in use, in hs.host.vmStat's own shape, so
-- lib/lmstudio's memory join has something plausible to divide.
hs.host = {
  vmStat = function()
    return { memSize = 34359738368, pageSize = 16384,
             anonymousPages = 600000, pagesPurgeable = 20000,
             pagesWiredDown = 200000, pagesUsedByVMCompressor = 100000 }
  end,
}

hs.execute = function(_) return "", true, "exit", 0 end
hs.json = { decode = function(s) return {} end, encode = function(_) return "{}" end }
hs.notify = { new = function(_) return { send = function() end } end }
hs.processInfo = { processID = 4242 }

-- Inject into globals so `require("hs.ipc")` etc. resolve without error.
hs.ipc = {}

return hs
