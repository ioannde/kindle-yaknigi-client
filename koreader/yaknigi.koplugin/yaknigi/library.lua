-- The library: what is being read first, large, then the shelves, each a list with covers.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
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
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local Screen = Device.screen

local Catalogue = require("yaknigi/catalogue")
local Kit = require("yaknigi/kit")
local SearchBox = require("yaknigi/searchbox")
local Shelves = require("yaknigi/shelves")

-- item_table holds { text, title, authors, mandatory, card, sign_in, whole, cover, shelf }.
local Library = InputContainer:extend{
    name = "YaknigiLibrary",
    covers_fullscreen = true,
    item_table = nil,
    page = 1,
    view = "home", -- or the id of a shelf, or "catalogue": all of Yandex's books
    query = nil,
    place = nil, -- a table that outlives this screen, for coming back from a book
    message = nil,
    on_sign_in = nil, -- set when nobody is signed in
    onMenuSelect = nil, -- function(self, item)
    close_callback = nil,
    on_refresh = nil,
    on_sign_out = nil,
    on_catalogue = nil, -- function(state): asks for the next books found
}

function Library:init()
    self.place = self.place or {}
    -- Signed out, there is nothing but the first screen to come back to.
    self.view = not self.on_sign_in and self.place.view or "home"
    self.query = not self.on_sign_in and self.place.query or nil
    self.page = self.place.page or 1
    self.catalogue = self.place.catalogue
    if self.view == "catalogue" and not self.catalogue then
        self.view, self.query = "home", nil
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:build()
end

