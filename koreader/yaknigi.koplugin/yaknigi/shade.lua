-- The panel that a swipe down brings from the top of any screen, as on the Kindle itself:
-- airplane mode, Wi-Fi, the dark theme, a sync with Yandex Books, all settings, and the light.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Kit = require("yaknigi/kit")
local Radio = require("yaknigi/radio")
local Status = require("yaknigi/status")

local Shade = InputContainer:extend{
    name = "YaknigiShade",
    no_shade = true,
    -- { sync = function or nil, settings = function or nil }, from the plugin.
    actions = nil,
}

-- The plugin that answers for sync and settings: the one of the screen now open.
Shade.owner = nil

--- A round tile: the drawing in a square, black when the thing it stands for is on.
local function disc(name, on, side)
    local icon_side = Kit.px(36)
    return Kit.Drawn:new{ width = side, height = side, draw = function(bb, x, y, w, h)
        local r = math.floor(w / 2)
        local icon = Kit.icon(name, icon_side)
        local ix, iy = x + math.floor((w - icon_side) / 2), y + math.floor((h - icon_side) / 2)
        if on then
            -- The drawing is black on white: painted so, then turned over in its own square.
            bb:paintRoundedRect(x, y, w, h, Blitbuffer.COLOR_BLACK, r)
            bb:paintRect(ix, iy, icon_side, icon_side, Blitbuffer.COLOR_WHITE)
            icon:paintTo(bb, ix, iy)
            bb:invertRect(ix, iy, icon_side, icon_side)
        else
            bb:paintRoundedRect(x, y, w, h, Blitbuffer.COLOR_WHITE, r)
            bb:paintBorder(x, y, w, h, Kit.px(1), Blitbuffer.COLOR_DARK_GRAY, r)
            icon:paintTo(bb, ix, iy)
        end
        icon:free()
    end }
end

function Shade:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeOutside = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.stop_status = Status.watch(self)
    self:build()
end

