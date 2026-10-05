local D = require("lib.dsh")

describe("dsh.args", function()
  it("puts the launcher's own flags first", function()
    -- `dsh` hands everything after the first token it does not recognize to the
    -- booted app, so --profile leading is what makes --port reach the web app.
    assert.same({ "--profile", "web", "--no-open", "--port", "3080" },
                D.args("web", 3080))
  end)

  it("defaults to the web profile on the default port", function()
    assert.same({ "--profile", "web", "--no-open", "--port", "3080" }, D.args())
  end)

  it("takes another profile and port", function()
    assert.same({ "--profile", "tui", "--no-open", "--port", "8080" },
                D.args("tui", 8080))
  end)
end)

describe("dsh.parseUrl", function()
  it("reads the address the server announces", function()
    assert.equals("http://127.0.0.1:3080",
                  D.parseUrl("dsh web: http://127.0.0.1:3080\n"))
  end)

  it("reads it out of a mid-stream slice", function()
    assert.equals("http://127.0.0.1:3081",
                  D.parseUrl("boot ok\ndsh web: http://127.0.0.1:3081\nready\n"))
  end)

  it("keeps a path but drops sentence punctuation", function()
    assert.equals("http://localhost:3080/app",
                  D.parseUrl("open http://localhost:3080/app."))
  end)

  it("returns nil when there is no address", function()
    assert.is_nil(D.parseUrl("loading profile web\n"))
    assert.is_nil(D.parseUrl(nil))
  end)
end)

describe("dsh.killCmd", function()
  local cmd = D.killCmd(3080, 4242)

  it("only kills listeners", function()
    -- Without -sTCP:LISTEN this also matches sockets whose *remote* port is
    -- 3080 — including the one Hammerspoon holds while polling the server.
    assert.truthy(cmd:find("-sTCP:LISTEN", 1, true))
  end)

  it("never kills Hammerspoon itself", function()
    assert.truthy(cmd:find("grep -vx 4242", 1, true))
  end)

  it("waits for the shutdown before the port is reused", function()
    assert.truthy(cmd:find("sleep", 1, true))
  end)

  it("succeeds when nothing is listening", function()
    assert.truthy(cmd:find("; true", 1, true))
  end)
end)

describe("dsh.url", function()
  it("prefers the address the server reported", function()
    assert.equals("http://127.0.0.1:3081",
                  D.url({ url = "http://127.0.0.1:3081", port = 3080 }))
  end)

  it("falls back to where the server was told to bind", function()
    assert.equals("http://127.0.0.1:3080", D.url({ host = "127.0.0.1", port = 3080 }))
  end)

  it("has a default to offer before anything has run", function()
    assert.equals("http://127.0.0.1:3080", D.url())
    assert.equals("http://127.0.0.1:3080", D.url({ url = "" }))
  end)
end)

describe("dsh.title", function()
  it("marks the server off", function()
    assert.equals("🐋💤", D.title({ running = false }))
  end)

  it("marks the server up", function()
    assert.equals("🐋", D.title({ running = true }))
  end)

  it("shows work in progress over either state", function()
    assert.equals("🐋⏳", D.title({ running = true, busy = "Restarting the server…" }))
  end)
end)

describe("dsh.tooltip", function()
  it("says where it is serving", function()
    assert.equals("Serving http://127.0.0.1:3080",
                  D.tooltip({ running = true, url = "http://127.0.0.1:3080" }))
  end)

  it("says when it is off", function()
    assert.equals("Server off", D.tooltip({ running = false }))
  end)

  it("says what it is doing while busy", function()
    assert.equals("Starting the server…",
                  D.tooltip({ running = false, busy = "Starting the server…" }))
  end)
end)

describe("dsh.detachCmd", function()
  local cmd = D.detachCmd("/opt/homebrew/bin/dsh", D.args("web", 3080), "/tmp/out.log")

  it("backgrounds the server so it outlives Hammerspoon", function()
    assert.truthy(cmd:find("^nohup "))
    assert.truthy(cmd:find("&$"))
  end)

  it("sends its output to the file, never back through a pipe", function()
    assert.truthy(cmd:find(">'/tmp/out.log' 2>&1 </dev/null", 1, true))
  end)

  it("quotes every word", function()
    assert.truthy(cmd:find("'/opt/homebrew/bin/dsh' '--profile' 'web'", 1, true))
    assert.truthy(D.detachCmd("/a b/it's", {}, "/o"):find([['/a b/it'\''s']], 1, true))
  end)
end)

describe("dsh.addressFrom", function()
  it("prefers the dsh web line over an earlier URL", function()
    assert.equals("http://127.0.0.1:3080/?token=abc",
                  D.addressFrom("see https://example.com/docs\ndsh web: http://127.0.0.1:3080/?token=abc\n"))
  end)

  it("falls back to any URL", function()
    assert.equals("http://127.0.0.1:3081", D.addressFrom("up at http://127.0.0.1:3081."))
  end)

  it("is nil for no file or no address", function()
    assert.is_nil(D.addressFrom(nil))
    assert.is_nil(D.addressFrom("booting\n"))
  end)
end)
