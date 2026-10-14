local guard = require("lib.ipc_guard")

-- A registered `hs` client as hs.ipc keeps it: a remote port that is either
-- still there or belongs to a CLI that was killed mid-command.
local function client(valid)
  local c = { deleted = false, sent = {} }
  c._cli = { console = true, remote = {
    isValid = function() return valid end,
    delete = function() c.deleted = true end,
    sendMessage = function(_, msg)
      if not valid then error("ipc port is no longer valid (early)") end
      c.sent[#c.sent + 1] = msg
    end,
  } }
  return c
end

-- Stands in for hs.ipc's print replacement: console first, then every client.
local function fakeIpc(clients)
  local ipc = { __registeredCLIInstances = clients, insidePrintInstances = {} }
  local console = {}
  local env = { print = function(...)
    console[#console + 1] = table.concat({ ... }, "\t")
    for id, v in pairs(ipc.__registeredCLIInstances) do
      ipc.insidePrintInstances[id] = 1
      v._cli.remote:sendMessage(table.concat({ ... }, "\t") .. "\n")
      ipc.insidePrintInstances[id] = nil
    end
  end }
  return ipc, env, console
end

describe("ipc_guard", function()
  it("drops a killed hs client before it can make print throw", function()
    local dead, live = client(false), client(true)
    local ipc, env, console = fakeIpc({ dead = dead, live = live })
    guard.install(ipc, env)

    env.print("hello")

    assert.same({ "hello" }, console)
    assert.same({ "hello\n" }, live.sent)
    assert.is_nil(ipc.__registeredCLIInstances.dead)
    assert.is_true(dead.deleted)
  end)

  it("clears the recursion mark the dead client left behind", function()
    local ipc, env = fakeIpc({ dead = client(false) })
    ipc.insidePrintInstances.dead = 1
    guard.install(ipc, env)

    env.print("x")

    assert.is_nil(ipc.insidePrintInstances.dead)
  end)

  it("never lets a failing print escape to the caller", function()
    local ipc, env = fakeIpc({})
    env.print = function() error("stack overflow") end
    guard.install(ipc, env)

    assert.has_no.errors(function() env.print("x") end)
  end)

  it("keeps live clients registered", function()
    local live = client(true)
    local ipc, env = fakeIpc({ live = live })
    guard.install(ipc, env)

    env.print("a"); env.print("b")

    assert.equals(live, ipc.__registeredCLIInstances.live)
    assert.same({ "a\n", "b\n" }, live.sent)
  end)
end)
