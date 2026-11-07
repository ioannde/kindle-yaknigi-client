-- Turns the KOReader reader into a plain reading screen: left and right turn pages, the
-- middle brings up our panels, and none of KOReader's own menus come up by themselves.
-- All of it works on this reader's instances, so KOReader's code stays unmodified.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
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

--- Only the time itself: what is repainted each minute.
function Clock.patch()
    local region = Clock.region()
    local widget = Kit.text("00:00", 13)
    local w = widget:getSize().w + 2 * Kit.px(10)
    widget:free()
    return Geom:new{ x = math.floor((region.w - w) / 2), y = 0, w = w, h = region.h }
end

function Clock:paintTo(bb, x, y)
    if not Prefs.reading_clock() then return end
    local widget = Kit.text(os.date("%H:%M"), 13)
    local size = widget:getSize()
    local region = Clock.region()
    widget:paintTo(bb, x + math.floor((region.w - size.w) / 2), y + math.floor((region.h - size.h) / 2))
    widget:free()
end

-- The bookmark as the system's own reader has it: a ribbon hanging from the top of the page,
-- a little way from the corner, with a notch cut into its end.
local Ribbon = {}

function Ribbon.region()
    local W = Screen:getWidth()
    local w = math.floor(W * 0.033)
    local h = math.min(math.floor(W * 0.045), Screen:scaleBySize(Prefs.PAGE_TOP_MARGIN))
    return Geom:new{ x = W - math.floor(W * 0.045) - w, y = 0, w = w, h = h }
end

function Ribbon.paint(bb, x, y)
    local box = Ribbon.region()
    local color = Blitbuffer.Color8(0x44)
    local left, top = x + box.x, y + box.y
    local half = math.floor(box.w / 2)
    local notch = math.floor(box.h * 0.2)
    bb:paintRect(left, top, box.w, box.h - notch, color)
    for row = 0, notch - 1 do
        -- The cut widens from the middle, down to the two points of the ribbon.
        local leg = half - math.floor((row + 1) / notch * half + 0.5)
        local line = top + box.h - notch + row
        bb:paintRect(left, line, leg, 1, color)
        bb:paintRect(left + box.w - leg, line, leg, 1, color)
    end
end

-- The way back after a link has led away: over the page, above its progress.
local LinkBack = WidgetContainer:extend{ shell = nil }
local LINK_BACK_TEXT = "Вернуться к тексту"
-- This far from where a link has led, the reader has gone on reading from there.
local LINK_BACK_PAGES = 3

local function link_back_region(footer_h)
    local text = Kit.text(LINK_BACK_TEXT, 16)
    local w = text:getSize().w + 2 * Kit.px(20)
    text:free()
    local h = Kit.px(44)
    return Geom:new{ x = math.floor((Screen:getWidth() - w) / 2),
        y = Screen:getHeight() - footer_h - h - Kit.px(8), w = w, h = h }
end

