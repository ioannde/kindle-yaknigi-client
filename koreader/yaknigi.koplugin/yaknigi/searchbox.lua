-- The library's search bar while it is being typed in: it opens right where the bar is
-- drawn, so there is one box on the screen and no dialog beneath it.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local UIManager = require("ui/uimanager")

local Kit = require("yaknigi/kit")
local Screen = Device.screen

local SearchBox = InputContainer:extend{
    name = "YaknigiSearch",
    is_always_active = true, -- the keyboard is above, and passes on the taps it does not want
    text = "",
    hint = "",
    top = 0, -- where the bar is on the screen
    side = 0, -- its margin
    height = 0, -- of the bar
    strip_h = 0, -- of the bar's place, cleaned of what is beneath
    on_find = nil, -- gets the text. Returns false to go on typing.
    on_close = nil,
}

function SearchBox:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local border = Kit.px(2)
    local icon = Kit.px(26)
    local find_text = Kit.text("Найти", 17, { bold = true })
    local find_w = find_text:getSize().w + Kit.px(12)
    local box_w = W - 2 * self.side - find_w
    local before_icon, after_icon = Kit.px(9), Kit.px(10) -- with the border, as in the bar it replaces
    local face = Kit.face(17)
    self.input = InputText:new{
        parent = self,
        text = self.text,
        hint = self.hint,
        face = face,
        width = box_w - 2 * border - before_icon - icon - after_icon - Kit.px(6),
        -- Exactly a line: its text is at the top of the box, and only then is it in the middle
        -- of the row. Longer text scrolls inside it.
        height = math.floor(1.3 * face.size + 0.5),
        scroll = true,
        padding = 0,
        margin = 0,
        bordersize = 0,
        enter_callback = function() self:find() end,
    }
    self.find_button = Kit.Tappable:new{
        callback = function() self:find() end,
        RightContainer:new{ dimen = Geom:new{ w = find_w, h = self.height }, find_text },
    }
    local row = HorizontalGroup:new{ align = "center",
        FrameContainer:new{
            bordersize = border,
            radius = math.floor(self.height / 2),
            color = Blitbuffer.COLOR_BLACK,
            padding = 0,
            LeftContainer:new{
                dimen = Geom:new{ w = box_w - 2 * border, h = self.height - 2 * border },
                HorizontalGroup:new{ align = "center",
                    HorizontalSpan:new{ width = before_icon },
                    IconWidget:new{ icon = "appbar.search", width = icon, height = icon },
                    HorizontalSpan:new{ width = after_icon },
                    self.input,
                },
            },
        },
        self.find_button,
    }
    self.dimen = Geom:new{ x = 0, y = self.top, w = W, h = self.strip_h }
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        padding_left = self.side,
        padding_right = self.side,
        padding_top = math.floor((self.strip_h - self.height) / 2),
        padding_bottom = self.strip_h - self.height - math.floor((self.strip_h - self.height) / 2),
        row,
    }
    self.ges_events.Tap = {
        GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = W, h = H } },
    }
end

function SearchBox:open()
    UIManager:show(self, "ui", self.dimen, 0, self.top)
    -- Only the emulator and Kindles with keys go without the one on the screen.
    if not (Device:hasKeyboard() or Device:hasScreenKB())
            or G_reader_settings:isTrue("virtual_keyboard_enabled") then
        self.input:onShowKeyboard()
    end
end

function SearchBox:getText() return self.input:getText() end
function SearchBox:setText(text) self.input:setText(text) end

--- The Enter key answers a moment later, by when the box may be gone.
function SearchBox:find()
    if self.closed then return end
    local text = self:getText()
    if self.on_find(text) ~= false then self:dismiss() end
end

function SearchBox:dismiss()
    if self.closed then return end
    self.closed = true
    -- Before closing: closing frees the keyboard, which would stay on the screen.
    self.input:onCloseKeyboard()
    UIManager:close(self, "ui", self.dimen)
    self.on_close()
end

--- A tap anywhere else leaves the search. What the box and its button want never comes here.
function SearchBox:onTap(_, ges)
    local keyboard = self.input.keyboard
    if keyboard and keyboard:isVisible() and keyboard.dimen and not ges.pos:notIntersectWith(keyboard.dimen) then
        return true -- between the keys
    end
    self:dismiss()
    return true
end

-- InputText asks these of its parent on a device with a D-pad.
function SearchBox:getFocusableWidgetXY() end

return SearchBox
