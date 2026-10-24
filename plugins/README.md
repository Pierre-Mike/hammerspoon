# plugins

Optional. Put your own plugins here, one folder each, with the same layout as
`apps/<name>/`: an `init.lua` and a `plugin.lua`. This folder is git-ignored, so
your plugins stay out of the repo.

    make plugin NAME=my_plugin DIR=plugins

If a name exists in both `apps/` and `plugins/`, the one in `apps/` loads.
See the README for the plugin API.
