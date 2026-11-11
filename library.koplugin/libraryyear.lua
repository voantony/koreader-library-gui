--[[--
Publication year for one book.

Calibre's `pubdate` wins when it is a real date. KOReader's own metadata is
next, when it actually carries a date. An EPUB's OPF `dc:date` is the last
resort, and only that: other formats are left alone.

The EPUB read never loads the book. It reads the zip's end-of-central-directory
and central directory (capped), then the container and the OPF, and stops.
A bad zip, a huge entry, or a clock budget returns nil. Nothing here raises.
]]

local M = {}

-- A publication year is four digits. Calibre writes 0101-01-01 for "no date".
local PLACEHOLDER = "0101-01-01"

-- How much of a zip we are willing to touch while the library is opening.
local MAX_TAIL = 22 + 65535
local MAX_CD = 2 * 1024 * 1024
local MAX_ENTRIES = 20000
local MAX_XML = 512 * 1024
local DEFAULT_BUDGET = 0.2 -- seconds of CPU time, checked between reads

local PROP_KEYS = {
    "year", "pubdate", "publication_date", "published", "date", "dc:date", "dc_date",
}

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

--- A 4-digit publication year, or nil. Never raises.
-- Accepts `2003`, `2003-05-01`, and `2003-05-01T00:00:00+00:00`.
-- Calibre's `0101-01-01` placeholder is not a year.
function M.fromValue(value)
    local ok, year = pcall(function()
        if type(value) == "number" then
            if value ~= value or value <= -math.huge or value >= math.huge then return nil end
            if value < 1000 or value > 9999 or value ~= math.floor(value) then return nil end
            return value
        end
        if type(value) ~= "string" or value == "" then return nil end
        if #value > 80 then value = value:sub(1, 80) end
        local token = value:match("^%s*(%S+)")
        if not token then return nil end
        local low = token:lower()
        if low:sub(1, #PLACEHOLDER) == PLACEHOLDER then return nil end
        local y = token:match("^(%d%d%d%d)$") or token:match("^(%d%d%d%d)[%-T/]")
        if not y or y == "0101" then return nil end
        local n = tonumber(y)
        if not n or n < 1000 or n > 9999 then return nil end
        return n
    end)
    if not ok then return nil end
    return year
end

--- Year from a metadata table, if it has one of the date fields KOReader
-- (or Calibre, or a sidecar) might carry. Creation/modification dates are
-- not publication dates and are ignored.
function M.fromProps(props)
    if type(props) ~= "table" then return nil end
    for i = 1, #PROP_KEYS do
        local key = PROP_KEYS[i]
        local ok, raw = pcall(function() return props[key] end)
        if ok then
            local year = M.fromValue(raw)
            if year then return year end
        end
    end
    return nil
end

local function eventName(attrs)
    if type(attrs) ~= "string" then return nil end
    local ev = attrs:match("[Ee][Vv][Ee][Nn][Tt]%s*=%s*\"([^\"]+)\"")
        or attrs:match("[Ee][Vv][Ee][Nn][Tt]%s*=%s*'([^']+)'")
    if type(ev) == "string" then return ev:lower() end
    return nil
end

local function preferredEvent(ev)
    return ev == "publication" or ev == "original-publication" or ev == "published"
end

local function metaContentYear(xml)
    local i = 1
    while i <= #xml do
        local s, e, tag = xml:find("<meta%s([^>]-)>", i)
        if not s then return nil end
        i = e + 1
        local prop = tag:match("[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Yy]%s*=%s*\"([^\"]+)\"")
            or tag:match("[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Yy]%s*=%s*'([^']+)'")
        if type(prop) == "string" then
            local p = prop:lower()
            if p == "dcterms:date" or p == "dcterms:issued" then
                local content = tag:match("[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%s*=%s*\"([^\"]*)\"")
                    or tag:match("[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%s*=%s*'([^']*)'")
                local year = M.fromValue(content)
                if year then return year end
                if tag:sub(-1) ~= "/" then
                    local body = xml:match("^(.-)</[Mm][Ee][Tt][Aa]%s*>", i)
                    year = M.fromValue(body)
                    if year then return year end
                end
            end
        end
    end
    return nil
end

--- Year from an OPF (or a fragment of one). `dc:date` first, preferring
-- `opf:event="publication"`. An EPUB3 `dcterms:date` / `dcterms:issued`
-- meta is used only when no `dc:date` yields a year. `dcterms:modified`
-- is not a publication date.
function M.fromOpf(xml)
    if type(xml) ~= "string" or xml == "" then return nil end
    local ok, year = pcall(function()
        if #xml > MAX_XML then xml = xml:sub(1, MAX_XML) end
        if xml:sub(1, 3) == "\239\187\191" then xml = xml:sub(4) end
        local fallback
        local i = 1
        while i <= #xml do
            local s, e, attrs, body = xml:find(
                "<[Dd][Cc]:[Dd][Aa][Tt][Ee]([^>]*)>(.-)</[Dd][Cc]:[Dd][Aa][Tt][Ee]%s*>", i)
            if not s then break end
            i = e + 1
            local text = body
            if text:find("<![CDATA[", 1, true) then
                text = text:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
            end
            if text:find("<", 1, true) then text = text:gsub("<[^>]+>", "") end
            local y = M.fromValue(text)
            if y then
                if preferredEvent(eventName(attrs)) then return y end
                if not fallback then fallback = y end
            end
        end
        if fallback then return fallback end
        return metaContentYear(xml)
    end)
    if not ok then return nil end
    return year
end

local function zipPath(name)
    if type(name) ~= "string" or name == "" then return nil end
    name = name:gsub("\\", "/"):gsub("^/+", "")
    if name == "" or #name > 1024 then return nil end
    local parts = 0
    for part in name:gmatch("[^/]+") do
        parts = parts + 1
        if parts > 40 or part == "." or part == ".." then return nil end
    end
    if parts == 0 then return nil end
    return name
end

local function findEOCD(tail)
    local min = #tail - 21 - 65535
    if min < 1 then min = 1 end
    local i = #tail - 21
    while i >= min do
        if tail:byte(i) == 0x50 and tail:byte(i + 1) == 0x4B
                and tail:byte(i + 2) == 0x05 and tail:byte(i + 3) == 0x06 then
            local comment = u16(tail, i + 20)
            if comment and i + 21 + comment == #tail then return i end
        end
        i = i - 1
    end
    return nil
end

local function inflate(data, usize)
    if type(data) ~= "string" or type(usize) ~= "number" then return nil end
    if usize < 0 or usize > MAX_XML then return nil end
    if usize == 0 then return "" end
    local ok, update = pcall(require, "libraryupdate")
    if not ok or type(update) ~= "table" or type(update.inflateRaw) ~= "function" then
        return nil
    end
    local out = update.inflateRaw(data, usize)
    if type(out) ~= "string" or #out ~= usize then return nil end
    return out
end

local function extract(f, entry, size, timed_out)
    if timed_out() then return nil end
    if type(entry) ~= "table" then return nil end
    if entry.flags % 2 == 1 then return nil end
    if entry.method ~= 0 and entry.method ~= 8 then return nil end
    if entry.csize < 0 or entry.usize < 0 then return nil end
    if entry.csize > MAX_XML or entry.usize > MAX_XML then return nil end
    if entry.local_off < 0 or entry.local_off >= size then return nil end
    if not f:seek("set", entry.local_off) then return nil end
    local hdr = f:read(30)
    if type(hdr) ~= "string" or #hdr ~= 30 or hdr:sub(1, 4) ~= "PK\003\004" then return nil end
    local name_len = u16(hdr, 27)
    local extra_len = u16(hdr, 29)
    if not name_len or not extra_len then return nil end
    if name_len > 4096 or extra_len > 65535 then return nil end
    local data_off = entry.local_off + 30 + name_len + extra_len
    if data_off < 0 or data_off + entry.csize > size then return nil end
    if entry.csize == 0 then return "" end
    if not f:seek("set", data_off) then return nil end
    local data = f:read(entry.csize)
    if type(data) ~= "string" or #data ~= entry.csize then return nil end
    if entry.method == 0 then
        if entry.csize ~= entry.usize then return nil end
        return data
    end
    return inflate(data, entry.usize)
end

local function centralDirectory(cd)
    local entries = {}
    local pos = 1
    while pos + 45 <= #cd do
        if cd:sub(pos, pos + 3) ~= "PK\001\002" then return nil end
        if #entries >= MAX_ENTRIES then return nil end
        local flags = u16(cd, pos + 8)
        local method = u16(cd, pos + 10)
        local csize = u32(cd, pos + 20)
        local usize = u32(cd, pos + 24)
        local name_len = u16(cd, pos + 28)
        local extra_len = u16(cd, pos + 30)
        local comment_len = u16(cd, pos + 32)
        local local_off = u32(cd, pos + 42)
        if not (flags and method and csize and usize and name_len and extra_len and comment_len and local_off) then
            return nil
        end
        if csize == 0xFFFFFFFF or usize == 0xFFFFFFFF or local_off == 0xFFFFFFFF then
            return nil
        end
        local name = cd:sub(pos + 46, pos + 45 + name_len)
        if #name ~= name_len then return nil end
        local safe = zipPath(name)
        if safe and safe:sub(-1) ~= "/" then
            entries[#entries + 1] = {
                name = safe,
                flags = flags,
                method = method,
                csize = csize,
                usize = usize,
                local_off = local_off,
            }
        end
        pos = pos + 46 + name_len + extra_len + comment_len
    end
    return entries
end

local function findNamed(entries, name)
    local want = zipPath(name)
    if not want then return nil end
    local lower = want:lower()
    local folded
    for i = 1, #entries do
        local n = entries[i].name
        if n == want then return entries[i] end
        if not folded and n:lower() == lower then folded = entries[i] end
    end
    return folded
end

local function rootfile(xml)
    if type(xml) ~= "string" then return nil end
    local path = xml:match("[Ff][Uu][Ll][Ll]%-[Pp][Aa][Tt][Hh]%s*=%s*\"([^\"]+)\"")
        or xml:match("[Ff][Uu][Ll][Ll]%-[Pp][Aa][Tt][Hh]%s*=%s*'([^']+)'")
    return zipPath(path)
end

local function firstOpf(entries)
    for i = 1, #entries do
        if entries[i].name:lower():match("%.opf$") then return entries[i] end
    end
    return nil
end

local function readHandle(f, timed_out)
    if timed_out() then return nil end
    local size = f:seek("end")
    if type(size) ~= "number" or size < 22 then return nil end
    local n = math.min(size, MAX_TAIL)
    if not f:seek("set", size - n) then return nil end
    local tail = f:read(n)
    if type(tail) ~= "string" or #tail ~= n then return nil end
    local eocd = findEOCD(tail)
    if not eocd then return nil end
    local count = u16(tail, eocd + 10)
    local cd_size = u32(tail, eocd + 12)
    local cd_off = u32(tail, eocd + 16)
    if not count or not cd_size or not cd_off then return nil end
    if count == 0 or count == 0xFFFF or count > MAX_ENTRIES then return nil end
    if cd_size == 0 or cd_size == 0xFFFFFFFF or cd_size > MAX_CD then return nil end
    if cd_off == 0xFFFFFFFF or cd_off + cd_size > size then return nil end
    if timed_out() then return nil end
    if not f:seek("set", cd_off) then return nil end
    local cd = f:read(cd_size)
    if type(cd) ~= "string" or #cd ~= cd_size then return nil end
    local entries = centralDirectory(cd)
    if not entries then return nil end
    local opf
    local container = findNamed(entries, "META-INF/container.xml")
    if container then
        local xml = extract(f, container, size, timed_out)
        local path = rootfile(xml)
        if path then opf = findNamed(entries, path) end
    end
    if not opf then opf = firstOpf(entries) end
    if not opf then return nil end
    local xml = extract(f, opf, size, timed_out)
    return M.fromOpf(xml)
end

local function isEpub(path)
    return type(path) == "string" and path:lower():match("%.epub$") ~= nil
end

--- Publication year inside an EPUB, or nil. Other paths are not opened.
-- `opts.clock` defaults to `os.clock`. `opts.budget` is seconds allowed
-- between reads (default 0.2). A budget that is already spent returns nil
-- without reading the book.
function M.fromEpub(path, opts)
    if not isEpub(path) then return nil end
    opts = type(opts) == "table" and opts or {}
    local clock = opts.clock
    if type(clock) ~= "function" then clock = os.clock end
    local budget = opts.budget
    if type(budget) ~= "number" then budget = DEFAULT_BUDGET end
    local ok_t, t0 = pcall(clock)
    if not ok_t or type(t0) ~= "number" then t0 = 0 end
    local deadline = t0 + budget
    local function timed_out()
        local ok_c, now = pcall(clock)
        if not ok_c or type(now) ~= "number" then return true end
        return now >= deadline
    end
    if timed_out() then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local ok, year = pcall(readHandle, f, timed_out)
    pcall(function() f:close() end)
    if not ok then return nil end
    return year
end

return M
