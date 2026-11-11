--[[--
Check GitLab for a newer Library GUI release and install it.

The plugin folder is only code. Settings live in KOReader's settings
(G_reader_settings, library_index.lua). Cover thumbnails and the timing
log live under KOReader's data directory. Replacing library.koplugin
does not touch those.

The installed version is the `version` field in _meta.lua. `make zip`
stamps that field in the staged copy from the Makefile VERSION.

A release is newer when its tag is a higher dotted version. The zip is
the generic-package asset named library.koplugin-vX.zip. Its SHA256 is
the `SHA256: <hex>` line in the release notes. v0.7.1 published that
hash as `SHA256 `<hex>``; both forms are accepted. A missing or
mismatched hash aborts before the plugin folder is changed.

A release that needs a newer KOReader says so on the next line,
`Requires KOReader: v2025.04`. A dev revision (`v2025.04-42`, the
commits-after-tag form from KOReader's git-rev) is allowed. The line is
read from the release notes before the zip is downloaded. The installed
revision comes from KOReader's version module (`getCurrentRevision` /
`getNormalizedCurrentVersion`) and is compared with the same weights
that module uses. Older than the line: the zip is not downloaded, and
KOReader itself is not updated. No line, or a version that cannot be
parsed, leaves the update alone.

On KOReader v2025.08 and newer the zip is unpacked with ffi/archiver
(the same libarchive the Archive viewer uses). v2025.04 Kindle packages
have no libarchive and no unzip binary, so the fallback is zlib's raw
inflate, then an `unzip` on PATH if one exists.
]]

local M = {}

M.PLUGIN_DIRNAME = "library.koplugin"
M.WEEK_SECONDS = 7 * 24 * 60 * 60
M.DAY_SECONDS = 24 * 60 * 60
M.NOTES_LIMIT = 700
M.PROJECT = "antonyvo%2Fkoreader-library-gui"
M.LATEST_URL = "https://gitlab.com/api/v4/projects/" .. M.PROJECT .. "/releases/permalink/latest"
M.FALLBACK_URL = "https://gitlab.com/api/v4/projects/" .. M.PROJECT .. "/releases?per_page=1"

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split "v0.7.10" into {0, 7, 10}. Nil when it is not a dotted version.
function M.splitVersion(v)
    if type(v) ~= "string" then return nil end
    v = trim(v)
    if v:sub(1, 1) == "v" or v:sub(1, 1) == "V" then v = v:sub(2) end
    -- Lua patterns cannot repeat a group, so rebuild the dotted form.
    if v == "" or v:find("[^0-9%.]") or v:find("..", 1, true) then return nil end
    if v:sub(1, 1) == "." or v:sub(-1) == "." then return nil end
    local parts = {}
    for n in v:gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
    if #parts < 2 then return nil end
    if table.concat(parts, ".") ~= v then return nil end
    return parts
end

--- -1 when a is older, 0 when equal, 1 when a is newer. Nil if either
-- string is not a version.
function M.compareVersions(a, b)
    local pa, pb = M.splitVersion(a), M.splitVersion(b)
    if not pa or not pb then return nil end
    local n = #pa
    if #pb > n then n = #pb end
    for i = 1, n do
        local x, y = pa[i] or 0, pb[i] or 0
        if x < y then return -1 end
        if x > y then return 1 end
    end
    return 0
end

--- True when latest is a newer dotted version than installed.
-- Nil when either side cannot be compared.
function M.isNewer(latest, installed)
    local cmp = M.compareVersions(latest, installed)
    if cmp == nil then return nil end
    return cmp == 1
end

--- "newer", "current", or "unknown" when the installed copy has no version.
function M.offerState(latest, installed)
    local newer = M.isNewer(latest, installed)
    if newer == true then return "newer" end
    if newer == false then return "current" end
    return "unknown"
end

--- KOReader revisions are vYYYY.MM, an optional point (vYYYY.MM.P), and the
-- commits since that tag (vYYYY.MM-N), plus an optional `-g<hash>`.
-- The 12-digit weight is Version:getNormalizedVersion's:
-- ((year * 100 + month) * 1000000) + (point * 10000) + commits.
-- v2015.11-982-g704d4238 is 201511000982. A dev build is newer than the tag
-- it follows and older than the next month. Nil when `rev` is not that
-- shape, so a parse failure never blocks an update.
function M.normalizeKoreaderVersion(rev)
    if type(rev) ~= "string" then return nil end
    rev = trim(rev)
    if rev == "" then return nil end
    if rev:sub(1, 1) ~= "v" and rev:sub(1, 1) ~= "V" then
        rev = "v" .. rev
    else
        rev = "v" .. rev:sub(2)
    end
    local year, month, point, commits = rev:match("^v(%d%d%d%d)%.(%d%d)%.?(%d?%d?)-?(%d*)")
    if not year or not month then return nil end
    year, month = tonumber(year), tonumber(month)
    if not year or not month then return nil end
    point = tonumber(point) or 0
    commits = tonumber(commits) or 0
    return ((year * 100 + month) * 1000000) + (point * 10000) + commits
end

--- -1 when a is older, 0 when equal, 1 when a is newer. Nil if either
-- revision cannot be parsed.
function M.compareKoreader(a, b)
    local na, nb = M.normalizeKoreaderVersion(a), M.normalizeKoreaderVersion(b)
    if not na or not nb then return nil end
    if na < nb then return -1 end
    if na > nb then return 1 end
    return 0
end

--- The number KOReader compares. `version_mod` is its version module when
-- the caller has one: getNormalizedVersion wins, and 0 means "not a
-- revision" (that is what the module returns instead of nil).
function M.koreaderVersionNumber(rev, version_mod)
    if type(rev) == "number" then
        if rev > 0 then return rev end
        return nil
    end
    if type(rev) ~= "string" or trim(rev) == "" then return nil end
    if type(version_mod) == "table" and type(version_mod.getNormalizedVersion) == "function" then
        local ok, num = pcall(version_mod.getNormalizedVersion, version_mod, rev)
        if ok and type(num) == "number" and num > 0 then return num end
    end
    return M.normalizeKoreaderVersion(rev)
end

--- Installed KOReader revision, from require("version") unless a module is passed.
-- Returns the normalized number and the git-rev string. Either may be nil.
-- getCurrentRevision is the git-rev; getNormalizedCurrentVersion is the number
-- KOReader itself compares. A missing module or a failed call is nil, not an error.
function M.installedKoreaderNumber(version_mod)
    local Version = version_mod
    if Version == nil then
        local ok, loaded = pcall(require, "version")
        if not ok or type(loaded) ~= "table" then return nil, nil end
        Version = loaded
    end
    if type(Version) ~= "table" then return nil, nil end
    local rev
    if type(Version.getCurrentRevision) == "function" then
        local ok, value = pcall(Version.getCurrentRevision, Version)
        if ok and type(value) == "string" then
            value = trim(value)
            if value ~= "" then rev = value end
        end
    end
    local num
    if type(Version.getNormalizedCurrentVersion) == "function" then
        local ok, value = pcall(Version.getNormalizedCurrentVersion, Version)
        if ok and type(value) == "number" and value > 0 then num = value end
    end
    if not num and rev then
        num = M.koreaderVersionNumber(rev, Version)
    end
    return num, rev
