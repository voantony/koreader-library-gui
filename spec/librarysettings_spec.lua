-- Settings backup files: serialize, keep the last three, restore only a real table.
local S = require("librarysettings")

local function memoryFs()
    local files = {}
    return {
        files = files,
        write = function(path, text)
            files[path] = text
            return true
        end,
        read = function(path) return files[path] end,
        list = function(dir)
            local names = {}
            local prefix = dir .. "/"
            for path in pairs(files) do
                if path:sub(1, #prefix) == prefix then
                    names[#names + 1] = path:sub(#prefix + 1)
                end
            end
            return names
        end,
        remove = function(path)
            files[path] = nil
            return true
        end,
    }
end

describe("settings backup", function()
    local saved = {
        view = "compact2",
        columns = 5,
        sort = "title",
        show_scrubber = true,
        filter_expands = false,
        view_memory = {
            ["tab:authors"] = { view = "list", sort = "author", filter = "unread", t = 9 },
        },
    }

    it("round-trips a v0.7.7-style table and rejects anything that is not settings", function()
        local text = S.serialize(saved)
        eq(type(text), "string")
        eq(text:match("^return "), "return ")
        local back = S.decode(text)
        eq(back.view, "compact2")
        eq(back.columns, 5)
        eq(back.view_memory["tab:authors"].view, "list")
        eq(back.view_memory["tab:authors"].filter, "unread")
        eq(S.decode("os.execute('rm')"), nil)
        eq(S.decode("return function() end"), nil)
        eq(S.decode("return 1"), nil)
        eq(S.validate({ nested = { ok = true } }), true)
    end)

    it("writes a timestamped file and keeps only the last three", function()
        local fs = memoryFs()
        local dir = "/settings"
        local paths = {}
        for _, t in ipairs({ 1700000001, 1700000002, 1700000003, 1700000004 }) do
            local path = S.writeBackup(fs, dir, saved, t)
            eq(type(path), "string")
            eq(S.isBackupName(path:match("([^/]+)$")), true)
            paths[#paths + 1] = path
        end
        eq(fs.files[paths[1]], nil, "the oldest backup was removed")
        eq(type(fs.files[paths[2]]), "string")
        eq(type(fs.files[paths[4]]), "string")
        local names = S.sorted(fs.list(dir))
        eq(#names, 3)
        local restored = S.readBackup(fs, paths[4])
        eq(restored.view, "compact2")
        eq(restored.columns, 5)
        eq(restored ~= saved, true, "the restored table is its own copy of the values")
    end)

    it("the updater can ask for a backup without touching settings.reader.lua", function()
        local Update = require("libraryupdate")
        local fs = memoryFs()
        local path = Update.saveSettingsBackup({ settings = saved }, fs, "/settings", 1700000100)
        eq(type(path), "string")
        eq(fs.files[path]:match("^return "), "return ")
        eq(Update.saveSettingsBackup({}), true, "nothing saved is not a failure")
        eq(Update.saveSettingsBackup({ settings = { bad = function() end } }, fs, "/settings", 1700000101), nil)
    end)
end)
