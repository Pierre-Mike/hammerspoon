-- Noise machine in the menu bar: play/stop, volume slider, and color picker.
-- Click the icon for a floating panel. Default color is brown.

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

local B = { playing = false, sound = nil, volume = 0.4, color = COLORS[1].id, panel = nil }

local ICON_OFF = "🟤"   -- stopped
local ICON_ON  = "🔊"   -- playing

B.menu = hs.menubar.new()

local function fileFor(id) return DIR .. "noise_" .. id .. ".wav" end

local function setIcon()
  B.menu:setTitle(B.playing and ICON_ON or ICON_OFF)
end

-- Push current state into the open panel so button/slider/picker stay in sync.
local function syncPanel()
  if B.panel then
    B.panel:evaluateJavaScript(string.format(
      "window.sync && window.sync(%s, %d, %q)",
      tostring(B.playing), math.floor(B.volume * 100 + 0.5), B.color))
  end
end

-- Build (or rebuild) the sound for the current color.
local function ensureSound()
  if not B.sound then
    B.sound = hs.sound.getByFile(fileFor(B.color))
    if B.sound then
      B.sound:loopSound(true)
      B.sound:volume(B.volume)
    end
  end
  return B.sound
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
  setIcon(); syncPanel()
end

local function stop()
  if B.sound then B.sound:stop() end
  B.playing = false
  setIcon(); syncPanel()
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
  if B.sound then B.sound:stop(); B.sound = nil end
  if wasPlaying then play() else syncPanel() end
end

local function panelHTML()
  local vol = math.floor(B.volume * 100 + 0.5)
  local opts = {}
  for _, c in ipairs(COLORS) do
    opts[#opts + 1] = string.format("<option value=\"%s\"%s>%s</option>",
      c.id, c.id == B.color and " selected" or "", c.label)
  end
  return string.format([[
<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
  html,body { margin:0; height:100%%; -webkit-user-select:none; cursor:default;
    font-family:-apple-system,BlinkMacSystemFont,sans-serif; }
  .card { box-sizing:border-box; height:100%%; padding:12px 16px; border-radius:14px;
    background:rgba(28,28,30,0.95); color:#fff; display:flex; flex-direction:column; gap:9px; }
  .row { display:flex; align-items:center; gap:12px; }
  .title { font-size:12px; color:#888; }
  #tg { width:38px; height:38px; flex:0 0 auto; border:none; border-radius:50%%;
    background:#3a3a3c; color:#fff; font-size:16px; cursor:pointer; }
  #tg:active { background:#505052; }
  #vol { -webkit-appearance:none; flex:1; height:5px; border-radius:3px;
    background:#5a4633; outline:none; }
  #vol::-webkit-slider-thumb { -webkit-appearance:none; width:18px; height:18px;
    border-radius:50%%; background:#b87333; cursor:pointer; }
  #lbl { flex:0 0 auto; width:38px; text-align:right; font-size:13px; color:#aaa;
    font-variant-numeric:tabular-nums; }
  #col { flex:1; -webkit-appearance:none; background:#3a3a3c; color:#fff; border:none;
    border-radius:7px; padding:5px 8px; font-size:13px; cursor:pointer; }
</style></head>
<body>
  <div class="card">
    <div class="title">Noise machine</div>
    <div class="row">
      <button id="tg">&#9654;</button>
      <input id="vol" type="range" min="0" max="100" value="%d">
      <span id="lbl">%d%%</span>
    </div>
    <div class="row">
      <select id="col">%s</select>
    </div>
  </div>
<script>
  var post = function(o){ window.webkit.messageHandlers.brown.postMessage(o); };
  var tg = document.getElementById('tg');
  var vol = document.getElementById('vol');
  var lbl = document.getElementById('lbl');
  var col = document.getElementById('col');
  vol.addEventListener('input', function(e){
    var v = +e.target.value; lbl.textContent = v + '%%'; post({type:'volume', value:v});
  });
  tg.addEventListener('click', function(){ post({type:'toggle'}); });
  col.addEventListener('change', function(e){ post({type:'color', value:e.target.value}); });
  window.sync = function(playing, v, color){
    tg.innerHTML = playing ? '&#9632;' : '&#9654;';
    vol.value = v; lbl.textContent = v + '%%';
    if (color) col.value = color;
  };
</script>
</body></html>]], vol, vol, table.concat(opts))
end

-- Receives {type:"volume"|"toggle"|"color", value:...} from the panel.
local ucc = hs.webview.usercontent.new("brown")
ucc:setCallback(function(m)
  local b = m.body
  if type(b) ~= "table" then return end
  if b.type == "volume" then
    setVolume((tonumber(b.value) or 40) / 100)
  elseif b.type == "toggle" then
    if B.playing then stop() else play() end
  elseif b.type == "color" then
    setColor(tostring(b.value))
  end
end)

local function buildPanel()
  local sf = hs.screen.mainScreen():frame()
  local w, h = 250, 130
  local x = sf.x + sf.w - w - 12
  local y = sf.y + 8
  local wv = hs.webview.new({ x = x, y = y, w = w, h = h }, { developerExtrasEnabled = false }, ucc)
  local masks = hs.webview.windowMasks
  wv:windowStyle(masks.borderless | masks.nonactivating)
  wv:level(hs.canvas.windowLevels.popUpMenu)
  local bh = hs.canvas.windowBehaviors
  wv:behavior(bh.canJoinAllSpaces | bh.stationary)
  wv:transparent(true)
  wv:allowTextEntry(false)
  wv:html(panelHTML())
  return wv
end

local function togglePanel()
  if B.panel then
    B.panel:delete(); B.panel = nil
    return
  end
  B.panel = buildPanel()
  B.panel:show()
  syncPanel()
end

B.menu:setClickCallback(togglePanel)
setIcon()

-- Exposed for `hs -c` testing and ducking from init.lua.
B.toggle = togglePanel
B.play = play
B.stop = stop
B.setColor = setColor
B.setVolume = setVolume

return B
