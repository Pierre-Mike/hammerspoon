# Contributing

Thanks for taking a look. This repo is a Hammerspoon setup and a plugin system.
Fixes, new plugins and improvements to the plugin API are all welcome.

## Before you start

For anything bigger than a small fix, open an issue first and describe what you
want to change. That saves you from building something that does not fit.

A plugin that only suits your own machine is better kept in your own repo. You can
symlink it into `plugins/`, which is git-ignored, and it loads like any other.

## Set up

You need [Lua 5.4](https://www.lua.org/) (Hammerspoon embeds 5.4) and
[busted](https://lunarmodules.github.io/busted/):

```sh
make install-deps
make test
```

`make test` runs the Lua specs, the NoseGuard geometry tests and the dictation
tests. The Lua specs run against a mock of `hs.*` in `tests/mocks/hs.lua`, so they
need no Mac and no Hammerspoon. CI runs `make test-lua`, so that one must pass
before a pull request can merge. The Python suites need Python 3.13, and
`test-dictate` needs [uv](https://docs.astral.sh/uv/).

## Add a plugin

```sh
make plugin NAME=my_plugin TITLE="My plugin"
```

Edit `apps/my_plugin/plugin.lua` and `apps/my_plugin/init.lua`. The
[README](README.md#write-a-plugin) has a worked example and the API reference.

A plugin in `apps/` should:

- Have a `plugin.lua` manifest with a one-line `description` and the `api` version it
  targets.
- Build everything through `plugin.ctx`, so switching it off removes it completely.
- Draw through `plugin.ui` and never write a color, font size or corner radius.
  `tests/spec/design_rules_spec.lua` checks this.
- Say in the tile what is wrong when a tool or permission is missing, and then do
  nothing else.
- Keep paths, keys and personal settings out of the code. Read them from
  `hs.settings` or the manifest's `settings`.
- Come with a spec in `tests/spec/` that covers its logic. Put pure logic in `lib/`
  so a spec can reach it without Hammerspoon.

## Change the plugin API

`plugins.API` in `lib/plugins.lua` is the version outsiders write against. Adding a
field or a function does not change it. Removing or renaming one, or changing what
it means, does: bump the number, say so in the pull request, and keep the old
behavior working for manifests that name the old version where you can.

Every change to `lib/plugins.lua` needs a spec in `tests/spec/plugins_spec.lua`. The
README example is run by `tests/spec/readme_example_spec.lua`, so keep the two in
step.

## Pull requests

- Keep each pull request to one change.
- Write commit messages in the imperative: "Add a settings row", not "Added".
- Say what you ran. `make test` output in the description is enough.
- Do not commit secrets, `.env` files, model files or large binaries. The
  `.gitignore` covers the usual ones. Say in the README how to get an asset instead.
- Write plain, direct prose in docs and comments, and sentence-case headings.

## Reporting a problem

Open an issue with your macOS version, the Hammerspoon version, and the console
output. A plugin that failed to load shows the reason on its row in the 🧩 Plugins
tile.