function Shade:build()
    local W = Screen:getWidth()
    local pad = Kit.px(16)
    local inner = W - 2 * pad
    local actions = self.actions or {}
    local tiles = {
        { id = "airplane", icon = "airplane", text = "Авиарежим", on = Radio.airplane(),
          tap = function() self:toggle("airplane") end },
        { id = "wifi", icon = "wifi", text = "Wi-Fi", on = Radio.wifi() and not Radio.airplane(),
          tap = function() self:toggle("wifi") end },
        { id = "dark", icon = "moon", text = "Тёмная тема", on = G_reader_settings:isTrue("night_mode"),
          tap = function() self:toggleDark() end },
    }
    if actions.sync then
        tiles[#tiles + 1] = { id = "sync", icon = "reload", text = "Синхронизация",
            tap = function() self:after(actions.sync) end }
    end
    if actions.settings then
        tiles[#tiles + 1] = { id = "settings", icon = "tab.settings", text = "Все настройки",
            tap = function() self:after(actions.settings) end }
    end
    local cell = math.floor(inner / 5)
    local side = Kit.px(60)
    local row = HorizontalGroup:new{ align = "top" }
    self.tiles = {}
    for _, tile in ipairs(tiles) do
        local group = VerticalGroup:new{ align = "center",
            disc(tile.icon, tile.on, side),
            Kit.gap(Kit.px(6)),
            Kit.text(tile.text, 14, { max_width = cell - Kit.px(4) }),
        }
        local button = Kit.button(group, cell, group:getSize().h + Kit.px(12), tile.tap)
        button.on = tile.on
        self.tiles[tile.id] = button
        row[#row + 1] = button
    end

    local rows = VerticalGroup:new{ align = "center", Kit.gap(Kit.px(4)), row, Kit.gap(Kit.px(8)) }
    local _, light, warmth = Kit.light_rows(rows, inner, self)
    self.light, self.warmth = light, warmth
    rows[#rows + 1] = Kit.gap(Kit.px(8))

    self.sheet = Kit.Sheet:new{ width = W, edge = "top",
        VerticalGroup:new{ align = "left",
            Status:new{ width = W },
            Kit.panel(W, rows, pad, true),
        },
    }
    self.area = Geom:new{ x = 0, y = 0, w = W, h = self.sheet:getSize().h }
    self[1] = OverlapGroup:new{ dimen = self.dimen:copy(), allow_mirroring = false,
        VerticalGroup:new{ align = "left", self.sheet, overlap_offset = { 0, 0 } } }
end

--- Built anew from what is now on, and shown; a shorter panel uncovers what was under it.
function Shade:rebuild()
    local before = self.area
    self:build()
    UIManager:setDirty("all", "ui", before:combine(self.area))
end

function Shade:onShow()
    UIManager:setDirty(self, "ui", self.area)
end

function Shade:close()
    UIManager:close(self, "ui", self.area)
end

--- Closes, then runs what would otherwise open under it.
function Shade:after(action)
    self:close()
    UIManager:nextTick(action)
end

function Shade:toggle(what)
    local done = function()
        -- Closed meanwhile, then there is nothing to show.
        if UIManager:isWidgetShown(self) then self:rebuild() end
    end
    -- KOReader does not always call back (an emulator has no radios to wait for): the panel
    -- looks again a little later all the same.
    if self.look_again then UIManager:unschedule(self.look_again) end
    self.look_again = done
    UIManager:scheduleIn(3, done)
    if what == "airplane" then
        Radio.setAirplane(not Radio.airplane(), done)
    else
        Radio.setWifi(not (Radio.wifi() and not Radio.airplane()), done)
    end
end

function Shade:toggleDark()
    UIManager:broadcastEvent(Event:new("ToggleNightMode"))
    self:rebuild()
end

-- The connection's news, from KOReader, also after it has stopped waiting for it.
function Shade:onNetworkConnected() self:rebuild() end
function Shade:onNetworkDisconnected() self:rebuild() end

function Shade:onTapOutside(_, ges)
    if not ges.pos:intersectWith(self.area) then self:close() end
    return true
end

function Shade:onSwipeOutside(_, ges)
    if ges.direction == "north" then self:close() end
    return true
end

function Shade:onCloseWidget()
    self.stop_status()
    if self.look_again then UIManager:unschedule(self.look_again) end
end

--- Shows the panel, over whatever is open.
function Shade.open()
    local owner = Shade.owner
    local top = Shade.topmost()
    -- The reading screen's own panels give way to it.
    if top and top.name == "YaknigiChrome" then top:dismiss() end
    local shade = Shade:new{ actions = owner and owner:shadeActions() or {} }
    UIManager:show(shade)
    return shade
end

--- The widget that would get a gesture first: the top one, past the toasts.
function Shade.topmost()
    local stack = UIManager._window_stack
    for i = #stack, 1, -1 do
        local widget = stack[i].widget
        if not widget.toast then return widget end
    end
end

--- Whether an event is the swipe down that brings the panel.
function Shade.wants(event)
    if event.handler ~= "onGesture" then return false end
    local ges = event.args[1]
    if not ges or ges.ges ~= "swipe" or ges.direction ~= "south" then return false end
    if Device.screen_saver_mode or not Shade.owner then return false end
    local top = Shade.topmost()
    if not top or top.no_shade then return false end
    -- The keyboard's keys take swipes for their other letters.
    for _, entry in ipairs(UIManager._window_stack) do
        if entry.widget.name == "VirtualKeyboard" then return false end
    end
    return true
end

local installed = false

--- Takes the swipe down before any screen does, wherever it is made.
function Shade.install()
    if installed then return end
    installed = true
    local send = UIManager.sendEvent
    UIManager.sendEvent = function(manager, event)
        if Shade.wants(event) then
            Shade.open()
            return
        end
        return send(manager, event)
    end
end

return Shade
