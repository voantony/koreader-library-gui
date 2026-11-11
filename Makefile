# KOReader's own LuaJIT works too, e.g. LUA=/path/to/koreader/luajit
LUA ?= luajit
PLUGIN := library.koplugin
VERSION ?= 0.7.7
# Optional. A KOReader tag (v2025.04) or dev revision (v2025.04-42).
# `make zip` writes it as `Requires KOReader:` in dist/release-notes.txt,
# next to the zip's SHA256 line. Paste both into the GitLab release notes.
# The in-plugin updater reads that line before downloading and will not
# install when the installed KOReader is older. It never updates KOReader.
# Leave this empty to keep today's behaviour (no minimum).
KOREADER_REQUIRES ?=
FILES := _meta.lua main.lua librarycore.lua librarystatus.lua libraryindex.lua libraryview.lua librarytile.lua librarycovers.lua librarykeyboard.lua librarycontrols.lua librarydetails.lua libraryreadermenu.lua libraryreaderpanel.lua librarybezel.lua libraryfooter.lua libraryrefresh.lua libraryreturn.lua libraryreadability.lua librarysuggest.lua librarytiming.lua libraryscrubber.lua libraryzones.lua librarygestures.lua librarywidgets.lua libraryupdate.lua libraryyear.lua

.PHONY: test zip stage clean

test:
	$(LUA) spec/run.lua

# Exactly the files that go to the device.
stage: clean
	mkdir -p dist/$(PLUGIN)
	cd $(PLUGIN) && cp $(FILES) ../dist/$(PLUGIN)/
	STAMP_PATH='dist/$(PLUGIN)/_meta.lua' VERSION='$(VERSION)' $(LUA) -e 'local p,v=os.getenv("STAMP_PATH"),os.getenv("VERSION"); local f=assert(io.open(p,"rb")); local s=f:read("*a"); f:close(); local n,c=s:gsub("(version%s*=%s*\")[^\"]*(\")", "%1"..v.."%2", 1); if c~=1 then error("could not stamp version in "..p) end; f=assert(io.open(p,"wb")); f:write(n); f:close()'
	cd dist/$(PLUGIN) && shasum -a 256 $(FILES) > ../SHA256SUMS 2>/dev/null || sha256sum $(FILES) > ../SHA256SUMS

zip: stage
	cd dist && zip -rX library.koplugin-v$(VERSION).zip $(PLUGIN) && (shasum -a 256 library.koplugin-v$(VERSION).zip 2>/dev/null || sha256sum library.koplugin-v$(VERSION).zip) >> SHA256SUMS
	@hash=$$( (shasum -a 256 "dist/library.koplugin-v$(VERSION).zip" 2>/dev/null || sha256sum "dist/library.koplugin-v$(VERSION).zip") | awk '{print $$1}' ); \
	printf 'SHA256: %s\n' "$$hash" > dist/release-notes.txt; \
	if [ -n "$(KOREADER_REQUIRES)" ]; then \
	  REQ='$(KOREADER_REQUIRES)' $(LUA) -e 'local u=dofile("library.koplugin/libraryupdate.lua"); local r=os.getenv("REQ"); if not u.normalizeKoreaderVersion(r) then error("KOREADER_REQUIRES is not a KOReader version ("..tostring(r).."). Use vYYYY.MM or vYYYY.MM-N.") end' || exit 1; \
	  printf 'Requires KOReader: %s\n' "$(KOREADER_REQUIRES)" >> dist/release-notes.txt; \
	fi; \
	echo "Paste dist/release-notes.txt into the GitLab release notes."; \
	cat dist/release-notes.txt

clean:
	rm -rf dist
