-- The terms of use: accepted once before anything else, and readable from the settings.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local AppState = require("yaknigi/appstate")
local Kit = require("yaknigi/kit")

local FILE = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/../TERMS.md"

local Terms = InputContainer:extend{
    name = "YaknigiTerms",
    covers_fullscreen = true,
    on_accept = nil, -- with these two it asks; without them it is only to read
    on_decline = nil,
}

-- A new edition of the text is a new number: it is then asked for again.
Terms.VERSION = 1

function Terms.accepted()
    return AppState:readSetting("terms") == Terms.VERSION
end

function Terms.accept()
    AppState:saveSetting("terms", Terms.VERSION)
    AppState:flush()
end

local function read_text()
    local f = io.open(FILE, "rb")
    if not f then return "" end
    local text = f:read("*a")
    f:close()
    -- The first line is the title of the screen.
    return (text:gsub("^[^\n]*\n+", ""):gsub("%s+$", ""))
end

function Terms:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } } }
    local inner = W - 2 * Kit.px(32)
    local button_h = Kit.px(56)

    local function finish(callback)
        return function()
            UIManager:close(self)
            if callback then callback() end
        end
    end
    local buttons = VerticalGroup:new{ align = "center" }
    if self.on_accept then
        self.accept_button = Kit.pill("Принимаю", inner, button_h, finish(self.on_accept))
        self.decline_button = Kit.button(Kit.text("Отказаться и выйти", 19), inner, button_h, finish(self.on_decline))
        buttons[1] = self.accept_button
        buttons[2] = self.decline_button
    else
        self.close_button = Kit.pill("Закрыть", inner, button_h, finish())
        buttons[1] = self.close_button
    end

    local title = CenterContainer:new{
        dimen = Geom:new{ w = inner, h = Kit.px(84) },
        Kit.text("Условия использования", 24, { bold = true }),
    }
    local gap = Kit.px(12)
    self.text = ScrollTextWidget:new{
        text = read_text(),
        face = Kit.face(18),
        width = inner,
        height = H - title:getSize().h - buttons:getSize().h - 3 * gap,
        dialog = self,
    }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = W, h = H },
            VerticalGroup:new{ align = "center", title, self.text, Kit.gap(gap), buttons, Kit.gap(gap) },
        },
    }
end

function Terms:onSwipe(_, ges)
    if ges.direction == "north" or ges.direction == "west" then
        self.text:scrollText(1)
    elseif ges.direction == "south" or ges.direction == "east" then
        self.text:scrollText(-1)
    end
    return true
end

function Terms:onShow()
    UIManager:setDirty(self, "full")
end

return Terms
