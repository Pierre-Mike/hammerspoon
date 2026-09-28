.PHONY: test test-lua test-noseguard install-deps

install-deps:
	luarocks install busted

test: test-lua test-noseguard

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
