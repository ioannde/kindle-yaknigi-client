-- Small widgets shared by the reading panels and the library.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local ProgressWidget = require("ui/widget/progresswidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local Kit = {}

function Kit.px(n) return Screen:scaleBySize(n) end
-- Corners of what lies on the page and of what holds a picture.
function Kit.sheet_radius() return Kit.px(16) end
function Kit.cover_radius() return Kit.px(6) end
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

--- A white panel of a fixed width. clear: what is under it (a Sheet) is its background.
function Kit.panel(width, content, padding, clear)
    padding = padding or Kit.px(16)
    return FrameContainer:new{
        background = not clear and Blitbuffer.COLOR_WHITE or nil,
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

-- How far a rounded corner stands from the side, row by row from the outermost.
local function corner_inset(radius, row)
    local dy = radius - row - 0.5
    return radius - math.floor(math.sqrt(radius * radius - dy * dy) + 0.5)
end

-- A panel lying over the page, its free edge rounded and the page showing past the corners.
-- edge: "top" or "bottom", the side of the screen it stands at.
local Sheet = WidgetContainer:extend{ width = nil, edge = "bottom" }

function Sheet:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self[1]:getSize().h }
end

function Sheet:getSize()
    return Geom:new{ w = self.dimen.w, h = self.dimen.h }
end

function Sheet:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h, r = self.dimen.w, self.dimen.h, Kit.sheet_radius()
    local at_bottom = self.edge == "bottom"
    local white, ink = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_DARK_GRAY
    bb:paintRect(x, at_bottom and y + r or y, w, h - r, white)
    local line = Kit.px(1)
    local before = r
    for i = 0, r - 1 do
        local row = at_bottom and y + i or y + h - 1 - i
        local inset = corner_inset(r, i)
        bb:paintRect(x + inset, row, w - 2 * inset, 1, white)
        if i < line then
            bb:paintRect(x + inset, row, w - 2 * inset, 1, ink)
        else
            local run = math.max(1, before - inset) + line - 1
            bb:paintRect(x + inset, row, run, 1, ink)
            bb:paintRect(x + w - inset - run, row, run, 1, ink)
        end
        before = inset
    end
    self[1]:paintTo(bb, x, y)
end

Kit.Sheet = Sheet

-- A picture with rounded corners and a thin edge, for covers: a white one has to end somewhere.
-- Its content is a box in which a picture of inner_w by inner_h stands in the middle.
local RoundedPicture = WidgetContainer:extend{ inner_w = nil, inner_h = nil }

function RoundedPicture:paintTo(bb, x, y)
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    self[1]:paintTo(bb, x, y)
    local w, h, r = self.inner_w, self.inner_h, Kit.cover_radius()
    local left, top = x + math.floor((size.w - w) / 2), y + math.floor((size.h - h) / 2)
    local white = Blitbuffer.COLOR_WHITE
    for i = 0, r - 1 do
        local inset = corner_inset(r, i)
        bb:paintRect(left, top + i, inset, 1, white)
        bb:paintRect(left + w - inset, top + i, inset, 1, white)
        bb:paintRect(left, top + h - 1 - i, inset, 1, white)
        bb:paintRect(left + w - inset, top + h - 1 - i, inset, 1, white)
    end
    bb:paintBorder(left, top, w, h, Kit.px(1), Blitbuffer.COLOR_LIGHT_GRAY, r)
end

Kit.RoundedPicture = RoundedPicture

-- A switch, as on the system's own settings. It shows; the row around it takes the tap.
local Switch = WidgetContainer:extend{ on = false }

function Switch.size() return Kit.px(52), Kit.px(30) end

function Switch:init()
    local w, h = Switch.size()
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = h }
end

function Switch:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    local r = math.floor(h / 2)
    local black, white = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    bb:paintRoundedRect(x, y, w, h, self.on and black or white, r)
    bb:paintBorder(x, y, w, h, Kit.px(2), black, r)
    local gap = Kit.px(5)
    local knob = h - 2 * gap
    bb:paintRoundedRect(self.on and x + w - gap - knob or x + gap, y + gap, knob, knob, self.on and white or black,
        math.floor(knob / 2))
end

Kit.Switch = Switch

-- Anything that can be tapped. The touch area is the size of the content.
local Tappable = InputContainer:extend{ callback = nil }

function Tappable:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

