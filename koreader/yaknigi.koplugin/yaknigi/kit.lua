-- Small widgets shared by the reading panels and the library.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen

local Kit = {}

function Kit.px(n) return Screen:scaleBySize(n) end
function Kit.face(size) return Font:getFace("cfont", size) end

function Kit.text(text, size, opts)
    opts = opts or {}
    return TextWidget:new{
        text = text,
        face = Kit.face(size),
        bold = opts.bold,
        fgcolor = opts.color,
        max_width = opts.max_width,
    }
end

function Kit.line(width)
    return LineWidget:new{ dimen = Geom:new{ w = width, h = Kit.px(1) }, background = Blitbuffer.COLOR_DARK_GRAY }
end

function Kit.gap(height) return VerticalSpan:new{ width = height } end

--- Content at the left of a box of a fixed width, so a row keeps its layout.
function Kit.fixed(content, width)
    return LeftContainer:new{ dimen = Geom:new{ w = width, h = content:getSize().h }, content }
end

--- A white panel of a fixed width.
function Kit.panel(width, content, padding)
    padding = padding or Kit.px(16)
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        padding_left = padding,
        padding_right = padding,
        padding_top = Kit.px(8),
        padding_bottom = Kit.px(8),
        width = width,
        content,
    }
end

-- Anything that can be tapped. The touch area is the size of the content.
local Tappable = InputContainer:extend{ callback = nil }

function Tappable:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function Tappable:onTapSelect()
    self.callback()
    return true
end

Kit.Tappable = Tappable

--- Tappable content centred in a box of the given size.
function Kit.button(content, width, height, callback)
    return Tappable:new{
        callback = callback,
        CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, content },
    }
end

function Kit.icon_button(name, side, callback)
    local icon = Kit.px(36)
    return Kit.button(IconWidget:new{ icon = name, width = icon, height = icon }, side, side, callback)
end

--- An icon or short text with a caption beneath, for the panel's bottom row.
function Kit.action(top, caption, width, callback)
    local group = VerticalGroup:new{
        CenterContainer:new{ dimen = Geom:new{ w = width, h = Kit.px(40) }, top },
        Kit.gap(Kit.px(4)),
        Kit.text(caption, 15, { max_width = width }),
    }
    return Kit.button(group, width, group:getSize().h + Kit.px(16), callback)
end

--- A row of equal cells with one selected, shown inverted.
-- labels: array of strings; selected: index; on_select(index).
function Kit.segments(labels, selected, width, on_select, height)
    height = height or Kit.px(44)
    local cell = math.floor(width / #labels)
    local row = HorizontalGroup:new{ align = "center" }
    for i, label in ipairs(labels) do
        local on = i == selected
        local box = FrameContainer:new{
            background = on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            bordersize = Kit.px(1),
            color = Blitbuffer.COLOR_BLACK,
            padding = 0,
            margin = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = cell - 2 * Kit.px(1), h = height - 2 * Kit.px(1) },
                Kit.text(label, 17, { color = on and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, max_width = cell - Kit.px(8) }),
            },
        }
        row[i] = Tappable:new{ callback = function() on_select(i) end, box }
    end
    return row
end

-- A progress bar that answers to tapping and dragging. on_commit gets the final ratio;
-- on_drag, if given, gets each step of a drag.
local Slider = InputContainer:extend{
    width = nil,
    ratio = 0,
    on_commit = nil,
    on_drag = nil,
}

function Slider:init()
    local bar_height = Kit.px(10)
    local touch = Kit.px(48) -- a thin bar is hard to hit with a finger
    self.bar = ProgressWidget:new{
        width = self.width,
        height = bar_height,
        percentage = self.ratio,
        margin_h = 0,
        margin_v = 0,
        radius = Kit.px(4),
        bordersize = Kit.px(1),
        fillcolor = Blitbuffer.COLOR_BLACK,
        ticks = nil,
    }
    self[1] = CenterContainer:new{ dimen = Geom:new{ w = self.width, h = touch }, self.bar }
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = touch }
    self.ges_events = {
        TapSlider = { GestureRange:new{ ges = "tap", range = self.dimen } },
        PanSlider = { GestureRange:new{ ges = "pan", range = self.dimen } },
        PanReleaseSlider = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
    }
end

function Slider:ratioAt(pos)
    local ratio = (pos.x - self.dimen.x) / self.width
    return math.max(0, math.min(1, ratio))
end

function Slider:show(ratio)
    self.ratio = ratio
    self.bar:setPercentage(ratio)
    UIManager:setDirty(self.show_dirty or "all", "fast", self.dimen)
end

function Slider:onTapSlider(_, ges)
    self.ratio = self:ratioAt(ges.pos)
    self.on_commit(self.ratio)
    return true
end

function Slider:onPanSlider(_, ges)
    self:show(self:ratioAt(ges.pos))
    if self.on_drag then self.on_drag(self.ratio) end
    return true
end

function Slider:onPanReleaseSlider(_, ges)
    self.ratio = self:ratioAt(ges.pos)
    self.on_commit(self.ratio)
    return true
end

Kit.Slider = Slider

return Kit
