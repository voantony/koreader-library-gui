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
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
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

-- Scale `bb` for a `box_w` x `box_h` slot (see Core.coverPlacement): covers
-- of about the slot's shape fill it exactly (a few pixels cropped evenly),
-- others are fitted inside it. Frees `bb`.
local function scaleInto(cache, key, bb, box_w, box_h)
    local RenderImage = require("ui/renderimage")
    local place = Core.coverPlacement(bb:getWidth(), bb:getHeight(), box_w, box_h)
    local scaled = RenderImage:scaleBlitBuffer(bb, place.w, place.h, true) -- frees the original
    if place.mode == "fill" and (place.w > box_w or place.h > box_h) then
        local cropped = Blitbuffer.new(box_w, box_h, scaled:getType())
        cropped:blitFrom(scaled, 0, 0, place.crop_x, place.crop_y, box_w, box_h)
        scaled:free() -- ours alone: never cached, never on screen
        scaled = cropped
    end
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
    local key = path .. "@" .. max_w .. "x" .. max_h .. "#slot"
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
            badge = Font:getFace("cfont", 12),
            chip = Font:getFace("cfont", 15),
            tab = Font:getFace("cfont", 17),
            percent = Font:getFace("cfont", 12),
        }
    end
    return faces
end
M.getFaces = getFaces

-- Spacing and sizes shared by tiles and rows (scaled for the screen's dpi).
local function shadowSize() return math.max(2, Screen:scaleBySize(2)) end
local function barHeight() return math.max(4, Screen:scaleBySize(3)) end
M.shadowSize = shadowSize

--- Height of the progress row under a cover: a thin bar and "43 %".
function M.progressRowHeight()
    local t = TextWidget:new{ text = "100 %", face = getFaces().percent }
    local h = math.max(barHeight(), t:getSize().h)
    t:free()
    return h
end

--- Height of everything under a cover: the progress row, the title and a
-- second line (or the title only when `one_line`). Every tile reserves the
-- progress row, so titles line up across a row whatever the books' state.
function M.labelHeight(one_line)
    local f = getFaces()
    local t = TextWidget:new{ text = "Ag", face = f.title, bold = true }
    local s = TextWidget:new{ text = "Ag", face = f.sub }
    local h = Size.padding.default + M.progressRowHeight() + Size.padding.small
        + t:getSize().h + (one_line and 0 or s:getSize().h) + Size.padding.small
    t:free(); s:free()
    return h
end

----------------------------------------------------------------------------
-- Small painted widgets: a soft drop shadow and a rounded progress bar
----------------------------------------------------------------------------

--- Paints a flat shadow down and to the right of its child, like a book
-- lying on a page. One grey rectangle: crisp on e-ink, no dithering.
local Shadow = Widget:extend{
    offset = nil,
    color = Blitbuffer.COLOR_LIGHT_GRAY,
    stack = false, -- two layers, like a small pile of books (groups)
}
M.Shadow = Shadow

function Shadow:init()
    self.offset = self.offset or shadowSize()
    self.depth = self.stack and 2 * self.offset or self.offset
end

function Shadow:getSize()
    local s = self[1]:getSize()
    return Geom:new{ w = s.w + self.depth, h = s.h + self.depth }
end

function Shadow:paintTo(bb, x, y)
    local s = self[1]:getSize()
    local o = self.offset
    self.dimen = Geom:new{ x = x, y = y, w = s.w + self.depth, h = s.h + self.depth }
    if self.stack then
        -- a second "book" behind: a white sheet with a grey edge
        bb:paintRect(x + 2 * o, y + 2 * o, s.w, s.h, Blitbuffer.COLOR_GRAY_9)
        bb:paintRect(x + o, y + o, s.w, s.h, Blitbuffer.COLOR_WHITE)
        bb:paintBorder(x + o, y + o, s.w, s.h, math.max(1, Size.border.thin), Blitbuffer.COLOR_GRAY_7)
    else
        bb:paintRect(x + o, y + o, s.w, s.h, self.color)
    end
    self[1]:paintTo(bb, x, y)
end

function Shadow:free()
    if self[1] and self[1].free then self[1]:free() end
end

--- A rounded progress bar: light track, dark fill.
local Bar = Widget:extend{
    width = nil,
    height = nil,
    fraction = 0,
    track = Blitbuffer.COLOR_GRAY_D,
    fill = Blitbuffer.COLOR_GRAY_3,
}
M.Bar = Bar

function Bar:init()
    self.height = self.height or barHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function Bar:getSize() return Geom:new{ w = self.width, h = self.height } end

function Bar:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local r = math.floor(self.height / 2)
    bb:paintRoundedRect(x, y, self.width, self.height, self.track, r)
    local fw = Core.barFill(self.width, self.fraction, self.height)
    if fw >= self.height then
        bb:paintRoundedRect(x, y, fw, self.height, self.fill, r)
    elseif fw > 0 then
        bb:paintRect(x, y, fw, self.height, self.fill)
    end
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
            fgcolor = Blitbuffer.COLOR_GRAY_3,
            bgcolor = Blitbuffer.COLOR_GRAY_E,
        })
    end
    return FrameContainer:new{
        width = w,
        height = h,
        padding = 0,
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_GRAY_9,
        background = Blitbuffer.COLOR_GRAY_E,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * Size.border.thin, h = h - 2 * Size.border.thin },
            group,
        },
    }
