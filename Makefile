.PHONY: test install-deps

install-deps:
	luarocks install busted

test:
	cd $(HOME)/.hammerspoon && \
	  LUA_PATH="./?.lua;./tests/mocks/?.lua;;" \
	  busted --config-file=tests/.busted
