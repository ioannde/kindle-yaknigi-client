-- Turns the KOReader reader into a plain reading screen: left and right turn pages, the
-- middle brings up our panels, and none of KOReader's own menus come up by themselves.
-- All of it works on this reader's instances, so KOReader's code stays unmodified.
local Event = require("ui/event")

local Shell = {}
Shell.__index = Shell

-- Rarely used in reading and each one more thing to read on a small dialog.
local HIGHLIGHT_BUTTONS_REMOVED = { "05_wikipedia", "09_view_html", "10_user_dict", "11_follow_link", "12_search" }
-- Three equal columns. KOReader's own back zone ends at a quarter of the width.
local CENTER_ZONE = { ratio_x = 1 / 3, ratio_y = 0, ratio_w = 1 / 3, ratio_h = 1 }
local BACK_REST_ZONE = { ratio_x = 1 / 4, ratio_y = 0, ratio_w = 1 / 3 - 1 / 4, ratio_h = 1 }

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
    ui.view.footer.genFooterText = function()
        return ("%d%%"):format(math.floor(shell:progress() * 100 + 0.5))
    end
    for _, id in ipairs(HIGHLIGHT_BUTTONS_REMOVED) do
        ui.highlight:removeFromHighlightDialog(id)
    end
    self:registerZone()
    ui.view.footer:onUpdateFooter(true)
end

function Shell:registerZone()
    local ui = self.ui
    ui:registerTouchZones({
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
    for _, id in ipairs { "yaknigi_center", "yaknigi_back_rest" } do
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
