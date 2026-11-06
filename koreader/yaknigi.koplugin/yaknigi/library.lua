-- The screens outside the book: the shelves, Yandex's feed and the search over all its books,
-- with the tabs to go between them and the book being read docked above the tabs.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local Screen = Device.screen

local Catalogue = require("yaknigi/catalogue")
local Feed = require("yaknigi/feed")
local Kit = require("yaknigi/kit")
local SearchBox = require("yaknigi/searchbox")
local Shelves = require("yaknigi/shelves")
local Status = require("yaknigi/status")
local Tabs = require("yaknigi/tabs")

-- item_table holds { text, title, authors, mandatory, card, sign_in, whole, cover, shelf }.
-- What went wrong and what to do about it, each on a line of its own: together they
-- would not fit the width of the screen.
local function retry_label(message, width)
    return VerticalGroup:new{ align = "center",
        Kit.text(message, 18, { max_width = width }),
        Kit.gap(Kit.px(6)),
        Kit.text("Нажмите, чтобы повторить", 16, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = width }),
    }
end

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local ROW_BUTTON_W, ROW_ICON = 64, 32

local Library = InputContainer:extend{
    name = "YaknigiLibrary",
    covers_fullscreen = true,
    item_table = nil,
    page = 1,
    view = "home", -- or a shelf's id, "catalogue": all of Yandex's books, "feed" or "feed_section"
    query = nil,
    place = nil, -- a table that outlives this screen, for coming back from a book
    message = nil,
    on_sign_in = nil, -- set when nobody is signed in
    onMenuSelect = nil, -- function(self, item)
    close_callback = nil,
    on_refresh = nil,
    on_settings = nil,
    on_catalogue = nil, -- function(state): asks for the next books found
    on_feed = nil, -- function(state): asks for the next of the feed
    load_feed = nil, -- function(): the feed as it was saved, for showing at once
    on_covers = nil, -- function(cards): gets the covers that are missing
    on_book_menu = nil, -- function(item): what can be done with a book
    on_add = nil, -- function(item): puts a book found into the library
    on_save = nil, -- function(item): saves a book on the device
    book_status = nil, -- function(item): "saving", "whole" or nil
}

function Library:init()
    self.place = self.place or {}
    -- Signed out, there is nothing but the first screen to come back to.
    self.view = not self.on_sign_in and self.place.view or "home"
    self.query = not self.on_sign_in and self.place.query or nil
    self.page = self.place.page or 1
    self.catalogue = self.place.catalogue
    self.feed, self.section = self.place.feed, self.place.section
    self.feed_page = self.place.feed_page or 1
    if self.view == "catalogue" and not self.catalogue then
        self.view, self.query = "home", nil
    end
    if (self.view == "feed" or self.view == "feed_section") and not self.feed then
        self.view = "home"
    end
    if self.view == "feed_section" and not self.section then
        self.view, self.page = "feed", self.feed_page
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.stop_status = Status.watch(self)
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:build()
end

-- How much to scale a picture for it to cover a cell, by file and cell: finding out takes
-- decoding the picture, and a screen is built anew for every cover that arrives.
local fill_factors = {}

--- The factor that makes the picture cover w x h, what stands out being cut off evenly.
local function fill_factor(file, w, h)
    local key = table.concat({ file, w, h }, "|")
    if fill_factors[key] then return fill_factors[key] end
    local fit = ImageWidget:new{ file = file, width = w, height = h, scale_factor = 0 }
    local size = fit:getSize() -- it decodes here: a bad file fails here
    -- A pixel over: the factor is rounded down on the way to a whole number of pixels.
    local factor = fit:getScaleFactor() * math.max((w + 1) / size.w, (h + 1) / size.h)
    fit:free()
    fill_factors[key] = factor
    return factor
end

