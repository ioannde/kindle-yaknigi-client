-- The strip at the top of the screens outside the book: the time, the connection and the
-- battery. It reads them each time it is painted, so a repaint is all it ever needs.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Screen = Device.screen

local Kit = require("yaknigi/kit")
local Prefs = require("yaknigi/prefs")

local Status = WidgetContainer:extend{ width = nil }

function Status.height() return Kit.px(24) end

function Status:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = Status.height() }
end

-- A battery lying on its side, as on the system's own strip. Returns its width.
local function paint_battery(bb, right, middle, level, charging)
    local w, h = Kit.px(24), Kit.px(12)
    local nub_w, nub_h = Kit.px(2), Kit.px(6)
    local line = Kit.px(1)
    local black, white = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    local x, y = right - w, middle - math.floor(h / 2)
    bb:paintRect(right, middle - math.floor(nub_h / 2), nub_w, nub_h, black)
    bb:paintBorder(x, y, w, h, line, black, Kit.px(2))
    local gap = line + Kit.px(1)
    local inner_w, inner_h = w - 2 * gap, h - 2 * gap
    bb:paintRect(x + gap, y + gap, math.floor(inner_w * math.max(0, math.min(100, level)) / 100 + 0.5), inner_h, black)
    if charging then -- a plus, and a white edge so that it shows over the charge
        local cx, cy = x + math.floor(w / 2), middle
        local long, thick = Kit.px(10), Kit.px(2)
        bb:paintRect(cx - math.floor(long / 2) - line, cy - math.floor(thick / 2) - line, long + 2 * line, thick + 2 * line, white)
        bb:paintRect(cx - math.floor(thick / 2) - line, y, thick + 2 * line, h, white)
        bb:paintRect(cx - math.floor(long / 2), cy - math.floor(thick / 2), long, thick, black)
        bb:paintRect(cx - math.floor(thick / 2), cy - math.floor(long / 2), thick, long, black)
    end
    return w + nub_w
end

function Status:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local pad = Kit.px(16)
    local middle = y + math.floor(self.dimen.h / 2) + Kit.px(2)
    local right = x + self.width - pad
    local function put(text, left_edge)
        local widget = Kit.text(text, 13, { color = Blitbuffer.COLOR_BLACK })
        local size = widget:getSize()
        local left = left_edge or right - size.w
        widget:paintTo(bb, left, middle - math.floor(size.h / 2))
        widget:free()
        return size.w
    end
    -- The time in the left corner, what the device is up to at the right.
    put(os.date("%H:%M"), x + pad)
    if Device:hasBattery() then
        local powerd = Device:getPowerDevice()
        local level = powerd:getCapacity()
        right = right - paint_battery(bb, right - Kit.px(2), middle, level, powerd:isCharging()) - Kit.px(6)
        right = right - put(level .. "%") - Kit.px(10)
    end
    if Device:hasWifiToggle() then
        local NetworkMgr = require("ui/network/manager")
        put(Prefs.network_symbol(NetworkMgr:isWifiOn(), NetworkMgr:isConnected()))
    end
end

--- Keeps the strip of a screen up to date; returns what to call when the screen closes.
function Status.watch(owner)
    local W, H = Screen:getWidth(), Status.height()
    local time_w = Kit.px(16) + Kit.px(70)
    local time_region = Geom:new{ x = 0, y = 0, w = time_w, h = H }
    local rest_region = Geom:new{ x = time_w, y = 0, w = W - time_w, h = H }
    local tick
    tick = function()
        if not Device.screen_saver_mode then
            UIManager:setDirty(owner, Kit.clock_refresh(time_region))
            UIManager:setDirty(owner, "ui", rest_region)
        end
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), tick)
    end
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), tick)
    return function() UIManager:unschedule(tick) end
end

return Status