function LinkBack:paintTo(bb, x, y)
    if not self.shell:linkBackShown() then return end
    local box = self.shell.link_back_box
    bb:paintRect(x + box.x, y + box.y, box.w, box.h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(x + box.x, y + box.y, box.w, box.h, Kit.px(1), Blitbuffer.COLOR_BLACK)
    local text = Kit.text(LINK_BACK_TEXT, 16)
    local size = text:getSize()
    text:paintTo(bb, x + box.x + math.floor((box.w - size.w) / 2), y + box.y + math.floor((box.h - size.h) / 2))
    text:free()
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
    local footer = ui.view.footer
    footer.genFooterText = function()
        local left, right = shell:progressText()
        return right and (left .. " " .. right) or left
    end
    -- Two parts stand at the two sides of the page, in line with its text. Its paint is
    -- replaced on this reader's footer alone, and the text it measures stays as it was.
    local container = footer.text_container
    local paint_text = container.paintTo
    container.paintTo = function(this, bb, x, y)
        local left, right = shell:progressText()
        if not right then return paint_text(this, bb, x, y) end
        local margins = ui.document.configurable.h_page_margins
        local margin = Kit.px(margins and margins[1] or 20)
        local function put(text, at_right)
            local widget = TextWidget:new{
                text = text,
                face = footer.footer_text_face,
                bold = footer.settings.text_font_bold,
            }
            local size = widget:getSize()
            widget:paintTo(bb, at_right and Screen:getWidth() - margin - size.w or margin,
                y + math.floor((this.dimen.h - size.h) / 2))
            widget:free()
        end
        put(left)
        put(right, true)
    end
    for _, id in ipairs(HIGHLIGHT_BUTTONS_REMOVED) do
        ui.highlight:removeFromHighlightDialog(id)
    end
    -- A tap on a highlight: its privacy comes first, and all of KOReader's is a tap further.
    ui.highlight.showHighlightNoteOrDialog = function(_, index)
        require("yaknigi/notes").showHighlightDialog(ui, index)
    end
    self:watchLinks()
    self:registerZone()
    -- Ours wherever it is asked for. KOReader's has its own menu, which is not needed here.
    ui.toc.onShowToc = function()
        require("ui/uimanager"):show(require("yaknigi/toc"):new{ ui = ui, shell = self })
        return true
    end
    local dogear = ui.view.dogear
    dogear.paintTo = function(_, bb, x, y) Ribbon.paint(bb, x, y) end
    dogear.getRefreshRegion = function() return Ribbon.region() end
    ui.view:registerViewModule("yaknigi_clock", Clock:new{})
    ui.view:registerViewModule("yaknigi_link_back", LinkBack:new{ shell = self })
    -- KOReader's note that the page numbers are being worked out says nothing to a reader.
    ui.view.flipping.getRollingRenderingStateIconWidget = function() return nil end
    ui.view.footer:onUpdateFooter(true)
    self:startClock()
end

--- A link that has led to another page offers the way back. A note in a chapter still on its
-- way cannot be shown yet, which is something other than the link being bad.
function Shell:watchLinks()
    local ui, link = self.ui, self.ui.link
    local go = link.onGotoLink
    link.onGotoLink = function(this, target, ...)
        local to = target.xpointer
        if self:hasStubs() and to and not to:match("^%w[%w+%-.]*:")
                and not ui.document:isXPointerInDocument(to) then
            require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                text = "Эта глава ещё загружается. Попробуйте чуть позже.", timeout = 3 })
            return true
        end
        local stack, page = #this.location_stack, ui.document:getCurrentPage()
        local result = go(this, target, ...)
        local now = ui.document:getCurrentPage()
        if #this.location_stack > stack and now ~= page then
            self.link_back = { page = now }
            self:paintLinkBack()
        end
        return result
    end
end

function Shell:paintLinkBack()
    require("ui/uimanager"):setDirty(self.ui.view.dialog, "ui", self.link_back_box)
end

function Shell:linkBackShown()
    if not self.link_back then return false end
    if math.abs(self.ui.document:getCurrentPage() - self.link_back.page) > LINK_BACK_PAGES then
        self.link_back = nil
        return false
    end
    return true
end

function Shell:goLinkBack()
    self.link_back = nil
    self.ui.link:onGoBackLink()
    self:paintLinkBack()
end

--- Repaints the time at the top of the page, unless the device sleeps or the page is covered.
function Shell:paintClock()
    local ui = self.ui
    if Device.screen_saver_mode or not Prefs.reading_clock() or not ui.view.footer:shouldBeRepainted() then
        return
    end
    require("ui/uimanager"):setDirty(ui.view.dialog, Kit.clock_refresh(Clock.patch()))
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
    local back = link_back_region(footer_h)
    self.link_back_box = back
    ui:registerTouchZones({
        {
            id = "yaknigi_link_back",
            ges = "tap",
            screen_zone = { ratio_x = back.x / W, ratio_y = back.y / H, ratio_w = back.w / W, ratio_h = back.h / H },
            overrides = { "tap_link", "readerhighlight_tap", "readerhighlight_tap_select_mode", "yaknigi_bookmark",
                "yaknigi_progress", "yaknigi_top", "yaknigi_center", "yaknigi_back_rest", "tap_forward", "tap_backward" },
            handler = function()
                if not self:linkBackShown() then return nil end
                self:goLinkBack()
                return true
            end,
        },
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
            screen_zone = { ratio_x = 0, ratio_y = 1 - footer_h / H, ratio_w = 1, ratio_h = footer_h / H },
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
            info.chapter_left = toc:getChapterPagesLeft(info.page) or (info.pages - info.page)
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
