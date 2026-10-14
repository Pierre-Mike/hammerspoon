local O = require("lib.ovis_ocr")

describe("ovis_ocr.base", function()
  it("defaults to loopback on 8797", function()
    assert.equals("http://127.0.0.1:8797", O.base())
  end)

  it("takes another port", function()
    assert.equals("http://127.0.0.1:9000", O.base(9000))
  end)
end)

describe("ovis_ocr.launchCmd", function()
  local cmd = O.launchCmd("/py", "/srv/server.py", "/tmp/log")

  it("execs, so terminate() reaches Python and not just the shell", function()
    assert.truthy(cmd:find("^exec "))
  end)

  it("appends the server's output to its log", function()
    assert.truthy(cmd:find(">> '/tmp/log' 2>&1", 1, true))
  end)

  it("quotes paths with spaces and quotes", function()
    local c = O.launchCmd("/a b/py", "/it's/server.py", "/tmp/l")
    assert.truthy(c:find("'/a b/py'", 1, true))
    assert.truthy(c:find([['/it'\''s/server.py']], 1, true))
  end)
end)

describe("ovis_ocr.killCmd", function()
  local cmd = O.killCmd(8797, 4242)

  it("only kills listeners", function()
    assert.truthy(cmd:find("-sTCP:LISTEN", 1, true))
  end)

  it("calls lsof by its full path", function()
    -- /usr/sbin is not on the task's PATH; a bare `lsof` fails silently.
    assert.truthy(cmd:find("^/usr/sbin/lsof "))
  end)

  it("never kills Hammerspoon itself", function()
    assert.truthy(cmd:find("grep -vx 4242", 1, true))
  end)

  it("succeeds when nothing is listening", function()
    assert.truthy(cmd:find("true$"))
  end)
end)

describe("ovis_ocr.curlArgs", function()
  local args = O.curlArgs("http://127.0.0.1:8797", '{"path":"/x.pdf"}', 600)

  it("posts JSON to /ocr", function()
    assert.equals("http://127.0.0.1:8797/ocr", args[#args])
    local joined = table.concat(args, " ")
    assert.truthy(joined:find("Content-Type: application/json", 1, true))
    assert.truthy(joined:find('-d {"path":"/x.pdf"}', 1, true))
  end)

  it("bounds the wait, because a long PDF takes minutes", function()
    local joined = table.concat(args, " ")
    assert.truthy(joined:find("--max-time 600", 1, true))
  end)

  it("fails on an HTTP error instead of handing back the error page as Markdown", function()
    assert.truthy(table.concat(args, " "):find("--fail-with-body", 1, true))
  end)
end)

describe("ovis_ocr.isSupported", function()
  it("takes images and PDFs, any case", function()
    for _, p in ipairs({ "/a.png", "/a.JPG", "/a.jpeg", "/a.pdf", "/a.HEIC", "/a.tiff", "/a.webp" }) do
      assert.is_true(O.isSupported(p), p)
    end
  end)

  it("refuses everything else", function()
    for _, p in ipairs({ "/a.docx", "/a", "/a.md", "", nil }) do
      assert.is_false(O.isSupported(p), tostring(p))
    end
  end)
end)

describe("ovis_ocr.title", function()
  it("sleeps when the server is off", function()
    assert.equals("📄💤", O.title({ running = false }))
  end)

  it("shows work in progress over everything", function()
    assert.equals("📄⏳", O.title({ running = true, busy = true }))
    assert.equals("📄⏳", O.title({ running = true, working = 1 }))
  end)

  it("is plain when up", function()
    assert.equals("📄", O.title({ running = true }))
  end)
end)

describe("ovis_ocr.status", function()
  it("says off", function()
    assert.equals("Server off", O.status({ running = false }))
  end)

  it("says the model loads on demand", function()
    assert.equals("Ready · model loads on first use",
                  O.status({ running = true, loaded = false }))
  end)

  it("says the model is resident", function()
    assert.equals("Model loaded", O.status({ running = true, loaded = true }))
  end)

  it("says it is reading", function()
    assert.equals("Reading…", O.status({ running = true, loaded = true, busy = true }))
  end)

  it("puts a start or stop in progress first", function()
    assert.equals("Starting…", O.status({ running = false, moving = "Starting…" }))
  end)
end)

describe("ovis_ocr.summary", function()
  it("counts pages and seconds", function()
    assert.equals("1 page · 3.2s", O.summary({ pages = 1, seconds = 3.2 }))
    assert.equals("4 pages · 12.5s", O.summary({ pages = 4, seconds = 12.5 }))
  end)

  it("survives a partial answer", function()
    assert.equals("0 pages", O.summary({}))
  end)
end)

describe("ovis_ocr.savedPath", function()
  it("sits beside the source with .ocr.md", function()
    assert.equals("/docs/scan.ocr.md", O.savedPath("/docs/scan.pdf"))
    assert.equals("/docs/a.b.ocr.md", O.savedPath("/docs/a.b.png"))
  end)

  it("handles a file with no extension", function()
    assert.equals("/docs/scan.ocr.md", O.savedPath("/docs/scan"))
  end)
end)
