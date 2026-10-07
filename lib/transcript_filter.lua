-- Pure clean-up applied to a finished transcript before it is pasted — no hs.*
-- dependency.
--
-- Two failure modes of speech models, Whisper above all:
--   • silence comes back as a stock subtitle line ("Thanks for watching!"),
--     learned from the captions it was trained on
--   • trailing silence sends the decoder into a loop that repeats the last
--     sentence many times over
-- The first is only dropped when it is the WHOLE transcript, so "thank you for
-- the review" still pastes. The second only collapses repeats that sit back to
-- back, so a deliberate "Yes. No. Yes." survives.

local M = {}

-- Lowercase, punctuation and spaces stripped: the key both rules compare on.
local function key(s)
  return (s:lower():gsub("[%p%s]+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- Normalised forms of the stock lines. Matched against the whole transcript.
M.HALLUCINATIONS = {
  ["thanks for watching"] = true,
  ["thank you for watching"] = true,
  ["thanks for watching bye"] = true,
  ["thank you"] = true,
  ["thank you very much"] = true,
  ["thanks"] = true,
  ["you"] = true,
  ["bye"] = true,
  ["blank audio"] = true,
  ["music"] = true,
  ["silence"] = true,
  ["please subscribe"] = true,
  ["like and subscribe"] = true,
}

-- Prefixes of caption credits ("Subtitles by the Amara.org community").
M.HALLUCINATION_PREFIXES = { "subtitles by", "transcription by", "captions by", "translated by" }

local function isHallucination(text)
  local k = key(text)
  if k == "" or M.HALLUCINATIONS[k] then return true end
  for _, p in ipairs(M.HALLUCINATION_PREFIXES) do
    if k:sub(1, #p) == p then return true end
  end
  return false
end

-- Sentences with their closing punctuation kept, split after . ! ? followed by
-- whitespace. Text without a final mark ends up as the last piece.
local function sentences(text)
  local out, start = {}, 1
  for stop in text:gmatch("[%.!?]+()%s+") do
    out[#out + 1] = text:sub(start, stop - 1)
    start = stop
  end
  local tail = text:sub(start):match("^%s*(.-)%s*$")
  if tail ~= "" then out[#out + 1] = tail end
  for i, s in ipairs(out) do out[i] = s:match("^%s*(.-)%s*$") end
  return out
end

-- Returns the cleaned transcript, "" when nothing real was said. Stock lines are
-- only dropped when opts.stockLines is set: they come from Whisper-style models,
-- and on a model that doesn't invent them, a spoken "Thank you." is real.
function M.clean(text, opts)
  if type(text) ~= "string" then return "" end
  text = text:match("^%s*(.-)%s*$")
  if text == "" then return "" end
  if opts and opts.stockLines and isHallucination(text) then return "" end
  local kept, last = {}, nil
  for _, s in ipairs(sentences(text)) do
    local k = key(s)
    if k ~= last then kept[#kept + 1] = s end
    last = k
  end
  return table.concat(kept, " ")
end

return M
