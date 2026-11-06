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

local function right_text()
    local NetworkMgr = require("ui/network/manager")
    local parts = {}
    if Device:hasWifiToggle() then
        parts[1] = Prefs.network_symbol(NetworkMgr:isWifiOn(), NetworkMgr:isConnected())
    end
    if Device:hasBattery() then
        local powerd = Device:getPowerDevice()
        local level = powerd:getCapacity()
        parts[#parts + 1] = powerd:getBatterySymbol(powerd:isCharged(), powerd:isCharging(), level)
            .. " " .. level .. "%"
    end
    return table.concat(parts, "   ")
end

function Status:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local pad = Kit.px(16)
    local function put(text, right)
        local widget = Kit.text(text, 13, { color = Blitbuffer.COLOR_BLACK })
        local size = widget:getSize()
        widget:paintTo(bb, right and x + self.width - pad - size.w or x + pad,
            y + math.floor((self.dimen.h - size.h) / 2) + Kit.px(2))
        widget:free()
    end
    put(os.date("%H:%M"))
    put(right_text(), true)
end

--- Keeps the strip of a screen up to date; returns what to call when the screen closes.
function Status.watch(owner)
    local region = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Status.height() }
    local tick
    tick = function()
        UIManager:setDirty(owner, "ui", region)
        UIManager:scheduleIn(61 - tonumber(os.date("%S")), tick)
    end
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), tick)
    return function() UIManager:unschedule(tick) end
end

return Status
