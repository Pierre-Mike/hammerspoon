-- The one look every plugin shares: colors, type, spacing, corners, motion,
-- and the hub panel's sizes.
--
-- Before this file, each app picked its own. The dictation HUD was black at
-- 82% with 14 pt corners, its notification black at 85% with 12, the live
-- preview 16, the text-actions bar navy with an orange hover, the karaoke
-- island pure black at 24. None of it was wrong on its own; side by side it
-- read as six apps from six people.
--
-- So no plugin names a color or a size any more. It asks lib/ui for a
-- component, and the component reads its numbers from here. Changing a token
-- changes every plugin at once, and that includes the hub panel: menuhub
-- injects css() into lib/menuhub_panel.html, so the tile grid and the overlays
-- cannot drift apart.
--
-- The values below are the defaults. A design (designs/<name>.lua, chosen by
-- lib/design) overrides any of them, and build() merges the two. The fields
-- of this module are the active design's tokens, built once at load.
--
-- build() and everything it calls are pure, so a design is tested without
-- Hammerspoon.

local M = {}

-- "#rrggbb" to the color table hs.canvas wants.
function M.rgb(hex, alpha)
  local r, g, b = tostring(hex):match("^#?(%x%x)(%x%x)(%x%x)$")
  if not r then error("theme: not a hex color: " .. tostring(hex), 2) end
  return { red = tonumber(r, 16) / 255, green = tonumber(g, 16) / 255,
           blue = tonumber(b, 16) / 255, alpha = alpha or 1 }
end

-- A color the way a design writes it: "#rrggbb", { "#rrggbb", alpha }, or a
-- finished hs.canvas table.
local function color(v)
  if type(v) == "string" then return M.rgb(v) end
  if type(v) == "table" and type(v[1]) == "string" then return M.rgb(v[1], v[2]) end
  return v
end

-- One level deep: keys in `over` replace keys in `base`.
local function merge(base, over)
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  for k, v in pairs(over or {}) do out[k] = v end
  return out
end

-- ── Palette ────────────────────────────────────────────────────────────────
-- Apple's system colors, both variants. Overlays float over whatever is on
-- screen and default to dark, the way macOS draws its own volume and
-- brightness HUDs. The hub panel follows the system appearance and uses both.
local PALETTE = {
  light = { blue = "#007aff", green = "#34c759", orange = "#ff9500",
            yellow = "#ffcc00", red = "#ff3b30", purple = "#af52de", pink = "#ff2d55" },
  dark  = { blue = "#0a84ff", green = "#30d158", orange = "#ff9f0a",
            yellow = "#ffd60a", red = "#ff453a", purple = "#bf5af2", pink = "#ff375f" },
}

-- ── Overlay colors ─────────────────────────────────────────────────────────
-- By role, never by hue: a plugin says "secondary text" or "danger", and what
-- that looks like is decided here. One set for dark overlays, one for light;
-- a design picks with `overlay = "light"`.
--
-- The surface is 0.96 opaque, not the 0.8 a blurred HUD can afford: hs.canvas
-- has no blur, so anything lighter lets the text underneath read through.
local OVERLAY = {
  dark = function(p)
    return {
      surface       = M.rgb("#1c1c1e", 0.96),   -- every floating panel
      surfaceSolid  = M.rgb("#000000"),         -- one that reads as hardware (the notch island)
      edge          = { white = 1, alpha = 0.10 },
      control       = { white = 1, alpha = 0.10 },  -- a button at rest
      controlHover  = { white = 1, alpha = 0.20 },
      text          = { white = 1, alpha = 0.96 },
      textSecondary = { white = 1, alpha = 0.62 },
      textTertiary  = { white = 1, alpha = 0.40 },
      success = M.rgb(p.green), warning = M.rgb(p.orange),
      danger  = M.rgb(p.red),   highlight = M.rgb(p.yellow),
    }
  end,
  light = function(p)
    return {
      surface       = M.rgb("#f6f6f8", 0.97),
      surfaceSolid  = M.rgb("#ffffff"),
      edge          = { white = 0, alpha = 0.12 },
      control       = { white = 0, alpha = 0.07 },
      controlHover  = { white = 0, alpha = 0.14 },
      text          = { white = 0.11, alpha = 1 },
      textSecondary = { white = 0, alpha = 0.60 },
      textTertiary  = { white = 0, alpha = 0.48 },
      success = M.rgb(p.green), warning = M.rgb(p.orange),
      danger  = M.rgb(p.red),   highlight = M.rgb(p.orange),
    }
  end,
}

