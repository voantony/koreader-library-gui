--[[--
Grid tiles and small widgets for the Library view: book tiles with progress
badges, group tiles (collections, authors, series) and filter chips.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

----------------------------------------------------------------------------
-- Cover cache: scaled blitbuffers keyed by path and size.
-- Keeps the last pages in memory so paging back and forth and live search
-- do not decompress covers from the database again.
----------------------------------------------------------------------------

local CoverCache = {}
CoverCache.__index = CoverCache

function M.newCoverCache(max_items)
    return setmetatable({ max = max_items or 64, items = {}, order = {} }, CoverCache)
end

-- Buffers are never freed by hand: a tile on screen may still hold one that
-- the cache has dropped, and freeing it would let another cover reuse the
-- memory (wrong cover painted). Blitbuffers have a GC finalizer, so dropping
-- the reference is enough.
function CoverCache:get(key)
    local bb = self.items[key]
    if bb ~= nil then
        -- least-recently-used: move the key to the newest end
        for i, k in ipairs(self.order) do
            if k == key then table.remove(self.order, i); break end
        end
        table.insert(self.order, key)
    end
    return bb
end

function CoverCache:put(key, bb)
    if self.items[key] ~= nil then return end
    self.items[key] = bb
    table.insert(self.order, key)
    while #self.order > self.max do
        local old = table.remove(self.order, 1)
        self.items[old] = nil
    end
end

function CoverCache:drop(key)
    if self.items[key] == nil then return end
    self.items[key] = nil
    for i, k in ipairs(self.order) do
        if k == key then table.remove(self.order, i); break end
    end
end

function CoverCache:clear()
    self.items, self.order = {}, {}
end

--- Fit (w, h) inside (max_w, max_h) keeping the aspect ratio.
local function fit(w, h, max_w, max_h)
    local scale = math.min(max_w / w, max_h / h)
    return math.max(1, math.floor(w * scale + 0.5)), math.max(1, math.floor(h * scale + 0.5))
end
M.fit = fit

--- Return a scaled cover blitbuffer for `path`, or nil.
-- `bim` is the BookInfoManager (or nil). Results, including "no cover yet",
-- are cached; call cache:drop(path) after a background extraction fills it in.
function M.getCover(cache, bim, path, max_w, max_h)
    local key = path .. "@" .. max_w .. "x" .. max_h
    local cached = cache:get(key)
    if cached ~= nil then return cached or nil, cached ~= false end
    if not bim then return nil, false end
    local ok, info = pcall(bim.getBookInfo, bim, path, true)
    if not ok or not info then return nil, false end -- not in DB yet: do not cache
    if not info.cover_bb then
        if info.cover_fetched then cache:put(key, false) end
        return nil, info.cover_fetched and true or false
    end
    local bb = info.cover_bb
    local w, h = fit(bb:getWidth(), bb:getHeight(), max_w, max_h)
    local RenderImage = require("ui/renderimage")
    local scaled = RenderImage:scaleBlitBuffer(bb, w, h, true) -- frees the original
    cache:put(key, scaled)
    return scaled, true
end

----------------------------------------------------------------------------
-- Faces
----------------------------------------------------------------------------

local faces
local function getFaces()
    if not faces then
        faces = {
            title = Font:getFace("cfont", 15),
            sub = Font:getFace("cfont", 13),
            placeholder_title = Font:getFace("cfont", 17),
            placeholder_sub = Font:getFace("cfont", 14),
            badge = Font:getFace("cfont", 13),
            chip = Font:getFace("cfont", 16),
        }
    end
    return faces
end
M.getFaces = getFaces

function M.labelHeight()
    local f = getFaces()
    local t = TextWidget:new{ text = "Ag", face = f.title, bold = true }
    local s = TextWidget:new{ text = "Ag", face = f.sub }
    local h = t:getSize().h + s:getSize().h + Size.padding.small
    t:free(); s:free()
    return h
end

----------------------------------------------------------------------------
-- Placeholder cover
----------------------------------------------------------------------------

local function placeholder(w, h, title, subtitle)
    local f = getFaces()
    local inner_w = w - 2 * Size.padding.default - 2 * Size.border.thin
    local group = VerticalGroup:new{ align = "center" }
    table.insert(group, TextBoxWidget:new{
        text = title or "",
        face = f.placeholder_title,
        bold = true,
        width = inner_w,
        alignment = "center",
        height = math.floor(h * 0.55),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        bgcolor = Blitbuffer.COLOR_GRAY_E,
    })
    if subtitle and subtitle ~= "" then
        table.insert(group, VerticalSpan:new{ width = Size.padding.default })
        table.insert(group, TextBoxWidget:new{
            text = subtitle,
            face = f.placeholder_sub,
            width = inner_w,
            alignment = "center",
            height = math.floor(h * 0.25),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            bgcolor = Blitbuffer.COLOR_GRAY_E,
        })
    end
    return FrameContainer:new{
        width = w,
        height = h,
        padding = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_GRAY_E,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * Size.border.thin, h = h - 2 * Size.border.thin },
            group,
        },
    }
