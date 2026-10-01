-- Minimal hs.* stub for running tests outside Hammerspoon.
-- Extend as needed when testing modules that use hs.canvas, hs.task, etc.

local hs = {}

-- doAfter/doEvery hand back a handle whose .start IS the callback, so a spec
-- fires the timer by calling it. Nothing runs on its own: a test that wants a
-- tick says so.
hs.timer = {
  secondsSinceEpoch = function() return os.time() end,
  doAfter = function(_, fn) return { start = fn, stop = function() end } end,
  doEvery = function(_, fn) return { start = fn, stop = function() end, fn = fn } end,
  new = function(_, fn) return { start = function() end, stop = function() end, fn = fn } end,
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
}

-- Real macOS virtual keycodes for the letters apps/dictation chords on
-- (Fn+C cancel, Fn+A → Orchestrator, Fn+P → firstmate).
hs.keycodes = { map = { a = 0, c = 8, p = 35 } }

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
-- getByName / soundFromFile so they can capture the call and assert on it.
hs.sound = {
  getByName = function(_)
    local s = {}
    s.volume = function(self, _) return self end
    s.play   = function(self)    return self end
    return s
  end,
  soundFromFile = function(_)
    local s = {}
    s.volume = function(self, _) return self end
    s.play   = function(self)    return self end
    return s
  end,
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

hs.execute = function(_) return "", true, "exit", 0 end
hs.json = { decode = function(s) return {} end, encode = function(_) return "{}" end }
hs.notify = { new = function(_) return { send = function() end } end }
hs.processInfo = { processID = 4242 }

-- Inject into globals so `require("hs.ipc")` etc. resolve without error.
hs.ipc = {}

return hs
