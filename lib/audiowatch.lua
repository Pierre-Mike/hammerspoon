-- One hs.audiodevice.watcher for every app.
--
-- hs.audiodevice.watcher holds a single callback: a second setCallback silently
-- replaces the first, so a later app would unhook dictation's mic-list refresh
-- and "selected mic disconnected" warning. Apps register here instead and each
-- gets every event.

local M = { handlers = {}, order = {} }

-- Pure: call every handler with the event, in registration order. A handler
-- that errors is reported through `onError` and does not stop the others.
function M.dispatch(handlers, order, event, onError)
  for _, name in ipairs(order) do
    local fn = handlers[name]
    if fn then
      local ok, err = pcall(fn, event)
      if not ok and onError then onError(name, err) end
    end
  end
end

local function fire(event)
  M.dispatch(M.handlers, M.order, event, function(name, err)
    print(string.format("[audiowatch] %s failed on %s: %s", name, tostring(event), tostring(err)))
  end)
end

-- Register (or replace) the handler for `name`; starts the watcher on first use.
function M.on(name, fn)
  if not M.handlers[name] then M.order[#M.order + 1] = name end
  M.handlers[name] = fn
  if not M.started then
    hs.audiodevice.watcher.setCallback(fire)
    hs.audiodevice.watcher.start()
    M.started = true
  end
end

-- Forget `name`. What makes a plugin switchable: a registry with no way out
-- means a disposed plugin keeps being told about every device change, and keeps
-- answering as if it were still running.
--
-- The system watcher stops once nothing is listening, so a config with every
-- audio-aware plugin switched off is not still being woken. A later on() starts
-- it again.
function M.off(name)
  if not M.handlers[name] then return end
  M.handlers[name] = nil
  for i, n in ipairs(M.order) do
    if n == name then table.remove(M.order, i); break end
  end
  if M.started and next(M.handlers) == nil then
    M.started = nil
    -- pcall'd: the handler list is already empty either way, so a build (or a
    -- test stub) without stop must not turn an unsubscribe into an error.
    pcall(function() hs.audiodevice.watcher.stop() end)
  end
end

return M
