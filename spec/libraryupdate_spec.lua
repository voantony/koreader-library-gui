-- Version comparison, the SHA256 line in release notes, and backup/restore.
local Update = require("libraryupdate")

local HASH = "17c1174b2ae2128ed545cd2d23c11dd4ec7755689e03aaad15c4f8887153a17a"

local function le16(n)
    n = n % 65536
    return string.char(n % 256, math.floor(n / 256))
end

local function le32(n)
    n = n % 4294967296
    return le16(n % 65536) .. le16(math.floor(n / 65536))
end

-- A stored (method 0) zip. `files` is { { name =, data = } }.
local function storedZip(files)
    local locals, central = {}, {}
    local offset = 0
    for i = 1, #files do
        local name, data = files[i].name, files[i].data or ""
        local crc = Update.crc32(data)
        local local_hdr = "PK\003\004"
            .. le16(20) .. le16(0) .. le16(0) .. le16(0) .. le16(0)
            .. le32(crc) .. le32(#data) .. le32(#data)
            .. le16(#name) .. le16(0)
            .. name .. data
        locals[#locals + 1] = local_hdr
        central[#central + 1] = "PK\001\002"
            .. le16(20) .. le16(20) .. le16(0) .. le16(0) .. le16(0) .. le16(0)
            .. le32(crc) .. le32(#data) .. le32(#data)
            .. le16(#name) .. le16(0) .. le16(0) .. le16(0) .. le16(0)
            .. le32(0) .. le32(offset)
            .. name
        offset = offset + #local_hdr
    end
    local local_blob = table.concat(locals)
    local central_blob = table.concat(central)
    local eocd = "PK\005\006"
        .. le16(0) .. le16(0)
        .. le16(#files) .. le16(#files)
        .. le32(#central_blob) .. le32(#local_blob)
        .. le16(0)
    return local_blob .. central_blob .. eocd
end

local function memfs()
    local tree = {}
    local function norm(path)
        if path ~= "/" then path = path:gsub("/+$", "") end
        return path
    end
    local fs = {}
    local writes = {}
    function fs.log() return writes end
    function fs.exists(path) return tree[norm(path)] ~= nil end
    function fs.isDir(path)
        local node = tree[norm(path)]
        return node ~= nil and node.kind == "dir"
    end
    function fs.list(path)
        path = norm(path)
        local prefix = path .. "/"
        local seen, names = {}, {}
        for full in pairs(tree) do
            if full:sub(1, #prefix) == prefix then
                local name = full:sub(#prefix + 1):match("^([^/]+)")
                if name and not seen[name] then
                    seen[name] = true
                    names[#names + 1] = name
                end
            end
        end
        table.sort(names)
        return names
    end
    function fs.mkDir(path)
        path = norm(path)
        writes[#writes + 1] = path
        if tree[path] and tree[path].kind ~= "dir" then return nil, "file exists" end
        tree[path] = { kind = "dir" }
        return true
    end
    function fs.writeFile(path, data)
        path = norm(path)
        writes[#writes + 1] = path
        tree[path] = { kind = "file", data = data }
        return true
    end
    function fs.read(path)
        local node = tree[norm(path)]
        if not node or node.kind ~= "file" then return nil end
        return node.data
    end
    function fs.removeFile(path)
        path = norm(path)
        writes[#writes + 1] = path
        if not tree[path] or tree[path].kind ~= "file" then return nil, "missing" end
        tree[path] = nil
        return true
    end
    function fs.removeDir(path)
        path = norm(path)
        writes[#writes + 1] = path
        if not tree[path] or tree[path].kind ~= "dir" then return nil, "missing" end
        tree[path] = nil
        return true
    end
    function fs.rename(src, dst)
        src, dst = norm(src), norm(dst)
        writes[#writes + 1] = dst
        if not tree[src] then return nil, "missing" end
        if tree[dst] then return nil, "exists" end
        local prefix = src .. "/"
        local moves = {}
        for path, node in pairs(tree) do
            if path == src or path:sub(1, #prefix) == prefix then
                moves[#moves + 1] = { path, dst .. path:sub(#src + 1), node }
            end
        end
        for i = 1, #moves do tree[moves[i][1]] = nil end
        for i = 1, #moves do tree[moves[i][2]] = moves[i][3] end
        return true
    end
    function fs.seed(path, node)
        tree[norm(path)] = node
    end
    return fs
end

local function seedPlugin(fs, dir, files)
    fs.seed(dir, { kind = "dir" })
    for name, data in pairs(files) do
        local path = dir .. "/" .. name
        local parent = path:match("^(.*)/[^/]+$")
        if parent and not fs.isDir(parent) then fs.seed(parent, { kind = "dir" }) end
        fs.seed(path, { kind = "file", data = data })
    end
end

describe("version comparison", function()
    it("orders dotted numbers, including a double digit", function()
        eq(Update.compareVersions("0.7.0", "0.7.1"), -1)
        eq(Update.compareVersions("0.7.1", "0.7.0"), 1)
        eq(Update.compareVersions("0.7.1", "0.7.1"), 0)
        eq(Update.compareVersions("0.7.10", "0.7.9"), 1)
        eq(Update.compareVersions("0.7.9", "0.7.10"), -1)
        eq(Update.compareVersions("0.8.0", "0.7.10"), 1)
        eq(Update.compareVersions("0.10.0", "0.9.0"), 1)
        eq(Update.compareVersions("v0.7.1", "0.7.1"), 0)
        eq(Update.compareVersions("V0.8", "0.7.9"), 1)
    end)

    it("treats a missing segment as zero and rejects junk", function()
        eq(Update.compareVersions("0.8", "0.8.0"), 0)
        eq(Update.compareVersions("0.7", "0.7.1"), -1)
        eq(Update.compareVersions("0.7.1-beta", "0.7.1"), nil)
        eq(Update.compareVersions("latest", "0.7.1"), nil)
        eq(Update.isNewer("0.7.1", "0.7.0"), true)
        eq(Update.isNewer("0.7.1", "0.7.1"), false)
        eq(Update.isNewer("0.7.0", "0.7.1"), false)
        eq(Update.isNewer("nope", "0.7.1"), nil)
        eq(Update.offerState("0.7.2", "0.7.0"), "newer")
        eq(Update.offerState("0.7.1", "0.7.1"), "current")
        eq(Update.offerState("0.7.2", nil), "unknown")
    end)

    it("reads the version the Makefile stamps into _meta.lua", function()
        eq(Update.readVersion('version = "0.7.1"'), "0.7.1")
        eq(Update.readVersion("version='0.7.0'"), "0.7.0")
        eq(Update.readVersion("fullname = \"Library GUI\"\n"), nil)
        eq(Update.tagVersion("v0.7.1"), "0.7.1")
        eq(Update.tagVersion("0.7.1"), "0.7.1")
        eq(Update.tagVersion("nightly"), nil)
    end)
end)

describe("SHA256 line in release notes", function()
    it("reads SHA256: hex and the backtick form v0.7.1 published", function()
        eq(Update.parseSha256("SHA256: " .. HASH), HASH)
        eq(Update.parseSha256("SHA256:" .. HASH), HASH)
        eq(Update.parseSha256("SHA256: `" .. HASH .. "`"), HASH)
        local published = "**Kindle zip:** `library.koplugin-v0.7.1.zip`, SHA256 `" .. HASH .. "`."
        eq(Update.parseSha256(published), HASH)
        eq(Update.parseSha256("sha256: " .. HASH:upper()), HASH)
    end)

    it("rejects a missing, short, or over-long hash", function()
        eq(Update.parseSha256("No checksum here."), nil)
        eq(Update.parseSha256(""), nil)
        eq(Update.parseSha256(nil), nil)
        eq(Update.parseSha256("SHA256: abcdef"), nil)
        eq(Update.parseSha256("SHA256: " .. HASH .. "aa"), nil)
    end)

    it("uses the first hash and drops that line from the short changelog", function()
        local other = string.rep("ab", 32)
        local notes = "Fixes a crash.\n\nSHA256: " .. HASH .. "\nAlso SHA256: " .. other
        eq(Update.parseSha256(notes), HASH)
        local short = Update.shortNotes(notes)
        eq(short:find("Fixes a crash.", 1, true) ~= nil, true)
        eq(short:find("SHA256", 1, true), nil)
        eq(short:find(HASH, 1, true), nil)
    end)

    it("turns release markup into plain text and drops the unzip line", function()
        local notes = "Hello **bold** [v0.7.1](https://example.test/x).\n\nUnzip into `koreader/plugins/`."
        local short = Update.shortNotes(notes)
        eq(short:find("**", 1, true), nil)
        eq(short:find("https://", 1, true), nil)
        eq(short:find("v0.7.1", 1, true) ~= nil, true)
        eq(short:find("Unzip", 1, true), nil)
        eq(short:find("bold", 1, true) ~= nil, true)
    end)
end)

describe("release document", function()
    it("picks the generic package zip and ignores source archives", function()
        local body = [[{"tag_name":"v0.7.1","description":"Fixes a crash.\n\nSHA256: ]]
            .. HASH .. [[","assets":{"links":[
            {"name":"library.koplugin-v0.7.1.zip (Kindle)","url":"https://gitlab.com/api/v4/projects/1/packages/generic/library-gui/0.7.1/library.koplugin-v0.7.1.zip"},
            {"name":"source","url":"https://gitlab.com/example/archive.zip"}
        ]}}]]
        local release = Update.decodeRelease(body)
        eq(release.tag_name, "v0.7.1")
        eq(Update.parseSha256(release.description), HASH)
        local asset = Update.pickAsset(release, "0.7.1")
        eq(asset.name, "library.koplugin-v0.7.1.zip")
        eq(asset.url:find("/packages/generic/", 1, true) ~= nil, true)
        eq(Update.pickAsset(release, "0.7.0"), nil)
        local list = Update.decodeRelease("[" .. body .. "]")
        eq(Update.normalizeRelease(list).tag_name, "v0.7.1")
    end)

    it("decodes a JSON string escape", function()
        local value = Update.decodeJson('{"description":"line\\nnext"}')
        eq(value.description, "line\nnext")
    end)
end)

describe("automatic update modes", function()
    local function ctx(over)
        local base = { due = true, wifi = true, book_open = false }
        for k, v in pairs(over or {}) do base[k] = v end
        return base
    end

    it("treats an unset choice as Notify me", function()
        eq(Update.mode(nil), "notify")
        eq(Update.mode({}), "notify")
        eq(Update.mode({ update_mode = "nope" }), "notify")
        eq(Update.mode({ update_mode = "off" }), "off")
        eq(Update.mode({ update_mode = "install" }), "install")
        eq(Update.mode({ check_updates_weekly = false }), "notify")
    end)

    it("does no background work when checks are off", function()
        eq(Update.planBackground("off", ctx()), "none")
        eq(Update.planBackground("off", ctx({ book_open = true })), "none")
        eq(Update.planBackground("off", ctx({ due = false, wifi = false })), "none")
    end)

    it("notifies only when a weekly check is due and Wi-Fi is already on", function()
        eq(Update.planBackground("notify", ctx()), "notify")
        eq(Update.planBackground("notify", ctx({ book_open = true })), "notify")
        eq(Update.planBackground("notify", ctx({ due = false })), "none")
        eq(Update.planBackground("notify", ctx({ wifi = false })), "none")
        eq(Update.planBackground(nil, ctx()), "notify")
    end)

    it("installs quietly only when Wi-Fi is already on and no book is open", function()
        eq(Update.planBackground("install", ctx()), "install")
        eq(Update.planBackground("install", ctx({ book_open = true })), "defer")
        eq(Update.planBackground("install", ctx({ wifi = false })), "none")
        eq(Update.planBackground("install", ctx({ due = false })), "none")
        eq(Update.planBackground("install", ctx({ due = false, book_open = true })), "none")
    end)
end)

describe("weekly check schedule", function()
    it("is due when never checked, and not again for seven days", function()
        local now = 1700000000
        eq(Update.weeklyDue(nil, now, nil), true)
        eq(Update.weeklyDue(now - Update.WEEK_SECONDS + 1, now, nil), false)
        eq(Update.weeklyDue(now - Update.WEEK_SECONDS, now, nil), true)
        eq(Update.weeklyDue(nil, now, now - 60), false)
        eq(Update.weeklyDue(nil, now, now - Update.DAY_SECONDS), true)
    end)
end)

describe("backup and restore", function()
    local plugin = "/koreader/plugins/library.koplugin"
    local bak = plugin .. ".bak"

    it("replaces an older .bak and leaves settings alone", function()
        local fs = memfs()
        seedPlugin(fs, plugin, { ["main.lua"] = "current", ["extra.lua"] = "keep" })
        seedPlugin(fs, bak, { ["main.lua"] = "stale" })
        seedPlugin(fs, "/stage/library.koplugin", { ["main.lua"] = "new" })
        local settings = "/koreader/settings/settings.reader.lua"
        fs.seed("/koreader/settings", { kind = "dir" })
        fs.seed(settings, { kind = "file", data = "do-not-touch" })
        local ok, err = Update.installReplacing(fs, plugin, "/stage/library.koplugin")
        eq(err, nil)
        eq(ok, true)
        eq(fs.read(plugin .. "/main.lua"), "new")
        eq(fs.read(bak .. "/main.lua"), "current")
        eq(fs.read(bak .. "/extra.lua"), "keep")
        eq(fs.read(settings), "do-not-touch")
        eq(fs.exists("/stage/library.koplugin/main.lua"), false)
        for i = 1, #fs.log() do
            eq(fs.log()[i]:find("/settings/", 1, true), nil)
        end
    end)

    it("puts the backup back when the install fails after it", function()
        local fs = memfs()
        seedPlugin(fs, plugin, { ["main.lua"] = "current", ["extra.lua"] = "keep" })
        seedPlugin(fs, "/stage/library.koplugin", { ["main.lua"] = "new" })
        local rename_blocks = 1
        local real_rename = fs.rename
        function fs.rename(src, dst)
            if dst == plugin and rename_blocks > 0 then
                rename_blocks = rename_blocks - 1
                return nil, "disk full"
            end
            return real_rename(src, dst)
        end
        local copy_blocks = 1
        local real_copy = Update.copyTree
        Update.copyTree = function(fs_, src, dst)
            if dst == plugin and copy_blocks > 0 then
                copy_blocks = copy_blocks - 1
                return nil, "disk full"
            end
            return real_copy(fs_, src, dst)
        end
        local ok, err = Update.installReplacing(fs, plugin, "/stage/library.koplugin")
        Update.copyTree = real_copy
        eq(ok, nil)
        eq(type(err) == "string" and err:find("restored", 1, true) ~= nil, true)
        eq(fs.read(plugin .. "/main.lua"), "current")
        eq(fs.read(plugin .. "/extra.lua"), "keep")
        eq(fs.exists(bak), false)
    end)

    it("refuses to write inside koreader/settings", function()
        local fs = memfs()
        local inside = "/koreader/settings/library.koplugin"
        seedPlugin(fs, inside, { ["main.lua"] = "current" })
        seedPlugin(fs, "/stage/library.koplugin", { ["main.lua"] = "new" })
        local ok, err = Update.installReplacing(fs, inside, "/stage/library.koplugin")
        eq(ok, nil)
        eq(err:find("settings", 1, true) ~= nil, true)
        eq(fs.read(inside .. "/main.lua"), "current")
    end)

    it("unpacks a stored zip and rejects a path that escapes the plugin", function()
        local fs = memfs()
        local bytes = storedZip({
            { name = "library.koplugin/", data = "" },
            { name = "library.koplugin/main.lua", data = "hello" },
        })
        local entries = Update.entriesFromZip(bytes)
        eq(#entries, 2)
        local ok = Update.materialize(entries, fs, "/stage", function()
            error("stored zip should not inflate")
        end)
        eq(ok, true)
        eq(fs.read("/stage/library.koplugin/main.lua"), "hello")

        local evil = storedZip({
            { name = "library.koplugin/../../outside.txt", data = "nope" },
        })
        local bad = Update.entriesFromZip(evil)
        local mok, merr = Update.materialize(bad, fs, "/stage")
        eq(mok, nil)
        eq(merr:find("unsafe", 1, true) ~= nil, true)
        eq(fs.exists("/outside.txt"), false)
        eq(fs.exists("/stage/outside.txt"), false)
    end)
end)

describe("checksum", function()
    it("matches the CRC-32 of a known string", function()
        eq(Update.crc32(""), 0)
        eq(Update.crc32("123456789"), 0xCBF43926)
    end)
end)