-- What a status means, mapped to a color role. A plugin passes the meaning.
local TONES = {
  neutral   = "textSecondary",
  info      = "accent",
  accent    = "accent",
  success   = "success",
  warning   = "warning",
  danger    = "danger",
  error     = "danger",
  recording = "danger",    -- the mic is live
  working   = "warning",   -- waiting on something: a model, a server
  draft     = "highlight", -- text that may still change
}

-- ── Type, shape, space, motion ─────────────────────────────────────────────
-- nil is hs.canvas's own default, which is the system font; bold has to be
-- asked for by name. A design names fonts by their PostScript name
-- ("Menlo-Regular", "AvenirNext-DemiBold").
local FONT = { regular = nil, bold = ".AppleSystemUIFontBold" }

local TEXT = {
  caption  = 11,  -- hints, key legends
  footnote = 12,  -- a secondary line under a title
  body     = 14,  -- toasts, buttons
  title    = 17,
  display  = 20,  -- a HUD's one word, a lyric line
  hero     = 28,  -- live transcript
}

local RADIUS = { sm = 8, md = 12, lg = 16, island = 24 }
local SPACE  = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24 }

-- Fixed sizes components share, so a button in one bar is a button in all.
local SIZE = {
  control  = 30,   -- button height
  dot      = 9,    -- status dot radius
  minWidth = 240,  -- narrowest a toast or bar is drawn
}

-- Where a surface sits, as distance from the edge it hugs: a bar just above
-- the Dock, a live caption higher, so the two never cover each other. The gap
-- fits a bar up to 90 pt tall, and dictation shows its transcript and the
-- rewrite bar together.
local INSET = { bottom = 60, caption = 150, top = 60 }

local MOTION = {
  fade  = 0.15,   -- show/hide
  toast = 1.6,    -- how long a toast stays by default
}

-- ── The hub panel ──────────────────────────────────────────────────────────
-- Its sizes, in CSS pixels. `width` is the window menuhub opens, and
-- `columns` the tile grid inside it.
local PANEL = {
  width = 360, columns = 2,
  font = '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif',
  fontSize = 13, small = 11, large = 15,
  pad = 14, gap = 8,
  tileHeight = 58, disc = 34, rowHeight = 34, control = 28,
  motion = 0.16,
}

-- Its colors, light and dark, because it follows the system appearance. The
-- accent and the switch come from the palette, so a design's accent reaches
-- the panel too.
local HUB = {
  light = function(p, accent)
    return {
      card = "rgba(246, 246, 248, 0.95)", edge = "rgba(0, 0, 0, 0.10)",
      tile = "rgba(255, 255, 255, 0.80)", ["tile-hover"] = "rgba(255, 255, 255, 1)",
      ["disc-bg"] = "rgba(0, 0, 0, 0.06)", rule = "rgba(0, 0, 0, 0.08)",
      text = "#1d1d1f", muted = "#6e6e73", accent = accent,
      pill = "rgba(0, 0, 0, 0.06)", ["pill-hover"] = "rgba(0, 0, 0, 0.11)",
      ["glyph-filter"] = "none", ["switch-off"] = "rgba(0, 0, 0, 0.12)",
      ["switch-on"] = p.green, track = "rgba(0, 0, 0, 0.10)",
    }
  end,
  dark = function(p, accent)
    return {
      card = "rgba(36, 36, 38, 0.95)", edge = "rgba(255, 255, 255, 0.12)",
      tile = "rgba(255, 255, 255, 0.07)", ["tile-hover"] = "rgba(255, 255, 255, 0.13)",
      ["disc-bg"] = "rgba(255, 255, 255, 0.10)", rule = "rgba(255, 255, 255, 0.08)",
      text = "#f5f5f7", muted = "#98989d", accent = accent,
      pill = "rgba(255, 255, 255, 0.08)", ["pill-hover"] = "rgba(255, 255, 255, 0.15)",
      ["glyph-filter"] = "invert(1)", ["switch-off"] = "rgba(255, 255, 255, 0.16)",
      ["switch-on"] = p.green, track = "rgba(255, 255, 255, 0.14)",
    }
  end,
}

