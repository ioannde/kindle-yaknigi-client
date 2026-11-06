-- The app's settings, from the library's menu and from the panels over a book. Laid out as
-- the system's own: a list of rows under headings, a switch or the current value at the right
-- of each, and a row with choices opening a screen of its own. It turns page by swipes when
-- it does not fit the screen.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Kit = require("yaknigi/kit")
local Prefs = require("yaknigi/prefs")
local Status = require("yaknigi/status")

local ROW_H, HEADING_H, BAR_H, PAGER_H = 60, 46, 56, 56

local Settings = InputContainer:extend{
    name = "YaknigiSettings",
    covers_fullscreen = true,
    ui = nil, -- the file manager's or the reader's
    on_sign_out = nil,
    body_height = nil, -- how much room the list has; the rest of the screen unless given
    all_rows = nil, -- also the rows that this device has no use for
}

local function index_of(list, value)
    for i, v in ipairs(list) do
        if v == value then return i end
    end
end

local function nearest(list, value)
    local best, distance = 1, math.huge
    for i, v in ipairs(list) do
        if math.abs(v - value) < distance then best, distance = i, math.abs(v - value) end
    end
    return best
end

function Settings:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.page = 1
    self.stop_status = Status.watch(self)
    self:build()
end

--- What the list consists of. Reads the current values, so it is asked anew at each build.
function Settings:entries()
    local list = {}
    local function heading(text) list[#list + 1] = { heading = text } end
    local function switch(key, title, on, set) list[#list + 1] = { key = key, title = title, on = on, set = set } end
    local function choice(key, title, labels, selected, pick, note)
        list[#list + 1] = { key = key, title = title, labels = labels, selected = selected, pick = pick, note = note }
    end

    heading("Чтение")
    switch("clock", "Часы на странице", Prefs.reading_clock(), function(on)
        G_reader_settings:saveSetting("yaknigi_reading_clock", on)
    end)
    if Device:canDoSwipeAnimation() or self.all_rows then
        switch("swipe", "Анимация листания", G_reader_settings:isTrue("swipe_animations"), function(on)
            G_reader_settings:saveSetting("swipe_animations", on)
        end)
    end
    switch("theme", "Тёмная тема", G_reader_settings:isTrue("night_mode"), function()
        UIManager:broadcastEvent(Event:new("ToggleNightMode"))
    end)
    local rates, rate_labels = {}, {}
    for i, item in ipairs(Prefs.REFRESH) do rates[i], rate_labels[i] = item[1], item[2] end
    choice("refresh", "Обновление экрана", rate_labels, index_of(rates, Prefs.refresh_rate()) or 3, function(i)
        Prefs.set_refresh_rate(rates[i])
    end, "Как часто экран полностью перерисовывается со вспышкой. Реже — меньше мигает, но заметнее следы прошлых страниц.")

    heading("Сон")
    local sleep_note = "Обложка книги, открытой последней"
    if Device:isKindle() and not Device:supportsScreensaver() then
        sleep_note = "На Kindle с рекламой заставку показывает сама система"
    end
    choice("sleep_screen", "Заставка", { "Обложка книги", "Текущая страница" },
        index_of(Prefs.SLEEP_SCREENS, Prefs.sleep_screen()), function(i)
            G_reader_settings:saveSetting("yaknigi_sleep_screen", Prefs.SLEEP_SCREENS[i])
            Prefs.apply_sleep_screen()
        end, sleep_note)
    local minutes = {}
    for i, m in ipairs(Prefs.SLEEP_MINUTES) do minutes[i] = m .. " мин" end
    choice("sleep_time", "Уходить в сон через", minutes, nearest(Prefs.SLEEP_MINUTES, Prefs.sleep_minutes()), function(i)
        Prefs.set_sleep_minutes(self.ui, Prefs.SLEEP_MINUTES[i])
    end)

    if self.on_sign_out then
        heading("Аккаунт")
        list[#list + 1] = { key = "sign_out", title = "Выйти из аккаунта", action = function()
            self:close()
            UIManager:nextTick(self.on_sign_out)
        end }
    end
    return list
end

local function row_line(width)
    return LineWidget:new{ dimen = Geom:new{ w = width, h = Kit.px(1) }, background = Blitbuffer.COLOR_LIGHT_GRAY }
end

--- A row across the screen: title at the left, right at the right, the whole of it to tap.
function Settings:row(title, right, right_room, callback)
    local W, h = self.dimen.w, Kit.px(ROW_H)
    local pad = Kit.px(16)
    local right_w = right and right:getSize().w or 0
    local title_w = W - 2 * pad - right_w - Kit.px(12) + (right_room or 0)
    local box = Geom:new{ w = W, h = h }
    local content = OverlapGroup:new{
        dimen = box:copy(),
        allow_mirroring = false,
        LeftContainer:new{ dimen = box:copy(),
            HorizontalGroup:new{ align = "center",
                HorizontalSpan:new{ width = pad },
                Kit.text(title, 18, { max_width = title_w }),
            },
        },
    }
    if right then
        content[2] = RightContainer:new{ dimen = box:copy(),
            HorizontalGroup:new{ align = "center",
                right,
                HorizontalSpan:new{ width = pad - (right_room or 0) },
            },
        }
    end
    return Kit.Tappable:new{ callback = callback, content }
end

--- The current value and a chevron, for a row that leads on.
local function value_and_chevron(value)
    local icon = Kit.px(28)
    local group = HorizontalGroup:new{ align = "center" }
    if value then
        group[1] = Kit.text(value, 16, { color = Blitbuffer.COLOR_DARK_GRAY })
        group[2] = HorizontalSpan:new{ width = Kit.px(6) }
    end
    group[#group + 1] = IconWidget:new{ icon = "chevron.right", width = icon, height = icon }
    return group, Kit.icon_right_room("chevron.right", icon)
end

--- Rows of the list: { height, widget }.
function Settings:mainRows()
    local W = self.dimen.w
    local rows = {}
    self.rows = {}
    for _, entry in ipairs(self:entries()) do
        if entry.heading then
            local box = Geom:new{ w = W, h = Kit.px(HEADING_H) }
            rows[#rows + 1] = {
                heading = true,
                height = box.h,
                widget = LeftContainer:new{ dimen = box,
                    HorizontalGroup:new{ align = "center",
                        HorizontalSpan:new{ width = Kit.px(16) },
                        Kit.text(entry.heading, 15, { bold = true, color = Blitbuffer.COLOR_DARK_GRAY }),
                    },
                },
            }
        else
            local widget
            if entry.labels then
                local right, room = value_and_chevron(entry.labels[entry.selected])
                widget = self:row(entry.title, right, room, function() self:open(entry) end)
            elseif entry.action then
                widget = self:row(entry.title, nil, nil, entry.action)
            else
                widget = self:row(entry.title, Kit.Switch:new{ on = entry.on }, nil, function()
                    entry.set(not entry.on)
                    self:changed()
                end)
            end
            self.rows[entry.key] = widget
            rows[#rows + 1] = {
                height = Kit.px(ROW_H) + Kit.px(1),
                widget = VerticalGroup:new{ align = "left", widget, row_line(W) },
            }
        end
    end
    return rows
end

--- The rows of a screen of choices.
function Settings:choiceRows(choice)
    local W = self.dimen.w
    local rows = {}
    self.options = {}
    for i, label in ipairs(choice.labels) do
        local mark
        if i == choice.selected then
            mark = IconWidget:new{ icon = "check", width = Kit.px(28), height = Kit.px(28) }
        end
        local widget = self:row(label, mark, nil, function()
            choice.pick(i)
            self.choice = nil
            self.page = self.list_page or 1
            self:changed()
        end)
        self.options[i] = widget
        rows[#rows + 1] = {
            height = Kit.px(ROW_H) + Kit.px(1),
            widget = VerticalGroup:new{ align = "left", widget, row_line(W) },
        }
    end
    if choice.note then
        local note = FrameContainer:new{
            bordersize = 0, padding = 0, padding_left = Kit.px(16), padding_right = Kit.px(16), padding_top = Kit.px(12),
            TextBoxWidget:new{
                text = choice.note,
                face = Kit.face(15),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
                width = W - 2 * Kit.px(16),
            },
        }
        rows[#rows + 1] = { height = note:getSize().h, widget = note }
    end
    return rows
end

--- Splits rows between pages of the given height. A heading stays with the row after it.
local function paginate(rows, height)
    local pages, page, used = {}, {}, 0
    for i, row in ipairs(rows) do
        local needed = row.height
        if row.heading and rows[i + 1] then needed = needed + rows[i + 1].height end
        if used + needed > height and #page > 0 then
            pages[#pages + 1] = page
            page, used = {}, 0
        end
        page[#page + 1] = row
        used = used + row.height
    end
    pages[#pages + 1] = page
    return pages
end

function Settings:build()
    local W = self.dimen.w
    local bar_h = Kit.px(BAR_H)
    local choice = self.choice
    local title = choice and choice.title or "Настройки"
    self.back = Kit.icon_button("chevron.left", bar_h, function()
        if self.choice then
            self.choice = nil
            self.page = self.list_page or 1
            self:changed()
        else
            self:close()
        end
    end, { edge = "left", margin = Kit.px(16), width = Kit.px(56) })
    local header = VerticalGroup:new{ align = "left",
        Status:new{ width = W },
        OverlapGroup:new{
            dimen = Geom:new{ w = W, h = bar_h },
            allow_mirroring = false,
            CenterContainer:new{ dimen = Geom:new{ w = W, h = bar_h },
                Kit.text(title, 20, { bold = true, max_width = W - 2 * Kit.px(64) }) },
            self.back,
        },
        Kit.line(W),
    }
    local header_h = header:getSize().h

    local rows = choice and self:choiceRows(choice) or self:mainRows()
    local room = self.body_height or self.dimen.h - header_h
    local pages = paginate(rows, room)
    if #pages > 1 then
        pages = paginate(rows, room - Kit.px(PAGER_H))
    end
    self.pages = #pages
    self.page = math.max(1, math.min(self.page, self.pages))
    local body = VerticalGroup:new{ align = "left" }
    for _, row in ipairs(pages[self.page]) do body[#body + 1] = row.widget end

    local frame = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        VerticalGroup:new{ align = "left", overlap_offset = { 0, 0 }, header },
        FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { 0, header_h }, body },
    }
    self.pager_prev, self.pager_next = nil, nil
    if self.pages > 1 then
        local pager_h = Kit.px(PAGER_H)
        local pager
        pager, self.pager_prev, self.pager_next = Kit.pager(self.page, self.pages, W, pager_h, function(delta)
            self:turn(delta)
        end)
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
            overlap_offset = { 0, self.dimen.h - pager_h }, pager }
    end
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, frame }
end

--- A row with choices opens them on a screen of their own.
function Settings:open(entry)
    self.choice = entry
    self.list_page = self.page
    self.page = 1
    self:build()
    UIManager:setDirty(self, "ui")
end

function Settings:turn(delta)
    local page = self.page + delta
    if page < 1 or page > self.pages then return end
    self.page = page
    self:build()
    UIManager:setDirty(self, "partial")
end

function Settings:onSwipe(_, ges)
    if ges.direction == "west" or ges.direction == "north" then self:turn(1)
    elseif ges.direction == "east" or ges.direction == "south" then self:turn(-1) end
    return true
end

--- Everything chosen here shows on this screen, and the page waits under it.
function Settings:changed()
    self:build()
    UIManager:setDirty(self, "ui")
end

function Settings:onShow()
    UIManager:setDirty(self, "partial")
end

function Settings:close()
    UIManager:close(self, "partial")
end

function Settings:onCloseWidget()
    self.stop_status()
end

return Settings
