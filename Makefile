LUA ?= luajit
PLUGIN := library.koplugin

.PHONY: test zip clean

test:
	$(LUA) spec/run.lua

zip: clean
	mkdir -p dist
	zip -r dist/$(PLUGIN).zip $(PLUGIN) -x '*/.*'

clean:
	rm -rf dist
