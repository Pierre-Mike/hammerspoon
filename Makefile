.PHONY: test test-lua test-noseguard install-deps

install-deps:
	luarocks install busted

test: test-lua test-noseguard

test-lua:
	cd $(HOME)/.hammerspoon && \
	  LUA_PATH="./?.lua;./tests/mocks/?.lua;;" \
	  busted --config-file=tests/.busted

# nose_geom.py has no third-party imports, so this needs neither the noseguard
# venv nor a camera. Runs against this checkout, not $HOME/.hammerspoon, so it
# still means something from a worktree.
REPO := $(dir $(lastword $(MAKEFILE_LIST)))

test-noseguard:
	cd $(REPO) && python3 -m unittest discover apps/noseguard/tests
