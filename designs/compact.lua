-- Compact: smaller type, tighter spacing, and a three-column hub.
return {
  name = "Compact",
  description = "Smaller type and spacing, three-column hub",
  accent = "purple",
  text   = { caption = 10, footnote = 11, body = 12, title = 15, display = 17, hero = 22 },
  radius = { sm = 6, md = 9, lg = 12, island = 18 },
  space  = { xs = 3, sm = 6, md = 9, lg = 12, xl = 18 },
  size   = { control = 24, dot = 7, minWidth = 200 },
  panel  = { width = 440, columns = 3, fontSize = 12, small = 10, large = 14,
             pad = 10, gap = 6, tileHeight = 48, disc = 28, rowHeight = 30, control = 24 },
}
