-- The "Прочитано" ribbon across the top right corner of a cover. KOReader turns pictures only
-- by right angles, so the ribbon is drawn once for each width of cover and then laid over.
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Kit = require("yaknigi/kit")

local ReadMark = {}

local LABEL = "Прочитано"
local BAND = 0x22 -- gray of the ribbon
local SMALLEST, BIGGEST = 8, 12 -- sizes of its words
local MOST_OF_WIDTH = 0.8 -- on a smaller cover the ribbon would hide the cover

local ROOT2 = math.sqrt(2)
local masks = {}

local function clamp(value) return math.max(0, math.min(1, value)) end

--- The words as a table of how much ink there is in each pixel, with a function to sample it.
local function ink_of(size)
    local text = Kit.text(LABEL, size, { bold = true })
    local measured = text:getSize()
    local w, h = measured.w, measured.h
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    text:paintTo(bb, 0, 0)
    text:free()
    local ink = {}
    for y = 0, h - 1 do
        for x = 0, w - 1 do ink[y * w + x] = 1 - bb:getPixel(x, y):getColor8().a / 255 end
    end
    bb:free()
    local function at(x, y)
        if x < 0 or y < 0 or x >= w or y >= h then return 0 end
        return ink[y * w + x]
    end
    return w, h, function(x, y)
        local left, top = math.floor(x), math.floor(y)
        local dx, dy = x - left, y - top
        return (at(left, top) * (1 - dx) + at(left + 1, top) * dx) * (1 - dy)
            + (at(left, top + 1) * (1 - dx) + at(left + 1, top + 1) * dx) * dy
    end
end

local function build(cover_w)
    local size = math.floor(cover_w / Kit.px(11))
    size = math.max(SMALLEST, math.min(BIGGEST, size))
    local text_w, text_h, ink = ink_of(size)
    -- A band at 45 degrees is as long as twice its distance from the corner.
    local near = math.max((text_w + text_h) / 2, cover_w * 0.2)
    local far = near + text_h
    local side = math.ceil(far * ROOT2) + 1
    if side > cover_w * MOST_OF_WIDTH then return false end

    local mask = Blitbuffer.new(side, side, Blitbuffer.TYPE_BBRGB32)
    local middle, along_middle = (near + far) / 2, side / ROOT2
    for y = 0, side - 1 do
        for x = 0, side - 1 do
            local px, py = x + 0.5, y + 0.5
            local across = (side - px + py) / ROOT2
            local alpha = clamp(across - near + 0.5) * clamp(far - across + 0.5)
            local gray = BAND
            if alpha > 0 then
                local along = (px + py) / ROOT2
                local amount = ink(along - along_middle + text_w / 2 - 0.5, across - middle + text_h / 2 - 0.5)
                gray = BAND + (255 - BAND) * amount
            end
            gray = math.floor(gray + 0.5)
            mask:setPixel(x, y, Blitbuffer.ColorRGB32(gray, gray, gray, math.floor(alpha * 255 + 0.5)))
        end
    end
    return mask
end

--- The ribbon for a cover of this width, or nil if the cover is too small to carry it.
local function mask_for(cover_w)
    if masks[cover_w] == nil then masks[cover_w] = build(cover_w) end
    return masks[cover_w] or nil
end

local Tagged = WidgetContainer:extend{ name = "YaknigiReadTag", mask = nil }

function Tagged:getSize() return self[1]:getSize() end

function Tagged:paintTo(bb, x, y)
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    self[1]:paintTo(bb, x, y)
    local side = self.mask:getWidth()
    bb:alphablitFrom(self.mask, x + size.w - side, y, 0, 0, side, side)
end

--- The cover with the ribbon over it, or as it is when it is too small for one.
function ReadMark.over(cover, width)
    local mask = mask_for(width)
    if not mask then return cover end
    return Tagged:new{ mask = mask, cover }
end

return ReadMark
