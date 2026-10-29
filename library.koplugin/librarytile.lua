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
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local Core = require("librarycore")
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

local function scaleInto(cache, key, bb, max_w, max_h)
    local w, h = fit(bb:getWidth(), bb:getHeight(), max_w, max_h)
    local RenderImage = require("ui/renderimage")
    local scaled = RenderImage:scaleBlitBuffer(bb, w, h, true) -- frees the original
    cache:put(key, scaled)
    return scaled
end

--- Return a scaled cover blitbuffer for `book`, or nil, and whether the
-- answer is final (false: not extracted yet, the caller should queue it).
-- `covers` = { store = librarycovers Store or nil, bim = BookInfoManager or nil }.
-- Sources, first hit wins:
--   1. the in-memory cache of scaled covers;
--   2. the built-in thumbnail file (small JPEG, cheapest to decode);
--   3. the cover browser database (Project: Title or Cover browser) if loaded.
-- Results, including "no cover", are cached; call cache:drop() or clear()
-- after a background extraction fills one in.
function M.getCover(cache, covers, book, max_w, max_h)
    local path = book.path
    local key = path .. "@" .. max_w .. "x" .. max_h
    local cached = cache:get(key)
    if cached ~= nil then return cached or nil, cached ~= false end
    covers = covers or {}
    local state, file
    if covers.store then
        state, file = covers.store:state(book)
        if state == "cover" then
            local bb = require("librarycovers").loadThumb(file)
            if bb then return scaleInto(cache, key, bb, max_w, max_h), true end
            covers.store:forget(path) -- unreadable thumbnail: extract again
            state = nil
        end
    end
    if covers.bim then
        local ok, info = pcall(covers.bim.getBookInfo, covers.bim, path, true)
        if ok and info then
            if info.cover_bb then return scaleInto(cache, key, info.cover_bb, max_w, max_h), true end
            if info.cover_fetched then
                cache:put(key, false)
                return nil, true
            end
        end
        if state == "none" then cache:put(key, false); return nil, true end
        return nil, false
    end
    if state == "none" then
        cache:put(key, false)
        return nil, true
    end
    return nil, false
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

--- Height of the text under a cover: title and a second line, or the
-- title only when `one_line` (Continue reading, where the bar shows progress).
function M.labelHeight(one_line)
    local f = getFaces()
    local t = TextWidget:new{ text = "Ag", face = f.title, bold = true }
    local s = TextWidget:new{ text = "Ag", face = f.sub }
    local h = t:getSize().h + (one_line and 0 or s:getSize().h) + Size.padding.small
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

--- "3 · Title" inside a series (when the book has a number), else the title.
function M.bookTitle(book, series_number)
    local title = book.title or book.name or ""
    if series_number then
        local n = Core.seriesNumber(book.series_index)
        if n then return n .. " · " .. title end
    end
    return title
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
    covers = nil,    -- { store=, bim= }, see M.getCover
    cover_cache = nil,
    on_tap = nil,
    on_hold = nil,
    one_line = false, -- title only under the cover
    caption = nil,    -- second line instead of status/author (Continue reading)
    series_number = false, -- "3 · Title" (inside a series)
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
        bb, known = M.getCover(self.cover_cache, self.covers, book, cover_w, cover_h)
    end
    self.needs_cover = book and not known and self.covers ~= nil
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
        line1 = M.bookTitle(book, self.series_number)
        line2 = self.caption or M.statusLine(book) or (book.authors and book.authors[1]) or ""
    end
    local label = VerticalGroup:new{
        align = "center",
        TextWidget:new{ text = line1 or "", face = f.title, bold = true, max_width = self.width - 2 * pad },
    }
    if not self.one_line then
        table.insert(label, TextWidget:new{ text = line2, face = f.sub, max_width = self.width - 2 * pad,
            fgcolor = Blitbuffer.COLOR_GRAY_3 })
    end
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
-- List row (list view): thumbnail, title, author, status on the right
----------------------------------------------------------------------------

--- Smallest row that fits the two text lines with padding.
function M.listRowHeight()
    local f = getFaces()
    local t = TextWidget:new{ text = "Ag", face = f.title, bold = true }
    local s = TextWidget:new{ text = "Ag", face = f.sub }
    local h = t:getSize().h + s:getSize().h + Size.padding.small + 2 * Size.padding.default + Size.line.thin
    t:free(); s:free()
    return h
end

--- Right-hand status: a pill for finished / new / on hold, else "42 %" over a bar.
local function rowStatus(book, w)
    if book.status == "complete" then return pill("\u{2713}", true) end
    if book.status == "new" then return pill(_("NEW"), false) end
    if book.status == "abandoned" then return pill(_("on hold"), false) end
    if book.percent then
        local f = getFaces()
        return VerticalGroup:new{
            align = "right",
            TextWidget:new{ text = T(_("%1 %"), math.floor(book.percent * 100 + 0.5)), face = f.title, bold = true },
            VerticalSpan:new{ width = Size.padding.small },
            ProgressWidget:new{
                width = w,
                height = Screen:scaleBySize(6),
                percentage = book.percent,
                margin_h = 0, margin_v = 0,
                bordersize = Size.border.thin,
                radius = 0,
                fillcolor = Blitbuffer.COLOR_BLACK,
                bgcolor = Blitbuffer.COLOR_WHITE,
            },
        }
    end
    return nil
