-- Warm: brown-black panels, an orange accent, rounder corners.
return {
  name = "Warm",
  description = "Brown-black panels, orange accent, rounder corners",
  overlay = "dark",          -- its colors are dark ones, so it does not follow the system
  accent = "orange",
  color = {
    surface      = { "#2a2420", 0.96 },
    surfaceSolid = "#140f0c",
    edge         = { "#ffb070", 0.16 },
    control      = { "#ffd9b8", 0.12 },
    controlHover = { "#ffd9b8", 0.22 },
    text         = "#fff4ea",
  },
  radius = { sm = 11, md = 16, lg = 22, island = 28 },
  hub = {
    light = { card = "rgba(252, 246, 240, 0.96)", tile = "rgba(255, 250, 245, 0.85)" },
    dark  = { card = "rgba(42, 36, 32, 0.96)", tile = "rgba(255, 220, 190, 0.08)",
              ["tile-hover"] = "rgba(255, 220, 190, 0.15)" },
  },
}
