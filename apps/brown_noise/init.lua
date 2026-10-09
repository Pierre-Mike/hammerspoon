-- Noise machine: play/stop, volume slider, and color picker, shown as the
-- Noise tile in the menu-bar hub (lib/menuhub.lua). Default color is brown.
--
-- The tile and the sound belong to this plugin's context, so B.dispose() stops
-- the noise and takes the tile back. That matters more here than almost
-- anywhere else in apps/: the WAV loops forever, so a plugin switched off
-- without releasing its sound would keep playing with nothing left to stop it.

local ctx = require("lib.context").new("Noise")

local HOME = os.getenv("HOME")
local DIR  = HOME .. "/.hammerspoon/"

-- Selectable colors. Order = dropdown order. First entry is the default.
local COLORS = {
  { id = "brown",  label = "Brown" },
  { id = "pink",   label = "Pink" },
  { id = "white",  label = "White" },
  { id = "blue",   label = "Blue" },
  { id = "violet", label = "Violet" },
}

local B = { playing = false, sound = nil, volume = 0.4, color = COLORS[1].id,
            release = nil }   -- ctx handle on the sound: stops it and forgets it

local ICON_OFF = "🟤"   -- stopped
local ICON_ON  = "🔊"   -- playing

B.menu = ctx:tile("Noise")

local function fileFor(id) return DIR .. "noise_" .. id .. ".wav" end

local function labelOf(id)
  for _, c in ipairs(COLORS) do if c.id == id then return c.label end end
  return id
end

-- Icon plus the one-line status the hub tile shows under "Noise".
local function setIcon()
  B.menu:setTitle(B.playing and ICON_ON or ICON_OFF)
  B.menu:setTooltip((B.playing and "Playing" or "Stopped") .. " · " .. labelOf(B.color))
end

-- Build (or rebuild) the sound for the current color.
local function ensureSound()
  if not B.sound then
    B.sound, B.release = ctx:sound(fileFor(B.color))
    if B.sound then
      B.sound:loopSound(true)
      B.sound:volume(B.volume)
    end
  end
  return B.sound
end

-- Let the current sound go. Through the context's release rather than
-- sound:stop(), so the context stops holding a handle to a sound nobody will
-- play again — a color picked five times should not leave five of them behind.
local function dropSound()
  if B.release then B.release() end
  B.sound, B.release = nil, nil
end

local function play()
  local s = ensureSound()
  if not s then
    hs.alert.show("noise_" .. B.color .. ".wav not found")
    return
  end
  s:volume(B.volume)
  s:play()
  B.playing = true
  setIcon()
end

local function stop()
  if B.sound then B.sound:stop() end
  B.playing = false
  setIcon()
end

local function setVolume(v)
  B.volume = v
  if B.sound then B.sound:volume(v) end
end

-- Switch color: swap the underlying sound, keep playing seamlessly if active.
local function setColor(id)
  if id == B.color then return end
  B.color = id
  local wasPlaying = B.playing
  dropSound()
  if wasPlaying then play() else setIcon() end
end

local function toggle()
  if B.playing then stop() else play() end
end

-- Drawn by the hub panel: a switch, a volume slider and a color picker.
B.menu:setMenu(function()
  local items = {
    { title = "Play", switch = true, checked = B.playing, fn = toggle },
    { title = "Volume", slider = {
        value = math.floor(B.volume * 100 + 0.5), min = 0, max = 100, unit = "%",
        fn = function(v) setVolume(v / 100) end,
    } },
    { title = "-" },
    { title = "Color", disabled = true },
  }
  for _, c in ipairs(COLORS) do
    items[#items + 1] = {
      title = c.label, checked = (c.id == B.color),
      fn = function() setColor(c.id) end,
    }
  end
  return items
end)
setIcon()

-- Exposed for `hs -c` testing.
B.toggle = toggle
B.play = play
B.stop = stop
B.setColor = setColor
B.setVolume = setVolume

-- Switch the plugin off: the noise stops and the tile goes, in one call.
function B.dispose()
  ctx:dispose()
  B.sound, B.release, B.playing = nil, nil, false
end

return B
