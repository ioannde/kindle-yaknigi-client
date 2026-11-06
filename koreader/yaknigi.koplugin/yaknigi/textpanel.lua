-- The "Aa" panel, laid out as the phone's: light and warmth, font and size, line spacing and
-- margins. The page stays visible above it, so that each change can be seen at once.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local cre = require("document/credocument"):engineInit()
local Screen = Device.screen

local Kit = require("yaknigi/kit")

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."

local TextPanel = InputContainer:extend{
    name = "YaknigiTextPanel",
    ui = nil,
    shell = nil,
}

TextPanel.LINE_SPACING = { 100, 115, 130 }
TextPanel.MARGINS = { 10, 20, 35 }

local PREFERRED_FONTS = { "Noto Serif", "FreeSerif", "Noto Sans", "FreeSans" }
-- Bundled for other scripts and for the interface, not for reading a book.
local NOT_FOR_BOOKS = { "CJK", "Arabic", "Bengali", "Devanagari", "Naskh", "Symbol", "Dingbats", "Mono", "Nerd", "Nimbus" }

local function font_list()
    local present, seen, list = {}, {}, {}
    for _, name in ipairs(cre.getFontFaces()) do present[name] = true end
    for _, name in ipairs(PREFERRED_FONTS) do
        if present[name] then list[#list + 1] = name; seen[name] = true end
    end
    -- Whatever the user added to the device's font folder.
    for _, name in ipairs(cre.getFontFaces()) do
        local skip = seen[name]
        for _, word in ipairs(NOT_FOR_BOOKS) do
            if name:find(word, 1, true) then skip = true end
        end
        if not skip then list[#list + 1] = name end
    end
    return list
end

local function nearest(values, value)
    local best, distance = 1, math.huge
    for i, v in ipairs(values) do
        local d = math.abs(v - value)
        if d < distance then best, distance = i, d end
    end
    return best
end

--- A drag asks for the same value many times over, and each change goes to the hardware.
local function only_changes(set)
    local last
    return function(value)
        if value ~= last then
            last = value
            set(value)
        end
    end
end

function TextPanel:init()
    local full = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = full } },
        SwipeFont = { GestureRange:new{ ges = "swipe", range = full } },
    }
    self.fonts = font_list()
    self:build()
end

--- A slider between the two drawings of what it changes.
local function slider_row(slider, left, left_side, right, right_side, box)
    local function icon(name, side)
        return CenterContainer:new{ dimen = Geom:new{ w = box, h = slider:getSize().h },
            IconWidget:new{ file = HERE .. "/icons/" .. name .. ".svg", width = side, height = side } }
    end
    return HorizontalGroup:new{ align = "center", icon(left, left_side), slider, icon(right, right_side) }
end

--- The name of a font, in that font if it can be had.
local function font_name_widget(name, size, width)
    local filename, index = cre.getFontFaceFilenameAndFaceIndex(name)
    local face
    if filename then
        local ok, got = pcall(Font.getFace, Font, filename, size, index)
        face = ok and got or nil
    end
    return Kit.text(name, size, { face = face, max_width = width })
end

local function mark_color(on)
    return on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
end

--- Lines of a page, closer or further apart.
local function spacing_mark(lines, on)
    return Kit.Drawn:new{ width = Kit.px(58), height = Kit.px(38), draw = function(bb, x, y, w, h)
        local thick = on and Kit.px(2) + 1 or Kit.px(1) + 1
        for i = 0, lines - 1 do
            bb:paintRect(x, y + math.floor(i * (h - thick) / (lines - 1)), w, thick, mark_color(on))
        end
    end }
end

--- A page, open below as if it went on, with its text further from the edges or closer.
local function margin_mark(inset, on)
    return Kit.Drawn:new{ width = Kit.px(58), height = Kit.px(38), draw = function(bb, x, y, w, h)
        local thick = on and Kit.px(2) + 1 or Kit.px(1) + 1
        local color = mark_color(on)
        bb:paintRect(x, y, w, thick, color)
        bb:paintRect(x, y, thick, h, color)
        bb:paintRect(x + w - thick, y, thick, h, color)
        local start = y + 2 * thick + Kit.px(3)
        for i = 0, 4 do
            bb:paintRect(x + inset, start + math.floor(i * (h - (start - y) - thick) / 4), w - 2 * inset, thick, color)
        end
    end }
end

