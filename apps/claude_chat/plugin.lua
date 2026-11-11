return {
  id          = "claude_chat",
  name        = "Claude",
  version     = "1.0.0",
  api         = 1,
  author      = "Pierre-Mike",
  description = "A Claude Code session kept running for quick questions, in the hub panel.",
  -- Below the world clock in the panel: widgets show in load order.
  after = { "world_clock" },
  settings = {
    model = { type = "choice", options = { "haiku", "sonnet", "opus", "default" }, default = "sonnet" },
  },
}
