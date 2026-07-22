-- Minimal hs.* stub for running tests outside Hammerspoon.
-- Extend as needed when testing modules that use hs.canvas, hs.task, etc.

local hs = {}

hs.timer = {
  secondsSinceEpoch = function() return os.time() end,
  doAfter = function(_, fn) return { start = fn, stop = function() end } end,
  new = function(_, fn) return { start = function() end, stop = function() end, fn = fn } end,
}

hs.pasteboard = {
  _contents = "",
  setContents = function(_, s) hs.pasteboard._contents = s end,
  getContents = function(_) return hs.pasteboard._contents end,
}

hs.eventtap = {
  new = function(_, _) return { start = function() end, stop = function() end } end,
  event = { types = { flagsChanged = 1, keyDown = 2, systemDefined = 3 } },
}

hs.keycodes = { map = { c = 8, a = 0 } }

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
    return { setTitle = function() end, setMenu = function() end }
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

-- Inject into globals so `require("hs.ipc")` etc. resolve without error.
hs.ipc = {}

return hs