end

--- A cover image in a box of exactly (w, h), thin border included: covers
-- that were fitted rather than filled sit centred on a light background.
local function coverBox(bb, w, h)
    local b = Size.border.thin
    local img = ImageWidget:new{ image = bb, image_disposable = false, width = bb:getWidth(), height = bb:getHeight() }
    return FrameContainer:new{
        width = w, height = h, padding = 0,
        bordersize = b,
        color = Blitbuffer.COLOR_GRAY_7,
        background = Blitbuffer.COLOR_GRAY_E,
        CenterContainer:new{ dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b }, img },
    }
end

--- The cover (or placeholder) of `book` in a (w, h) box with a 2:3 shape.
-- Returns the widget, its width and whether the cover is still to be made.
local function bookCover(tile, book, box_w, box_h, title, sub)
    local b = Size.border.thin
    local w = math.min(box_w, math.floor(box_h * 2 / 3 + 0.5))
    local h = math.min(box_h, math.floor(w * 3 / 2 + 0.5))
    local bb, known
    if book then
        bb, known = M.getCover(tile.cover_cache, tile.covers, book, w - 2 * b, h - 2 * b)
    end
    local needs = book and not known and tile.covers ~= nil
    if bb then return coverBox(bb, w, h), w, h, needs end
    return placeholder(w, h, title, sub), w, h, needs
end

----------------------------------------------------------------------------
-- Badges
----------------------------------------------------------------------------

local function pill(text, inverted)
    local f = getFaces()
    local t = TextWidget:new{
        text = text,
        face = f.badge,
        bold = true,
        fgcolor = inverted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
        bgcolor = inverted and Blitbuffer.COLOR_GRAY_2 or Blitbuffer.COLOR_WHITE,
    }
    local h = t:getSize().h
    return FrameContainer:new{
        padding = 0,
        padding_left = Size.padding.default,
        padding_right = Size.padding.default,
        bordersize = Size.border.thin,
        color = inverted and Blitbuffer.COLOR_GRAY_2 or Blitbuffer.COLOR_GRAY_5,
        radius = math.floor(h / 2),
        background = inverted and Blitbuffer.COLOR_GRAY_2 or Blitbuffer.COLOR_WHITE,
        t,
    }
end
M.pill = pill

--- Overlay the status badges on a cover of size (w, h).
local function decorate(cover, w, h, book)
    local layers = OverlapGroup:new{ dimen = Geom:new{ w = w, h = h }, allow_mirroring = false, cover }
    local m = Size.padding.default
    local p
    if book.status == "complete" then
        p = pill("\u{2713}", true)
    elseif book.status == "new" then
        p = pill(_("NEW"), false)
    elseif book.status == "abandoned" then
        p = pill(_("on hold"), false)
    end
    if p then
        p.overlap_offset = { w - p:getSize().w - m, m }
        table.insert(layers, p)
    end
    return layers
end