function Tappable:paintTo(bb, x, y)
    self.painted = true
    InputContainer.paintTo(self, bb, x, y)
end

function Tappable:onTapSelect()
    -- Until it is painted it thinks it is in the corner of the screen, and a tap that
    -- waited in the queue while the screen was rebuilt would land on the wrong thing.
    if not self.painted then return end
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

-- Content moved inside a box of a fixed size, for what no container can align by itself.
local Placed = WidgetContainer:extend{ width = 0, height = 0, dx = 0, dy = 0 }

function Placed:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function Placed:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self[1]:paintTo(bb, x + self.dx, y + self.dy)
end

Kit.Placed = Placed

-- How much empty room KOReader's icons have around what is drawn, as a share of the icon's
-- side. Centring the icon does not centre the drawing, and the two differ from icon to icon.
local INK = {
    ["chevron.left"] = { left = 21 / 76, right = 25 / 76, top = 11 / 76, bottom = 15 / 76 },
    ["chevron.right"] = { left = 25 / 76, right = 21 / 76, top = 11 / 76, bottom = 15 / 76 },
    ["appbar.menu"] = { left = 10 / 76, right = 7 / 76, top = 14 / 76, bottom = 15 / 76 },
    ["appbar.search"] = { left = 13 / 76, right = 6 / 76, top = 7 / 76, bottom = 11 / 76 },
}
local NO_INK = { left = 0, right = 0, top = 0, bottom = 0 }
local ICON = 36

--- Empty room at the right of an icon of the given side.
function Kit.icon_right_room(name, side)
    local ink = INK[name] or NO_INK
    return math.floor(ink.right * side + 0.5)
end

--- Width of what is actually drawn in an icon.
function Kit.icon_ink_width(name)
    local ink = INK[name] or NO_INK
    return math.floor(Kit.px(ICON) * (1 - ink.left - ink.right) + 0.5)
end

--- The drawing is what gets aligned: centred in a box side by side, or with opts.edge
-- ("left" or "right") at opts.margin from that edge of the box. opts.width narrows the box.
function Kit.icon_button(name, side, callback, opts)
    opts = opts or {}
    local icon = Kit.px(ICON)
    local width = opts.width or side
    local ink = INK[name] or NO_INK
    local left, right = math.floor(ink.left * icon + 0.5), math.floor(ink.right * icon + 0.5)
    local top, bottom = math.floor(ink.top * icon + 0.5), math.floor(ink.bottom * icon + 0.5)
    local dx
    if opts.edge == "left" then
        dx = (opts.margin or 0) - left
    elseif opts.edge == "right" then
        dx = width - (opts.margin or 0) - icon + right
    else
        dx = math.floor((width - (icon - left - right)) / 2) - left
    end
    return Tappable:new{
        callback = callback,
        Placed:new{
            width = width,
            height = side,
            dx = dx,
            dy = math.floor((side - (icon - top - bottom)) / 2) - top,
            IconWidget:new{ icon = name, width = icon, height = icon },
        },
    }
end