-- ── Contrast ───────────────────────────────────────────────────────────────
-- WCAG contrast between two hs.canvas colors. `fg` is blended over `bg` by its
-- alpha first, because "white at 40%" is a grey only once it sits on
-- something. `bg` is taken as opaque.
local function channels(c)
  local w = c.white
  return c.red or w or 0, c.green or w or 0, c.blue or w or 0
end

local function luminance(r, g, b)
  local function lin(x) return x <= 0.03928 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4 end
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
end

function M.contrast(fg, bg)
  local a = fg.alpha or 1
  local fr, fgr, fb = channels(fg)
  local br, bgr, bb = channels(bg)
  local l1 = luminance(fr * a + br * (1 - a), fgr * a + bgr * (1 - a), fb * a + bb * (1 - a))
  local l2 = luminance(br, bgr, bb)
  if l1 < l2 then l1, l2 = l2, l1 end
  return (l1 + 0.05) / (l2 + 0.05)
end

-- ── Building a design ──────────────────────────────────────────────────────
-- Pure. The defaults above with `d` laid over them. Every field of `d` is
-- optional; see designs/default.lua for the whole list.
--   d.overlay  "auto" (default) follows `appearance`, the system's light or
--              dark; "dark" or "light" pins it
--   d.light, d.dark  { accent, color } that apply in that appearance only
--   d.accent   a palette name ("orange") or "#rrggbb"
--   d.palette  { light = {...}, dark = {...} } replacing named colors
--   d.color    any role, as "#rrggbb", { "#rrggbb", alpha } or an hs.canvas table
--   d.tones, d.font, d.text, d.leading, d.radius, d.space, d.size, d.inset,
--   d.motion, d.panel   replace the keys they name
--   d.hub      { light = {...}, dark = {...} } CSS colors for the panel
function M.build(d, appearance)
  d = d or {}
  local t = { name = d.name, description = d.description }
  local pal = d.palette or {}
  t.palette = { light = merge(PALETTE.light, pal.light), dark = merge(PALETTE.dark, pal.dark) }
  -- "auto" follows the system appearance passed in; "dark" or "light" pins it.
  t.overlaySetting = (d.overlay == "light" or d.overlay == "dark") and d.overlay or "auto"
  t.overlay = t.overlaySetting == "auto" and (appearance == "light" and "light" or "dark")
              or t.overlaySetting
  -- What a design says for one appearance only: d.light = { color = ... }.
  local per = d[t.overlay] or {}

  local accent = per.accent or d.accent or "blue"
  local function accentIn(mode)
    if accent:match("^#") then return accent end
    return t.palette[mode][accent] or error("theme: no palette color " .. accent, 3)
  end

  t.color = OVERLAY[t.overlay](t.palette[t.overlay])
  t.color.accent = M.rgb(accentIn(t.overlay))
  for k, v in pairs(d.color or {}) do t.color[k] = color(v) end
  for k, v in pairs(per.color or {}) do t.color[k] = color(v) end
  -- Text on an accent-filled button. White, the way macOS labels its own
  -- buttons, as long as it clears 3:1; black on an accent too light for it
  -- (orange, yellow).
  if not ((d.color and d.color.onAccent) or (per.color and per.color.onAccent)) then
    local white = { white = 1, alpha = 1 }
    t.color.onAccent = M.contrast(white, t.color.accent) >= 3 and white or { white = 0, alpha = 0.88 }
  end

  t.tones   = merge(TONES, d.tones)
  t.font    = merge(FONT, d.font)
  t.text    = merge(TEXT, d.text)
  t.leading = d.leading or 1.32
  t.radius  = merge(RADIUS, d.radius)
  t.space   = merge(SPACE, d.space)
  t.size    = merge(SIZE, d.size)
  t.inset   = merge(INSET, d.inset)
  t.motion  = merge(MOTION, d.motion)
  t.panel   = merge(PANEL, d.panel)
  -- Every role its own table. refresh() rewrites them in place, and two roles
  -- sharing one table would have the second overwrite the first.
  for k, v in pairs(t.color) do t.color[k] = merge(v) end

  local hub = d.hub or {}
  t.hub = { light = merge(HUB.light(t.palette.light, accentIn("light")), hub.light),
            dark  = merge(HUB.dark(t.palette.dark, accentIn("dark")), hub.dark) }
  return t