--- Under a cover: a thin bar and "43 %" for a book being read, nothing
-- (but the same height) otherwise.
-- For a group (collection, author, series), how many of its books are
-- finished: "2/6" on the bar.
local function progressRow(book, w, group)
    local h = M.progressRowHeight()
    local fraction, label
    if group then
        local pr = Core.seriesProgress(group.books)
        if pr.total > 0 then
            fraction, label = pr.read / pr.total, T(_("%1/%2"), pr.read, pr.total)
        end
    elseif book and book.percent and book.status ~= "new" and book.status ~= "complete" then
        fraction, label = book.percent, T(_("%1 %"), math.floor(book.percent * 100 + 0.5))
    end
    if not fraction then
        return VerticalSpan:new{ width = h }
    end
    local pct = TextWidget:new{
        text = label,
        face = getFaces().percent, bold = true, fgcolor = Blitbuffer.COLOR_GRAY_3,
    }
    local gap = Size.padding.default
    local bar_w = math.max(barHeight() * 2, w - pct:getSize().w - gap)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalGroup:new{ align = "center", Bar:new{ width = bar_w, fraction = fraction }, HorizontalSpan:new{ width = gap }, pct },
    }
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

--- The second line under a grid cover: the caption when given (Continue
-- reading), else the author (the bar and badges already show the status),
-- else the status.
function M.secondLine(book, caption)
    if caption then return caption end
    local author = book.authors and book.authors[1]
    if author and author ~= "" then return author end
    return M.statusLine(book) or ""
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
    caption = nil,    -- second line instead of the author (Continue reading)
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
    local shadow = shadowSize() * (self.group and 2 or 1)
    local box_w = self.width - 2 * pad - shadow
    local box_h = self.cover_h - pad - shadow
    local book = self.book or (self.group and self.group.cover_book)

    local title, sub
    if self.group then
        title = self.group.name
    elseif book then
        title = book.title
        sub = book.authors and table.concat(book.authors, ", ")
    end
    local cover, cover_w, cover_h, needs = bookCover(self, book, box_w, box_h, title, sub)
    self.needs_cover = needs
    if self.group then
        local p = pill(tostring(#self.group.books), true)
        cover = OverlapGroup:new{ dimen = Geom:new{ w = cover_w, h = cover_h }, allow_mirroring = false, cover }
        p.overlap_offset = { cover_w - p:getSize().w - Size.padding.default, cover_h - p:getSize().h - Size.padding.default }
        table.insert(cover, p)
    elseif book then
        cover = decorate(cover, cover_w, cover_h, book)
    end

    local line1, line2
    if self.group then
        line1 = self.group.name
        line2 = T(_("%1 books"), #self.group.books)
        if #self.group.books == 1 then line2 = _("1 book") end
    else
        line1 = M.bookTitle(book, self.series_number)
        line2 = M.secondLine(book, self.caption)
    end
    local text_w = self.width - 2 * pad
    local label = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.padding.default },
        progressRow(not self.group and book or nil, cover_w, self.group),
        VerticalSpan:new{ width = Size.padding.small },
        TextWidget:new{ text = line1 or "", face = f.title, bold = true, max_width = text_w },
    }
    if not self.one_line then
        table.insert(label, TextWidget:new{ text = line2 or "", face = f.sub, max_width = text_w,
            fgcolor = Blitbuffer.COLOR_GRAY_4 })
    end
    self[1] = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = pad },
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.cover_h - pad },
            Shadow:new{ cover, stack = self.group ~= nil },
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
    if book.status == "complete" then return pill("\u{2713} " .. _("Finished"), true) end
    if book.status == "new" then return pill(_("NEW"), false) end
    if book.status == "abandoned" then return pill(_("on hold"), false) end
    if book.percent then
        local f = getFaces()
        return VerticalGroup:new{
            align = "right",
            TextWidget:new{ text = T(_("%1 %"), math.floor(book.percent * 100 + 0.5)), face = f.title, bold = true },
            VerticalSpan:new{ width = Size.padding.default },
            Bar:new{ width = w, fraction = book.percent },
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
    local margin = Size.margin.default + Size.padding.default
    local pad = Size.padding.large
    local book = self.book or (self.group and self.group.cover_book)
    local line = Size.line.thin
    local inner_h = self.height - line
    local shadow = shadowSize()

    -- thumbnail (cover or placeholder) with a 2:3 shape, centred in a fixed box
    local th = math.min(self.thumb_h, inner_h - 2 * Size.padding.small) - shadow
    local tw = math.min(self.thumb_w - shadow, math.floor(th * 2 / 3 + 0.5))
    local b = Size.border.thin
    local bb, known
    if book then
        bb, known = M.getCover(self.cover_cache, self.covers, book, tw - 2 * b, th - 2 * b)
    end
    self.needs_cover = book and not known and self.covers ~= nil
    local thumb
    if bb then
        thumb = coverBox(bb, tw, th)
    else
        thumb = FrameContainer:new{
            width = tw, height = th, padding = 0,
            bordersize = b,
            color = Blitbuffer.COLOR_GRAY_9,
            background = Blitbuffer.COLOR_GRAY_E,
            CenterContainer:new{
                dimen = Geom:new{ w = tw - 2 * b, h = th - 2 * b },
                TextWidget:new{
                    text = ((self.group and self.group.name or book and book.title or "?")
                        :match("^[%z\1-\127\194-\244][\128-\191]*") or "?"):upper(),
                    face = f.placeholder_title, bold = true, bgcolor = Blitbuffer.COLOR_GRAY_E,
                },
            },
        }
    end
    local thumb_box = CenterContainer:new{ dimen = Geom:new{ w = self.thumb_w, h = inner_h }, Shadow:new{ thumb } }

    -- right column
    local right
    local right_w = Screen:scaleBySize(80)
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
        TextWidget:new{ text = line2 or "", face = f.sub, max_width = text_w, fgcolor = Blitbuffer.COLOR_GRAY_4 },
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
        -- a light rule from the text column to the right edge, like a phone list
        HorizontalGroup:new{
            HorizontalSpan:new{ width = margin + self.thumb_w + pad },
            LineWidget:new{
                background = Blitbuffer.COLOR_GRAY_D,
                dimen = Geom:new{ w = math.max(0, self.width - 2 * margin - self.thumb_w - pad), h = line },
            },
        },
    }
