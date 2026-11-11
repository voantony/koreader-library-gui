--- Backup and restore of the library_plugin settings table.
-- Files live in KOReader's settings directory. This module does not
-- open settings.reader.lua. The caller saves through G_reader_settings.
local S = {}

S.PREFIX = "library_plugin_settings.backup."
S.KEEP = 3
S.MAX_BYTES = 512 * 1024
S.MAX_DEPTH = 12

function S.backupName(now)
    now = tonumber(now) or os.time()
    return S.PREFIX .. os.date("!%Y%m%d-%H%M%S", now) .. ".lua"
end

function S.isBackupName(name)
    return type(name) == "string" and name:match("^" .. S.PREFIX:gsub("%.", "%%.") .. "%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%.lua$") ~= nil
end

--- Newest first. Names that are not backups are dropped.
function S.sorted(names)
    local out = {}
    for _, name in ipairs(names or {}) do
        if S.isBackupName(name) then out[#out + 1] = name end
    end
    table.sort(out, function(a, b) return a > b end)
    return out
end

--- Names to delete once `keep` newest backups remain.
function S.expired(names, keep)
    keep = keep or S.KEEP
    local sorted = S.sorted(names)
    local drop = {}
    for i = keep + 1, #sorted do drop[#drop + 1] = sorted[i] end
    return drop
end

local function serialize(v, depth)
    depth = depth or 0
    if depth > S.MAX_DEPTH then return nil, "too deep" end
    local tv = type(v)
    if tv == "boolean" then return v and "true" or "false" end
    if tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return nil, "bad number" end
        return string.format("%.17g", v)
    end
    if tv == "string" then return string.format("%q", v) end
    if tv ~= "table" then return nil, "unsupported value" end
    local parts, seen = {}, {}
    for i = 1, #v do
        local item, err = serialize(v[i], depth + 1)
        if not item then return nil, err end
        parts[#parts + 1] = item
        seen[i] = true
    end
    local keys = {}
    for k in pairs(v) do
        if not seen[k] then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        if type(k) ~= "string" then return nil, "bad key" end
        local item, err = serialize(v[k], depth + 1)
        if not item then return nil, err end
        parts[#parts + 1] = string.format("[%q]=%s", k, item)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function S.serialize(settings)
    local body, err = serialize(settings, 0)
    if not body then return nil, err end
    return "return " .. body .. "\n"
end

function S.deepCopy(v, depth)
    depth = depth or 0
    if depth > S.MAX_DEPTH then return nil end
    if type(v) ~= "table" then return v end
    local out = {}
    for k, item in pairs(v) do
        out[k] = S.deepCopy(item, depth + 1)
    end
    return out
end

function S.validate(settings, depth)
    depth = depth or 0
    if depth > S.MAX_DEPTH then return false, "too deep" end
    if type(settings) ~= "table" then return false, "not a settings table" end
    for k, v in pairs(settings) do
        if type(k) ~= "string" and type(k) ~= "number" then return false, "bad key" end
        local tv = type(v)
        if tv == "table" then
            local ok, err = S.validate(v, depth + 1)
            if not ok then return false, err end
        elseif tv ~= "string" and tv ~= "number" and tv ~= "boolean" then
            return false, "unsupported value"
        end
    end
    return true
end

function S.writeBackup(fs, dir, settings, now)
    if type(fs) ~= "table" or type(fs.write) ~= "function" or type(fs.list) ~= "function" then
        return nil, "no settings folder"
    end
    if type(dir) ~= "string" or dir == "" then return nil, "no settings folder" end
    local ok, err = S.validate(settings)
    if not ok then return nil, err end
    local text, serr = S.serialize(settings)
    if not text then return nil, serr end
    if #text > S.MAX_BYTES then return nil, "settings are too large" end
    local name = S.backupName(now)
    local path = dir .. "/" .. name
    local wrote, werr = fs.write(path, text)
    if not wrote then return nil, werr or "could not write the backup" end
    local names = fs.list(dir) or {}
    if type(fs.remove) == "function" then
        for _, old in ipairs(S.expired(names, S.KEEP)) do
            fs.remove(dir .. "/" .. old)
        end
    end
    return path
end

function S.decode(text)
    if type(text) ~= "string" or #text == 0 or #text > S.MAX_BYTES then
        return nil, "backup is empty or too large"
    end
    if not text:match("^%s*return%s") then return nil, "backup is not a settings file" end
    local chunk, lerr = loadstring(text)
    if not chunk then return nil, lerr or "backup could not be read" end
    if setfenv then setfenv(chunk, {}) end
    local ok, value = pcall(chunk)
    if not ok then return nil, "backup could not be read" end
    local valid, verr = S.validate(value)
    if not valid then return nil, verr end
    return value
end

function S.readBackup(fs, path)
    if type(fs) ~= "table" or type(fs.read) ~= "function" then return nil, "backup could not be read" end
    local text = fs.read(path)
    if type(text) ~= "string" then return nil, "backup could not be read" end
    return S.decode(text)
end

--- The filesystem KOReader's settings directory is used with.
function S.ioFS()
    local lfs = require("lfs")
    return {
        write = function(path, text)
            local f, err = io.open(path, "wb")
            if not f then return nil, err end
            f:write(text)
            f:close()
            return true
        end,
        read = function(path)
            local f = io.open(path, "rb")
            if not f then return nil end
            local text = f:read("*a")
            f:close()
            return text
        end,
        list = function(dir)
            local names = {}
            for name in lfs.dir(dir) do
                if name ~= "." and name ~= ".." then names[#names + 1] = name end
            end
            return names
        end,
        remove = function(path)
            os.remove(path)
            return true
        end,
    }
end

return S
