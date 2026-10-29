# KOReader's own LuaJIT works too, e.g. LUA=/path/to/koreader/luajit
LUA ?= luajit
PLUGIN := library.koplugin
FILES := _meta.lua main.lua librarycore.lua libraryindex.lua libraryview.lua librarytile.lua

.PHONY: test zip stage clean

test:
	$(LUA) spec/run.lua

# Exactly the files that go to the device (see INSTALL_PLAN.md).
stage: clean
	mkdir -p dist/$(PLUGIN)
	cd $(PLUGIN) && cp $(FILES) ../dist/$(PLUGIN)/
	cd dist/$(PLUGIN) && shasum -a 256 $(FILES) > ../SHA256SUMS 2>/dev/null || sha256sum $(FILES) > ../SHA256SUMS

zip: stage
	cd dist && zip -r $(PLUGIN).zip $(PLUGIN)

clean:
	rm -rf dist