--- The current value and a chevron, for a row that leads on. Returns them and how much empty
-- room the drawing of the chevron leaves at its right, to go past the row's margin by.
function Kit.value_and_chevron(value)
    local icon = Kit.px(28)
    local group = HorizontalGroup:new{ align = "center" }
    if value then
        group[1] = Kit.text(value, 16, { color = Blitbuffer.COLOR_DARK_GRAY })
        group[2] = HorizontalSpan:new{ width = Kit.px(6) }
    end
    group[#group + 1] = IconWidget:new{ icon = "chevron.right", width = icon, height = icon }
    return group, Kit.icon_right_room("chevron.right", icon)
end

--- ‹ page / pages ›. on_turn gets -1 or 1. Returns the row and both arrows.
function Kit.pager(page, pages, width, height, on_turn)
    local third = math.floor(width / 3)
    local prev = Kit.button(Kit.text("‹", 34), third, height, function() on_turn(-1) end)
    local next_ = Kit.button(Kit.text("›", 34), third, height, function() on_turn(1) end)
    local row = HorizontalGroup:new{ align = "center",
        prev,
        CenterContainer:new{
            dimen = Geom:new{ w = width - 2 * third, h = height },
            Kit.text(page .. " / " .. pages, 17),
        },
        next_,
    }
    return row, prev, next_
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

-- A pill around its cells.
local SegmentRow = HorizontalGroup:extend{}

function SegmentRow:paintTo(bb, x, y)
    local size = self:getSize()
    bb:paintBorder(x, y, size.w, size.h, Kit.px(1), Blitbuffer.COLOR_DARK_GRAY, math.floor(size.h / 2))
    HorizontalGroup.paintTo(self, bb, x, y)
end

--- A pill of equal cells, the selected one a black pill inside it.
-- labels: array of strings; selected: index; on_select(index).
function Kit.segments(labels, selected, width, on_select, height)
    height = height or Kit.px(44)
    local cell = math.floor(width / #labels)
    local row = SegmentRow:new{ align = "center" }
    for i, label in ipairs(labels) do
        local on = i == selected
        local box = FrameContainer:new{
            background = on and Blitbuffer.COLOR_BLACK or nil,
            bordersize = 0,
            padding = 0,
            margin = 0,
            radius = math.floor(height / 2),
            CenterContainer:new{
                dimen = Geom:new{ w = cell, h = height },
                Kit.text(label, 17, { color = on and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, max_width = cell - Kit.px(4) }),
            },
        }
        row[i] = Tappable:new{ callback = function() on_select(i) end, box }
    end
    return row
end

-- A bar with a round handle, that answers to tapping and dragging. on_commit gets the final
-- ratio; on_drag, if given, gets each step of a drag.
local Slider = InputContainer:extend{
    width = nil,
    ratio = 0,
    on_commit = nil,
    on_drag = nil,
}

function Slider:init()
    local touch = Kit.px(48) -- a thin bar is hard to hit with a finger
    self.knob = Kit.px(12)
    -- The handle's middle reaches the ends of the track, and all of it stays on the screen.
    self.track = self.width - 2 * self.knob
    self.bar = ProgressWidget:new{
        width = self.track,
        height = Kit.px(8),
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
    -- A finger wanders off so thin a strip, and a drag still belongs to where it began. How it
    -- ends depends on the speed: a quick one is a swipe, with the finger's way in one piece.
    local screen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local function anywhere(ges) return { GestureRange:new{ ges = ges, range = screen } } end
    self.ges_events = {
        TapSlider = { GestureRange:new{ ges = "tap", range = self.dimen } },
        PanSlider = anywhere("pan"),
        HoldPanSlider = anywhere("hold_pan"),
        PanReleaseSlider = anywhere("pan_release"),
        HoldReleaseSlider = anywhere("hold_release"),
        SwipeSlider = anywhere("swipe"),
        MultiswipeSlider = anywhere("multiswipe"),
    }
end

function Slider:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    local r = self.knob
    local cx = x + r + math.floor(self.ratio * self.track + 0.5)
    local cy = y + math.floor(self.dimen.h / 2)
    bb:paintRoundedRect(cx - r, cy - r, 2 * r, 2 * r, Blitbuffer.COLOR_WHITE, r)
    bb:paintBorder(cx - r, cy - r, 2 * r, 2 * r, Kit.px(2), Blitbuffer.COLOR_BLACK, r)
end

function Slider:ratioAt(pos)
    local ratio = (pos.x - self.dimen.x - self.knob) / self.track
    return math.max(0, math.min(1, ratio))
end

function Slider:has(pos)
    local d = self.dimen
    return pos.x >= d.x and pos.x < d.x + d.w and pos.y >= d.y and pos.y < d.y + d.h
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
    if not self.dragging then
        if not self:has(ges.start_pos or ges.pos) then return end -- someone else's drag
        self.dragging = true
    end
    self:show(self:ratioAt(ges.pos))
    if self.on_drag then self.on_drag(self.ratio) end
    return true
end

Slider.onHoldPanSlider = Slider.onPanSlider

--- A swipe's pos is where it began and end_pos where the finger left; the others have pos.
function Slider:onPanReleaseSlider(_, ges)
    if not self.dragging and not self:has(ges.pos) then return end
    self.dragging = nil
    self.ratio = self:ratioAt(ges.end_pos or ges.pos)
    self.on_commit(self.ratio)
    return true
end

Slider.onHoldReleaseSlider = Slider.onPanReleaseSlider
Slider.onSwipeSlider = Slider.onPanReleaseSlider
Slider.onMultiswipeSlider = Slider.onPanReleaseSlider

Kit.Slider = Slider

return Kit
