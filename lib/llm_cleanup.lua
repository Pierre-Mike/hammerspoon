-- Optional LLM pass over a finished dictation, through LM Studio's
-- OpenAI-compatible server — no hs.* dependency. apps/dictation does the HTTP
-- and the JSON; this module picks the model, builds the request and decides
-- whether the reply is usable. Any doubt returns nil, and nil means "paste the
-- raw transcript": a clean-up pass must never cost the user their words.

local M = {}

M.BASE = "http://127.0.0.1:1234"
M.TIMEOUT = 4          -- seconds before the raw transcript pastes anyway

M.PROMPT = table.concat({
  "You clean up dictated text.",
  "Fix punctuation and capitalisation, remove filler words (um, uh, like) and",
  "false starts, and fix obvious speech-recognition mistakes.",
  "Keep the speaker's wording, language and meaning. Do not answer, summarise",
  "or add anything. Reply with the cleaned text only.",
}, " ")

-- First loaded LLM in LM Studio's /api/v0/models listing, or nil.
function M.pickModel(decoded)
  if type(decoded) ~= "table" or type(decoded.data) ~= "table" then return nil end
  for _, m in ipairs(decoded.data) do
    if m.state == "loaded" and (m.type == "llm" or m.type == "vlm") and m.id then return m.id end
  end
  return nil
end

-- Body for POST /v1/chat/completions, as a table for the caller to encode.
function M.request(text, model)
  return {
    model = model,
    temperature = 0,
    stream = false,
    messages = {
      { role = "system", content = M.PROMPT },
      { role = "user", content = text },
    },
  }
end

-- The cleaned text from a decoded chat completion, or nil if it is unusable.
function M.parse(decoded, original)
  local ok, content = pcall(function() return decoded.choices[1].message.content end)
  if not ok or type(content) ~= "string" then return nil end
  content = content:gsub("<think>.-</think>", "")
  content = content:match("^%s*(.-)%s*$")
  if content == "" then return nil end
  -- A clean-up only ever trims and punctuates. Far more text than went in means
  -- the model answered the dictation instead.
  if #content > 2 * #(original or "") + 40 then return nil end
  return content
end

return M