end

--- True only when both sides parse and the installed revision is older than
-- the release's minimum. No minimum, or either side unparsable, is false:
-- the update is not blocked.
function M.koreaderTooOld(installed, required, version_mod)
    local need = M.koreaderVersionNumber(required, version_mod)
    if not need then return false end
    local have = M.koreaderVersionNumber(installed, version_mod)
    if not have then return false end
    return have < need
end

-- Automatic updates. An unset value means Notify me: a saved choice is
-- only "off", "notify", or "install".
M.MODE_ORDER = { "off", "notify", "install" }

function M.mode(settings)
    local id = type(settings) == "table" and settings.update_mode or nil
    if id == "off" or id == "notify" or id == "install" then return id end
    return "notify"
end

--- What a background check may do. Manual "Check for updates now" does not
-- use this: it always runs, and it may turn Wi-Fi on.
-- ctx.due: the weekly interval has passed.
-- ctx.wifi: Wi-Fi is already on and the device is online. Never means "turn it on".
-- ctx.book_open: a book is open. Quiet install waits for the Library or the next start.
-- Returns "none", "notify", "install", or "defer".
function M.planBackground(mode, ctx)
    ctx = ctx or {}
    mode = M.mode({ update_mode = mode })
    if mode == "off" or not ctx.due or not ctx.wifi then return "none" end
    if mode == "notify" then return "notify" end
    if ctx.book_open then return "defer" end
    return "install"
end

--- version = "0.7.1" inside _meta.lua.
function M.readVersion(text)
    if type(text) ~= "string" then return nil end
    return text:match('version%s*=%s*"([%d%.]+)"')
        or text:match("version%s*=%s*'([%d%.]+)'")
end

