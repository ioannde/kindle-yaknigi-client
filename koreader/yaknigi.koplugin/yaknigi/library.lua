-- The library: what is being read first, large, and the rest as a list with covers.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local ProgressWidget = require("ui/widget/progresswidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Kit = require("yaknigi/kit")

-- item_table holds { text, title, authors, mandatory, card, sign_in, whole, cover }.
local Library = InputContainer:extend{
    name = "YaknigiLibrary",
    covers_fullscreen = true,
    item_table = nil,
    page = 1,
    message = nil,
    on_sign_in = nil, -- set when nobody is signed in
    onMenuSelect = nil, -- function(self, item)
    close_callback = nil,
    on_refresh = nil,
    on_sign_out = nil,
}

function Library:init()
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

-- What each page holds. The first has the book being read in large.
function Library:layout()
    local H = Screen:getHeight()
    local header_h = Kit.px(60)
    local footer_h = Kit.px(56)
    local area = H - header_h - footer_h - 2 * Kit.px(1)
    local row_h = Kit.px(100)
    local hero_h = Kit.px(190)
    local items = self.item_table or {}
    local has_hero = items[1] and items[1].mandatory and true or false
    local first_rows = math.floor((area - (has_hero and hero_h or 0)) / row_h)
    local rows = math.floor(area / row_h)
    local listed = #items - (has_hero and 1 or 0)
    local pages = 1
    if listed > first_rows then pages = 1 + math.ceil((listed - first_rows) / rows) end
    return {
        header_h = header_h, footer_h = footer_h, row_h = row_h, hero_h = hero_h, has_hero = has_hero,
        first_rows = first_rows, rows = rows, pages = pages,
    }
end

function Library:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = Kit.px(16)
    local inner = W - 2 * pad
    local L = self:layout()
    self.page = math.max(1, math.min(self.page, L.pages))
    self.total_pages = L.pages
    local items = self.item_table or {}
    local side = Kit.px(56)

    self.close_button = Kit.icon_button("close", side, function() self:onClose() end)
    self.menu_button = Kit.icon_button("appbar.menu", side, function() self:showMenu() end)
    local header = HorizontalGroup:new{ align = "center",
        self.close_button,
        CenterContainer:new{
            dimen = Geom:new{ w = W - 2 * side, h = L.header_h },
            Kit.text("Яндекс Книги", 20, { bold = true }),
        },
        self.menu_button,
    }

    local body = VerticalGroup:new{ align = "left" }
    self.rows = {}
    if #items == 0 then
        local box = Geom:new{ w = inner, h = H - L.header_h - L.footer_h - Kit.px(2) }
        if self.on_sign_in then
            body[1] = Kit.button(Kit.text("Войти в Яндекс", 22, { bold = true }), box.w, box.h, self.on_sign_in)
        else
            body[1] = CenterContainer:new{
                dimen = box,
                Kit.text(self.message or "Загружаю библиотеку…", 18, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = inner }),
            }
        end
    else
        local start
        local count
        if self.page == 1 then
            start = 1
            if L.has_hero then
                body[#body + 1] = self:hero(items[1], inner, L.hero_h)
                body[#body + 1] = Kit.line(inner)
                start = 2
            end
            count = L.first_rows
        else
            start = (L.has_hero and 2 or 1) + L.first_rows + (self.page - 2) * L.rows
            count = L.rows
        end
        for i = start, math.min(#items, start + count - 1) do
            body[#body + 1] = self:row(items[i], inner, L.row_h)
            self.rows[#self.rows + 1] = items[i]
        end
    end

    local third = math.floor(inner / 3)
    self.prev_button = Kit.button(Kit.text("‹", 34), third, L.footer_h, function() self:turn(-1) end)
    self.next_button = Kit.button(Kit.text("›", 34), third, L.footer_h, function() self:turn(1) end)
    local pager = HorizontalGroup:new{ align = "center",
        self.prev_button,
        CenterContainer:new{
            dimen = Geom:new{ w = inner - 2 * third, h = L.footer_h },
            Kit.text(self.page .. " / " .. L.pages, 17),
        },
        self.next_button,
    }

    local frame = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        VerticalGroup:new{ align = "left", overlap_offset = { 0, 0 }, header, Kit.line(W) },
        FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { pad, L.header_h + Kit.px(1) }, body },
    }
    if L.pages > 1 then
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
            overlap_offset = { pad, H - L.footer_h }, pager }
    end
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        frame,
    }
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
    self:build()
    UIManager:setDirty(self, "partial")
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
