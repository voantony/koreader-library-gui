--- Home-screen widgets above the book grid (#1).
-- At most two sit side by side. The default, when the reader has not
-- chosen, is the single Continue reading strip the library already had.
-- Long-pressing a widget title switches that slot. "None" removes it.
-- With no widgets left, the books use the full area, as when
-- "Show Continue Reading" is unchecked.
local Widgets = {}

Widgets.MAX = 2

-- Menu order matches the issue: Continue Reading, Favorites, then a
-- series, a collection, or a folder. None hides the slot.
Widgets.CHOICES = {
    { kind = "continue", label = "Continue Reading" },
    { kind = "favorites", label = "Favorites" },
    { kind = "series", label = "A series", pick = true },
    { kind = "collection", label = "A collection", pick = true },
    { kind = "folder", label = "A folder", pick = true },
    { kind = "none", label = "None" },
}

local function copySpec(spec)
    if type(spec) ~= "table" or type(spec.kind) ~= "string" or spec.kind == "none" or spec.kind == "" then
        return nil
    end
    return {
        kind = spec.kind,
        name = type(spec.name) == "string" and spec.name or nil,
        path = type(spec.path) == "string" and spec.path or nil,
    }
end

--- 0–2 widgets. Drops empty slots. Ignores anything past the second.
function Widgets.normalize(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, spec in ipairs(list) do
        local item = copySpec(spec)
        if item then out[#out + 1] = item end
        if #out >= Widgets.MAX then break end
    end
    return out
end

--- What the library shows before the reader has saved a choice.
-- Continue reading on (the shipped default) is one Continue Reading widget.
-- The old toggle off is no widgets.
function Widgets.defaultFromContinue(show_continue)
    if show_continue == false then return {} end
    return { { kind = "continue" } }
end

--- The configured slots. A saved list, even an empty one, wins over the
-- old Show Continue Reading toggle.
function Widgets.slots(settings)
    if type(settings) == "table" and settings.home_widgets ~= nil then
        return Widgets.normalize(settings.home_widgets)
    end
    local show = not (type(settings) == "table" and settings.show_continue == false)
    return Widgets.defaultFromContinue(show)
end

--- True when the saved list is in use. Nil means "keep today's strip".
function Widgets.customized(settings)
    return type(settings) == "table" and settings.home_widgets ~= nil
end

--- Same gates as the Continue reading strip: Books tab, no open shelf,
-- no search, no filter, keyboard down. An empty slot list is hidden.
function Widgets.areaVisible(slots, state)
    state = state or {}
    if type(slots) ~= "table" or #slots < 1 then return false end
    if state.tab ~= "books" or state.group then return false end
    if state.query and tostring(state.query):match("%S") then return false end
    if state.filter and state.filter ~= "all" then return false end
    if state.keyboard then return false end
    return true
end

function Widgets.label(spec)
    if type(spec) ~= "table" then return "" end
    if spec.kind == "continue" then return "Continue Reading" end
    if spec.kind == "favorites" then return "Favorites" end
    if spec.kind == "series" then return spec.name or "Series" end
    if spec.kind == "collection" then return spec.name or "Collection" end
    if spec.kind == "folder" then
        local path = spec.path or ""
        return path:match("([^/]+)$") or path
    end
    return spec.kind or ""
end

local function byName(groups, name)
    if type(name) ~= "string" or name == "" then return {} end
    for _, g in ipairs(groups or {}) do
        if g.name == name then return g.books or {} end
    end
    return {}
end

--- Books for one widget. `ctx.favorites` is the Favorites collection.
-- `ctx.series` and `ctx.collections` are { name, books } lists.
-- A folder is the directory of indexed books, matched by path prefix.
function Widgets.books(spec, ctx)
    ctx = ctx or {}
    if type(spec) ~= "table" then return {} end
    if spec.kind == "continue" then return ctx.continue or {} end
    if spec.kind == "favorites" then return ctx.favorites or {} end
    if spec.kind == "series" then return byName(ctx.series, spec.name) end
    if spec.kind == "collection" then return byName(ctx.collections, spec.name) end
    if spec.kind == "folder" then
        local prefix = spec.path
        if type(prefix) ~= "string" or prefix == "" then return {} end
        if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
        local out = {}
        for _, book in ipairs(ctx.all or {}) do
            local path = type(book) == "table" and book.path or nil
            if type(path) == "string" and (path:sub(1, #prefix) == prefix or path == spec.path) then
                out[#out + 1] = book
            end
        end
        return out
    end
    return {}
end

--- Replace slot `index` (1 or 2). "none" removes it and closes the gap.
-- Returns the new list. Does not mutate `slots`.
function Widgets.setSlot(slots, index, spec)
    local list = Widgets.normalize(slots)
    index = math.floor(tonumber(index) or 1)
    if index < 1 then index = 1 end
    if index > Widgets.MAX then index = Widgets.MAX end
    local item = copySpec(spec)
    if not item then
        table.remove(list, index)
        return list
    end
    if index > #list + 1 then index = #list + 1 end
    list[index] = item
    return Widgets.normalize(list)
end

--- Parent directories of indexed books, for the folder picker.
function Widgets.folderChoices(books)
    local seen, out = {}, {}
    for _, book in ipairs(books or {}) do
        local path = type(book) == "table" and book.path or nil
        local dir = type(path) == "string" and path:match("^(.*)/[^/]+$") or nil
        if dir and dir ~= "" and not seen[dir] then
            seen[dir] = true
            out[#out + 1] = dir
        end
    end
    table.sort(out)
    return out
end

function Widgets.names(groups)
    local out = {}
    for _, g in ipairs(groups or {}) do
        if type(g.name) == "string" and g.name ~= "" then out[#out + 1] = g.name end
    end
    return out
end

return Widgets
