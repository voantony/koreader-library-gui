-- Minimal test runner: `luajit spec/run.lua` from the repository root.
-- No dependencies beyond LuaJIT / Lua 5.1.
package.path = "./library.koplugin/?.lua;./spec/?.lua;" .. package.path

local passed, failed, failures = 0, 0, {}
local current = ""

_G.describe = function(name, fn)
    local prev = current
    current = (prev ~= "" and prev .. " › " or "") .. name
    fn()
    current = prev
end

_G.it = function(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write(".")
    else
        failed = failed + 1
        io.write("F")
        table.insert(failures, current .. " › " .. name .. "\n    " .. tostring(err))
    end
end

local function show(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

_G.eq = function(actual, expected, msg)
    if actual ~= expected then
        error((msg and msg .. ": " or "") .. "expected " .. show(expected) .. ", got " .. show(actual), 2)
    end
end

_G.same = function(actual, expected, msg)
    local function deep(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for k, v in pairs(a) do if not deep(v, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end
    if not deep(actual, expected) then
        local function dump(t)
            if type(t) ~= "table" then return show(t) end
            local parts = {}
            for k, v in pairs(t) do table.insert(parts, tostring(k) .. "=" .. dump(v)) end
            table.sort(parts)
            return "{" .. table.concat(parts, ", ") .. "}"
        end
        error((msg and msg .. ": " or "") .. "expected " .. dump(expected) .. ", got " .. dump(actual), 2)
    end
end

for _, spec in ipairs({ "librarycore_spec", "libraryindex_spec", "librarycovers_spec", "libraryfeatures_spec", "librarysh_spec", "librarysearchtap_spec", "librarygui_spec", "libraryviewmemory_spec", "librarycontrols_spec" }) do
    require(spec)
end

io.write("\n")
for _, f in ipairs(failures) do print("FAIL: " .. f) end
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