end

ListRow.getSize = Tile.getSize
ListRow.paintTo = Tile.paintTo
ListRow.onTapTile = Tile.onTapTile
ListRow.onHoldTile = Tile.onHoldTile

----------------------------------------------------------------------------
-- Chip (status filters, Resume, back): a rounded pill
----------------------------------------------------------------------------

--- Smallest touch target for chips and tabs, about 7 mm.
function M.minTouch()
    return Screen:scaleBySize(42)
end

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
    local bg = self.selected and Blitbuffer.COLOR_GRAY_2 or Blitbuffer.COLOR_WHITE
    local hpad = Size.padding.large
    local text = TextWidget:new{ text = self.text, face = f.chip, bold = self.selected, fgcolor = fg, bgcolor = bg,
        max_width = self.width and (self.width - 2 * hpad) or self.max_text_w }
    local b = Size.border.thin
    local h = math.max(text:getSize().h + 2 * Size.padding.default, math.floor(M.minTouch() * 0.85))
    local w = self.width or (text:getSize().w + 2 * hpad + 2 * b)
    local frame = FrameContainer:new{
        padding = 0,
        bordersize = b,
        color = self.selected and Blitbuffer.COLOR_GRAY_2 or Blitbuffer.COLOR_GRAY_7,
        radius = math.floor(h / 2),
        background = bg,
        width = w,
        height = h,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b },
            text,
        },
    }
    self[1] = frame
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
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

----------------------------------------------------------------------------
-- Tab (Books | Collections | Authors | Series): text with an underline
----------------------------------------------------------------------------

local Tab = InputContainer:extend{
    text = nil,
    selected = false,
    callback = nil,
    width = nil,
}
M.Tab = Tab

function Tab:init()
    local f = getFaces()
    local text = TextWidget:new{
        text = self.text, face = f.tab, bold = self.selected,
        fgcolor = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY_5,
        max_width = self.width - 2 * Size.padding.default,
    }
    local mark_h = math.max(3, Screen:scaleBySize(2.5))
    local h = math.max(M.minTouch(), text:getSize().h + 2 * Size.padding.default + mark_h)
    local mark_w = math.min(self.width - 2 * Size.padding.large, text:getSize().w + 2 * Size.padding.large)
    self[1] = VerticalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = self.width, h = h - mark_h }, text },
        self.selected and LineWidget:new{ background = Blitbuffer.COLOR_BLACK, dimen = Geom:new{ w = mark_w, h = mark_h } }
            or VerticalSpan:new{ width = mark_h },
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = h }
    self.ges_events = { TapChip = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

Tab.paintTo = Chip.paintTo
Tab.onTapChip = Chip.onTapChip

return M