end

----------------------------------------------------------------------------
-- Badges
----------------------------------------------------------------------------

local function pill(text, inverted)
    local f = getFaces()
    return FrameContainer:new{
        padding = 0,
        padding_left = Size.padding.small,
        padding_right = Size.padding.small,
        bordersize = Size.border.thin,
        radius = Size.radius.default,
        background = inverted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        TextWidget:new{
            text = text,
            face = f.badge,
            bold = true,
            fgcolor = inverted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
            bgcolor = inverted and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        },
    }
end
M.pill = pill

--- Overlay the progress decorations on a cover of size (w, h).
local function decorate(cover, w, h, book)
    local layers = OverlapGroup:new{ dimen = Geom:new{ w = w, h = h }, allow_mirroring = false, cover }
    local m = Size.padding.small
    if book.status == "complete" then
        local p = pill("\u{2713}", true)
        p.overlap_offset = { w - p:getSize().w - m, m }
        table.insert(layers, p)
    elseif book.status == "new" then
        local p = pill(_("NEW"), false)
        p.overlap_offset = { w - p:getSize().w - m, m }
        table.insert(layers, p)
    elseif book.percent then
        local bar_h = Screen:scaleBySize(7)
        local bar = ProgressWidget:new{
            width = w - 2 * m,
            height = bar_h,
            percentage = book.percent,
            margin_h = 0, margin_v = 0,
            bordersize = Size.border.thin,
            radius = 0,
            fillcolor = Blitbuffer.COLOR_BLACK,
            bgcolor = Blitbuffer.COLOR_WHITE,
        }
        bar.overlap_offset = { m, h - bar_h - m }
        table.insert(layers, bar)
    end
    if book.status == "abandoned" then
        local p = pill(_("on hold"), false)
        p.overlap_offset = { m, m }
        table.insert(layers, p)
    end
    return layers
end

function M.statusLine(book)
    if book.status == "complete" then return _("Finished") end
    if book.status == "abandoned" then return _("On hold") end
    if book.percent and book.status ~= "new" then
        return T(_("%1 % read"), math.floor(book.percent * 100 + 0.5))
    end
    return nil
end

----------------------------------------------------------------------------
-- Tile (a book or a group)
----------------------------------------------------------------------------

local Tile = InputContainer:extend{
    width = nil,
    height = nil,
    cover_h = nil,
    book = nil,      -- for book tiles
    group = nil,     -- { name=, books=, cover_book= } for group tiles
    bim = nil,
    cover_cache = nil,
    on_tap = nil,
    on_hold = nil,
}
M.Tile = Tile

