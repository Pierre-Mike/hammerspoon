-- lib/llm_cleanup builds the optional LM Studio clean-up request and judges its
-- reply. Pure: the caller does the HTTP and the JSON.
local lc = require("lib.llm_cleanup")

describe("llm_cleanup.pickModel", function()
  it("picks the first loaded LLM from LM Studio's /api/v0/models", function()
    local models = { data = {
      { id = "embed", type = "embeddings", state = "loaded" },
      { id = "big", type = "llm", state = "not-loaded" },
      { id = "qwen", type = "llm", state = "loaded" },
    } }
    assert.equals("qwen", lc.pickModel(models))
  end)

  it("returns nil when no LLM is loaded, so the take pastes raw", function()
    assert.is_nil(lc.pickModel({ data = { { id = "big", type = "llm", state = "not-loaded" } } }))
    assert.is_nil(lc.pickModel(nil))
    assert.is_nil(lc.pickModel({}))
  end)
end)

describe("llm_cleanup.request", function()
  it("sends the transcript as the user message to the chosen model", function()
    local r = lc.request("um so the the build is red", "qwen")
    assert.equals("qwen", r.model)
    assert.equals(0, r.temperature)
    assert.equals("system", r.messages[1].role)
    assert.equals("user", r.messages[2].role)
    assert.equals("um so the the build is red", r.messages[2].content)
    assert.is_false(r.stream)
  end)
end)

describe("llm_cleanup.parse", function()
  local function reply(content)
    return { choices = { { message = { content = content } } } }
  end

  it("returns the cleaned text", function()
    assert.equals("The build is red.", lc.parse(reply("The build is red.\n"), "um the build is red"))
  end)

  -- Thinking models wrap their reasoning in <think>; only the answer pastes.
  it("drops a <think> block before the answer", function()
    assert.equals("The build is red.",
      lc.parse(reply("<think>remove filler</think>\nThe build is red."), "um the build is red"))
  end)

  it("rejects an empty or malformed reply", function()
    assert.is_nil(lc.parse(reply("   "), "hello"))
    assert.is_nil(lc.parse({}, "hello"))
    assert.is_nil(lc.parse(nil, "hello"))
  end)

  -- A model that answers the dictation instead of cleaning it writes far more
  -- than it was given. That is not a clean-up, so the raw take wins.
  it("rejects a reply much longer than the transcript", function()
    assert.is_nil(lc.parse(reply(string.rep("word ", 80)), "what is the capital of France"))
  end)
end)