--- A choice of three drawings; returns the cells and the row of them.
local function marks(drawings, selected, width, on_select)
    local cell = math.floor(width / #drawings)
    local cells, row = {}, HorizontalGroup:new{ align = "center" }
    for i, draw in ipairs(drawings) do
        cells[i] = Kit.button(draw(i == selected), cell, Kit.px(54), function() on_select(i) end)
        row[i] = cells[i]
    end
    return cells, row
end

--- Where in the list of fonts we are: at most this many dots, around the current one.
local MAX_DOTS = 7

local function font_dots(count, current, width)
    local shown = math.min(count, MAX_DOTS)
    local first = math.max(1, math.min(current - math.floor(shown / 2), count - shown + 1))
    return Kit.Drawn:new{ width = width, height = Kit.px(18), draw = function(bb, x, y, w, h)
        local r, step = Kit.px(4), Kit.px(20)
        local left = x + math.floor((w - (shown - 1) * step) / 2)
        local middle = y + math.floor(h / 2)
        for i = 0, shown - 1 do
            local on = first + i == current
            bb:paintRoundedRect(left + i * step - r, middle - r, 2 * r, 2 * r, mark_color(on), r)
        end
    end }
end

--- The minus and the plus, cut square rather than borrowed from a font: they centre exactly.
local function size_mark(plus)
    return Kit.Drawn:new{ width = Kit.px(22), height = Kit.px(22), draw = function(bb, x, y, w, h)
        local thick = Kit.px(2) + 1
        bb:paintRect(x, y + math.floor((h - thick) / 2), w, thick, Blitbuffer.COLOR_BLACK)
        if plus then bb:paintRect(x + math.floor((w - thick) / 2), y, thick, h, Blitbuffer.COLOR_BLACK) end
    end }
end

function TextPanel:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = Kit.px(16)
    local inner = W - 2 * pad
    local ui = self.ui
    local config = ui.document.configurable
    local rows = VerticalGroup:new{ align = "center" }

    local powerd = Device:hasFrontlight() and Device:getPowerDevice()
    if powerd then
        local box = Kit.px(44)
        local slider_w = inner - 2 * box
        local set_light = only_changes(function(v) powerd:setIntensity(v) end)
        self.light = Kit.Slider:new{
            width = slider_w,
            ratio = powerd:frontlightIntensity() / powerd.fl_max,
            show_dirty = self,
            on_drag = function(r) set_light(math.floor(r * powerd.fl_max + 0.5)) end,
            on_commit = function(r) set_light(math.floor(r * powerd.fl_max + 0.5)); self:rebuild() end,
        }
        rows[#rows + 1] = slider_row(self.light, "sun", Kit.px(24), "sun", Kit.px(36), box)
        if Device:hasNaturalLight() then
            local set_warmth = only_changes(function(v) powerd:setWarmth(v) end)
            self.warmth = Kit.Slider:new{
                width = slider_w,
                ratio = powerd:frontlightWarmth() / 100,
                show_dirty = self,
                on_drag = function(r) set_warmth(math.floor(r * 100 + 0.5)) end,
                on_commit = function(r) set_warmth(math.floor(r * 100 + 0.5)); self:rebuild() end,
            }
            rows[#rows + 1] = slider_row(self.warmth, "cold", Kit.px(30), "warm", Kit.px(30), box)
        end
        rows[#rows + 1] = Kit.gap(Kit.px(12))
    end

    -- Two columns: the font and the spacing on the left, the size and the margins on the right.
    local between = Kit.px(16)
    local col = math.floor((inner - between) / 2)
    local name_h = Kit.px(56)

    local current = 1
    local font_name = ui.font.font_face or ""
    for i, name in ipairs(self.fonts) do
        if name == font_name then current = i end
    end
    -- Half of the name goes back and half goes forward; a swipe across it does the same.
    local nothing = HorizontalSpan:new{ width = 0 }
    self.font_prev = Kit.button(nothing, math.floor(col / 2), name_h, function() self:stepFont(-1) end)
    self.font_next = Kit.button(nothing, col - math.floor(col / 2), name_h, function() self:stepFont(1) end)
    local name_box = Geom:new{ w = col, h = name_h }
    local font_column = VerticalGroup:new{ align = "center",
        OverlapGroup:new{ dimen = name_box:copy(), allow_mirroring = false,
            CenterContainer:new{ dimen = name_box:copy(), font_name_widget(font_name, 28, col - Kit.px(8)) },
            HorizontalGroup:new{ self.font_prev, self.font_next },
        },
    }
    if #self.fonts > 1 then font_column[2] = font_dots(#self.fonts, current, col) end

    local pill_h = Kit.px(52)
    local pill_w = math.min(col, Kit.px(250))
    local border = Kit.px(1) + 1
    local cell = math.floor((pill_w - 2 * border - border) / 2)
    self.size_down = Kit.button(size_mark(false), cell, pill_h - 2 * border, function() self:stepSize(-1) end)
    self.size_up = Kit.button(size_mark(true), cell, pill_h - 2 * border, function() self:stepSize(1) end)
    local pill = FrameContainer:new{
        bordersize = border, padding = 0, margin = 0,
        radius = math.floor(pill_h / 2),
        color = Blitbuffer.COLOR_BLACK,
        HorizontalGroup:new{ align = "center",
            self.size_down,
            LineWidget:new{ dimen = Geom:new{ w = border, h = pill_h - 2 * border }, background = Blitbuffer.COLOR_BLACK },
            self.size_up,
        },
    }
    rows[#rows + 1] = HorizontalGroup:new{ align = "center",
        font_column,
        HorizontalSpan:new{ width = between },
        CenterContainer:new{ dimen = Geom:new{ w = col, h = font_column:getSize().h }, pill },
    }
    rows[#rows + 1] = Kit.gap(Kit.px(10))

    local spacing_row, margins_row
    self.spacing, spacing_row = marks({
        function(on) return spacing_mark(5, on) end,
        function(on) return spacing_mark(4, on) end,
        function(on) return spacing_mark(3, on) end,
    }, nearest(self.LINE_SPACING, config.line_spacing), col, function(i) self:setLineSpacing(self.LINE_SPACING[i]) end)
    local margin = config.h_page_margins and config.h_page_margins[1] or 20
    self.margins, margins_row = marks({
        function(on) return margin_mark(Kit.px(5), on) end,
        function(on) return margin_mark(Kit.px(12), on) end,
        function(on) return margin_mark(Kit.px(18), on) end,
    }, nearest(self.MARGINS, margin), col, function(i) self:setMargins(self.MARGINS[i]) end)
    rows[#rows + 1] = HorizontalGroup:new{ align = "center",
        spacing_row,
        HorizontalSpan:new{ width = between },
        margins_row,
    }
    rows[#rows + 1] = Kit.gap(Kit.px(12))
    self.advanced = Kit.button(Kit.text("ДОПОЛНИТЕЛЬНЫЕ НАСТРОЙКИ", 14), inner, Kit.px(44), function()
        self:close()
        UIManager:nextTick(function() ui.config:onShowConfigMenu() end)
    end)
    rows[#rows + 1] = self.advanced

    local body = Kit.Sheet:new{ width = W, edge = "bottom",
        Kit.panel(W, rows, pad, true),
    }
    local h = body:getSize().h
    self.area = Geom:new{ x = 0, y = H - h, w = W, h = h }
    self[1] = body
    self.dimen = self.area:copy()
end

--- A swipe across the name of the font goes on to the next one, as on the phone.
function TextPanel:onSwipeFont(_, ges)
    local on_name = ges.pos:intersectWith(self.font_prev.dimen) or ges.pos:intersectWith(self.font_next.dimen)
    if not on_name then return end
    if ges.direction == "west" then self:stepFont(1)
    elseif ges.direction == "east" then self:stepFont(-1) end
    return true
end

function TextPanel:paintTo(bb)
    -- Sits at the bottom of the screen, whatever the panel's height is.
    InputContainer.paintTo(self, bb, self.area.x, self.area.y)
end

function TextPanel:rebuild(whole_screen)
    self:build()
    UIManager:setDirty(whole_screen and "all" or self, "ui", self.area)
end

function TextPanel:onShow()
    UIManager:setDirty(self, "ui", self.area)
end

function TextPanel:close()
    UIManager:close(self, "ui", self.area)
end

function TextPanel:onTapOutside(_, ges)
    if not ges.pos:intersectWith(self.area) then self:close() end
    return true
end

-- Each change is also the default for books to come: the shell puts these in a book's
-- settings before it opens.

function TextPanel:stepFont(delta)
    local list = self.fonts
    if #list == 0 then return end
    local index = 0
    for i, name in ipairs(list) do
        if name == self.ui.font.font_face then index = i end
    end
    local name = list[(index - 1 + delta) % #list + 1]
    self.ui:handleEvent(Event:new("SetFont", name))
    G_reader_settings:saveSetting("cre_font", name)
    self:rebuild()
end

function TextPanel:stepSize(delta)
    local config = self.ui.document.configurable
    local size = math.floor(config.font_size) + delta
    self.ui:handleEvent(Event:new("SetFontSize", size))
    G_reader_settings:saveSetting("copt_font_size", config.font_size)
    self:rebuild()
end

function TextPanel:setLineSpacing(percent)
    self.ui:handleEvent(Event:new("SetLineSpace", percent))
    G_reader_settings:saveSetting("copt_line_spacing", percent)
    self:rebuild()
end

function TextPanel:setMargins(side)
    local margins = { side, side }
    self.ui.document.configurable.h_page_margins = margins
    self.ui:handleEvent(Event:new("SetPageHorizMargins", margins))
    G_reader_settings:saveSetting("copt_h_page_margins", margins)
    self:rebuild()
end

return TextPanel
