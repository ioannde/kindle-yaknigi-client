-- Turns the KOReader reader into a plain reading screen: left and right turn pages, the
-- middle brings up our panels, and none of KOReader's own menus come up by themselves.
-- All of it works on this reader's instances, so KOReader's code stays unmodified.
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local Kit = require("yaknigi/kit")
local Prefs = require("yaknigi/prefs")

local Shell = {}
Shell.__index = Shell

-- Rarely used in reading and each one more thing to read on a small dialog.
local HIGHLIGHT_BUTTONS_REMOVED = { "05_wikipedia", "09_view_html", "10_user_dict", "11_follow_link", "12_search" }
-- Three equal columns. KOReader's own back zone ends at a quarter of the width.
local CENTER_ZONE = { ratio_x = 1 / 3, ratio_y = 0, ratio_w = 1 / 3, ratio_h = 1 }
-- As on a Kindle: the top of the page brings up the panels too, whichever column it is in.
local TOP_ZONE = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 0.2 }
local BACK_REST_ZONE = { ratio_x = 1 / 4, ratio_y = 0, ratio_w = 1 / 3 - 1 / 4, ratio_h = 1 }

-- The clock, in the margin above the text.
local Clock = WidgetContainer:extend{}

function Clock.region()
    return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:scaleBySize(Prefs.PAGE_TOP_MARGIN) }
end

function Clock:paintTo(bb, x, y)
    if not Prefs.reading_clock() then return end
    local widget = Kit.text(os.date("%H:%M"), 13)
    local size = widget:getSize()
    local region = Clock.region()
    widget:paintTo(bb, x + math.floor((region.w - size.w) / 2), y + math.floor((region.h - size.h) / 2))
    widget:free()
end

