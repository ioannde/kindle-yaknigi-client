-- The "Aa" panel: light, theme, font, size, line spacing and margins. The page stays
-- visible above it, so that each change can be seen at once.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local cre = require("document/credocument"):engineInit()
local Screen = Device.screen

local Kit = require("yaknigi/kit")

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
    }
    self.fonts = font_list()
    self:build()
end

function TextPanel:label(text)
    return Kit.text(text, 15, { color = Blitbuffer.COLOR_DARK_GRAY })
end

function TextPanel:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = Kit.px(16)
    local inner = W - 2 * pad
    local ui = self.ui
    local config = ui.document.configurable
    local rows = VerticalGroup:new{ align = "left" }

    local powerd = Device:hasFrontlight() and Device:getPowerDevice()
    if powerd then
        rows[#rows + 1] = self:label("Подсветка")
        local set_light = only_changes(function(v) powerd:setIntensity(v) end)
        self.light = Kit.Slider:new{
            width = inner,
            ratio = powerd:frontlightIntensity() / powerd.fl_max,
            show_dirty = self,
            on_drag = function(r) set_light(math.floor(r * powerd.fl_max + 0.5)) end,
            on_commit = function(r) set_light(math.floor(r * powerd.fl_max + 0.5)); self:rebuild() end,
        }
        rows[#rows + 1] = self.light
        if Device:hasNaturalLight() then
            rows[#rows + 1] = self:label("Теплота")
            local set_warmth = only_changes(function(v) powerd:setWarmth(v) end)
            self.warmth = Kit.Slider:new{
                width = inner,
                ratio = powerd:frontlightWarmth() / 100,
                show_dirty = self,
                on_drag = function(r) set_warmth(math.floor(r * 100 + 0.5)) end,
                on_commit = function(r) set_warmth(math.floor(r * 100 + 0.5)); self:rebuild() end,
            }
            rows[#rows + 1] = self.warmth
        end
    end

    local night = G_reader_settings:isTrue("night_mode")
    self.theme = Kit.segments({ "Светлая", "Тёмная" }, night and 2 or 1, inner, function(i)
        if (i == 2) ~= night then UIManager:broadcastEvent(Event:new("ToggleNightMode")) end
        self:rebuild(true)
    end)
    rows[#rows + 1] = self.theme
    rows[#rows + 1] = Kit.gap(Kit.px(14))

    -- Font on the left, size on the right.
    local side = Kit.px(48)
    local font_name = ui.font.font_face or ""
    local name_width = math.floor(inner * 0.62) - 2 * side
    self.font_prev = Kit.button(Kit.text("‹", 28), side, side, function() self:stepFont(-1) end)
    self.font_next = Kit.button(Kit.text("›", 28), side, side, function() self:stepFont(1) end)
    self.size_down = Kit.button(Kit.text("A−", 18), side, side, function() self:stepSize(-1) end)
    self.size_up = Kit.button(Kit.text("A+", 24), side, side, function() self:stepSize(1) end)
    local size_label_width = inner - math.floor(inner * 0.62) - 2 * side
    rows[#rows + 1] = HorizontalGroup:new{ align = "center",
        self.font_prev,
        Kit.button(Kit.text(font_name, 18, { max_width = name_width }), name_width, side, function() self:stepFont(1) end),
        self.font_next,
        self.size_down,
        Kit.button(Kit.text(tostring(math.floor(config.font_size)), 18), size_label_width, side, function() end),
        self.size_up,
    }
    rows[#rows + 1] = Kit.gap(Kit.px(14))

    local half = math.floor((inner - Kit.px(16)) / 2)
    self.spacing = Kit.segments({ "Плотный", "Обычный", "Широкий" }, nearest(self.LINE_SPACING, config.line_spacing), half,
        function(i) self:setLineSpacing(self.LINE_SPACING[i]) end)
    local margin = config.h_page_margins and config.h_page_margins[1] or 20
    self.margins = Kit.segments({ "Узкие", "Обычные", "Широкие" }, nearest(self.MARGINS, margin), half,
        function(i) self:setMargins(self.MARGINS[i]) end)
    rows[#rows + 1] = HorizontalGroup:new{ align = "top",
        VerticalGroup:new{ align = "left", self:label("Интервал"), self.spacing },
        HorizontalSpan:new{ width = Kit.px(16) },
        VerticalGroup:new{ align = "left", self:label("Поля"), self.margins },
    }
    rows[#rows + 1] = Kit.gap(Kit.px(10))
    self.advanced = Kit.button(Kit.text("Другие настройки", 15), inner, Kit.px(40), function()
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
