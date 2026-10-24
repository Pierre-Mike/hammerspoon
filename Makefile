.PHONY: test test-lua test-noseguard test-dictate install-deps plugin

install-deps:
	luarocks install busted

test: test-lua test-noseguard test-dictate

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

# A new plugin from templates/plugin: `make plugin NAME=my_app TITLE="My app"`.
# TITLE is the tile's name and defaults to NAME. Refuses to overwrite.
TITLE ?= $(NAME)
plugin:
	@test -n "$(NAME)" || { echo "usage: make plugin NAME=my_app [TITLE=\"My app\"]"; exit 1; }
	@test ! -e $(REPO)apps/$(NAME) || { echo "apps/$(NAME) already exists"; exit 1; }
	mkdir -p $(REPO)apps/$(NAME)
	sed -e 's/Template/$(TITLE)/g' $(REPO)templates/plugin/init.lua > $(REPO)apps/$(NAME)/init.lua
	@echo "apps/$(NAME)/init.lua created. Reload Hammerspoon: hs -c 'hs.reload()'"