--- The 64 hex digits after SHA256, with or without a colon and backticks.
function M.parseSha256(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("[Ss][Hh][Aa]256", "SHA256")
    local patterns = {
        "SHA256%s*:?%s*`([0-9a-fA-F]+)`",
        "SHA256%s*:?%s*([0-9a-fA-F]+)",
    }
    for i = 1, #patterns do
        local hex = text:match(patterns[i])
        if hex and #hex == 64 then return hex:lower() end
    end
    return nil
end

--- `Requires KOReader: v2025.04` from the release notes. Nil when the line
-- is absent or the version is not a KOReader revision. One line is enough;
-- a later line is not consulted when the first one does not parse, so a
-- broken declaration cannot block the update.
function M.parseRequiresKoreader(text)
    if type(text) ~= "string" or text == "" then return nil end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local cleaned = line:gsub("%*%*", ""):gsub("`", "")
        local token = cleaned:match("[Rr]equires%s+[Kk][Oo][Rr]eader%s*:?%s*(%S+)")
        if token then
            token = token:gsub("[,;%.%)]+$", "")
            if M.normalizeKoreaderVersion(token) then return token end
            return nil
        end
    end
    return nil
end

--- Release notes for the dialog: checksum and install lines removed, and
-- the light markup GitLab releases use turned into plain text.
function M.shortNotes(description)
    if type(description) ~= "string" or description == "" then return "" end
    local kept = {}
    for line in (description .. "\n"):gmatch("([^\n]*)\n") do
        local cleaned = line:gsub("%*%*", "")
        cleaned = cleaned:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
        cleaned = cleaned:gsub("`", "")
        local skip = cleaned:find("SHA256", 1, true)
            or cleaned:lower():find("requires koreader", 1, true)
            or cleaned:find("library.koplugin-v", 1, true)
            or cleaned:match("^%s*Unzip into")
        if not skip then kept[#kept + 1] = cleaned end
    end
    local text = table.concat(kept, "\n")
    text = text:gsub("\n\n\n+", "\n\n")
    text = trim(text)
    if #text <= M.NOTES_LIMIT then return text end
    local cut = text:sub(1, M.NOTES_LIMIT):gsub("%s+%S*$", "")
    if cut == "" then cut = text:sub(1, M.NOTES_LIMIT) end
    return cut .. "..."
end

function M.tagVersion(tag)
    if type(tag) ~= "string" then return nil end
    local v = tag:match("^[vV](.+)$") or tag
    if not M.splitVersion(v) then return nil end
    return v:gsub("^[vV]", "")
end

--- The generic-package zip for this version. Source archives are ignored.
function M.pickAsset(release, version)
    if type(release) ~= "table" or type(version) ~= "string" then return nil end
    local assets = release.assets
    local links = type(assets) == "table" and assets.links or nil
    if type(links) ~= "table" then return nil end
    local want = "library.koplugin-v" .. version .. ".zip"
    for i = 1, #links do
        local link = links[i]
        local name = type(link) == "table" and link.name or nil
        local url = type(link) == "table" and link.url or nil
        if type(name) == "string" and type(url) == "string" and url ~= ""
                and name:find(want, 1, true) then
            return { name = want, url = url }
        end
    end
    return nil
end

--- A release object, or the first element when the list endpoint was used.
function M.normalizeRelease(decoded)
    if type(decoded) ~= "table" then return nil end
    if type(decoded.tag_name) == "string" then return decoded end
    local first = decoded[1]
    if type(first) == "table" and type(first.tag_name) == "string" then return first end
    return nil
end

function M.weeklyDue(checked_at, now, failed_at)
    if type(now) ~= "number" then return false end
    if type(failed_at) == "number" and (now - failed_at) < M.DAY_SECONDS then
        return false
    end
    if type(checked_at) ~= "number" then return true end
    return (now - checked_at) >= M.WEEK_SECONDS
end

--- True when a path is koreader/settings or a child of it.
function M.underSettings(path)
    if type(path) ~= "string" then return false end
    return path:find("/settings/", 1, true) ~= nil or path:match("/settings$") ~= nil
end

function M.isPluginDir(path)
    if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then return false end
    return path:gsub("/+$", ""):match("([^/]+)$") == M.PLUGIN_DIRNAME
end

function M.backupPath(plugin_dir)
    return plugin_dir:gsub("/+$", "") .. ".bak"
end

function M.pluginDir(plugin)
    local path = type(plugin) == "table" and plugin.path or nil
    if type(path) == "string" and path ~= "" then
        path = path:gsub("\\", "/"):gsub("/main%.lua$", ""):gsub("/+$", "")
        if M.isPluginDir(path) then return path end
    end
    -- This file sits in the plugin folder, so a missing self.path still resolves.
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    src = src:gsub("\\", "/")
    local dir = src:match("^(.*)/libraryupdate%.lua$")
    if dir and M.isPluginDir(dir) then return dir end
    return nil
end

--- A zip entry KOReader may write: the library.koplugin directory and files
-- inside it. Anything absolute, with a backslash, or with ".." is refused.
-- is_dir covers archive readers that omit the trailing slash on folders.
function M.safeZipPath(name, is_dir)
    if type(name) ~= "string" or name == "" then return nil end
    if name:find("\\", 1, true) or name:find("\0", 1, true) then return nil end
    if name:sub(1, 1) == "/" then return nil end
    local directory = is_dir or name:sub(-1) == "/"
    local parts = {}
    for part in name:gmatch("[^/]+") do
        if part == ".." then return nil end
        if part ~= "." then parts[#parts + 1] = part end
    end
    if parts[1] ~= M.PLUGIN_DIRNAME then return nil end
    if not directory and #parts < 2 then return nil end
    local rel = table.concat(parts, "/")
    if directory then rel = rel .. "/" end
    return rel
end

local function bxor(a, b)
    local result, bitv = 0, 1
    for _i = 1, 32 do
        local abit, bbit = a % 2, b % 2
        if abit ~= bbit then result = result + bitv end
        a = (a - abit) / 2
        b = (b - bbit) / 2
        bitv = bitv * 2
    end
    return result
end

local crc_table
local function crcTable()
    if crc_table then return crc_table end
    crc_table = {}
    for n = 0, 255 do
        local c = n
        for _i = 1, 8 do
            if c % 2 == 1 then
                c = bxor(math.floor(c / 2), 0xEDB88320)
            else
                c = math.floor(c / 2)
            end
        end
        crc_table[n] = c
    end
    return crc_table
end

function M.crc32(data)
    if type(data) ~= "string" then return nil end
    local table_crc = crcTable()
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        local idx = bxor(crc % 256, data:byte(i))
        crc = bxor(math.floor(crc / 256), table_crc[idx])
    end
    -- bxor with 0xFFFFFFFF on a value that may have only been reduced mod 2^32
    crc = crc % 4294967296
    return bxor(crc, 0xFFFFFFFF)
end

local function u16(s, i)
    local a, b = s:byte(i, i + 1)
    if not b then return nil end
    return a + b * 256
end

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function findEOCD(s)
    local min = #s - 22 - 65535
    if min < 1 then min = 1 end
    local i = #s - 21
    while i >= min do
        if s:byte(i) == 0x50 and s:byte(i + 1) == 0x4B
                and s:byte(i + 2) == 0x05 and s:byte(i + 3) == 0x06 then
            local comment = u16(s, i + 20)
            if comment and i + 21 + comment == #s then return i end
        end
        i = i - 1
    end
    return nil
end

--- Central-directory entries. Each file carries its compressed bytes.
-- Directory entries have data == nil. Refuses zip64 sizes.
function M.entriesFromZip(bytes)
    if type(bytes) ~= "string" or #bytes < 22 then return nil, "not a zip" end
    local eocd = findEOCD(bytes)
    if not eocd then return nil, "not a zip" end
    local count = u16(bytes, eocd + 10)
    local cd_size = u32(bytes, eocd + 12)
    local cd_off = u32(bytes, eocd + 16)
    if not count or not cd_size or not cd_off then return nil, "not a zip" end
    if cd_off == 0xFFFFFFFF or cd_size == 0xFFFFFFFF then
        return nil, "zip64 archives are not supported"
    end
    local entries = {}
    local pos = cd_off + 1
    local cd_end = cd_off + cd_size
    for _i = 1, count do
        if pos + 46 - 1 > #bytes then return nil, "truncated zip" end
        if bytes:sub(pos, pos + 3) ~= "PK\001\002" then return nil, "truncated zip" end
        local flags = u16(bytes, pos + 8)
        local method = u16(bytes, pos + 10)
        local crc = u32(bytes, pos + 16)
        local csize = u32(bytes, pos + 20)
        local usize = u32(bytes, pos + 24)
        local name_len = u16(bytes, pos + 28)
        local extra_len = u16(bytes, pos + 30)
        local comment_len = u16(bytes, pos + 32)
        local local_off = u32(bytes, pos + 42)
        if not (flags and method and crc and csize and usize and name_len and extra_len and comment_len and local_off) then
            return nil, "truncated zip"
        end
        if csize == 0xFFFFFFFF or usize == 0xFFFFFFFF or local_off == 0xFFFFFFFF then
            return nil, "zip64 archives are not supported"
        end
        if flags % 2 == 1 then return nil, "encrypted zips are not supported" end
        local name = bytes:sub(pos + 46, pos + 45 + name_len)
        if #name ~= name_len then return nil, "truncated zip" end
        local local_pos = local_off + 1
        if bytes:sub(local_pos, local_pos + 3) ~= "PK\003\004" then
            return nil, "truncated zip"
        end
        local local_name = u16(bytes, local_pos + 26)
        local local_extra = u16(bytes, local_pos + 28)
        if not local_name or not local_extra then return nil, "truncated zip" end
        local data_pos = local_pos + 30 + local_name + local_extra
        local data
        if csize > 0 then
            data = bytes:sub(data_pos, data_pos + csize - 1)
            if #data ~= csize then return nil, "truncated zip" end
        else
            data = ""
        end
        entries[#entries + 1] = {
            name = name,
            method = method,
            crc = crc,
            usize = usize,
            data = data,
        }
        pos = pos + 46 + name_len + extra_len + comment_len
        if pos - 1 > cd_end then return nil, "truncated zip" end
    end
    return entries
end

function M.mkdirp(fs, path)
    if type(path) ~= "string" or path == "" or path == "/" then return true end
    path = path:gsub("/+$", "")
    local acc = ""
    for part in path:gmatch("[^/]+") do
        acc = acc .. "/" .. part
        if fs.isDir(acc) then
            -- already there
        elseif fs.exists(acc) then
            return nil, "not a directory"
        else
            local ok, err = fs.mkDir(acc)
            if not ok and not fs.isDir(acc) then
                return nil, err or "could not create a folder"
            end
        end
    end
    return true
end

function M.copyTree(fs, src, dst)
    if fs.isDir(src) then
        if not fs.isDir(dst) then
            local ok, err = fs.mkDir(dst)
            if not ok and not fs.isDir(dst) then return nil, err or "could not copy a folder" end
        end
        local names = fs.list(src)
        for i = 1, #names do
            local ok, err = M.copyTree(fs, src .. "/" .. names[i], dst .. "/" .. names[i])
            if not ok then return nil, err end
        end
        return true
    end
    local data = fs.read(src)
    if data == nil then return nil, "could not read a file" end
    return fs.writeFile(dst, data)
end

function M.removeTree(fs, path)
    if not fs.exists(path) then return true end
    if fs.isDir(path) then
        local names = fs.list(path)
        for i = 1, #names do
            local ok, err = M.removeTree(fs, path .. "/" .. names[i])
            if not ok then return nil, err end
        end
        return fs.removeDir(path)
    end
    return fs.removeFile(path)
end

--- Write checked entries under dest. inflate(compressed, usize) is required
-- for method 8. Method 0 is stored bytes.
function M.materialize(entries, fs, dest, inflate)
    if type(entries) ~= "table" then return nil, "not a zip" end
    for i = 1, #entries do
        local entry = entries[i]
        local rel = M.safeZipPath(entry.name)
        if not rel then return nil, "unsafe path in the archive" end
        if rel:sub(-1) == "/" then
            local ok, err = M.mkdirp(fs, dest .. "/" .. rel:sub(1, -2))
            if not ok then return nil, err end
        else
            local data, err
            if entry.method == 0 then
                data = entry.data or ""
            elseif entry.method == 8 then
                if type(inflate) ~= "function" then
                    return nil, "this KOReader build cannot unpack the update"
                end
                data, err = inflate(entry.data or "", entry.usize)
                if not data then return nil, err or "could not unpack the update" end
            else
                return nil, "unsupported zip compression"
            end
            if #data ~= entry.usize then return nil, "uncompressed size does not match" end
            if M.crc32(data) ~= entry.crc then return nil, "checksum mismatch inside the zip" end
            local full = dest .. "/" .. rel
            local parent = full:match("^(.*)/[^/]+$")
            local ok, merr = M.mkdirp(fs, parent)
            if not ok then return nil, merr end
            ok, merr = fs.writeFile(full, data)
            if not ok then return nil, merr or "could not write a file" end
        end
    end
    return true
end

--- Put the previous plugin at library.koplugin.bak, replacing an older .bak,
-- then move staged into its place. Any failure after the backup puts .bak back.
function M.installReplacing(fs, plugin_dir, staged_dir)
    if type(plugin_dir) ~= "string" or type(staged_dir) ~= "string" then
        return nil, "missing path"
    end
    plugin_dir = plugin_dir:gsub("/+$", "")
    staged_dir = staged_dir:gsub("/+$", "")
    if M.underSettings(plugin_dir) or M.underSettings(staged_dir) then
        return nil, "refusing to change koreader/settings"
    end
    if not M.isPluginDir(plugin_dir) then
        return nil, "the plugin folder is not library.koplugin"
    end
    if not fs.isDir(staged_dir) or not fs.exists(staged_dir .. "/main.lua") or fs.isDir(staged_dir .. "/main.lua") then
        return nil, "the update is missing main.lua"
    end
    local bak = M.backupPath(plugin_dir)
    local backed = false
    local function fail(err)
        if not backed then return nil, err end
        local ok, rerr = M.restoreBackup(fs, plugin_dir, bak)
        if not ok then
            return nil, err .. " The backup could not be restored (" .. tostring(rerr) .. ")."
        end
        return nil, err .. " The previous version was restored."
    end
    if fs.exists(bak) then
        local ok, err = M.removeTree(fs, bak)
        if not ok then return nil, err or "could not replace the old backup" end
    end
    if fs.exists(plugin_dir) then
        local ok, err = fs.rename(plugin_dir, bak)
        if not ok then
            ok, err = M.copyTree(fs, plugin_dir, bak)
            if not ok then return nil, err or "could not back up the plugin" end
            ok, err = M.removeTree(fs, plugin_dir)
            if not ok then return nil, err or "could not move the plugin aside" end
        end
        backed = true
    end
    local ok, err = fs.rename(staged_dir, plugin_dir)
    if not ok then
        ok, err = M.copyTree(fs, staged_dir, plugin_dir)
        if not ok then return fail(err or "could not install the update") end
    end
    if not fs.exists(plugin_dir .. "/main.lua") then
        return fail("the installed plugin is missing main.lua")
    end
    return true
end

function M.restoreBackup(fs, plugin_dir, bak)
    plugin_dir = plugin_dir:gsub("/+$", "")
    bak = bak or M.backupPath(plugin_dir)
    if M.underSettings(plugin_dir) then return nil, "refusing to change koreader/settings" end
    if not fs.exists(bak) then return nil, "no backup" end
    if fs.exists(plugin_dir) then
        local ok, err = M.removeTree(fs, plugin_dir)
        if not ok then return nil, err or "could not remove the failed update" end
    end
    local ok, err = fs.rename(bak, plugin_dir)
    if not ok then
        ok, err = M.copyTree(fs, bak, plugin_dir)
        if not ok then return nil, err or "could not restore the backup" end
        M.removeTree(fs, bak)
    end
    if not fs.exists(plugin_dir .. "/main.lua") then
        return nil, "the restored plugin is missing main.lua"
    end
    return true
end

----------------------------------------------------------------------------
-- JSON (GitLab's release document). rapidjson is used when KOReader has it.
----------------------------------------------------------------------------

local function utf8encode(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
    end
    if cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + (math.floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40))
    end
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + (math.floor(cp / 0x1000) % 0x40),
        0x80 + (math.floor(cp / 0x40) % 0x40),
        0x80 + (cp % 0x40))
end

function M.decodeJson(s)
    if type(s) ~= "string" then return nil, "not json" end
    local i, n = 1, #s
    local function peek() return s:sub(i, i) end
    local function skip()
        while i <= n do
            local c = s:sub(i, i)
            if c ~= " " and c ~= "\n" and c ~= "\r" and c ~= "\t" then return end
            i = i + 1
        end
    end
    local parse
    local function parseString()
        i = i + 1
        local out = {}
        while i <= n do
            local c = s:sub(i, i)
            if c == '"' then
                i = i + 1
                return table.concat(out)
            end
            if c == "\\" then
                local e = s:sub(i + 1, i + 1)
                local map = {
                    n = "\n", r = "\r", t = "\t", ["\\"] = "\\",
                    ['"'] = '"', ["/"] = "/",
                }
                if map[e] then
                    out[#out + 1] = map[e]
                    i = i + 2
                elseif e == "u" then
                    local hex = s:sub(i + 2, i + 5)
                    if not hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
                        return nil, "bad unicode escape"
                    end
                    out[#out + 1] = utf8encode(tonumber(hex, 16))
                    i = i + 6
                else
                    return nil, "bad escape"
                end
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
        return nil, "unterminated string"
    end
    local function parseNumber()
        local start = i
        if peek() == "-" then i = i + 1 end
        if not peek():match("%d") then return nil, "bad number" end
        if peek() == "0" then
            i = i + 1
        else
            while peek():match("%d") do i = i + 1 end
        end
        if peek() == "." then
            i = i + 1
            if not peek():match("%d") then return nil, "bad number" end
            while peek():match("%d") do i = i + 1 end
        end
        local e = peek()
        if e == "e" or e == "E" then
            i = i + 1
            if peek() == "+" or peek() == "-" then i = i + 1 end
            if not peek():match("%d") then return nil, "bad number" end
            while peek():match("%d") do i = i + 1 end
        end
        local num = tonumber(s:sub(start, i - 1))
        if not num then return nil, "bad number" end
        return num
    end
    function parse()
        skip()
        local c = peek()
        if c == '"' then return parseString() end
        if c == "{" then
            i = i + 1
            local obj = {}
            skip()
            if peek() == "}" then i = i + 1; return obj end
            while true do
                skip()
                if peek() ~= '"' then return nil, "bad object" end
                local key, err = parseString()
                if not key then return nil, err end
                skip()
                if peek() ~= ":" then return nil, "bad object" end
                i = i + 1
                local value
                value, err = parse()
                if err then return nil, err end
                obj[key] = value
                skip()
                local sep = peek()
                if sep == "," then
                    i = i + 1
                elseif sep == "}" then
                    i = i + 1
                    return obj
                else
                    return nil, "bad object"
                end
            end
        end
        if c == "[" then
            i = i + 1
            local arr = {}
            skip()
            if peek() == "]" then i = i + 1; return arr end
            while true do
                local value, err = parse()
                if err then return nil, err end
                arr[#arr + 1] = value
                skip()
                local sep = peek()
                if sep == "," then
                    i = i + 1
                elseif sep == "]" then
                    i = i + 1
                    return arr
                else
                    return nil, "bad array"
                end
            end
        end
        if c == "-" or c:match("%d") then return parseNumber() end
        if s:sub(i, i + 3) == "true" then i = i + 4; return true end
        if s:sub(i, i + 4) == "false" then i = i + 5; return false end
        if s:sub(i, i + 3) == "null" then i = i + 4; return nil end
        return nil, "bad json"
    end
    local value, err = parse()
    if err then return nil, err end
    skip()
    if i <= n then return nil, "trailing json" end
    return value
end

function M.decodeRelease(body)
    if type(body) ~= "string" or body == "" then return nil, "empty response" end
    local ok, rapidjson = pcall(require, "rapidjson")
    if ok and type(rapidjson) == "table" and type(rapidjson.decode) == "function" then
        local decoded_ok, value = pcall(rapidjson.decode, body)
        if decoded_ok then
            local release = M.normalizeRelease(value)
            if release then return release end
        end
    end
    local value, err = M.decodeJson(body)
    if not value then return nil, err or "could not read the release" end
    local release = M.normalizeRelease(value)
    if not release then return nil, "could not read the release" end
    return release
end

----------------------------------------------------------------------------
-- Device IO. Loaded only when an update runs, so the specs can require
-- this module without KOReader.
----------------------------------------------------------------------------

function M.realFS()
    local lfs = require("libs/libkoreader-lfs")
    local fs = {}
    function fs.exists(path) return lfs.attributes(path) ~= nil end
    function fs.isDir(path) return lfs.attributes(path, "mode") == "directory" end
    function fs.list(path)
        local names = {}
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then names[#names + 1] = name end
        end
        table.sort(names)
        return names
    end
    function fs.mkDir(path)
        local ok, err = lfs.mkdir(path)
        if ok then return true end
        return nil, err
    end
    function fs.removeFile(path)
        local ok, err = os.remove(path)
        if ok then return true end
        return nil, err
    end
    function fs.removeDir(path) return fs.removeFile(path) end
    function fs.rename(src, dst)
        local ok, err = os.rename(src, dst)
        if ok then return true end
        return nil, err
    end
    function fs.read(path)
        local handle = io.open(path, "rb")
        if not handle then return nil end
        local data = handle:read("*a")
        handle:close()
        return data
    end
    function fs.writeFile(path, data)
        local handle, err = io.open(path, "wb")
        if not handle then return nil, err end
        local ok, werr = handle:write(data)
        handle:close()
        if not ok then return nil, werr end
        return true
    end
    return fs
end

function M.inflateRaw(compressed, usize)
    if type(compressed) ~= "string" or type(usize) ~= "number" then
        return nil, "could not unpack the update"
    end
    if usize < 0 or usize > 32 * 1024 * 1024 then
        return nil, "the update is too large"
    end
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then return nil, "this KOReader build cannot unpack the update" end
    if not M._inflate_cdef then
        local defined, def_err = pcall(ffi.cdef, [[
            typedef struct library_z_stream {
                const unsigned char *next_in;
                unsigned int avail_in;
                unsigned long total_in;
                unsigned char *next_out;
                unsigned int avail_out;
                unsigned long total_out;
                const char *msg;
                void *state;
                void *zalloc;
                void *zfree;
                void *opaque;
                int data_type;
                unsigned long adler;
                unsigned long reserved;
            } library_z_stream;
            int inflateInit2_(library_z_stream *strm, int windowBits, const char *version, int stream_size);
            int inflate(library_z_stream *strm, int flush);
            int inflateEnd(library_z_stream *strm);
            const char *zlibVersion(void);
        ]])
        if not defined then return nil, tostring(def_err) end
        M._inflate_cdef = true
    end
    local lib
    if type(ffi.loadlib) == "function" then
        local loaded, handle = pcall(ffi.loadlib, "z", 1)
        if loaded then lib = handle end
    end
    if not lib then
        local loaded, handle = pcall(ffi.load, "z")
        if loaded then lib = handle end
    end
    if not lib then return nil, "this KOReader build cannot unpack the update" end
    local strm = ffi.new("library_z_stream")
    local ver = ffi.string(lib.zlibVersion())
    local rc = lib.inflateInit2_(strm, -15, ver, ffi.sizeof("library_z_stream"))
    if rc ~= 0 then
        return nil, "could not unpack the update"
    end
    local src = ffi.new("uint8_t[?]", math.max(#compressed, 1))
    if #compressed > 0 then ffi.copy(src, compressed, #compressed) end
    local dst = ffi.new("uint8_t[?]", math.max(usize, 1))
    strm.next_in = src
    strm.avail_in = #compressed
    strm.next_out = dst
    strm.avail_out = usize == 0 and 1 or usize
    rc = lib.inflate(strm, 4)
    lib.inflateEnd(strm)
    if rc ~= 1 or tonumber(strm.total_out) ~= usize then
        return nil, "could not unpack the update"
    end
    if usize == 0 then return "" end
    return ffi.string(dst, usize)
end

local function caBundle()
    local lfs = require("libs/libkoreader-lfs")
    local candidates = {}
    if lfs.currentdir then
        local cwd = lfs.currentdir()
        if type(cwd) == "string" then
            candidates[#candidates + 1] = cwd .. "/data/ca-bundle.crt"
        end
    end
    for entry in (package.path or ""):gmatch("[^;]+") do
        local root = entry:match("^(.*)/common/%?%.lua$")
            or entry:match("^(.*)/frontend/%?%.lua$")
        if root then candidates[#candidates + 1] = root .. "/data/ca-bundle.crt" end
    end
    for i = 1, #candidates do
        if lfs.attributes(candidates[i], "mode") == "file" then return candidates[i] end
    end
    return nil
end

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.unzipCommand()
    local lfs = require("libs/libkoreader-lfs")
    local ffi_ok, ffiUtil = pcall(require, "ffi/util")
    local path = os.getenv("PATH") or ""
    for dir in (path .. ":"):gmatch("(.-):") do
        if dir ~= "" then
            local candidate = dir .. "/unzip"
            if ffi_ok and type(ffiUtil) == "table" and type(ffiUtil.isExecutable) == "function" then
                if ffiUtil.isExecutable(candidate) then return candidate end
            elseif lfs.attributes(candidate, "mode") == "file" then
                return candidate
            end
        end
    end
    return nil
end

local function readFile(path)
    local handle = io.open(path, "rb")
    if not handle then return nil, "could not read the download" end
    local data = handle:read("*a")
    handle:close()
    return data
end

function M.sha256File(path)
    local data, err = readFile(path)
    if not data then return nil, err end
    local ok, sha = pcall(require, "ffi/sha2")
    if not ok or type(sha) ~= "table" or type(sha.sha256) ~= "function" then
        return nil, "SHA256 is not available in this KOReader build"
    end
    local hex = sha.sha256(data)
    if type(hex) ~= "string" then return nil, "SHA256 is not available in this KOReader build" end
    return hex:lower()
end

--- Unpack zip_path into stage_dir/library.koplugin. Does not touch the plugin.
function M.extractZipFile(zip_path, stage_dir)
    local fs = M.realFS()
    local bytes, err = readFile(zip_path)
    if not bytes then return nil, err end
    local entries, zerr = M.entriesFromZip(bytes)
    if not entries then return nil, zerr end
    for i = 1, #entries do
        if not M.safeZipPath(entries[i].name) then
            return nil, "unsafe path in the archive"
        end
    end
    M.removeTree(fs, stage_dir)
    local ok, merr = M.mkdirp(fs, stage_dir)
    if not ok then return nil, merr end

    local function ready()
        return fs.exists(stage_dir .. "/" .. M.PLUGIN_DIRNAME .. "/main.lua")
    end

    local archiver_ok, Archiver = pcall(require, "ffi/archiver")
    if archiver_ok and type(Archiver) == "table" and type(Archiver.Reader) == "table" then
        local reader = Archiver.Reader:new()
        if not reader:open(zip_path) then
            return nil, reader.err or "could not open the archive"
        end
        local listed = {}
        for entry in reader:iterate() do listed[#listed + 1] = entry end
        for i = 1, #listed do
            local entry = listed[i]
            local rel = M.safeZipPath(entry.path, entry.mode == "directory")
            if not rel then
                reader:close()
                M.removeTree(fs, stage_dir)
                return nil, "unsafe path in the archive"
            end
            if entry.mode == "link" or entry.mode == "socket" or entry.mode == "char device"
                    or entry.mode == "block device" or entry.mode == "named pipe" then
                reader:close()
                M.removeTree(fs, stage_dir)
                return nil, "the archive contains a " .. entry.mode
            end
            if rel:sub(-1) == "/" or entry.mode == "directory" then
                local mok, dir_err = M.mkdirp(fs, stage_dir .. "/" .. rel:gsub("/+$", ""))
                if not mok then
                    reader:close()
                    return nil, dir_err
                end
            else
                local data
                if (tonumber(entry.size) or 0) == 0 then
                    data = ""
                else
                    data = reader:extractToMemory(entry.path)
                end
                if not data then
                    local read_err = reader.err or "could not read a file from the archive"
                    reader:close()
                    M.removeTree(fs, stage_dir)
                    return nil, read_err
                end
                local full = stage_dir .. "/" .. rel
                local parent = full:match("^(.*)/[^/]+$")
                local mok, dir_err = M.mkdirp(fs, parent)
                if not mok then reader:close(); return nil, dir_err end
                mok, dir_err = fs.writeFile(full, data)
                if not mok then reader:close(); return nil, dir_err end
            end
        end
        reader:close()
        if ready() then return true end
        M.removeTree(fs, stage_dir)
        return nil, "the update is missing main.lua"
    end

    local unzip = M.unzipCommand()
    if unzip then
        M.mkdirp(fs, stage_dir)
        local cmd = shellQuote(unzip) .. " -qq -o " .. shellQuote(zip_path) .. " -d " .. shellQuote(stage_dir)
        local r1 = os.execute(cmd)
        if (r1 == true or r1 == 0) and ready() then return true end
        M.removeTree(fs, stage_dir)
    end

    local function inflate(data, size) return M.inflateRaw(data, size) end
    local mok, mat_err = M.materialize(entries, fs, stage_dir, inflate)
    if not mok then
        M.removeTree(fs, stage_dir)
        return nil, mat_err
    end
    if not ready() then
        M.removeTree(fs, stage_dir)
        return nil, "the update is missing main.lua"
    end
    return true
end

local function httpRequest(url, sink, cafile)
    local https = require("ssl.https")
    local req = {
        url = url,
        method = "GET",
        sink = sink,
        headers = {
            ["Accept"] = "*/*",
            ["User-Agent"] = "LibraryGUI",
        },
    }
    if cafile then
        req.protocol = "any"
        req.options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" }
        req.verify = "peer"
        req.cafile = cafile
    end
    return https.request(req)
end

function M.httpGet(url, dest_path)
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")
    socketutil:set_timeout(30, 120)
    local cafile = caBundle()
    local ok_call, result, err = pcall(function()
        if dest_path then
            local handle, open_err = io.open(dest_path, "wb")
            if not handle then return nil, open_err end
            local sink = socketutil.file_sink(handle)
            local one, code = httpRequest(url, sink, cafile)
            pcall(function() handle:close() end)
            if one == nil then return nil, tostring(code) end
            if tonumber(code) ~= 200 then return nil, "HTTP " .. tostring(code) end
            return true
        end
        local chunks = {}
        local sink = socketutil.table_sink(chunks)
        local one, code = httpRequest(url, sink, cafile)
        if one == nil then return nil, tostring(code) end
        if tonumber(code) ~= 200 then return nil, "HTTP " .. tostring(code) end
        return table.concat(chunks)
    end)
    socketutil:reset_timeout()
    if not ok_call then return nil, tostring(result) end
    return result, err
end

function M.fetchRelease()
    local body, err = M.httpGet(M.LATEST_URL)
    if type(body) ~= "string" then
        body, err = M.httpGet(M.FALLBACK_URL)
    end
    if type(body) ~= "string" then return nil, err or "couldn't reach GitLab" end
    return M.decodeRelease(body)
end

local function workPaths()
    local DataStorage = require("datastorage")
    local root = DataStorage:getDataDir()
    if type(root) ~= "string" or root == "" then return nil, "could not find KOReader's cache" end
    local dir = root .. "/cache/library_update"
    return dir, dir .. "/plugin.zip", dir .. "/stage"
end

local function shortErr(err)
    local text = tostring(err or "unknown error")
    text = text:gsub("%s+", " ")
    if text:find("certificate", 1, true) or text:find("VERIFY", 1, true) then
        return "the HTTPS certificate check failed"
    end
    if #text > 180 then text = text:sub(1, 180) end
    return text
end

local function tr()
    local _ = require("gettext")
    local T = require("ffi/util").template
    return _, T
end

local function present(plugin, widget)
    if type(plugin) == "table" and type(plugin.showOverLibrary) == "function" then
        plugin:showOverLibrary(widget)
        return
    end
    require("ui/uimanager"):show(widget)
end

local function tell(text, timeout, plugin)
    local InfoMessage = require("ui/widget/infomessage")
    present(plugin, InfoMessage:new{ text = text, timeout = timeout })
end

local function ask(text, ok_text, cancel_text, ok_callback, plugin)
    local ConfirmBox = require("ui/widget/confirmbox")
    present(plugin, ConfirmBox:new{
        text = text,
        ok_text = ok_text,
        cancel_text = cancel_text,
        ok_callback = ok_callback,
        flush_events_on_show = true,
    })
end

local function withBusy(text, fn, plugin)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local widget = InfoMessage:new{ text = text }
    present(plugin, widget)
    if UIManager.forceRePaint then UIManager:forceRePaint() end
    local ok, a, b = pcall(fn)
    pcall(function() UIManager:close(widget) end)
    if not ok then return nil, a end
    return a, b
end

local function stamp(plugin, key)
    if type(plugin.settings) ~= "table" then return end
    plugin.settings[key] = os.time()
    if plugin.saveSettings then plugin:saveSettings() end
end

function M.installedVersion(plugin_dir, fs)
    fs = fs or M.realFS()
    local text = fs.read(plugin_dir .. "/_meta.lua")
    return M.readVersion(text)
end

--- Download, check the hash, back up, and replace. No dialogs. A failure
-- after the backup restores library.koplugin.bak. info: version, url, sha.
function M.applyRelease(plugin, info)
    local plugin_dir = M.pluginDir(plugin)
    if not plugin_dir then return nil, "could not find the plugin folder" end
    if type(info) ~= "table" or type(info.url) ~= "string" or type(info.sha) ~= "string" then
        return nil, "the release is incomplete"
    end
    local dir, zip_path, stage = workPaths()
    if not dir then return nil, zip_path end
    local fs = M.realFS()
    local mok, merr = M.mkdirp(fs, dir)
    if not mok then return nil, merr end
    local function cleanup()
        fs.removeFile(zip_path)
        M.removeTree(fs, stage)
    end
    local got, gerr = M.httpGet(info.url, zip_path)
    if not got then cleanup(); return nil, gerr or "couldn't download the update" end
    local hex, herr = M.sha256File(zip_path)
    if not hex then cleanup(); return nil, herr end
    if hex ~= info.sha then
        cleanup()
        return nil, "mismatch"
    end
    local extracted, eerr = M.extractZipFile(zip_path, stage)
    if not extracted then cleanup(); return nil, eerr end
    local installed, ierr = M.installReplacing(fs, plugin_dir, stage .. "/" .. M.PLUGIN_DIRNAME)
    cleanup()
    if not installed then return nil, ierr end
    return true
end

--- Download, check the hash, back up, and replace. May turn Wi-Fi on.
-- info fields: version, url, sha.
function M.installRelease(plugin, info)
    local _, T = tr()
    local plugin_dir = M.pluginDir(plugin)
    if not plugin_dir then
        tell(_("Could not find the library.koplugin folder."), nil, plugin)
        return
    end
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:willRerunWhenOnline(function() M.installRelease(plugin, info) end) then
        return
    end
    local result, err = withBusy(T(_("Downloading Library GUI %1…"), info.version), function()
        return M.applyRelease(plugin, info)
    end, plugin)
    if result then
        ask(
            T(_("Library GUI %1 is installed. The previous copy is library.koplugin.bak. Restart KOReader now?"), info.version),
            _("Restart"),
            _("Later"),
            function()
                local UIManager = require("ui/uimanager")
                UIManager:restartKOReader()
            end, plugin)
        return
    end
    local message
    if err == "mismatch" then
        message = _("The download does not match the published SHA256, so nothing was changed.")
    else
        message = T(_("The update failed. %1"), shortErr(err))
    end
    tell(message, nil, plugin)
end

local function offer(plugin, info, installed)
    local _, T = tr()
    local notes = info.notes
    local text
    if installed then
        text = T(_("Library GUI %1 is available. You have %2."), info.version, installed)
    else
        text = T(_("Library GUI %1 is available. The installed version could not be read."), info.version)
    end
    if notes ~= "" then text = text .. "\n\n" .. notes end
    ask(text, _("Update"), _("Cancel"), function()
        M.installRelease(plugin, info)
    end, plugin)
end

-- Shown when a release needs a newer KOReader. %1 is the Library version,
-- %2 is the KOReader version. This plugin never updates KOReader.
M.BLOCK_TEMPLATE = "Library GUI %1 needs KOReader %2 or newer. Update KOReader with its own updater (Tools or the menu > Update)."

function M.displayVersion(v)
    if type(v) ~= "string" then return "?" end
    v = trim(v)
    if v == "" then return "?" end
    if v:sub(1, 1) == "v" or v:sub(1, 1) == "V" then return v end
    return "v" .. v
end

--- Drop the `-g<hash>` tail so the sentence shows v2025.04-42, not the commit.
function M.displayKoreader(v)
    return (M.displayVersion(v):gsub("-[gG][0-9a-fA-F].*$", ""))
end

function M.blockText(library_version, required)
    return (M.BLOCK_TEMPLATE
        :gsub("%%1", M.displayVersion(library_version))
        :gsub("%%2", M.displayKoreader(required)))
end

function M.presentBlock(plugin, library_version, required)
    local _, T = tr()
    tell(T(_(M.BLOCK_TEMPLATE), M.displayVersion(library_version), M.displayKoreader(required)), nil, plugin)
end

--- Quiet install remembers why it skipped. Updates shows the note once.
function M.rememberBlock(settings, library_version, required)
    if type(settings) ~= "table" then return false end
    if type(library_version) ~= "string" or library_version == "" then return false end
    if type(required) ~= "string" or required == "" then return false end
    settings.update_need_library = library_version
    settings.update_need_koreader = required
    settings.update_need_pending = true
    return true
end

function M.clearBlock(settings)
    if type(settings) ~= "table" then return false end
    if settings.update_need_pending == nil
            and settings.update_need_library == nil
            and settings.update_need_koreader == nil then
        return false
    end
    settings.update_need_pending = nil
    settings.update_need_library = nil
    settings.update_need_koreader = nil
    return true
end

--- KOReader's menu search calls sub_item_table_func while indexing. That is
-- not the user opening Updates. `names` is the debug frame names above the call.
function M.updatesOpenedFrom(names)
    if type(names) ~= "table" then return false end
    local opened = false
    for i = 1, #names do
        if names[i] == "search" then return false end
        if names[i] == "onMenuSelect" then opened = true end
    end
    return opened
end

--- The notice quiet install saved, then clears it. Nil when there is nothing
-- to say: no pending note, or the installed KOReader now meets it.
-- An unreadable installed revision still returns the note. `koreader_rev`
-- nil reads require("version"); a string is used as given (specs).
function M.takePendingBlock(settings, koreader_rev, version_mod)
    if type(settings) ~= "table" or settings.update_need_pending ~= true then
        return nil, false
    end
    local library_version = settings.update_need_library
    local required = settings.update_need_koreader
    settings.update_need_pending = nil
    settings.update_need_library = nil
    settings.update_need_koreader = nil
    if type(library_version) ~= "string" or type(required) ~= "string" then
        return nil, true
    end
    local Version = version_mod
    if Version == nil and type(koreader_rev) ~= "string" and type(koreader_rev) ~= "number" then
        local ok, loaded = pcall(require, "version")
        if ok and type(loaded) == "table" then Version = loaded end
    end
    local have
    if type(koreader_rev) == "string" or type(koreader_rev) == "number" then
        have = M.koreaderVersionNumber(koreader_rev, Version)
    else
        have = M.installedKoreaderNumber(Version)
    end
    local need = M.koreaderVersionNumber(required, Version)
    if have and need and have >= need then return nil, true end
    if not need then return nil, true end
    return { library = library_version, required = required }, true
end

local function saveIf(plugin, changed)
    if changed and type(plugin) == "table" and type(plugin.saveSettings) == "function" then
        plugin:saveSettings()
    end
end

--- What to do with a fetched release. `mode` is "manual", "notify", or "install".
-- `koreader_rev` nil reads KOReader's version module. A string skips that
-- require so specs stay hermetic.
-- action:
--   "current"    up to date
--   "skip"       quiet path, nothing to say (not a newer version)
--   "blocked"    KOReader is too old; do not download
--   "no-asset"   newer, but no plugin zip
--   "no-sha"     newer, but no SHA256 line
--   "notify"     short "available" notice
--   "install"    download and install now
--   "offer"      manual check: ask before downloading
-- download_now is true only for "install". Blocked never sets it.
function M.planRelease(mode, release, plugin_version, koreader_rev, version_mod)
    mode = mode or "manual"
    release = type(release) == "table" and release or {}
    local description = type(release.description) == "string" and release.description or ""
    local version = M.tagVersion(release.tag_name)
    local sha = M.parseSha256(description)
    local asset = version and M.pickAsset(release, version) or nil
    local state = version and M.offerState(version, plugin_version) or "unknown"
    local required = M.parseRequiresKoreader(description)
    local Version = version_mod
    if Version == nil and type(koreader_rev) ~= "string" and type(koreader_rev) ~= "number" then
        local ok, loaded = pcall(require, "version")
        if ok and type(loaded) == "table" then Version = loaded end
    end
    local have
    if type(koreader_rev) == "string" or type(koreader_rev) == "number" then
        have = M.koreaderVersionNumber(koreader_rev, Version)
    else
        have = M.installedKoreaderNumber(Version)
    end
    local need = M.koreaderVersionNumber(required, Version)
    local too_old = have ~= nil and need ~= nil and have < need
    local action
    if state == "current" then
        action = "current"
    elseif state ~= "newer" and mode ~= "manual" then
        -- A weekly check stays quiet when the installed plugin version cannot
        -- be compared. A manual check still considers the zip.
        action = "skip"
    elseif too_old then
        action = "blocked"
    elseif not asset then
        action = "no-asset"
    elseif not sha then
        action = "no-sha"
    elseif mode == "notify" then
        action = "notify"
    elseif mode == "install" then
        action = "install"
    else
        action = "offer"
    end
    return {
        action = action,
        download_now = action == "install",
        version = version,
        sha = sha,
        url = asset and asset.url or nil,
        state = state,
        required = required,
        notes = M.shortNotes(description),
    }
end

--- Query GitLab. allow_install shows Update. silent_current skips "up to date".
function M.check(plugin, opts)
    opts = opts or {}
    if M._busy then return end
    local plugin_dir = M.pluginDir(plugin)
    if not plugin_dir then
        if not opts.quiet then
            local _ = tr()
            tell(_("Could not find the library.koplugin folder."), nil, plugin)
        end
        return
    end
    local NetworkMgr = require("ui/network/manager")
    if not opts.already_online then
        if NetworkMgr:willRerunWhenOnline(function()
            local again = {}
            for k, v in pairs(opts) do again[k] = v end
            again.already_online = true
            M.check(plugin, again)
        end) then
            return
        end
    end
    M._busy = true
    local _, T = tr()
    local release, rerr
    if opts.quiet then
        release, rerr = M.fetchRelease()
    else
        release, rerr = withBusy(_("Checking for updates…"), function()
            return M.fetchRelease()
        end, plugin)
    end
    M._busy = false
    if not release then
        stamp(plugin, "update_check_failed_at")
        if not opts.quiet then
            tell(T(_("Couldn't check for updates. %1"), shortErr(rerr)), nil, plugin)
        end
        return
    end
    stamp(plugin, "update_checked_at")
    local installed = M.installedVersion(plugin_dir)
    local plan = M.planRelease(opts.notify_only and "notify" or "manual", release, installed)
    if plan.action == "current" then
        saveIf(plugin, M.clearBlock(plugin.settings))
        if not opts.quiet then
            tell(T(_("Library GUI is up to date (%1)."), installed), nil, plugin)
        end
        return
    end
    if plan.action == "skip" then return end
    if plan.action == "blocked" then
        -- Check now and Notify me say why. The zip is not downloaded.
        saveIf(plugin, M.clearBlock(plugin.settings))
        M.presentBlock(plugin, plan.version, plan.required)
        return
    end
    if plan.action == "no-asset" then
        if not opts.quiet then
            tell(_("The release has no library.koplugin zip, so nothing was changed."), nil, plugin)
        end
        return
    end
    if plan.action == "no-sha" then
        if not opts.quiet then
            tell(_("This release has no SHA256 line, so nothing was installed."), nil, plugin)
        end
        return
    end
    saveIf(plugin, M.clearBlock(plugin.settings))
    local found = {
        version = plan.version,
        url = plan.url,
        sha = plan.sha,
        notes = plan.notes,
    }
    -- Notify me: a short notice only. Install quietly is a different path.
    if plan.action == "notify" then
        tell(T(_("Library GUI %1 is available."), plan.version), 4, plugin)
        return
    end
    offer(plugin, found, installed)
end

function M.prompt(plugin)
    M.check(plugin, { quiet = false })
end

local function wifiAlreadyOn()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or type(NetworkMgr) ~= "table" then return false end
    if not NetworkMgr.isWifiOn or not NetworkMgr.isOnline then return false end
    return NetworkMgr:isWifiOn() and NetworkMgr:isOnline() and true or false
end

local function bookOpen(plugin)
    return type(plugin) == "table" and type(plugin.ui) == "table" and plugin.ui.document and true or false
end

--- Quiet install. No Wi-Fi prompt, no progress dialog, no restart. A failure
-- restores the backup inside applyRelease and is not shown.
function M.quietInstall(plugin)
    if M._busy then return end
    local settings = plugin.settings or {}
    if not M.weeklyDue(settings.update_checked_at, os.time(), settings.update_check_failed_at) then
        return
    end
    if bookOpen(plugin) or not wifiAlreadyOn() then return end
    M._busy = true
    local _, T = tr()
    local release = M.fetchRelease()
    if not release then
        M._busy = false
        stamp(plugin, "update_check_failed_at")
        return
    end
    local installed = M.installedVersion(M.pluginDir(plugin))
    local plan = M.planRelease("install", release, installed)
    if not plan.download_now then
        M._busy = false
        if plan.action == "blocked" then
            -- No dialog. The same sentence waits until Updates is opened.
            saveIf(plugin, M.rememberBlock(plugin.settings, plan.version, plan.required))
            stamp(plugin, "update_checked_at")
            return
        end
        -- A real answer, even "nothing newer", counts as this week's check.
        -- An incomplete release does not, so a later one can still install.
        if plan.action == "current" or plan.action == "skip" then
            if plan.action == "current" then
                saveIf(plugin, M.clearBlock(plugin.settings))
            end
            stamp(plugin, "update_checked_at")
        else
            stamp(plugin, "update_check_failed_at")
        end
        return
    end
    saveIf(plugin, M.clearBlock(plugin.settings))
    local ok = M.applyRelease(plugin, { version = plan.version, url = plan.url, sha = plan.sha })
    M._busy = false
    if not ok then
        stamp(plugin, "update_check_failed_at")
        return
    end
    stamp(plugin, "update_checked_at")
    tell(T(_("Library updated to v%1 — takes effect next restart"), plan.version), 4, plugin)
end

--- Background check. Off does nothing. Notify me only posts a notice.
-- Install quietly never turns Wi-Fi on and never restarts KOReader.
function M.maybeWeekly(plugin)
    local settings = type(plugin) == "table" and plugin.settings or nil
    if type(settings) ~= "table" then return end
    local mode = M.mode(settings)
    local due = M.weeklyDue(settings.update_checked_at, os.time(), settings.update_check_failed_at)
    local plan = M.planBackground(mode, {
        due = due,
        wifi = mode ~= "off" and wifiAlreadyOn() or false,
        book_open = bookOpen(plugin),
    })
    if plan == "notify" then
        M.check(plugin, { quiet = true, already_online = true, notify_only = true })
    elseif plan == "install" then
        M.quietInstall(plugin)
    end
end

return M
