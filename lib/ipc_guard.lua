-- hs.ipc swaps the global print for one that mirrors every line to each `hs`
-- client still registered. A client killed mid-command (`timeout … hs -c`)
-- stays registered until hs.ipc's own sweep, once a minute. Until then, sending
-- to it throws, the throw is logged, the log prints, and the print throws again
-- until the stack overflows. Every plugin that logs breaks, and a model switch
-- dies halfway, after it saves the new model but before it restarts the server.
--
-- install() wraps that print: the same pruning hs.ipc does every minute runs
-- before each line, and a print that still fails is swallowed rather than
-- unwinding whatever plugin code called it.
local M = {}

local function prune(ipc)
  for id, v in pairs(ipc.__registeredCLIInstances or {}) do
    local remote = v._cli and v._cli.remote
    if not (remote and remote:isValid()) then
      if remote then pcall(remote.delete, remote) end
      ipc.__registeredCLIInstances[id] = nil
      if ipc.insidePrintInstances then ipc.insidePrintInstances[id] = nil end
    end
  end
end

function M.install(ipc, env)
  env = env or _G
  local ipcPrint = env.print
  env.print = function(...)
    prune(ipc)
    pcall(ipcPrint, ...)
  end
end

return M
