# Hammerspoon plugins

A [Hammerspoon](https://www.hammerspoon.org/) config built from small plugins. Each
plugin adds one tool to a shared menu-bar hub: dictation, ambient noise, local
speech and OCR servers, live lyrics, a face-touch deterrent and more. Drop a
folder in, reload, and it has a tile. Take it out and it leaves nothing behind.

The repo is two things. It is a working setup you can run as is, and it is a
plugin system you can build on: a manifest per plugin, a versioned API, one shared
look, and a registry that keeps a broken plugin from breaking the rest.

## What you get

- **One menu-bar button.** A 🔨 panel with a tile per plugin, in light and dark
  mode. A tile opens a menu with switches, pickers, sliders and actions.
- **Plugins that load themselves.** Anything in `apps/` or `plugins/` with an
  `init.lua` is found at startup. A plugin that throws fails alone and says why
  on its row.
- **A switch per plugin.** The 🧩 Plugins tile turns each one off and on without
  editing a file. A plugin built on the plugin object really goes away: timers
  stop, tiles disappear, child processes end.
- **One look.** Plugins pick a component (toast, HUD, button bar, menu rows) and
  never write a color. Five designs ship, and a change to one file restyles
  everything. See [DESIGN.md](DESIGN.md).
- **Tests that run anywhere.** Specs run against a mock of `hs.*`, so they need
  no Mac. The CI runs them on Linux.

Plugins that ship with the repo:

| Plugin | What it does |
|---|---|
| `dictation` | Hold Fn, speak, release. The transcript is typed at the cursor. |
| `brown_noise` | A noise machine with five colors and a volume slider. |
| `tts` | A spoken-text queue any app can post to, using a local voice model. |
| `karaoke` | Synced lyrics of the playing song in a notch-style island. |
| `lmstudio` | Start LM Studio and switch its loaded model from the hub. |
| `ovis_ocr` | Local OCR: an image or PDF in, Markdown out. |
| `noseguard` | Uses the camera to interrupt you when a finger rests on your nose. |
| `quit_guard` | Cmd+Q and Cmd+W need a double press in the apps you pick. |
| `tailscale_funnel` | One public address for this Mac, leased by whichever plugin needs it. |

The rest, and the details of each, are in [docs/apps.md](docs/apps.md).

## Install

You need macOS on Apple silicon and [Hammerspoon](https://www.hammerspoon.org/):

```sh
brew install --cask hammerspoon
```

Clone the repo and point Hammerspoon at it. If you already have a
`~/.hammerspoon`, move it aside first.

```sh
git clone https://github.com/Pierre-Mike/hammerspoon.git ~/Github/hammerspoon
ln -s ~/Github/hammerspoon ~/.hammerspoon
```

Open Hammerspoon and choose Reload Config. The 🔨 button appears in the menu bar.

Some plugins need more: `ffmpeg` for dictation, a Python environment for the speech
servers, and camera, microphone and accessibility permission for the plugins that
use them. [docs/apps.md](docs/apps.md) lists the requirements per plugin. A plugin
whose tool is missing says so on its tile and does nothing else.

To see which plugins are running, or to switch one off, open the 🧩 Plugins tile.

Run the tests with `make install-deps` (installs `busted`) and then `make test`.

## Write a plugin

Start from the template:

```sh
make plugin NAME=hello TITLE="Hello"
```

This creates `apps/hello/plugin.lua` and `apps/hello/init.lua`. To keep your plugin
out of the repo, add `DIR=plugins` and it goes in the git-ignored `plugins/` folder
instead. Reload Hammerspoon and the tile is there.

A plugin is a folder with two files.

`plugin.lua` is the manifest. It is plain data and is read before the plugin runs:

```lua
return {
  id          = "hello",
  name        = "Hello",
  version     = "1.0.0",
  api         = 1,
  author      = "you",
  description = "Greets you from the hub.",
  after       = { "dictation" },
  settings    = {
    greeting = { type = "string", default = "Hello" },
    volume   = { type = "number", default = 50, min = 0, max = 100 },
  },
}
```

`init.lua` returns a function. The registry calls it with one `plugin` object:

```lua
local menu = require("lib.ui").menu

return function(plugin)
  local count = 0
  local tile = plugin.tile()

  local function greet()
    count = count + 1
    plugin.ui:toast(plugin.settings.get("greeting"), { tone = "success" })
    tile:setTooltip("Said hello " .. count .. " times")
  end

  plugin.action("greet", greet)

  tile:setTitle("👋")
  tile:setMenu(function()
    return {
      menu.text("Said hello " .. count .. " times"),
      menu.separator(),
      menu.action("Say hello", greet),
    }
  end)

  plugin.ctx:timer(3600, function()
    plugin.ui:toast("An hour has passed")
  end)

  return {
    start = function() plugin.log("ready") end,
    stop  = function() plugin.log("bye") end,
  }
end
```

Reload, open the 🔨 panel, click the Hello tile and choose Say hello. From a shell,
`hs -c 'plugins = require("lib.plugins"); plugins.run("hello.greet")'` does the same.

When the plugin is switched off, `stop` runs (if you wrote one), then everything made
through `plugin.ctx` is undone: the tile, the timer and the action. You write no
cleanup code for those.

Two rules keep plugins switchable and consistent. Build through `plugin.ctx`, not
raw `hs.timer.new` and friends. Draw through `plugin.ui`, and never write a color,
font size or corner radius. A spec fails the build if a plugin does.

### Older plugins still work

A plugin with no `plugin.lua` loads as before. It `require`s what it needs and
returns a table, optionally with a `dispose()` function. Nothing about it has to
change. It just gets no manifest features: no ordering hints, no settings schema,
no plugin object.

## API reference

The current API version is **1**. It is `plugins.API` in `lib/plugins.lua`. A manifest
names the version it was written for in `api`. A plugin that asks for a newer version
than the config provides does not load, and the Plugins tile shows why. The version
only goes up when a change would break an existing plugin.

### Manifest fields

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | no | Must equal the folder name. Defaults to it. |
| `name` | string | no | Display name. Defaults to the id. |
| `version` | string | no | Your version of the plugin. Defaults to `0.0.0`. |
| `api` | whole number | no | The plugin API version it targets. Defaults to 1. |
| `author` | string | no | Who wrote it. |
| `description` | string | no | One line. |
| `after` | list of ids | no | Load after these, when they are installed. |
| `needs` | list of ids | no | Same ordering, and do not load unless these are running. |
| `settings` | table | no | Schema for the plugin's settings, below. |

A manifest with a wrong field fails that one plugin, with the reason on its row.
The manifest is read in an empty Lua environment, so it cannot call anything.

Load order starts from the list in `init.lua`, then alphabetical. `after` and `needs`
move a plugin to follow what it names and move nothing else. A circle of
dependencies cannot be ordered: those plugins keep their default place and a
warning goes to the console. Order is also tile order in the hub.

### Settings schema

Each entry is `name = { type = ..., default = ... }`. Types:

| Type | Extra keys |
|---|---|
| `boolean` | none |
| `number` | `min`, `max` |
| `string` | none |
| `choice` | `options`, a list of allowed values |

Values are stored in `hs.settings` under `plugin.<id>.<name>`, so they survive reloads.
A stored value that no longer fits the schema is ignored and the default is used.

### The plugin object

| Member | What it does |
|---|---|
| `plugin.id`, `plugin.manifest`, `plugin.api` | Who you are and which API is running. The manifest is `nil` for plugins without one. |
| `plugin.ctx` | The context. `ctx:timer`, `ctx:after`, `ctx:hotkey`, `ctx:task`, `ctx:url`, `ctx:watcher`, `ctx:eventtap`, `ctx:httpserver`, `ctx:atExit` and `ctx:effect(fn)` for anything else. Everything is undone on switch-off. See `lib/context.lua`. |
| `plugin.ui` | Shared components: `toast`, `hud`, `bar`, `notify`, `surface`. Pass a tone such as `success`, `working` or `danger`, never a color. See [DESIGN.md](DESIGN.md). |
| `plugin.tile(title)` | Adds a hub tile. It has `setTitle`, `setTooltip`, `setMenu` and `setClickCallback`. Build menu rows with `require("lib.ui").menu`. |
| `plugin.action(name, fn)` | Registers `<id>.<name>`. Anyone can run it with `plugins.run("<id>.<name>", ...)`. |
| `plugin.settings.get(key)` | The stored value, or the default. `nil` for a key not in the schema. |
| `plugin.settings.set(key, value)` | Returns `true`, or `false` and why. Fires the `settings` event. |
| `plugin.log(fmt, ...)` | A `string.format` line in the Hammerspoon console, tagged `[id]`. |
| `plugin.on(event, fn)` | Listens for an event and returns a function that stops listening. |

### Events

| Event | When | Arguments |
|---|---|---|
| `start` | After your entry function and `start` hook ran. | none |
| `stop` | When the plugin is switched off. | none |
| `settings` | After `plugin.settings.set` accepted a value. | key, value |
| `plugin:loaded` | Another plugin finished loading. | its id |
| `plugin:unloaded` | Another plugin was switched off. | its id |

A listener that throws is logged and does not stop the others.

### What your entry function returns

A table, or nothing. Two optional functions are used if present:

- `start(plugin)` runs after the entry function. If it throws, the plugin is torn
  down and marked failed.
- `stop(plugin)` runs on switch-off, before the context is cleaned up. You do not
  need it for anything the context owns.

Anything else on the table is yours. Other plugins can read it through
`plugins.loaded["your_id"]`.

### Discovery

The registry looks in `apps/` first, then in `plugins/`. A plugin is a folder with
an `init.lua`, or, for `apps/` only, a single `.lua` file. If a name exists in both
folders, the one in `apps/` loads. A folder with no `init.lua` is ignored.

### Registry functions

For scripts and tests: `plugins.loaded`, `plugins.failed`, `plugins.order`,
`plugins.run(name, ...)`, `plugins.enable(name)`, `plugins.disable(name)`,
`plugins.check(id, table)` to validate a manifest, and `plugins.activate(id, entry,
manifest)` to run an entry function directly in a spec.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