end

-- A tone name, or a color role, to its color. Unknown names are neutral rather
-- than an error: a typo in a status dot must not cost the message it sits on.
-- `t` is a built design, the active one when left out.
function M.tone(name, t)
  t = t or M
  local role = t.tones[name] or (t.color[name] and name) or "textSecondary"
  return t.color[role]
end

local function px(n) return string.format("%gpx", n) end

local function block(vars, t)
  local keys = {}
  for k in pairs(vars) do keys[#keys + 1] = k end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = string.format("--%s: %s;", k, vars[k]) end
  -- Corners and sizes too, so a tile in the panel rounds like a surface on
  -- screen and a compact design is compact in both places.
  for _, k in ipairs({ "sm", "md", "lg" }) do
    out[#out + 1] = string.format("--radius-%s: %s;", k, px(t.radius[k]))
  end
  local p = t.panel
  out[#out + 1] = "--font: " .. p.font .. ";"
  for _, pair in ipairs({
    { "font-size", p.fontSize }, { "font-small", p.small }, { "font-large", p.large },
    { "pad", p.pad }, { "gap", p.gap }, { "tile-height", p.tileHeight },
    { "disc", p.disc }, { "row-height", p.rowHeight }, { "control-height", p.control },
  }) do
    out[#out + 1] = string.format("--%s: %s;", pair[1], px(pair[2]))
  end
  out[#out + 1] = string.format("--columns: %d;", p.columns)
  out[#out + 1] = string.format("--motion: %gs;", p.motion)
  return table.concat(out, " ")
end

-- The custom properties menuhub_panel.html reads, light first and dark under
-- prefers-color-scheme. Sorted, so the output is the same on every reload.
function M.css(t)
  t = t or M
  return ":root { " .. block(t.hub.light, t) .. " }\n"
      .. "@media (prefers-color-scheme: dark) { :root { " .. block(t.hub.dark, t) .. " } }"
end

-- ── The active design ──────────────────────────────────────────────────────
local design = require("lib.design")
local overrides, name = design.overrides()

-- Lay a built design over this module. Color roles are rewritten in place
-- rather than replaced, because plugins keep references to them from load
-- time (dictation's transcript colors, karaoke's three whites): rewriting the
-- table they hold is what lets an appearance change reach them without a
-- reload.
local function apply(t)
  for k, v in pairs(t) do
    if k == "color" and type(M.color) == "table" then
      for role, c in pairs(v) do
        local held = M.color[role]
        if type(held) == "table" then
          for key in pairs(held) do held[key] = nil end
          for key, val in pairs(c) do held[key] = val end
        else
          M.color[role] = c
        end
      end
    else
      M[k] = v
    end
  end
end

apply(M.build(overrides, design.appearance()))
M.file = name                -- designs/<file>.lua, as lib/design names it
M.name = M.name or name      -- the design's own name for itself, for people

-- Called when macOS switches between light and dark. Rebuilds the overlay
-- colors for the new appearance and tells whoever asked (lib/ui's
-- onAppearance) so anything already on screen can redraw. A design pinned to
-- dark or light ignores it. Returns true when the colors changed.
local listeners, seq = {}, 0

function M.refresh(appearance)
  appearance = appearance or design.appearance()
  if M.overlaySetting ~= "auto" or appearance == M.overlay then return false end
  apply(M.build(overrides, appearance))
  M.name = M.name or name
  for _, fn in pairs(listeners) do pcall(fn, M.overlay) end
  return true
end

-- Register fn(appearance) for refresh(). Returns the function that removes it.
function M.onChange(fn)
  seq = seq + 1
  local id = seq
  listeners[id] = fn
  return function() listeners[id] = nil end
end

return M
