-- Details card authors: an author with only this book in the library is
-- plain text; authors with 2+ books stay tappable. Counts match the Authors tab.
local Core = require("librarycore")

local function books()
    return {
        { path = "/e", title = "Emma", authors = { "Jane Austen" } },
        { path = "/p", title = "Pride", authors = { "Jane Austen" } },
        { path = "/b", title = "Black Beauty", authors = { "Anna Sewell" } },
        { path = "/g", title = "Good Omens", authors = { "Terry Pratchett", "Neil Gaiman" } },
        { path = "/m", title = "Mort", authors = { "Terry Pratchett" } },
    }
end

describe("author links on the details card", function()
    it("a 1-book author is not linked", function()
        same(Core.authorLinks({ "Anna Sewell" }, books()), { false })
    end)

    it("a 2-book author is linked", function()
        same(Core.authorLinks({ "Jane Austen" }, books()), { true })
    end)

    it("a multi-author book links each author on their own count", function()
        same(Core.authorLinks({ "Terry Pratchett", "Neil Gaiman" }, books()), { true, false })
    end)

    it("matches names like the Authors tab tap does (case-insensitive)", function()
        same(Core.authorLinks({ "jane austen" }, books(), nil, string.lower), { true })
    end)

    it("keeps every author tappable when no books are known yet", function()
        same(Core.authorLinks({ "Anna Sewell", "Jane Austen" }, {}), { true, true })
        same(Core.authorLinks({ "Anna Sewell" }, nil), { true })
        same(Core.authorLinks(nil, books()), {})
    end)

    it("agrees with the Authors tab book counts", function()
        local counts = {}
        for _, g in ipairs(Core.group(books(), "author")) do counts[g.key] = #g.books end
        for _, name in ipairs({ "Jane Austen", "Anna Sewell", "Terry Pratchett", "Neil Gaiman" }) do
            eq(Core.authorLinks({ name }, books())[1], counts[name] >= 2, name)
        end
    end)
end)

-- The card itself, with KOReader widgets stubbed: plain names get no tap.
local function widget(kind)
    local cls = { kind = kind }
    cls.__index = cls
    function cls:extend(o) o = o or {}; o.__index = o; o.kind = o.kind or kind; return setmetatable(o, self) end
    function cls:new(o)
        o = setmetatable(o or {}, self)
        if o.init then o:init() end
        return o
    end
    function cls:getSize() return { w = 10, h = 10 } end
    return cls
end

local function loadDetails()
    local stub
    stub = function()
        return setmetatable({}, { __index = function() return stub() end, __call = function() return stub() end })
    end
    local mods = {
        ["ui/widget/container/inputcontainer"] = widget("input"),
        ["ui/widget/textwidget"] = widget("text"),
        ["ui/widget/horizontalgroup"] = widget("hgroup"),
        ["ui/widget/verticalgroup"] = widget("vgroup"),
        ["ui/widget/verticalspan"] = widget("vspan"),
        ["ui/widget/horizontalspan"] = widget("hspan"),
        ["ui/widget/linewidget"] = widget("line"),
        ["ui/geometry"] = widget("geom"),
        ["ui/gesturerange"] = widget("range"),
        ["ui/size"] = { padding = { default = 4, small = 2 }, line = { thin = 1 } },
        ["ui/font"] = { getFace = function() return {} end },
        gettext = function(s) return s end,
        ["ffi/util"] = { template = function(s) return s end },
    }
    local old = require
    _G.require = function(name)
        if mods[name] ~= nil then return mods[name] end
        if name == "librarycore" then return old(name) end
        return stub()
    end
    local ok, mod = pcall(dofile, "library.koplugin/librarydetails.lua")
    _G.require = old
    if not ok then error(mod, 0) end
    return mod
end

describe("details card author names", function()
    local Details = loadDetails()

    local function names(info)
        local card = setmetatable({ info = info, on_shelf = function(kind, name)
            _G.__shelf = kind .. ":" .. name
        end }, { __index = Details })
        local col = card:buildAuthors(500)
        local out = {}
        local function walk(w)
            if type(w) ~= "table" then return end
            if w.onTapLink then out[#out + 1] = { text = w.text, link = true, w = w }; return end
            if w.kind == "text" and w.text ~= "," then out[#out + 1] = { text = w.text, link = false }; return end
            for _, c in ipairs(w) do walk(c) end
        end
        walk(col)
        return out
    end

    it("draws a 1-book author as plain text and a 2-book author as a link", function()
        local got = names({ authors = { "Terry Pratchett", "Neil Gaiman" }, author_links = { true, false } })
        eq(#got, 2)
        eq(got[1].text, "Terry Pratchett"); eq(got[1].link, true)
        eq(got[2].text, "Neil Gaiman"); eq(got[2].link, false)
        _G.__shelf = nil
        got[1].w:onTapLink()
        eq(_G.__shelf, "authors:Terry Pratchett")
    end)

    it("links every author when no counts were given", function()
        local got = names({ authors = { "Anna Sewell" } })
        eq(got[1].link, true)
    end)
end)
