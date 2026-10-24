-- Terminal: black panels, Menlo, a green accent and square-ish corners.
return {
  name = "Terminal",
  description = "Black panels, Menlo, green accent, small corners",
  overlay = "dark",          -- its colors are dark ones, so it does not follow the system
  accent = "green",
  color = {
    surface      = { "#0b0d0b", 0.97 },
    edge         = { "#30d158", 0.35 },
    control      = { "#30d158", 0.12 },
    controlHover = { "#30d158", 0.24 },
    text         = "#d8f5dc",
    textSecondary = { "#d8f5dc", 0.66 },
    textTertiary  = { "#d8f5dc", 0.45 },
  },
  font   = { regular = "Menlo-Regular", bold = "Menlo-Bold" },
  radius = { sm = 3, md = 4, lg = 6, island = 8 },
  panel  = { font = 'Menlo, "SF Mono", monospace', fontSize = 12, small = 10, large = 14 },
  hub = {
    dark = { card = "rgba(11, 13, 11, 0.97)", tile = "rgba(48, 209, 88, 0.06)",
             ["tile-hover"] = "rgba(48, 209, 88, 0.13)", edge = "rgba(48, 209, 88, 0.35)",
             text = "#d8f5dc", muted = "#7fa886" },
  },
}