local function cover_box(item, w, h)
    if item.cover then
        local ok, image = pcall(function()
            local widget = ImageWidget:new{
                file = item.cover,
                width = w,
                height = h,
                scale_factor = fill_factor(item.cover, w, h),
            }
            widget:getSize()
            return widget
        end)
        if ok then
            return Kit.RoundedPicture:new{
                inner_w = w,
                inner_h = h,
                CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, image },
            }
        end
    end
    -- No cover yet: a frame with the first letter of the title.
    local letter = (item.title or "?"):match("[%z\1-\127\194-\244][\128-\191]*") or "?"
    return FrameContainer:new{
        bordersize = Kit.px(1),
        padding = 0,
        radius = Kit.cover_radius(),
        color = Blitbuffer.COLOR_DARK_GRAY,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * Kit.px(1), h = h - 2 * Kit.px(1) },
            Kit.text(letter, 26, { color = Blitbuffer.COLOR_DARK_GRAY }),
        },
    }
end

local function title_box(text, width, size, lines)
    return TextBoxWidget:new{
        text = text,
        face = Kit.face(size),
        bold = true,
        width = width,
        height = math.floor(Kit.face(size).size * 1.3 * lines),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    }
end

Library.cover_box = cover_box

--- The picture at the right of a row, and what a tap on it does. A book of the library has its
-- menu; a book found is added, then saved, and then has its menu too.
function Library:rowButton(item, height)
    if not item.card then return nil end
    local status = self.book_status and self.book_status(item)
    local name, file, action
    local function menu() self.on_book_menu(item) end
    if item.adding or status == "saving" then
        file, action = "wait", function() end
    elseif not item.found then
        file, action = "dots", menu
    elseif status == "whole" then
        name, action = "check", menu
    elseif self:inLibrary(item) or item.in_library then
        file, action = "cloud.down", function() self.on_save(item) end
    else
        name, action = "plus", function() self.on_add(item) end
    end
    return Kit.icon_button(name, height, action, {
        width = Kit.px(ROW_BUTTON_W),
        edge = "right",
        icon_size = Kit.px(ROW_ICON),
        file = file and (HERE .. "/icons/" .. file .. ".svg") or nil,
    })
end

