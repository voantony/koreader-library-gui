# KOReader's own LuaJIT works too, e.g. LUA=/path/to/koreader/luajit
LUA ?= luajit
PLUGIN := library.koplugin
VERSION ?= 0.3.0
FILES := _meta.lua main.lua librarycore.lua libraryindex.lua libraryview.lua librarytile.lua librarycovers.lua librarykeyboard.lua librarycontrols.lua librarydetails.lua libraryreadermenu.lua libraryreaderpanel.lua librarybezel.lua librarysuggest.lua librarytiming.lua

.PHONY: test zip stage clean

test:
	$(LUA) spec/run.lua

# Exactly the files that go to the device.
stage: clean
	mkdir -p dist/$(PLUGIN)
	cd $(PLUGIN) && cp $(FILES) ../dist/$(PLUGIN)/
	cd dist/$(PLUGIN) && shasum -a 256 $(FILES) > ../SHA256SUMS 2>/dev/null || sha256sum $(FILES) > ../SHA256SUMS

zip: stage
	cd dist && zip -rX library-gui-$(VERSION).zip $(PLUGIN) && (shasum -a 256 library-gui-$(VERSION).zip 2>/dev/null || sha256sum library-gui-$(VERSION).zip) >> SHA256SUMS

clean:
	rm -rf dist
