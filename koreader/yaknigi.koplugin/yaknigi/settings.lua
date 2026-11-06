-- The app's settings, from the library's menu and from the panels over a book.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Kit = require("yaknigi/kit")
local Prefs = require("yaknigi/prefs")
local Status = require("yaknigi/status")

local Settings = InputContainer:extend{
    name = "YaknigiSettings",
    covers_fullscreen = true,
    ui = nil, -- the file manager's or the reader's
    on_sign_out = nil,
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
    self.stop_status = Status.watch(self)
    self:build()
end

function Settings:build()
    local W, H = self.dimen.w, self.dimen.h
    local pad = Kit.px(16)
    local inner = W - 2 * pad
    local row_h = Kit.px(60)
    local grey = Blitbuffer.COLOR_DARK_GRAY
    local rows = VerticalGroup:new{ align = "left" }
    local function add(widget) rows[#rows + 1] = widget end
    local function section(text)
        add(Kit.gap(Kit.px(14)))
        add(Kit.text(text, 18, { bold = true }))
        add(Kit.gap(Kit.px(2)))
    end
    local function label(text)
        add(Kit.gap(Kit.px(6)))
        add(Kit.text(text, 15, { color = grey, max_width = inner }))
        add(Kit.gap(Kit.px(4)))
    end

    section("Чтение")
    label("Прогресс на странице")
    local format = index_of(Prefs.PROGRESS, Prefs.progress_format())
    local function set_format(i)
        G_reader_settings:saveSetting("yaknigi_progress", Prefs.PROGRESS[i])
        self:changed()
    end
    self.progress = Kit.segments({ "12%", "723", "723 из 1023" }, format, inner, set_format)
    add(self.progress)
    self.progress_left = Kit.segments({ "До конца главы", "До конца книги" }, format and format - 3, inner,
        function(i) set_format(i + 3) end)
    add(Kit.gap(Kit.px(6)))
    add(self.progress_left)

    label("Часы на странице")
    local clock = Prefs.reading_clock()
    self.clock = Kit.segments({ "Показывать", "Скрыть" }, clock and 1 or 2, inner, function(i)
        G_reader_settings:saveSetting("yaknigi_reading_clock", i == 1)
        self:changed()
    end)
    add(self.clock)

    if Device:canDoSwipeAnimation() then
        label("Анимация листания")
        local swipe = G_reader_settings:isTrue("swipe_animations")
        self.swipe = Kit.segments({ "Включена", "Выключена" }, swipe and 1 or 2, inner, function(i)
            G_reader_settings:saveSetting("swipe_animations", i == 1)
            self:changed()
        end)
        add(self.swipe)
    end

    label("Тема")
    local night = G_reader_settings:isTrue("night_mode")
    self.theme = Kit.segments({ "Светлая", "Тёмная" }, night and 2 or 1, inner, function(i)
        if (i == 2) ~= night then UIManager:broadcastEvent(Event:new("ToggleNightMode")) end
        self:changed()
    end)
    add(self.theme)

    section("Сон")
    label("Заставка")
    self.sleep_screen = Kit.segments({ "Обложка книги", "Текущая страница" },
        index_of(Prefs.SLEEP_SCREENS, Prefs.sleep_screen()), inner, function(i)
            G_reader_settings:saveSetting("yaknigi_sleep_screen", Prefs.SLEEP_SCREENS[i])
            Prefs.apply_sleep_screen()
            self:changed()
        end)
    add(self.sleep_screen)
    local note = "Обложка книги, открытой последней"
    if Device:isKindle() and not Device:supportsScreensaver() then
        note = "На Kindle с рекламой заставку показывает сама система"
    end
    add(Kit.gap(Kit.px(4)))
    add(Kit.text(note, 14, { color = grey, max_width = inner }))

    label("Уходить в сон через")
    local minutes = {}
    for i, m in ipairs(Prefs.SLEEP_MINUTES) do minutes[i] = m .. " мин" end
    self.sleep_time = Kit.segments(minutes, nearest(Prefs.SLEEP_MINUTES, Prefs.sleep_minutes()), inner, function(i)
        Prefs.set_sleep_minutes(self.ui, Prefs.SLEEP_MINUTES[i])
        self:changed()
    end)
    add(self.sleep_time)

    self.sign_out = nil
    if self.on_sign_out then
        section("Аккаунт")
        add(Kit.gap(Kit.px(4)))
        self.sign_out = Kit.segments({ "Выйти из аккаунта" }, nil, inner, function()
            self:close()
            UIManager:nextTick(self.on_sign_out)
        end)
        add(self.sign_out)
    end

    self.back = Kit.icon_button("chevron.left", Kit.px(56), function() self:close() end, { edge = "left", margin = pad })
    local header = VerticalGroup:new{ align = "left",
        Status:new{ width = W },
        OverlapGroup:new{
            dimen = Geom:new{ w = W, h = row_h },
            allow_mirroring = false,
            CenterContainer:new{ dimen = Geom:new{ w = W, h = row_h }, Kit.text("Настройки", 20, { bold = true }) },
            CenterContainer:new{ dimen = Geom:new{ w = Kit.px(56), h = row_h }, self.back },
        },
        Kit.line(W),
    }
    local frame = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        VerticalGroup:new{ align = "left", overlap_offset = { 0, 0 }, header },
        FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { pad, header:getSize().h }, rows },
    }
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, frame }
end

--- Everything chosen here shows on this screen, and the page's bottom line waits under it.
function Settings:changed()
    self:build()
    UIManager:setDirty(self, "ui")
    local view = self.ui and self.ui.view
    if view and view.footer then view.footer:onUpdateFooter() end
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