function Library:row(item, width, height)
    local cover_h = height - Kit.px(16)
    local cover_w = math.floor(cover_h * 2 / 3)
    local gap = Kit.px(14)
    local button = self:rowButton(item, height)
    local left_w = button and width - Kit.px(ROW_BUTTON_W) or width
    local text_w = left_w - cover_w - gap
    local lines = VerticalGroup:new{ align = "left",
        title_box(item.title or item.text, text_w, 19, 2),
    }
    if item.authors and item.authors ~= "" then
        lines[#lines + 1] = Kit.text(item.authors, 15, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = text_w })
    end
    local state = {}
    -- A book of the feed may well be in the library.
    local mine = item.found and self:inLibrary(item)
    if item.mandatory then state[#state + 1] = item.mandatory
    elseif mine then state[#state + 1] = mine.mandatory or "в библиотеке" end
    if item.whole then state[#state + 1] = "скачана" end
    if #state > 0 then
        lines[#lines + 1] = Kit.gap(Kit.px(4))
        lines[#lines + 1] = Kit.text(table.concat(state, " · "), 15, { color = Blitbuffer.COLOR_DARK_GRAY })
    end
    local row = Kit.Tappable:new{
        callback = function() self:onMenuSelect(item) end,
        CenterContainer:new{
            dimen = Geom:new{ w = left_w, h = height },
            HorizontalGroup:new{ align = "center",
                cover_box(item, cover_w, cover_h),
                HorizontalSpan:new{ width = gap },
                Kit.fixed(lines, text_w),
            },
        },
    }
    if not button then return row end
    self.row_buttons[item] = button
    -- Side by side: a tap on the picture is not a tap on the book.
    return HorizontalGroup:new{ align = "center", row, button }
end

--- This book as it stands in the library, if it does.
function Library:inLibrary(item)
    if not self.owned then
        self.owned = {}
        for _, mine in ipairs(self.item_table or {}) do
            local book = mine.card and mine.card.book
            if book and book.uuid then self.owned[book.uuid] = mine end
        end
    end
    return self.owned[item.card.book.uuid]
end

local HEADER_H, FOOTER_H, SEARCH_H, ROW_H = 60, 56, 56, 100
local SHELF_ROW_H, STRIP_HEADING_H, STRIP_LABEL_H, STRIP_GAP = 52, 40, 24, 14
local BIGGEST_COVER_H, SMALLEST_COVER_H = 190, 110
local DOCK_H, DOCK_LINE_H, DOCK_COVER_H = 72, 3, 60
local FEED_SECTIONS = 3 -- on a page

--- The book being read, a tap away on the screens where one might choose what to read.
function Library:dock(item, width)
    local percent = math.max(0, math.min(100, tonumber((item.mandatory or ""):match("%d+")) or 0))
    local pad = Kit.px(16)
    local done = math.floor(width * percent / 100)
    local thickness = Kit.px(DOCK_LINE_H)
    local bar = HorizontalGroup:new{ align = "top" }
    if done > 0 then
        bar[1] = LineWidget:new{ dimen = Geom:new{ w = done, h = thickness }, background = Blitbuffer.COLOR_BLACK }
    end
    if done < width then
        bar[#bar + 1] = LineWidget:new{ dimen = Geom:new{ w = width - done, h = thickness }, background = Blitbuffer.COLOR_LIGHT_GRAY }
    end
    local cover_h = Kit.px(DOCK_COVER_H)
    local cover_w = math.floor(cover_h * 2 / 3)
    local pill_w, pill_h = Kit.px(92), Kit.px(38)
    local pill = FrameContainer:new{
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        radius = math.floor(pill_h / 2),
        bordersize = 0,
        padding = 0,
        CenterContainer:new{ dimen = Geom:new{ w = pill_w, h = pill_h }, Kit.text("Читать", 15, { bold = true }) },
    }
    local gap = Kit.px(12)
    local text_w = width - 2 * pad - cover_w - pill_w - 2 * gap
    local names = VerticalGroup:new{ align = "left",
        Kit.text(item.title or item.text, 16, { bold = true, max_width = text_w }),
    }
    if item.authors and item.authors ~= "" then
        names[2] = Kit.gap(Kit.px(2))
        names[3] = Kit.text(item.authors, 14, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = text_w })
    end
    self.dock_item = item
    self.dock_widget = Kit.Tappable:new{
        callback = function() self:onMenuSelect(item) end,
        VerticalGroup:new{ align = "left",
            bar,
            LeftContainer:new{
                dimen = Geom:new{ w = width, h = Kit.px(DOCK_H) },
                HorizontalGroup:new{ align = "center",
                    HorizontalSpan:new{ width = pad },
                    cover_box(item, cover_w, cover_h),
                    HorizontalSpan:new{ width = gap },
                    Kit.fixed(names, text_w),
                    HorizontalSpan:new{ width = gap },
                    pill,
                },
            },
        },
    }
    return self.dock_widget
end

--- A name to tap at the left, how many there are and a chevron at the right.
local function heading_row(name, count, width, height, callback, size, icon)
    local right, room = Kit.value_and_chevron(count and tostring(count) or nil)
    local box = Geom:new{ w = width + room, h = height }
    local title_w = width - right:getSize().w - Kit.px(12) + room
    local left = HorizontalGroup:new{ align = "center" }
    if icon then
        local side = Kit.px(26)
        local file = icon:match("%.svg$") and icon or nil
        left[1] = IconWidget:new{ icon = not file and icon or nil, file = file, width = side, height = side }
        left[2] = HorizontalSpan:new{ width = Kit.px(14) }
        title_w = title_w - side - Kit.px(14)
    end
    left[#left + 1] = Kit.text(name, size, { bold = not icon, max_width = title_w })
    return Kit.Tappable:new{
        callback = callback,
        OverlapGroup:new{
            dimen = box:copy(),
            allow_mirroring = false,
            LeftContainer:new{ dimen = box:copy(), left },
            RightContainer:new{ dimen = box:copy(), right },
        },
    }
end

--- A row of covers, as many as fit, standing from margin to margin.
function Library:coverRow(books, width, cover_h, with_progress)
    local cover_w = math.floor(cover_h * 2 / 3)
    local gap = Kit.px(STRIP_GAP)
    local fit = math.max(1, math.floor((width + gap) / (cover_w + gap)))
    if #books >= fit and fit > 1 then gap = math.floor((width - fit * cover_w) / (fit - 1)) end
    local row = HorizontalGroup:new{ align = "top" }
    for i = 1, math.min(fit, #books) do
        local item = books[i]
        local cell = VerticalGroup:new{ align = "left", cover_box(item, cover_w, cover_h) }
        if with_progress then
            cell[2] = LeftContainer:new{
                dimen = Geom:new{ w = cover_w, h = Kit.px(STRIP_LABEL_H) },
                Kit.text(item.mandatory or "", 14, { color = Blitbuffer.COLOR_DARK_GRAY }),
            }
        end
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = Kit.Tappable:new{ callback = function() self:onMenuSelect(item) end, cell }
        self.rows[#self.rows + 1] = item
    end
    return row
end

--- A shelf's name and its covers.
function Library:strip(id, books, width, cover_h, with_progress)
    local row = self:coverRow(books, width, cover_h, with_progress)
    self.strips[id] = row
    return VerticalGroup:new{ align = "left",
        heading_row(Shelves.name(id), #Shelves.list(self.item_table, id), width, Kit.px(STRIP_HEADING_H),
            function() self:openShelf(id) end, 20),
        row,
    }
end

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local SHELF_ICONS = { all = "book.opened", finished = "check", device = HERE .. "/icons/cloud.down.svg" }

function Library:shelfRow(id, width)
    local row = heading_row(Shelves.name(id), #Shelves.list(self.item_table, id), width, Kit.px(SHELF_ROW_H),
        function() self:openShelf(id) end, 18, SHELF_ICONS[id])
    self.shelf_rows[id] = row
    return row
end

-- The first screen: the covers as big as there is room for, then the shelves. If the screen
-- is too short for them the list stays, as it leads to the same books.
function Library:homeBody(width, area)
    local body = VerticalGroup:new{ align = "left" }
    local reading = Shelves.list(self.item_table, "reading")
    table.remove(reading, 1) -- that one is in the dock
    local want = Shelves.list(self.item_table, "want")
    local heading_h, label_h = Kit.px(STRIP_HEADING_H), Kit.px(STRIP_LABEL_H)
    local free = area - 3 * Kit.px(SHELF_ROW_H) - Kit.px(8)
    local show_reading, show_want = #reading > 0, #want > 0
    local cover_h = 0
    while show_reading or show_want do
        local strips = (show_reading and 1 or 0) + (show_want and 1 or 0)
        cover_h = math.floor((free - strips * heading_h - (show_reading and label_h or 0)) / strips)
        if cover_h >= Kit.px(SMALLEST_COVER_H) then break end
        if show_want then show_want = false else show_reading = false end
    end
    cover_h = math.min(cover_h, Kit.px(BIGGEST_COVER_H))
    if show_reading then body[#body + 1] = self:strip("reading", reading, width, cover_h, true) end
    if show_want then body[#body + 1] = self:strip("want", want, width, cover_h) end
    body[#body + 1] = Kit.gap(Kit.px(8))
    for _, id in ipairs { "all", "finished", "device" } do
        body[#body + 1] = self:shelfRow(id, width)
    end
    return body
end

--- Yandex's recommendations: a few sections to a page, each with as many covers as fit.
function Library:feedBody(width, area)
    local state = self.feed
    local sections = state.sections
    self.total_pages = math.max(1, math.ceil(#sections / FEED_SECTIONS))
    -- A page to go on to, when what is on it is still to come.
    if #sections > 0 and not state.finished then self.total_pages = self.total_pages + 1 end
    self.page = math.max(1, math.min(self.page, self.total_pages))
    local cell = math.floor(area / FEED_SECTIONS)
    local heading_h = Kit.px(STRIP_HEADING_H)
    local cover_h = math.min(Kit.px(BIGGEST_COVER_H), cell - heading_h - Kit.px(10))
    local body = VerticalGroup:new{ align = "left" }
    self.feed_sections, self.feed_strips = {}, {}
    local start = (self.page - 1) * FEED_SECTIONS + 1
    for i = start, math.min(#sections, start + FEED_SECTIONS - 1) do
        local section = sections[i]
        local heading = heading_row(section.name, #section.items, width, heading_h,
            function() self:openSection(section) end, 20)
        local row = self:coverRow(section.items, width, cover_h)
        self.feed_sections[#self.feed_sections + 1] = heading
        self.feed_strips[#self.feed_strips + 1] = row
        body[#body + 1] = VerticalGroup:new{ align = "left", heading, row, Kit.gap(Kit.px(10)) }
    end
    self.retry_button = nil
    if #body == 0 then
        local box = Geom:new{ w = width, h = area }
        if state.failed then
            self.retry_button = Kit.button(
                retry_label(state.failed, width),
                width, Kit.px(2 * ROW_H), function()
                    self.on_feed(state)
                    self:refreshScreen()
                end)
            body[1] = CenterContainer:new{ dimen = box, self.retry_button }
        else
            local text = state.finished and "Здесь пока пусто" or "Загружаю…"
            body[1] = CenterContainer:new{ dimen = box, Kit.text(text, 18, { color = Blitbuffer.COLOR_DARK_GRAY }) }
        end
    end
    return body
end

--- A box to tap for typing (see SearchBox), and a way to drop what was searched for.
function Library:searchBar(width)
    local height = Kit.px(44)
    local clear_w = self.query and height or 0
    local icon = Kit.px(26)
    local text_w = width - clear_w - icon - Kit.px(32)
    local box = FrameContainer:new{
        bordersize = Kit.px(1),
        radius = math.floor(height / 2),
        color = Blitbuffer.COLOR_DARK_GRAY,
        padding = 0,
        LeftContainer:new{
            dimen = Geom:new{ w = width - clear_w - 2 * Kit.px(1), h = height - 2 * Kit.px(1) },
            HorizontalGroup:new{ align = "center",
                HorizontalSpan:new{ width = Kit.px(14) },
                IconWidget:new{ icon = "appbar.search", width = icon, height = icon },
                HorizontalSpan:new{ width = Kit.px(10) },
                Kit.text(self.query or "Поиск", 17, {
                    color = not self.query and Blitbuffer.COLOR_DARK_GRAY or nil,
                    max_width = text_w,
                }),
            },
        },
    }
    self.search_bar = Kit.Tappable:new{ callback = function() self:showSearch() end, box }
    local row = HorizontalGroup:new{ align = "center", self.search_bar }
    self.clear_button = nil
    if self.query then
        -- Its middle is where the middle of an icon at the right of a header is.
        local cross = Kit.text("×", 30)
        local size = cross:getSize()
        self.clear_button = Kit.Tappable:new{
            callback = function() self:search("") end,
            Kit.Placed:new{
                width = clear_w,
                height = height,
                dx = clear_w - math.floor(Kit.icon_ink_width("appbar.menu") / 2) - math.floor(size.w / 2) - Kit.px(1),
                dy = math.floor((height - size.h) / 2) - Kit.px(1),
                cross,
            },
        }
        row[2] = self.clear_button
    end
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = Kit.px(SEARCH_H) }, row }
end

function Library:listBody(width, area)
    local section = self.view == "feed_section"
    local books = section and self.section.items or Shelves.list(self.item_table, self.view, self.query)
    self.shown = #books
    local row_h = Kit.px(ROW_H)
    local per_page = math.max(1, math.floor(area / row_h))
    self.total_pages = math.max(1, math.ceil(#books / per_page))
    self.page = math.max(1, math.min(self.page, self.total_pages))
    local body = VerticalGroup:new{ align = "left" }
    if #books == 0 then
        body[1] = CenterContainer:new{
            dimen = Geom:new{ w = width, h = area },
            Kit.text(self.query and "Ничего не нашлось" or "Здесь пока пусто", 18, { color = Blitbuffer.COLOR_DARK_GRAY }),
        }
    end
    local start = (self.page - 1) * per_page + 1
    for i = start, math.min(#books, start + per_page - 1) do
        body[#body + 1] = self:row(books[i], width, row_h)
        self.rows[#self.rows + 1] = books[i]
    end
    return body
end

--- What was found, with the next books asked for before the list runs out of them.
function Library:catalogueBody(width, area)
    local state = self.catalogue
    local books = state.items
    local row_h = Kit.px(ROW_H)
    local per_page = math.max(1, math.floor(area / row_h))
    self.total_pages = math.max(1, math.ceil(#books / per_page))
    -- A page to go on to, when the books for it are still to come.
    if #books > 0 and not state.finished and (#books % per_page == 0 or state.failed) then
        self.total_pages = self.total_pages + 1
    end
    self.page = math.max(1, math.min(self.page, self.total_pages))
    local start = (self.page - 1) * per_page + 1
    local body = VerticalGroup:new{ align = "left" }
    for i = start, math.min(#books, start + per_page - 1) do
        body[#body + 1] = self:row(books[i], width, row_h)
        self.rows[#self.rows + 1] = books[i]
    end
    self.retry_button = nil
    if #self.rows == 0 then
        local box = Geom:new{ w = width, h = area }
        if state.failed then
            self.retry_button = Kit.button(
                retry_label(state.failed, width),
                width, Kit.px(2 * ROW_H), function()
                    self.on_catalogue(state)
                    self:refreshScreen()
                end)
            body[1] = CenterContainer:new{ dimen = box, self.retry_button }
        else
            local text = "Ничего не нашлось"
            if not state.query then text = "Введите название или автора"
            elseif not state.finished then text = #books == 0 and "Ищу…" or "Загружаю…" end
            body[1] = CenterContainer:new{ dimen = box, Kit.text(text, 18, { color = Blitbuffer.COLOR_DARK_GRAY }) }
        end
    end
    return body
end

function Library:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = Kit.px(16)
    local inner = W - 2 * pad
    local row_h, footer_h = Kit.px(HEADER_H), Kit.px(FOOTER_H)
    local header_h = Status.height() + row_h
    local items = self.item_table or {}
    self.item_table = items
    local side = Kit.px(56)
    local view = self.view
    local home, in_feed = view == "home", view == "feed"
    local top_level = home or in_feed or view == "catalogue"
    self.rows, self.strips, self.shelf_rows = {}, {}, {}
    self.row_buttons = {}
    self.owned = nil
    self.feed_sections, self.feed_strips = nil, nil
    self.total_pages = 1
    self.dock_widget, self.dock_item = nil, nil

    local tab_bar
    tab_bar, self.tab_cells = Tabs.bar(W, self:currentTab(), function(id) self:selectTab(id) end)
    local bottom_h = Tabs.height()
    -- Typing a search is no time to go back to a book, and there is no room on the screen.
    local reading = not self.on_sign_in and view ~= "catalogue" and Shelves.list(items, "reading")[1]
    local dock = reading and self:dock(reading, W)
    if dock then bottom_h = bottom_h + dock:getSize().h end

    local body
    local search_bar
    local body_top = header_h + Kit.px(1)
    local free = H - body_top - bottom_h
    if self.on_sign_in then
        body = Kit.button(Kit.text("Войти в Яндекс", 22, { bold = true }), inner, free, self.on_sign_in)
    elseif view == "catalogue" then
        search_bar = self:searchBar(inner)
        body_top = body_top + Kit.px(SEARCH_H)
        body = self:catalogueBody(inner, H - body_top - bottom_h - footer_h)
    elseif in_feed then
        body = self:feedBody(inner, free - footer_h)
    elseif view == "feed_section" then
        body = self:listBody(inner, free - footer_h)
    elseif #items == 0 then
        body = CenterContainer:new{
            dimen = Geom:new{ w = inner, h = free },
            Kit.text(self.message or "Загружаю библиотеку…", 18, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = inner }),
        }
    elseif home then
        body = self:homeBody(inner, free)
    else
        search_bar = self:searchBar(inner)
        body_top = body_top + Kit.px(SEARCH_H)
        body = self:listBody(inner, H - body_top - bottom_h - footer_h)
    end

    self.back_button, self.refresh_button = nil, nil
    local header_row
    local box = Geom:new{ w = W, h = row_h }
    if top_level then
        -- As in the phone app: a large name at the left, and no way back to go by accident.
        local title = home and "Мои книги" or in_feed and "Яндекс Книги" or "Поиск"
        header_row = OverlapGroup:new{
            dimen = box:copy(),
            allow_mirroring = false,
            LeftContainer:new{ dimen = box:copy(),
                HorizontalGroup:new{ align = "center",
                    HorizontalSpan:new{ width = pad },
                    Kit.text(title, 28, { bold = true, max_width = W - 2 * pad - side }),
                },
            },
        }
        if (home or in_feed) and not self.on_sign_in then
            self.refresh_button = Kit.icon_button("cre.render.reload", side, function() self:refresh() end,
                { edge = "right", margin = pad })
            header_row[2] = RightContainer:new{ dimen = box:copy(), self.refresh_button }
        end
    else
        self.back_button = Kit.icon_button("chevron.left", side, function() self:goBack() end, { edge = "left", margin = pad })
        local title = view == "feed_section" and self.section.name
            or ("%s · %d"):format(Shelves.name(view), self.shown or 0)
        header_row = HorizontalGroup:new{ align = "center",
            Kit.fixed(self.back_button, side),
            CenterContainer:new{
                dimen = Geom:new{ w = W - 2 * side, h = row_h },
                Kit.text(title, 20, { bold = true, max_width = W - 2 * side }),
            },
        }
    end
    local header = VerticalGroup:new{ align = "left", overlap_offset = { 0, 0 }, Status:new{ width = W }, header_row }
    if not top_level then header[3] = Kit.line(W) end

    local pager
    pager, self.prev_button, self.next_button = Kit.pager(self.page, self.total_pages, inner, footer_h,
        function(delta) self:turn(delta) end)

    local frame = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        header,
        FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { pad, body_top }, body },
    }
    if search_bar then
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
            overlap_offset = { pad, header_h + Kit.px(1) }, search_bar }
    end
    if self.total_pages > 1 then
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
            overlap_offset = { pad, H - bottom_h - footer_h }, pager }
    end
    if dock then
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
            overlap_offset = { 0, H - bottom_h }, dock }
    end
    frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
        overlap_offset = { 0, H - Tabs.height() }, tab_bar }
    -- Covers take memory until freed, and a long session turns many pages.
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        frame,
    }
    if in_feed then self.feed_page = self.page end
    local place = self.place
    place.view, place.query, place.page = self.view, self.query, self.page
    place.feed, place.section, place.feed_page = self.feed, self.section, self.feed_page
end

--- Which tab this screen belongs to.
function Library:currentTab()
    if self.view == "catalogue" then return "search" end
    if self.view == "feed" or self.view == "feed_section" then return "feed" end
    return "library"
end

function Library:selectTab(id)
    logger.info("yaknigi: tab", id)
    if id == "settings" then
        self.on_settings()
    elseif id == "feed" then
        self:openFeed()
    elseif id == "search" then
        self:openSearch()
    else
        self:goHome()
    end
end

--- Coming to the feed finds it as it was left; a tap on its tab while in it goes to its start.
function Library:openFeed()
    if self.on_sign_in then return self:show("feed") end
    local page = self.view ~= "feed" and self.view ~= "feed_section" and self.feed_page or 1
    local first_time = not self.feed
    if first_time then self.feed = self.load_feed() end
    self:show("feed", nil, page)
    if first_time then self.on_covers(Feed.cards(self.feed.sections, Feed.ROW_COVERS)) end
end

--- What was found last is still there; a tap on the tab while in it starts typing.
function Library:openSearch()
    if self.on_sign_in then return self:show("catalogue") end
    if self.view == "catalogue" then return self:showSearch() end
    if self.catalogue then return self:show("catalogue", self.catalogue.query) end
    self:search("")
end

--- A section of the feed as a list. What is in it is as much as the feed itself sends.
function Library:openSection(section)
    self.section = section
    self:show("feed_section")
    self.on_covers(Catalogue.cards(section.items))
end

function Library:goBack()
    if self.view == "feed_section" then
        self.section = nil
        self:show("feed", nil, self.feed_page)
    else
        self:goHome()
    end
end

function Library:refresh()
    if self.view == "feed" then
        Feed.renew(self.feed)
        self.on_feed(self.feed)
    else
        self.on_refresh()
    end
end

--- Goes to another screen of the library, without keeping the old one's page.
function Library:show(view, query, page)
    self.view, self.query, self.page = view, query, page or 1
    self:build()
    UIManager:setDirty(self, "partial")
    self:askForMore()
end

--- Near the end of what was found, gets the next books, for the next page to be there.
function Library:askForMore()
    if self.on_sign_in then return end
    local near_end = self.page >= self.total_pages - 1
    if self.view == "catalogue" and near_end then
        self.on_catalogue(self.catalogue)
    elseif self.view == "feed" and (near_end or self.feed.stale) then
        self.on_feed(self.feed)
    end
end

function Library:openShelf(id)
    logger.info("yaknigi: library shelf", id)
    self:show(id)
end

function Library:goHome()
    self:show("home")
end

--- On a shelf, looks through that shelf; on the search tab, through all of Yandex's books.
function Library:search(query)
    query = query:match("^%s*(.-)%s*$")
    query = query ~= "" and query or nil
    if self.view == "home" or self.view == "feed" or self.view == "feed_section" or self.view == "catalogue" then
        self.catalogue = Catalogue.new(query)
        self.place.catalogue = self.catalogue
        self:show("catalogue", query)
        if not query then self:showSearch() end -- the box comes empty, to type anew
    else
        self:show(self.view, query)
    end
end

function Library:showSearch()
    if self.search_box then return end
    -- The books are mostly in Russian, and the sign-in code leaves the Latin keyboard on.
    if #(G_reader_settings:readSetting("keyboard_layouts") or {}) == 0 then
        G_reader_settings:saveSetting("keyboard_layouts", { "ru", "en" })
    end
    G_reader_settings:saveSetting("keyboard_layout", "ru")
    self.search_box = SearchBox:new{
        text = self.query or "",
        hint = self.view == "catalogue" and "Поиск по всем книгам" or "Поиск по библиотеке",
        top = Status.height() + Kit.px(HEADER_H) + Kit.px(1),
        side = Kit.px(16),
        height = Kit.px(44),
        strip_h = Kit.px(SEARCH_H),
        on_find = function(text)
            if not self.query and not text:find("%S") then return false end
            UIManager:nextTick(function() self:search(text) end)
        end,
        on_close = function() self.search_box = nil end,
    }
    self.search_box:open()
end

function Library:onCloseWidget()
    self.stop_status()
    if self.search_box then self.search_box:dismiss() end
end

function Library:refreshScreen()
    self:build()
    UIManager:setDirty(self, "ui")
end

--- Same call as KOReader's Menu, used when new data arrives.
function Library:switchItemTable(_, items)
    self.item_table = items
    self:refreshScreen()
end

function Library:setMessage(text)
    self.message = text
    self:refreshScreen()
end

function Library:turn(delta)
    local page = self.page + delta
    if page < 1 or page > self.total_pages then return end
    self.page = page
    logger.info("yaknigi: library page", page, "of", self.total_pages)
    self:build()
    UIManager:setDirty(self, "partial")
    self:askForMore()
    -- This page's covers before those of the pages not being looked at.
    local missing = {}
    for _, item in ipairs(self.rows or {}) do
        if item.card and not item.cover then missing[#missing + 1] = item.card end
    end
    if #missing > 0 then self.on_covers(missing) end
end

function Library:onSwipe(_, ges)
    if ges.direction == "west" or ges.direction == "north" then self:turn(1)
    elseif ges.direction == "east" or ges.direction == "south" then self:turn(-1) end
    return true
end

function Library:onClose()
    self.close_callback()
    return true
end

return Library
