# Design

Every plugin in this config draws with the same components and the same tokens, so the whole config looks like one app. This file is the brief for a person or an agent adding or changing anything a plugin shows on screen. Read it before you write UI code here.

## Where the look lives

- `designs/<name>.lua` is a design: the colors, fonts, sizes, corners and hub layout that differ from the defaults. One design is active at a time, and you can switch whenever you like.
- `lib/theme.lua` holds the defaults and merges the active design over them. No plugin names a color or a size.
- `lib/ui.lua` holds the components. A plugin reaches them through its context with `local ui = ctx:ui()`.
- `lib/menuhub_panel.html` is the hub panel. Its colors, corners, fonts, sizes and column count come from `theme.css()`, which menuhub puts in place of the `/*@theme*/` marker, so a design changes the panel and the overlays together.
- `tests/spec/design_spec.lua` builds every design and fails when its text doesn't read on its panel.
- `tests/spec/design_rules_spec.lua` fails the build when a plugin writes a color table, a corner radius, a raw point size, `hs.alert`, `hs.notify.new` or `ctx:canvas(` itself. The failure message names the component to use instead.

Run `hs -c 'uiGallery()'`, or pick "Preview the UI kit" in the Plugins tile, to see every component on screen.

## Pick a component

| You want to | Use |
|---|---|
| Say something happened ("Copied", "Nothing selected") | `ui:toast(text, { tone, seconds })` |
| Show a state that lasts until you end it ("Recording", "Transcribing") | `local _, hide = ui:hud(text, { tone })` |
| Offer a few actions on something without stealing focus | `ui:bar(name, { pick, hover })`, then `bar:show(state)` |
| Tell the user something they may read later | `ui:notify(text, { title, subtitle, onClick })` |
| Build a tile's menu | `ui.menu.switch`, `choice`, `action`, `slider`, `submenu`, `text`, `separator` |
| Draw something no component covers (a lyric sweep, a growing transcript) | `ui:surface(name, frame, opts)` with `ui.backdrop`, `ui.label`, `ui.dot`, `ui.button` |

A toast replaces whatever toast is up, from any plugin, so messages never stack. A HUD and a surface are named, so drawing one again replaces the last. Everything goes through the plugin's context and leaves when the plugin is switched off.

Use a surface only when no component fits. If two plugins draw the same kind of surface, move it into `lib/ui.lua` as a component.

## Tones

Pass a meaning, never a color. `theme.tones` maps each meaning to a color. The colors below are the default design's.

| Tone | Color | Use it for |
|---|---|---|
| `success` | green | something finished and worked |
| `danger`, `error` | red | something failed, or will cost the user something |
| `warning` | orange | refused or blocked, nothing lost |
| `working` | orange | waiting on a model, a server, the mic |
| `recording` | red | the mic is live |
| `draft` | yellow | text that may still change |
| `info`, `accent` | blue | a neutral highlight |
| `neutral` | grey | the default |

Leave out the tone when the message carries no status. A dot on every toast stops meaning anything.

## Placement

`ui.place` has five positions. Each component has a default, and a caller should rarely override it.

- `center` holds a HUD: state the user is watching.
- `lower` holds a toast, two-thirds down the screen where macOS puts its own volume HUD.
- `caption` holds text that grows upward as it arrives, like dictation's live preview.
- `bottom` holds a bar just above the Dock, close to where the hand goes.
- `top` sits under the menu bar.

Overlays never take focus. A plugin that pastes or types into the frontmost app depends on that.

## Writing on screen

- Use sentence case: "Nothing selected", not "Nothing Selected" or "nothing selected".
- Keep a toast to one line of about 60 characters. Use `utils.truncate` on anything the user wrote.
- Name the thing and the result: "Copied: the quick brown…", "⌘W blocked in Windows App · press again to close".
- Separate parts with " · ", not a dash.
- End with "…" only while work is still running: "Transcribing…".
- Say what failed and what is left: "Couldn't rewrite: not logged in", "Kept the original".

## Menus

Every tile's menu renders as grouped lists in the hub panel and as a plain dropdown on Option-click. Build rows with `ui.menu`, so the same row kind looks the same in every tile.

- Put the main switch first: `menu.switch("Show lyrics", on, toggle)`.
- Put status lines under it as `menu.text(...)`. A text row at the top of a group becomes that group's caption.
- Use `menu.choice` for one-of-several pickers, so the hub draws the ✓ on the right.
- Use `menu.separator()` between groups, not blank rows.
- Grey out an action that cannot run now with `{ disabled = true }`, instead of hiding it.

## Changing the look

Write or edit a file in `designs/`. `designs/default.lua` lists every key a design can set, with its default. Then:

```sh
make test-lua                         # every design builds and reads
hs -c 'return uiDesign("warm")'       # switch and reload; the gallery runs after
hs -c 'return uiShoot("/tmp/hs-design/warm")'   # toast, HUD, bar and hub as PNGs
hs -c 'return uiDesign("default")'    # back
```

The 🧩 Plugins tile has the same switch under Design. The repo ships five designs: default, warm, light, compact and terminal. A file named `_something.lua` is a draft and stays out of the menu.

Edit `lib/theme.lua` only to change a default for every design, or to add a token. Name a new token by its role (`textSecondary`, `control`), not by its look (`grey60`).

Overlays follow the system appearance by default (`overlay = "auto"`). When macOS switches between light and dark, `lib/plugins.lua` hears it and `theme.refresh()` rewrites the overlay colors in place, with no reload. A surface that stays on screen redraws through `ctx:ui():onAppearance(fn)`, which is how the karaoke island changes mid-song. A design whose colors only work one way sets `overlay = "dark"` or `"light"`, as warm, terminal and light do. A design can also put `light = { color = ... }` and `dark = { color = ... }` blocks beside its shared colors. The hub panel always follows the system. hs.canvas cannot blur, which is why a surface should stay at 95% opacity or more.

## Starting a plugin

`make plugin NAME=my_app TITLE="My app"` copies `templates/plugin/init.lua` to `apps/my_app/init.lua`. The template already builds its tile from `ui.menu` and shows a toast and a HUD. `tests/spec/design_rules_spec.lua` loads the template too, so it stays correct.
