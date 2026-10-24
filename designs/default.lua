-- The default design: macOS system colors and the system font. Overlays
-- follow the system appearance, light or dark, and switch with it live.
--
-- A design is a table of overrides on lib/theme's defaults. This one changes
-- nothing, so it is also the reference: every key a design can set is listed
-- below, commented out, with its default value. Copy this file to start a new
-- design, uncomment what you want to change, and switch to it with
--   hs -c 'uiDesign("my_design")'
-- or from the Design submenu in the 🧩 Plugins tile.
--
-- A file whose name starts with "_" is a draft and does not show in the menu.
-- tests/spec/design_spec.lua builds every design and fails on unreadable text,
-- so run `make test-lua` before switching to a new one.

return {
  name = "Default",
  description = "macOS system colors and font, follows light and dark",

  -- overlay = "auto",          -- follow the system; "dark" or "light" pins one
  -- accent  = "blue",          -- a palette name, or "#rrggbb"

  -- For a design that follows the system, what differs per appearance. Each
  -- takes `accent` and `color`, laid over the ones below.
  -- light = { color = { surface = { "#fbf7f2", 0.97 } } },
  -- dark  = { color = { surface = { "#2a2420", 0.96 } } },

  -- Named colors, per appearance. Overlays use one set, the hub panel both.
  -- palette = {
  --   light = { blue = "#007aff", green = "#34c759", orange = "#ff9500",
  --             yellow = "#ffcc00", red = "#ff3b30", purple = "#af52de", pink = "#ff2d55" },
  --   dark  = { blue = "#0a84ff", green = "#30d158", orange = "#ff9f0a",
  --             yellow = "#ffd60a", red = "#ff453a", purple = "#bf5af2", pink = "#ff375f" },
  -- },

  -- Overlay color roles. "#rrggbb", { "#rrggbb", alpha }, or { white = 1, alpha = 0.5 }.
  -- These apply in both appearances; the values shown are the dark ones.
  -- lib/theme.lua has the light set.
  -- color = {
  --   surface = { "#1c1c1e", 0.96 }, surfaceSolid = "#000000",
  --   edge = { white = 1, alpha = 0.10 },
  --   control = { white = 1, alpha = 0.10 }, controlHover = { white = 1, alpha = 0.20 },
  --   text = { white = 1, alpha = 0.96 }, textSecondary = { white = 1, alpha = 0.62 },
  --   textTertiary = { white = 1, alpha = 0.40 },
  --   accent = (from `accent`), onAccent = (white or black, whichever reads),
  --   success = green, warning = orange, danger = red, highlight = yellow,
  -- },

  -- Which role each meaning uses.
  -- tones = { neutral = "textSecondary", info = "accent", success = "success",
  --           warning = "warning", danger = "danger", recording = "danger",
  --           working = "warning", draft = "highlight" },

  -- Fonts by PostScript name; nil is the system font.
  -- font = { regular = nil, bold = ".AppleSystemUIFontBold" },

  -- Point sizes by role, and line height as a multiple of the size.
  -- text = { caption = 11, footnote = 12, body = 14, title = 17, display = 20, hero = 28 },
  -- leading = 1.32,

  -- radius = { sm = 8, md = 12, lg = 16, island = 24 },
  -- space  = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24 },
  -- size   = { control = 30, dot = 9, minWidth = 240 },
  -- inset  = { bottom = 60, caption = 150, top = 60 },
  -- motion = { fade = 0.15, toast = 1.6 },

  -- The hub panel, in CSS pixels.
  -- panel = { width = 360, columns = 2,
  --           font = '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif',
  --           fontSize = 13, small = 11, large = 15, pad = 14, gap = 8,
  --           tileHeight = 58, disc = 34, rowHeight = 34, control = 28, motion = 0.16 },

  -- The hub panel's colors, as CSS, per system appearance. Any key replaces
  -- one: card, edge, tile, tile-hover, disc-bg, rule, text, muted, accent,
  -- pill, pill-hover, glyph-filter, switch-off, switch-on, track.
  -- hub = { light = { card = "rgba(246, 246, 248, 0.95)" },
  --         dark  = { card = "rgba(36, 36, 38, 0.95)" } },
}