end

local ListRow = InputContainer:extend{
    width = nil,
    height = nil,
    thumb_w = nil,
    thumb_h = nil,
    book = nil,
    group = nil,
    covers = nil,
    cover_cache = nil,
    on_tap = nil,
    on_hold = nil,
    series_number = false, -- "3 · Title" (inside a series)
}
M.ListRow = ListRow

function ListRow:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        TapTile = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldTile = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    local f = getFaces()
    local margin = Size.margin.default
    local pad = Size.padding.default
    local book = self.book or (self.group and self.group.cover_book)
    local line = Size.line.thin
    local inner_h = self.height - line

    -- thumbnail (cover or placeholder), centred in a fixed box
    local tw, th = self.thumb_w, math.min(self.thumb_h, inner_h - 2 * Size.padding.small)
    tw = math.min(tw, math.floor(th * 2 / 3 + 0.5))
    local bb, known
    if book then
        bb, known = M.getCover(self.cover_cache, self.covers, book, tw - 2 * Size.border.thin, th - 2 * Size.border.thin)
    end
    self.needs_cover = book and not known and self.covers ~= nil
    local thumb
    if bb then
        thumb = FrameContainer:new{ padding = 0, bordersize = Size.border.thin,
            ImageWidget:new{ image = bb, image_disposable = false, width = bb:getWidth(), height = bb:getHeight() } }
    else
        thumb = FrameContainer:new{
            width = tw, height = th, padding = 0,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_GRAY_E,
            CenterContainer:new{
                dimen = Geom:new{ w = tw - 2 * Size.border.thin, h = th - 2 * Size.border.thin },
                TextWidget:new{
                    text = ((self.group and self.group.name or book and book.title or "?")
                        :match("^[%z\1-\127\194-\244][\128-\191]*") or "?"):upper(),
                    face = f.placeholder_title, bold = true, bgcolor = Blitbuffer.COLOR_GRAY_E,
                },
            },
        }
    end
    local thumb_box = CenterContainer:new{ dimen = Geom:new{ w = self.thumb_w, h = inner_h }, thumb }

    -- right column
    local right
    local right_w = Screen:scaleBySize(70)
    if self.group then
        right = pill(tostring(#self.group.books), true)
    else
        right = rowStatus(book, right_w)
    end
    local right_box = LeftContainer:new{ dimen = Geom:new{ w = right_w, h = inner_h },
        right and FrameContainer:new{ padding = 0, bordersize = 0,
            -- right-align inside the column
            padding_left = math.max(0, right_w - right:getSize().w), right } or VerticalSpan:new{ width = 0 } }

    -- text column
    local text_w = self.width - 2 * margin - self.thumb_w - 2 * pad - right_w
    -- Two lines: the status is in the right-hand column.
    local line1, line2
    if self.group then
        line1 = self.group.name
        line2 = #self.group.books == 1 and _("1 book") or T(_("%1 books"), #self.group.books)
    else
        line1 = M.bookTitle(book, self.series_number)
        line2 = book.authors and table.concat(book.authors, ", ") or ""
        if book.series then
            local s = book.series
            if book.series_index then s = s .. " #" .. (tostring(book.series_index):gsub("%.0$", "")) end
            line2 = line2 ~= "" and (line2 .. " · " .. s) or s
        end
    end
    local texts = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = line1 or "", face = f.title, bold = true, max_width = text_w },
        VerticalSpan:new{ width = Size.padding.small },
        TextWidget:new{ text = line2 or "", face = f.sub, max_width = text_w, fgcolor = Blitbuffer.COLOR_GRAY_3 },
    }
    local text_box = LeftContainer:new{ dimen = Geom:new{ w = text_w, h = inner_h }, texts }

    self[1] = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = margin },
            thumb_box,
            HorizontalSpan:new{ width = pad },
            text_box,
            HorizontalSpan:new{ width = pad },
            right_box,
            HorizontalSpan:new{ width = margin },
        },
        LineWidget:new{
            background = Blitbuffer.COLOR_GRAY_9,
            dimen = Geom:new{ w = self.width, h = line },
        },
    }
end

ListRow.getSize = Tile.getSize
ListRow.paintTo = Tile.paintTo
ListRow.onTapTile = Tile.onTapTile
ListRow.onHoldTile = Tile.onHoldTile

----------------------------------------------------------------------------
-- Chip (tabs and status filters)
----------------------------------------------------------------------------

local Chip = InputContainer:extend{
    text = nil,
    selected = false,
    callback = nil,
    width = nil,
    max_text_w = nil, -- truncate long text (no fixed width)
}
M.Chip = Chip

function Chip:init()
    local f = getFaces()
    local fg = self.selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local bg = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
    local text = TextWidget:new{ text = self.text, face = f.chip, bold = self.selected, fgcolor = fg, bgcolor = bg,
        max_width = self.width and (self.width - 2 * Size.padding.default) or self.max_text_w }
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
