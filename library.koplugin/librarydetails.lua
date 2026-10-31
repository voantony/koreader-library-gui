--[[--
Read-only book details card.

Long-press a book, or choose Book details in the reader menu. The same card
either way. A normal tap still opens the book. Description text is passed in
already loaded; this module does not scan the library.

Two columns when the screen is wide enough: cover, progress, a large
Continue (or Open) and genre/collection chips on the left; title, tappable
authors, series and the description on the right. One column when two do
not fit. Mark finished / Mark unread, More and Close sit along the bottom.

The description pages with a tap or a vertical swipe. There is no scrollbar.
Every label is black. Nothing here edits metadata.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
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
local LineWidget = require("ui/widget/linewidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Core = require("librarycore")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE

local OPEN_LABEL = { open = _("Open"), continue = _("Continue") }
local STATUS_LABEL = { mark_finished = _("Mark finished"), mark_unread = _("Mark unread") }

local function face(name, size)
    local f = Font:getFace(name, size)
    if f then return f end
    return Font:getFace("cfont", size)
end

local function progressText(book)
    local pct, left = Core.progressParts(book)
    if left then return T(_("%1% · %2 left"), pct, left) end
    return T(_("%1%"), pct)
end

local function vgap(px)
    return VerticalSpan:new{ width = px }
end

local function hgap(px)
    return HorizontalSpan:new{ width = px }
end

----------------------------------------------------------------------------
-- Tappable name (author or series): black text, black underline
----------------------------------------------------------------------------

local Link = InputContainer:extend{
    text = "",
    size = 18,
    italic = false,
    max_width = nil,
    on_tap = nil,
}

function Link:init()
    local f = self.italic and face("NotoSans-Italic.ttf", self.size) or face("cfont", self.size)
    local label = TextWidget:new{
        text = self.text, face = f, fgcolor = BLACK,
        max_width = self.max_width,
    }
    local w = label:getSize().w
    local rule = LineWidget:new{
        background = BLACK,
        dimen = Geom:new{ w = math.max(1, w), h = math.max(1, Size.line.thin) },
    }
    self[1] = VerticalGroup:new{ align = "left", label, rule }
    local s = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = s.w, h = s.h }
    self.ges_events = {
        TapLink = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function Link:onTapLink()
    if self.on_tap then self.on_tap() end
    return true
end

----------------------------------------------------------------------------
-- Genre or collection chip. No section heading.
----------------------------------------------------------------------------

local Chip = InputContainer:extend{
    kind = nil,
    name = "",
    max_width = nil,
    on_tap = nil,
}

function Chip:init()
    local pad_x = Size.padding.default
    local pad_y = Size.padding.small
    local label = TextWidget:new{
        text = self.name,
        face = face("cfont", 15),
        fgcolor = BLACK,
        max_width = math.max(24, (self.max_width or 200) - 2 * pad_x - 4),
    }
    local radius = math.floor((label:getSize().h + 2 * pad_y) / 2)
    self[1] = FrameContainer:new{
        padding = 0,
        padding_left = pad_x,
        padding_right = pad_x,
        padding_top = pad_y,
        padding_bottom = pad_y,
        bordersize = Size.border.thin,
        color = BLACK,
        background = WHITE,
        radius = radius,
        label,
    }
    local s = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = s.w, h = s.h }
    self.ges_events = {
        TapChip = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function Chip:onTapChip()
    if self.on_tap then self.on_tap(self.kind, self.name) end
    return true
end

----------------------------------------------------------------------------
-- Description: whole pages, tap or swipe. No scrollbar.
----------------------------------------------------------------------------

local Pager = InputContainer:extend{
    box = nil,
    label = nil,
    width = nil,
    height = nil,
    dialog = nil,
}

function Pager:init()
    local group = VerticalGroup:new{ align = "left", self.box }
    if self.label then
        table.insert(group, vgap(4))
        table.insert(group, self.label)
    end
    self[1] = group
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        SwipePage = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
        TapPage = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    self:refreshLabel()
end

function Pager:pageCount()
    local vis = self.box:getVisLineCount() or 1
    local all = self.box:getAllLineCount() or 1
    if vis < 1 then vis = 1 end
    return math.max(1, math.ceil(all / vis))
end

function Pager:currentPage()
    local vis = self.box:getVisLineCount() or 1
    if vis < 1 then vis = 1 end
    local top = self.box.virtual_line_num or 1
    return math.min(self:pageCount(), math.floor((top - 1) / vis) + 1)
end

function Pager:refreshLabel()
    if not self.label then return end
    local pages = self:pageCount()
    if pages > 1 then
        self.label:setText(T(_("%1 / %2"), self:currentPage(), pages))
    end
end

function Pager:turn(dir)
    if dir > 0 then self.box:scrollDown()
    elseif dir < 0 then self.box:scrollUp()
    else return end
    self:refreshLabel()
    if self.dialog then
        UIManager:setDirty(self.dialog, function() return "ui", self.dimen end)
    end
end

function Pager:onSwipePage(_, ges)
    local pos = ges and ges.pos
    local dir = Core.descriptionPageTurn({
        kind = "swipe",
        direction = ges and ges.direction,
        x = pos and pos.x,
        y = pos and pos.y,
    }, self.dimen)
    if not dir then return false end
    self:turn(dir)
    return true
end

function Pager:onTapPage(_, ges)
    local pos = ges and ges.pos
    local dir = Core.descriptionPageTurn({
        kind = "tap",
        x = pos and pos.x,
        y = pos and pos.y,
    }, self.dimen)
    if dir then self:turn(dir) end
    return true
end

local function makePager(w, h, text, dialog)
    h = math.max(1, h)
    w = math.max(1, w)
    local body = face("cfont", 17)
    local function box(height)
        return TextBoxWidget:new{
            text = text,
            face = body,
            width = w,
            height = math.max(1, height),
            fgcolor = BLACK,
            bgcolor = WHITE,
            dialog = dialog,
            alignment = "left",
            justified = false,
        }
    end
    local widget = box(h)
    local label
    local overflows = (widget:getAllLineCount() or 1) > (widget:getVisLineCount() or 1)
    if overflows then
        local sample = TextWidget:new{ text = "0 / 0", face = face("cfont", 14), fgcolor = BLACK }
        local label_h = sample:getSize().h + 4
        sample:free()
        widget:free()
        widget = box(math.max(1, h - label_h))
        label = TextWidget:new{ text = "", face = face("cfont", 14), fgcolor = BLACK }
    end
    return Pager:new{
        box = widget,
        label = label,
        width = w,
        height = h,
        dialog = dialog,
    }
end

----------------------------------------------------------------------------
-- Card
----------------------------------------------------------------------------

local Details = InputContainer:extend{
    book = nil,
    info = nil,
    already_open = false,
    covers = nil,
    cover_cache = nil,
    on_continue = nil,
    on_status = nil,
    on_close = nil,
    on_more = nil,
    on_shelf = nil,
    covers_fullscreen = true,
}

function Details:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local L = Core.detailsLayout(sw, sh)
    local info = self.info or {}
    self.info = info
    local gap = L.gap

    self.status_button = nil
    self.progress_widget = nil
    self.pager = nil

    local buttons = self:buildBottom(L.inner_w)
    local buttons_h = buttons:getSize().h
    local body_h = math.max(1, L.inner_h - buttons_h - gap)

    local body
    if L.columns == 2 then
        body = self:buildColumns(L, body_h)
    else
        body = self:buildStack(L, body_h)
    end

    local content = VerticalGroup:new{ align = "left", body, vgap(gap), buttons }
    local card = FrameContainer:new{
        padding = L.pad,
        margin = 0,
        bordersize = L.border,
        color = BLACK,
        background = WHITE,
        content,
    }
    self[1] = FrameContainer:new{
        padding = L.margin,
        margin = 0,
        bordersize = 0,
        background = WHITE,
        width = sw,
        height = sh,
        card,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.frame_box = Geom:new{
        x = L.margin, y = L.margin,
        w = sw - 2 * L.margin, h = sh - 2 * L.margin,
    }
    self.ges_events = {
        TapCard = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        SwipeCard = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
    }
    if Device.input and Device.input.group then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextPage = { { Device.input.group.PgFwd } },
            PrevPage = { { Device.input.group.PgBack } },
        }
    end
end

function Details:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function Details:progressBook()
    return {
        status = self.book and self.book.status,
        percent = self.book and self.book.percent,
        time_left = self.info and self.info.time_left,
    }
end

function Details:setProgress()
    if self.progress_widget and self.progress_widget.setText then
        self.progress_widget:setText(progressText(self:progressBook()))
        UIManager:setDirty(self, function() return "ui", self.dimen end)
    end
end

function Details:setStatusLabel()
    if not self.status_button then return end
    local id = Core.detailsStatusAction(self.book)
    self.status_button:setText(STATUS_LABEL[id], self.status_button.width)
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function Details:takeCover(w, h)
    if not (self.covers and self.cover_cache and self.book) then return nil end
    local Tiles = require("librarytile")
    local ok, bb = pcall(Tiles.getCover, self.cover_cache, self.covers, self.book, w, h)
    if not ok or not bb or not bb.copy then return nil end
    local copied, copy = pcall(function() return bb:copy() end)
    if copied and copy then return copy end
    return nil
end

function Details:buildCover(w, h)
    w, h = math.max(1, w), math.max(1, h)
    local b = Size.border.thin
    local copy = self:takeCover(math.max(1, w - 2 * b), math.max(1, h - 2 * b))
    if copy then
        return FrameContainer:new{
            padding = 0,
            margin = 0,
            bordersize = b,
            color = BLACK,
            background = WHITE,
            ImageWidget:new{
                image = copy,
                width = math.max(1, w - 2 * b),
                height = math.max(1, h - 2 * b),
                image_disposable = true,
            },
        }
    end
    local pad = Size.padding.default
    local inner_w = math.max(1, w - 2 * pad - 2 * b)
    local inner_h = math.max(1, h - 2 * pad - 2 * b)
    local title = self.info.title
    if type(title) ~= "string" or title == "" then title = _("Book") end
    return FrameContainer:new{
        padding = pad,
        margin = 0,
        bordersize = b,
        color = BLACK,
        background = WHITE,
        width = w,
        height = h,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            TextBoxWidget:new{
                text = title,
                face = face("cfont", 15),
                bold = true,
                width = inner_w,
                height = inner_h,
                alignment = "center",
                fgcolor = BLACK,
                bgcolor = WHITE,
                height_overflow_show_ellipsis = true,
            },
        },
    }
end

function Details:buildProgress(width)
    local widget = TextWidget:new{
        text = progressText(self:progressBook()),
        face = face("cfont", 16),
        bold = true,
        fgcolor = BLACK,
        max_width = math.max(1, width),
    }
    self.progress_widget = widget
    return widget
end

function Details:buildContinue(width)
    local id = Core.detailsOpenAction(self.book)
    return Button:new{
        text = OPEN_LABEL[id],
        width = math.max(1, width),
        callback = function()
            if self.on_continue then self.on_continue() end
        end,
        margin = 0,
        bordersize = Size.border.default,
        padding = Size.padding.large,
        text_font_face = "cfont",
        text_font_size = 22,
        text_font_bold = true,
    }
end

function Details:buildChips(max_w, max_h)
    local items = {}
    for _, name in ipairs(self.info.genres or {}) do
        if type(name) == "string" and name ~= "" then
            items[#items + 1] = { kind = "genres", name = name }
        end
    end
    for _, name in ipairs(self.info.collections or {}) do
        if type(name) == "string" and name ~= "" then
            items[#items + 1] = { kind = "collections", name = name }
        end
    end
    if #items == 0 then return nil end
    local gap = Size.padding.small
    local widgets, widths = {}, {}
    for i, item in ipairs(items) do
        local chip = Chip:new{
            kind = item.kind,
            name = item.name,
            max_width = max_w,
            on_tap = self.on_shelf,
        }
        widgets[i] = chip
        widths[i] = chip:getSize().w
    end
    local packed = Core.packRows(widths, max_w, gap)
    local col = VerticalGroup:new{ align = "left" }
    local used = 0
    for r, idxs in ipairs(packed) do
        local row = HorizontalGroup:new{ align = "center" }
        for j, i in ipairs(idxs) do
            if j > 1 then table.insert(row, hgap(gap)) end
            table.insert(row, widgets[i])
        end
        local row_h = row:getSize().h
        local add = row_h + (used > 0 and gap or 0)
        if max_h and used > 0 and used + add > max_h then break end
        if used > 0 then table.insert(col, vgap(gap)) end
        table.insert(col, row)
        used = used + add
    end
    if used == 0 then return nil end
    return col
end

function Details:buildAuthors(max_w)
    local names = self.info.authors or {}
    if #names == 0 then return nil end
    local gap = Size.padding.default
    local pieces, widths = {}, {}
    for i, name in ipairs(names) do
        local link = Link:new{
            text = name,
            italic = true,
            size = 18,
            max_width = math.max(1, max_w - 16),
            on_tap = function()
                if self.on_shelf then self.on_shelf("authors", name) end
            end,
        }
        local piece = link
        if i < #names then
            local comma = TextWidget:new{
                text = ",",
                face = face("cfont", 18),
                fgcolor = BLACK,
            }
            piece = HorizontalGroup:new{ align = "bottom", link, comma }
        end
        pieces[i] = piece
        widths[i] = piece:getSize().w
    end
    local packed = Core.packRows(widths, max_w, gap)
    local col = VerticalGroup:new{ align = "left" }
    for r, idxs in ipairs(packed) do
        if r > 1 then table.insert(col, vgap(Size.padding.small)) end
        local row = HorizontalGroup:new{ align = "bottom" }
        for j, i in ipairs(idxs) do
            if j > 1 then table.insert(row, hgap(gap)) end
            table.insert(row, pieces[i])
        end
        table.insert(col, row)
    end
    return col
end

function Details:buildSeries(max_w)
    local line = self.info.series_line
    if type(line) ~= "string" or line == "" then return nil end
    local series = self.info.series
    return Link:new{
        text = line,
        size = 16,
        max_width = max_w,
        on_tap = function()
            if series and self.on_shelf then self.on_shelf("series", series) end
        end,
    }
end

function Details:buildTitle(max_w)
    local title = self.info.title
    if type(title) ~= "string" or title == "" then title = _("Book") end
    return TextBoxWidget:new{
        text = title,
        face = face("cfont", 22),
        bold = true,
        width = math.max(1, max_w),
        fgcolor = BLACK,
        bgcolor = WHITE,
        alignment = "left",
    }
end

function Details:buildHeader(max_w)
    local col = VerticalGroup:new{ align = "left", self:buildTitle(max_w) }
    local authors = self:buildAuthors(max_w)
    if authors then
        table.insert(col, vgap(Size.padding.small))
        table.insert(col, authors)
    end
    local series = self:buildSeries(max_w)
    if series then
        table.insert(col, vgap(Size.padding.small))
        table.insert(col, series)
    end
    return col
end

function Details:descriptionText()
    local text = self.info.description
    if type(text) ~= "string" or text == "" then return _("No description") end
    return text
end

--- Left: cover, progress, Continue, chips. Right: title, authors, series, blurb.
function Details:buildColumns(L, body_h)
    local gap = L.gap
    local cover_w = L.cover_w
    local probe_progress = self:buildProgress(cover_w)
    local probe_button = self:buildContinue(cover_w)
    local fixed = probe_progress:getSize().h + probe_button:getSize().h + gap * 3
    local min_cover = math.min(L.cover_h, math.max(100, math.floor(body_h * 0.28)))
    local chip_room = math.max(0, body_h - min_cover - fixed)
    local chips = self:buildChips(cover_w, chip_room > 0 and chip_room or nil)
    local chips_h = chips and chips:getSize().h or 0
    if chips then fixed = fixed + chips_h end
    local cover_h = math.min(L.cover_h, math.max(min_cover, body_h - fixed))
    -- The probes were built at cover_w; reuse them (same width).
    local left = VerticalGroup:new{
        align = "left",
        self:buildCover(cover_w, cover_h),
        vgap(gap),
        probe_progress,
        vgap(gap),
        probe_button,
    }
    if chips then
        table.insert(left, vgap(gap))
        table.insert(left, chips)
    end
    local header = self:buildHeader(L.text_w)
    local desc_h = math.max(48, body_h - header:getSize().h - gap)
    self.pager = makePager(L.text_w, desc_h, self:descriptionText(), self)
    local right = VerticalGroup:new{ align = "left", header, vgap(gap), self.pager }
    return HorizontalGroup:new{ align = "top", left, hgap(gap), right }
end

--- Narrow or short screens: cover, Continue, then the text down the page.
function Details:buildStack(L, body_h)
    local gap = L.gap
    local width = L.inner_w
    local cover = self:buildCover(L.cover_w, L.cover_h)
    local progress = self:buildProgress(width)
    local button = self:buildContinue(width)
    local header = self:buildHeader(width)
    local top_h = cover:getSize().h + progress:getSize().h + button:getSize().h
        + header:getSize().h + gap * 4
    local chip_room = math.max(0, math.floor(body_h * 0.22))
    local chips = self:buildChips(width, chip_room > 36 and chip_room or 0)
    local chips_h = chips and (chips:getSize().h + gap) or 0
    local desc_h = math.max(48, body_h - top_h - chips_h)
    self.pager = makePager(width, desc_h, self:descriptionText(), self)
    local col = VerticalGroup:new{
        align = "left",
        cover,
        vgap(gap),
        progress,
        vgap(gap),
        button,
        vgap(gap),
    }
    if chips then
        table.insert(col, chips)
        table.insert(col, vgap(gap))
    end
    table.insert(col, header)
    table.insert(col, vgap(gap))
    table.insert(col, self.pager)
    return col
end

function Details:buildBottom(width)
    local gap = Size.padding.small
    local n = 3
    local bw = math.max(1, math.floor((width - (n - 1) * gap) / n))
    local status_id = Core.detailsStatusAction(self.book)
    local status = Button:new{
        text = STATUS_LABEL[status_id],
        width = bw,
        callback = function()
            if self.on_status then self.on_status() end
        end,
        margin = 0,
        bordersize = Size.border.thin,
        padding = Size.padding.default,
        text_font_face = "cfont",
        text_font_size = 16,
        text_font_bold = false,
    }
    self.status_button = status
    local more = Button:new{
        text = _("More"),
        width = bw,
        callback = function()
            if self.on_more then self.on_more() end
        end,
        margin = 0,
        bordersize = Size.border.thin,
        padding = Size.padding.default,
        text_font_face = "cfont",
        text_font_size = 16,
        text_font_bold = false,
    }
    local close = Button:new{
        text = _("Close"),
        width = bw,
        callback = function()
            if self.on_close then self.on_close() else UIManager:close(self) end
        end,
        margin = 0,
        bordersize = Size.border.thin,
        padding = Size.padding.default,
        text_font_face = "cfont",
        text_font_size = 16,
        text_font_bold = false,
    }
    return HorizontalGroup:new{ align = "center", status, hgap(gap), more, hgap(gap), close }
end

function Details:onTapCard(_, ges)
    local p = ges and ges.pos
    local b = self.frame_box
    if p and b and (p.x < b.x or p.y < b.y or p.x >= b.x + b.w or p.y >= b.y + b.h) then
        if self.on_close then self.on_close() else UIManager:close(self) end
    end
    return true
end

function Details:onSwipeCard()
    return true
end

function Details:onClose()
    if self.on_close then self.on_close() else UIManager:close(self) end
    return true
end

function Details:onNextPage()
    if self.pager then self.pager:turn(1) end
    return true
end

function Details:onPrevPage()
    if self.pager then self.pager:turn(-1) end
    return true
end

return Details
