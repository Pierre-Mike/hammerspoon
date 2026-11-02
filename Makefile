.PHONY: test test-lua test-noseguard test-dictate test-pronunciation install-deps plugin

install-deps:
	luarocks install busted

test: test-lua test-noseguard test-dictate test-pronunciation

# Both suites run against the checkout this Makefile lives in, never
# $HOME/.hammerspoon — otherwise `make test` from a git worktree would silently
# grade the live config instead of the branch under test.
REPO := $(dir $(lastword $(MAKEFILE_LIST)))

test-lua:
	cd $(REPO) && \
	  LUA_PATH="./?.lua;./tests/mocks/?.lua;;" \
	  busted --config-file=tests/.busted

# nose_geom.py has no third-party imports, so this needs neither the noseguard
# venv nor a camera.

test-noseguard:
	cd $(REPO) && python3 -m unittest discover apps/noseguard/tests

# The live-dictation commit rule. stream.py needs numpy, so the run brings its
# own rather than borrowing parakeet-mlx's interpreter.
test-dictate:
	cd $(REPO) && uv run --no-project --with pytest --with numpy python -m pytest -q dictate/tests

# The word scoring behind dictation's pronunciation lessons. align.py is pure,
# so this needs neither the phoneme model nor espeak.
test-pronunciation:
	cd $(REPO) && uv run --no-project --with pytest python -m pytest -q -p no:cacheprovider apps/dictation/scorer/tests

# A new plugin from templates/plugin: `make plugin NAME=my_app TITLE="My app"`.
# NAME is the folder and the manifest id. TITLE is the tile's name and defaults
# to NAME. Refuses to overwrite. Set DIR=plugins to put it in the optional
# plugins/ folder instead of apps/.
TITLE ?= $(NAME)
DIR ?= apps
plugin:
	@test -n "$(NAME)" || { echo "usage: make plugin NAME=my_app [TITLE=\"My app\"] [DIR=apps|plugins]"; exit 1; }
	@echo "$(NAME)" | grep -Eq '^[a-z][a-z0-9_]*$$' || { echo "NAME must be lowercase letters, digits and underscores"; exit 1; }
	@test ! -e $(REPO)$(DIR)/$(NAME) || { echo "$(DIR)/$(NAME) already exists"; exit 1; }
	mkdir -p $(REPO)$(DIR)/$(NAME)
	sed -e 's/"template"/"$(NAME)"/g' -e 's/Template/$(TITLE)/g' -e 's/template\.hello/$(NAME).hello/g' \
	  $(REPO)templates/plugin/plugin.lua > $(REPO)$(DIR)/$(NAME)/plugin.lua
	sed -e 's/Template/$(TITLE)/g' -e 's/template\.hello/$(NAME).hello/g' \
	  $(REPO)templates/plugin/init.lua > $(REPO)$(DIR)/$(NAME)/init.lua
	@echo "$(DIR)/$(NAME) created. Reload Hammerspoon: hs -c 'hs.reload()'"