function Tile:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        TapTile = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldTile = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    local f = getFaces()
    local pad = Size.padding.small
    local cover_w = self.width - 2 * pad
    local cover_h = self.cover_h - pad
    local book = self.book or (self.group and self.group.cover_book)

    local bb, known
    if book then
        bb, known = M.getCover(self.cover_cache, self.bim, book.path, cover_w, cover_h)
    end
    self.needs_cover = book and not known and self.bim ~= nil
    local cover
    if bb then
        local cw, ch = bb:getWidth(), bb:getHeight()
        local img = ImageWidget:new{ image = bb, image_disposable = false, width = cw, height = ch }
        cover = FrameContainer:new{ padding = 0, bordersize = Size.border.thin, img }
        cover_w, cover_h = cw + 2 * Size.border.thin, ch + 2 * Size.border.thin
    else
        local title, sub
        if self.group then
            title, sub = self.group.name, nil
        else
            title = book.title
            sub = book.authors and table.concat(book.authors, ", ")
        end
        local ph_w = math.min(cover_w, math.floor(cover_h * 2 / 3 + 0.5))
        cover = placeholder(ph_w, cover_h, title, sub)
        cover_w = ph_w
    end
    if self.group then
        local p = pill(tostring(#self.group.books), true)
        cover = OverlapGroup:new{ dimen = Geom:new{ w = cover_w, h = cover_h }, allow_mirroring = false, cover }
        p.overlap_offset = { cover_w - p:getSize().w - pad, cover_h - p:getSize().h - pad }
        table.insert(cover, p)
    else
        cover = decorate(cover, cover_w, cover_h, book)
    end

    local line1, line2
    if self.group then
        line1 = self.group.name
        line2 = T(_("%1 books"), #self.group.books)
        if #self.group.books == 1 then line2 = _("1 book") end
    else
        line1 = book.title
        line2 = M.statusLine(book) or (book.authors and book.authors[1]) or ""
    end
    local label = VerticalGroup:new{
        align = "center",
        TextWidget:new{ text = line1 or "", face = f.title, bold = true, max_width = self.width - 2 * pad },
        TextWidget:new{ text = line2, face = f.sub, max_width = self.width - 2 * pad, fgcolor = Blitbuffer.COLOR_GRAY_3 },
    }
    self[1] = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = pad },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.cover_h - pad },
            cover,
        },
        label,
    }
end

function Tile:getSize()
    return self.dimen
end

function Tile:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end

function Tile:onTapTile()
    if self.on_tap then self.on_tap(self) end
    return true
end

function Tile:onHoldTile()
    if self.on_hold then self.on_hold(self) end
    return true
end

----------------------------------------------------------------------------
-- Chip (tabs and status filters)
----------------------------------------------------------------------------

local Chip = InputContainer:extend{
    text = nil,
    selected = false,
    callback = nil,
    width = nil,
}
M.Chip = Chip

function Chip:init()
    local f = getFaces()
    local fg = self.selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local bg = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local text = TextWidget:new{ text = self.text, face = f.chip, bold = self.selected, fgcolor = fg, bgcolor = bg,
        max_width = self.width and (self.width - 2 * Size.padding.default) or nil }
    local frame = FrameContainer:new{
        padding = Size.padding.small,
        padding_left = Size.padding.default,
        padding_right = Size.padding.default,
        bordersize = Size.border.thin,
        radius = Size.radius.button,
        background = bg,
        width = self.width,
        CenterContainer:new{
            dimen = Geom:new{
                w = (self.width or (text:getSize().w + 2 * Size.padding.default)) - 2 * Size.padding.default - 2 * Size.border.thin,
                h = text:getSize().h,
            },
            text,
        },
    }
    self[1] = frame
    self.dimen = Geom:new{ x = 0, y = 0, w = frame:getSize().w, h = frame:getSize().h }
    self.ges_events = { TapChip = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function Chip:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end

function Chip:onTapChip()
    if self.callback then self.callback() end
    return true
end

return M