local function cover_box(item, w, h)
    if item.cover then
        local ok, image = pcall(ImageWidget.new, ImageWidget, {
            file = item.cover,
            width = w,
            height = h,
            scale_factor = 0, -- fits, keeping the shape
        })
        -- It decodes at the first request for its size: a bad file must fail here.
        ok = ok and pcall(image.getSize, image)
        if ok then
            return FrameContainer:new{ bordersize = 0, padding = 0,
                CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, image } }
        end
    end
    -- No cover yet: a frame with the first letter of the title.
    local letter = (item.title or "?"):match("[%z\1-\127\194-\244][\128-\191]*") or "?"
    return FrameContainer:new{
        bordersize = Kit.px(1),
        padding = 0,
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

function Library:row(item, width, height)
    local cover_h = height - Kit.px(16)
    local cover_w = math.floor(cover_h * 2 / 3)
    local gap = Kit.px(14)
    local text_w = width - cover_w - gap
    local lines = VerticalGroup:new{ align = "left",
        title_box(item.title or item.text, text_w, 19, 2),
    }
    if item.authors and item.authors ~= "" then
        lines[#lines + 1] = Kit.text(item.authors, 15, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = text_w })
    end
    local state = {}
    if item.mandatory then state[#state + 1] = item.mandatory end
    if item.whole then state[#state + 1] = "скачана" end
    if #state > 0 then
        lines[#lines + 1] = Kit.gap(Kit.px(4))
        lines[#lines + 1] = Kit.text(table.concat(state, " · "), 15, { color = Blitbuffer.COLOR_DARK_GRAY })
    end
    return Kit.Tappable:new{
        callback = function() self:onMenuSelect(item) end,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            HorizontalGroup:new{ align = "center",
                cover_box(item, cover_w, cover_h),
                HorizontalSpan:new{ width = gap },
                Kit.fixed(lines, text_w),
            },
        },
    }
end

function Library:hero(item, width, height)
    local cover_h = height - Kit.px(16)
    local cover_w = math.floor(cover_h * 2 / 3)
    local gap = Kit.px(18)
    local text_w = width - cover_w - gap
    local lines = VerticalGroup:new{ align = "left",
        Kit.text("Продолжить чтение", 15, { color = Blitbuffer.COLOR_DARK_GRAY }),
        Kit.gap(Kit.px(6)),
        title_box(item.title or item.text, text_w, 24, 3),
    }
    if item.authors and item.authors ~= "" then
        lines[#lines + 1] = Kit.gap(Kit.px(4))
        lines[#lines + 1] = Kit.text(item.authors, 17, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = text_w })
    end
    local percent = tonumber((item.mandatory or ""):match("%d+"))
    if percent then
        lines[#lines + 1] = Kit.gap(Kit.px(14))
        lines[#lines + 1] = ProgressWidget:new{
            width = text_w, height = Kit.px(8), percentage = percent / 100,
            margin_h = 0, margin_v = 0, radius = Kit.px(3), bordersize = Kit.px(1),
            fillcolor = Blitbuffer.COLOR_BLACK,
        }
        lines[#lines + 1] = Kit.gap(Kit.px(4))
        lines[#lines + 1] = Kit.text(item.mandatory, 15, { color = Blitbuffer.COLOR_DARK_GRAY })
    end
    return Kit.Tappable:new{
        callback = function() self:onMenuSelect(item) end,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            HorizontalGroup:new{ align = "center",
                cover_box(item, cover_w, cover_h),
                HorizontalSpan:new{ width = gap },
                Kit.fixed(lines, text_w),
            },
        },
    }
end

local HEADER_H, FOOTER_H, SEARCH_H, ROW_H, HERO_H = 60, 56, 56, 100, 190
local SHELF_ROW_H, STRIP_HEADING_H, STRIP_COVER_H, STRIP_LABEL_H = 46, 40, 140, 24

--- A row of covers under the shelf's name, as many as fit.
function Library:strip(id, books, width, with_progress)
    local heading = HorizontalGroup:new{ align = "center",
        Kit.fixed(Kit.text(Shelves.name(id), 20, { bold = true }), width - Kit.px(120)),
        RightContainer:new{
            dimen = Geom:new{ w = Kit.px(120), h = Kit.px(STRIP_HEADING_H) },
            Kit.text(("все %d ›"):format(#Shelves.list(self.item_table, id)), 16, { color = Blitbuffer.COLOR_DARK_GRAY }),
        },
    }
    local cover_h = Kit.px(STRIP_COVER_H)
    local cover_w = math.floor(cover_h * 2 / 3)
    local gap = Kit.px(14)
    local fit = math.floor((width + gap) / (cover_w + gap))
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
    end
    self.strips[id] = row
    return VerticalGroup:new{ align = "left",
        Kit.Tappable:new{ callback = function() self:openShelf(id) end, heading },
        row,
    }
end

function Library:shelfRow(id, width)
    local height = Kit.px(SHELF_ROW_H)
    local row = Kit.Tappable:new{
        callback = function() self:openShelf(id) end,
        HorizontalGroup:new{ align = "center",
            Kit.fixed(Kit.text(Shelves.name(id), 19), width - Kit.px(100)),
            RightContainer:new{
                dimen = Geom:new{ w = Kit.px(100), h = height },
                Kit.text(("%d ›"):format(#Shelves.list(self.item_table, id)), 17, { color = Blitbuffer.COLOR_DARK_GRAY }),
            },
        },
    }
    self.shelf_rows[id] = row
    return row
end

-- The first screen: the book to go back to, then the shelves. Covers go first if the
-- screen is short, as the list below them leads to the same books.
function Library:homeBody(width, area)
    local body = VerticalGroup:new{ align = "left" }
    local reading = Shelves.list(self.item_table, "reading")
    local hero = table.remove(reading, 1)
    local want = Shelves.list(self.item_table, "want")
    local free = area - 3 * Kit.px(SHELF_ROW_H)
    if hero then
        body[#body + 1] = self:hero(hero, width, Kit.px(HERO_H))
        body[#body + 1] = Kit.line(width)
        free = free - Kit.px(HERO_H)
    end
    local with_label = Kit.px(STRIP_HEADING_H + STRIP_COVER_H + STRIP_LABEL_H)
    if #reading > 0 and free >= with_label then
        body[#body + 1] = self:strip("reading", reading, width, true)
        free = free - with_label
    end
    if #want > 0 and free >= Kit.px(STRIP_HEADING_H + STRIP_COVER_H) then
        body[#body + 1] = self:strip("want", want, width)
    end
    body[#body + 1] = Kit.gap(Kit.px(4))
    for _, id in ipairs { "all", "finished", "device" } do
        body[#body + 1] = self:shelfRow(id, width)
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
        radius = Kit.px(8),
        color = Blitbuffer.COLOR_DARK_GRAY,
        padding = 0,
        LeftContainer:new{
            dimen = Geom:new{ w = width - clear_w - 2 * Kit.px(1), h = height - 2 * Kit.px(1) },
            HorizontalGroup:new{ align = "center",
                HorizontalSpan:new{ width = Kit.px(10) },
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
        self.clear_button = Kit.button(Kit.text("×", 30), clear_w, height, function() self:search("") end)
        row[2] = self.clear_button
    end
    return CenterContainer:new{ dimen = Geom:new{ w = width, h = Kit.px(SEARCH_H) }, row }
end

function Library:listBody(width, area)
    local books = Shelves.list(self.item_table, self.view, self.query)
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
                Kit.text(state.failed .. " Нажмите, чтобы повторить.", 18, { max_width = width }),
                width, Kit.px(ROW_H), function()
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
    local header_h, footer_h = Kit.px(HEADER_H), Kit.px(FOOTER_H)
    local items = self.item_table or {}
    self.item_table = items
    local side = Kit.px(56)
    local home = self.view == "home"
    self.rows, self.strips, self.shelf_rows = {}, {}, {}
    self.total_pages = 1

    local body
    local search_bar
    local body_top = header_h + Kit.px(1)
    if self.view == "catalogue" then
        search_bar = self:searchBar(inner)
        body_top = body_top + Kit.px(SEARCH_H)
        body = self:catalogueBody(inner, H - body_top - footer_h)
    elseif #items == 0 then
        local box = Geom:new{ w = inner, h = H - header_h - footer_h - Kit.px(2) }
        if self.on_sign_in then
            body = Kit.button(Kit.text("Войти в Яндекс", 22, { bold = true }), box.w, box.h, self.on_sign_in)
        else
            body = CenterContainer:new{
                dimen = box,
                Kit.text(self.message or "Загружаю библиотеку…", 18, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = inner }),
            }
        end
    elseif home then
        body = self:homeBody(inner, H - body_top)
    else
        search_bar = self:searchBar(inner)
        body_top = body_top + Kit.px(SEARCH_H)
        body = self:listBody(inner, H - body_top - footer_h)
    end

    -- On the first screen nothing is up in the left corner: the way back from a book is
    -- there, and one tap too many must do no more than go back a screen.
    self.menu_button = Kit.icon_button("appbar.menu", side, function() self:showMenu() end)
    self.back_button, self.search_button = nil, nil
    local title = "Мои книги"
    local left = HorizontalSpan:new{ width = side }
    local right = HorizontalGroup:new{ align = "center", self.menu_button }
    if home then
        -- All of Yandex's books can be searched, even with nothing in the library yet.
        if not self.on_sign_in then
            self.search_button = Kit.icon_button("appbar.search", side, function() self:showSearch() end)
            right = HorizontalGroup:new{ align = "center", self.search_button, self.menu_button }
        end
    else
        self.back_button = Kit.icon_button("chevron.left", side, function() self:goHome() end)
        left = self.back_button
        title = self.view == "catalogue" and "Все книги Яндекса"
            or ("%s · %d"):format(Shelves.name(self.view), self.shown or 0)
    end
    local side_w = math.max(side, right:getSize().w)
    local header = HorizontalGroup:new{ align = "center",
        Kit.fixed(left, side_w),
        CenterContainer:new{
            dimen = Geom:new{ w = W - 2 * side_w, h = header_h },
            Kit.text(title, 20, { bold = true, max_width = W - 2 * side_w }),
        },
        RightContainer:new{ dimen = Geom:new{ w = side_w, h = header_h }, right },
    }

    local pager
    pager, self.prev_button, self.next_button = Kit.pager(self.page, self.total_pages, inner, footer_h,
        function(delta) self:turn(delta) end)

    local frame = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        VerticalGroup:new{ align = "left", overlap_offset = { 0, 0 }, header, Kit.line(W) },
        FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { pad, body_top }, body },
    }
    if search_bar then
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
            overlap_offset = { pad, header_h + Kit.px(1) }, search_bar }
    end
    if self.total_pages > 1 then
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
            overlap_offset = { pad, H - footer_h }, pager }
    end
    -- Covers take memory until freed, and a long session turns many pages.
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        frame,
    }
    self.place.view, self.place.query, self.place.page = self.view, self.query, self.page
end

--- Goes to another screen of the library, without keeping the old one's page.
function Library:show(view, query)
    self.view, self.query, self.page = view, query, 1
    self:build()
    UIManager:setDirty(self, "partial")
    self:askForMore()
end

--- Near the end of what was found, gets the next books, for the next page to be there.
function Library:askForMore()
    if self.view == "catalogue" and self.page >= self.total_pages - 1 then
        self.on_catalogue(self.catalogue)
    end
end

function Library:openShelf(id)
    logger.info("yaknigi: library shelf", id)
    self:show(id)
end

function Library:goHome()
    self:show("home")
end

--- On a shelf, looks through that shelf; from the first screen, through all of Yandex's books.
function Library:search(query)
    query = query:match("^%s*(.-)%s*$")
    query = query ~= "" and query or nil
    if self.view ~= "home" and self.view ~= "catalogue" then
        self:show(self.view, query)
    elseif query or self.view == "catalogue" then
        self.catalogue = Catalogue.new(query)
        self.place.catalogue = self.catalogue
        self:show("catalogue", query)
        if not query then self:showSearch() end -- the cross clears the box to type anew
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
        hint = (self.view == "home" or self.view == "catalogue") and "Поиск по всем книгам" or "Поиск по библиотеке",
        top = Kit.px(HEADER_H) + Kit.px(1),
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
end

function Library:onSwipe(_, ges)
    if ges.direction == "west" then self:turn(1)
    elseif ges.direction == "east" then self:turn(-1) end
    return true
end

function Library:showMenu()
    local dialog
    local function item(text, action)
        return { {
            text = text,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                UIManager:nextTick(action)
            end,
        } }
    end
    local buttons = {}
    if self.on_sign_in then
        buttons[1] = item("Войти в Яндекс", function() self.on_sign_in() end)
    else
        buttons[1] = item("Обновить", function() self.on_refresh() end)
    end
    if self.on_sign_out then buttons[#buttons + 1] = item("Выйти из аккаунта", function() self.on_sign_out() end) end
    buttons[#buttons + 1] = item("Закрыть приложение", function() self:onClose() end)
    dialog = ButtonDialog:new{ buttons = buttons }
    UIManager:show(dialog)
end

function Library:onClose()
    self.close_callback()
    return true
end

return Library
