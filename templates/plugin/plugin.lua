-- The manifest: plain data, read before the plugin runs. `make plugin` fills in
-- the id and name. See "Write a plugin" in the README for every field.
return {
  id          = "template",
  name        = "Template",
  version     = "0.1.0",
  api         = 1,
  author      = "you",
  description = "One line on what this plugin does.",
  -- after = { "dictation" },   -- load after these, when installed
  -- needs = { "tts" },         -- do not load unless these are running
  settings = {
    greeting = { type = "string", default = "Hello from the template" },
  },
}