--- plugin must answer stubs() (a table of fragments) and paths() (the book's chapters).
function Shell.new(ui, plugin)
    return setmetatable({ ui = ui, plugin = plugin }, Shell)
end

local function nothing() return nil end

function Shell:install()
    local ui = self.ui
    -- These zones stay registered, as KOReader registers them again on rotation. A
    -- handler that returns nothing passes the tap on to the page-turn zones beneath.
    ui.menu.onTapShowMenu = nothing
    ui.menu.onSwipeShowMenu = nothing
    ui.config.onTapShowConfigMenu = nothing
    ui.config.onSwipeShowConfigMenu = nothing
    ui.view.footer.TapFooter = nothing
    ui.view.footer.onHoldFooter = nothing
    ui.menu.onPressMenu = function() self:showChrome(); return true end

    local shell = self
    ui.view.footer.getBookProgress = function() return shell:progress() end
    -- KOReader puts a symbol before the number, whichever prefix style is chosen.
    ui.view.footer.genFooterText = function() return shell:progressText() end
    for _, id in ipairs(HIGHLIGHT_BUTTONS_REMOVED) do
        ui.highlight:removeFromHighlightDialog(id)
    end
    self:registerZone()
    -- The corner mark big enough to be found again on a page.
    local dogear = ui.view.dogear
    dogear.dogear_max_size = math.ceil(Screen:getWidth() * 0.05)
    dogear:setupDogear(math.min(dogear.dogear_max_size, Kit.px(Prefs.PAGE_TOP_MARGIN)))
    ui.view:registerViewModule("yaknigi_clock", Clock:new{})
    ui.view.footer:onUpdateFooter(true)
    self:startClock()
end

--- Repaints the time at the top of the page, unless the device sleeps or the page is covered.
function Shell:paintClock()
    local ui = self.ui
    if Device.screen_saver_mode or not Prefs.reading_clock() or not ui.view.footer:shouldBeRepainted() then
        return
    end
    require("ui/uimanager"):setDirty(ui.view.dialog, "ui", Clock.region())
end

--- Each minute's turn of the clock on the page.
function Shell:startClock()
    local UIManager = require("ui/uimanager")
    local function next_minute() return 61 - tonumber(os.date("%S")) end
    self.clock_tick = function()
        self:paintClock()
        UIManager:scheduleIn(next_minute(), self.clock_tick)
    end
    UIManager:scheduleIn(next_minute(), self.clock_tick)
end

--- Awake again. The screensaver may still be up, and nothing may be drawn over it.
function Shell:onWake()
    local footer = self.ui.view.footer
    if not Device.screen_saver_mode then footer:onUpdateFooter(footer:shouldBeRepainted()) end
    self:paintClock()
end

--- A tap on the progress on the page: it shows the next thing.
function Shell:nextProgress()
    Prefs.next_progress()
    self.ui.view.footer:onUpdateFooter(true)
end

function Shell:stop()
    if self.clock_tick then
        require("ui/uimanager"):unschedule(self.clock_tick)
        self.clock_tick = nil
    end
end

function Shell:registerZone()
    local ui = self.ui
    local W, H = Screen:getWidth(), Screen:getHeight()
    local footer_h = math.max(ui.view.footer:getHeight() + Kit.px(12), Kit.px(44))
    ui:registerTouchZones({
        {
            -- A square of a tenth of the width, at the corner where the mark appears.
            id = "yaknigi_bookmark",
            ges = "tap",
            screen_zone = { ratio_x = 0.9, ratio_y = 0, ratio_w = 0.1, ratio_h = 0.1 * W / H },
            overrides = { "tap_forward", "tap_backward", "yaknigi_top", "yaknigi_center", "yaknigi_back_rest" },
            handler = function()
                ui.bookmark:onToggleBookmark()
                return true
            end,
        },
        {
            id = "yaknigi_progress",
            ges = "tap",
            screen_zone = { ratio_x = 0.2, ratio_y = 1 - footer_h / H, ratio_w = 0.6, ratio_h = footer_h / H },
            overrides = { "tap_forward", "tap_backward", "yaknigi_center", "yaknigi_back_rest", "readerfooter_tap" },
            handler = function()
                self:nextProgress()
                return true
            end,
        },
        {
            id = "yaknigi_top",
            ges = "tap",
            screen_zone = TOP_ZONE,
            overrides = { "tap_forward", "tap_backward", "yaknigi_center", "yaknigi_back_rest" },
            handler = function() self:showChrome(); return true end,
        },
        {
            id = "yaknigi_center",
            ges = "tap",
            screen_zone = CENTER_ZONE,
            overrides = { "tap_forward", "tap_backward" },
            handler = function() self:showChrome(); return true end,
        },
        {
            id = "yaknigi_back_rest",
            ges = "tap",
            screen_zone = BACK_REST_ZONE,
            overrides = { "tap_forward" },
            handler = function() return ui.rolling:onGotoViewRel(-1) end,
        },
    })
    -- Links and highlights still come first.
    for _, id in ipairs { "yaknigi_progress", "yaknigi_top", "yaknigi_center", "yaknigi_back_rest" } do
        for _, zone in ipairs { "tap_link", "readerhighlight_tap", "readerhighlight_tap_select_mode" } do
            ui.touch_zone_dg:addNodeDep(id, zone)
        end
    end
    ui:registerTouchZones({}) -- orders them again
end

function Shell:showChrome()
    local Chrome = require("yaknigi/chrome")
    local UIManager = require("ui/uimanager")
    UIManager:show(Chrome:new{ ui = self.ui, shell = self })
end

function Shell:hasStubs()
    return next(self.plugin:stubs()) ~= nil
end

--- Share of the book read. A skeleton's pages say little about the book: stubs take one
-- page each, so while there are any, count chapters.
function Shell:progress()
    local doc = self.ui.document
    if not self:hasStubs() then
        local page, pages = doc:getCurrentPage(), doc:getPageCount()
        return pages > 0 and page / pages or 0
    end
    local fragment = tonumber((doc:getXPointer() or ""):match("DocFragment%[(%d+)%]")) or 1
    return (fragment - 1) / math.max(1, #self.plugin:paths())
end

--- Text of the chosen progress display. Asks the table of contents only when it is shown.
function Shell:progressText(long)
    local format = Prefs.progress_format()
    local info = { ratio = self:progress() }
    if not self:hasStubs() then
        local doc, toc = self.ui.document, self.ui.toc
        info.page, info.pages = doc:getCurrentPage(), doc:getPageCount()
        if format == "chapter" then
            -- It has nothing to say after the last heading or before the first.
            local left = toc:getChapterPagesLeft(info.page) or (info.pages - info.page)
            local done = toc:getChapterPagesDone(info.page) or (info.page - 1)
            info.chapter_left, info.chapter_pages = left, left + done + 1
        end
    end
    return Prefs.progress_text(format, info, long)
end

function Shell:gotoRatio(ratio)
    local ui = self.ui
    ui.link:addCurrentLocationToStack()
    if self:hasStubs() then
        local count = #self.plugin:paths()
        local fragment = math.max(1, math.min(count, math.floor(ratio * count) + 1))
        ui.rolling:onGotoXPointer(("/body/DocFragment[%d]"):format(fragment))
    else
        local page = math.max(1, math.floor(ratio * ui.document:getPageCount() + 0.5))
        ui:handleEvent(Event:new("GotoPage", page))
    end
end

return Shell
