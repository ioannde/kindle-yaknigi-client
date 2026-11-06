-- What can be done with a book, as the phone's sheet from below: a row with a picture and a name
-- for each thing. A tap outside takes it away.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Kit = require("yaknigi/kit")

local HERE = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
local ROW_H, ICON = 64, 32

local BookMenu = InputContainer:extend{
    name = "YaknigiBookMenu",
    modal = true,
    title = nil,
    authors = nil,
    -- { key, text, icon or file, action, disabled }. An action runs once the sheet is gone.
    entries = nil,
}

function BookMenu:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SwipeOutside = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    local margin = Kit.px(10)
    local pad = Kit.px(20)
    local sheet_w = W - 2 * margin
    local inner = sheet_w - 2 * pad - 2 * Kit.px(1)
    local names = VerticalGroup:new{ align = "left",
        Kit.gap(Kit.px(14)),
        Kit.text(self.title or "", 19, { bold = true, max_width = inner }),
    }
    if self.authors and self.authors ~= "" then
        names[#names + 1] = Kit.gap(Kit.px(2))
        names[#names + 1] = Kit.text(self.authors, 15, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = inner })
    end
    names[#names + 1] = Kit.gap(Kit.px(12))
    local rows = VerticalGroup:new{ align = "left",
        HorizontalGroup:new{ HorizontalSpan:new{ width = pad }, names },
        Kit.line(sheet_w - 2 * Kit.px(1)),
    }
    self.rows = {}
    local icon = Kit.px(ICON)
    local box = Geom:new{ w = sheet_w - 2 * Kit.px(1), h = Kit.px(ROW_H) }
    for _, entry in ipairs(self.entries) do
        local color = entry.disabled and Blitbuffer.COLOR_DARK_GRAY or nil
        local content = LeftContainer:new{ dimen = box:copy(),
            HorizontalGroup:new{ align = "center",
                HorizontalSpan:new{ width = pad },
                IconWidget:new{
                    icon = entry.icon,
                    file = entry.file and (HERE .. "/icons/" .. entry.file .. ".svg") or nil,
                    width = icon, height = icon,
                    dim = entry.disabled or nil,
                },
                HorizontalSpan:new{ width = Kit.px(16) },
                Kit.text(entry.text, 18, { color = color, max_width = inner - icon - Kit.px(16) }),
            },
        }
        local row = Kit.Tappable:new{
            callback = function()
                if entry.disabled then return end
                self:dismiss()
                UIManager:nextTick(entry.action)
            end,
            content,
        }
        self.rows[entry.key] = row
        rows[#rows + 1] = row
    end
    local sheet = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_DARK_GRAY,
        bordersize = Kit.px(1),
        radius = Kit.px(18),
        padding = 0,
        rows,
    }
    local size = sheet:getSize()
    self.sheet_area = Geom:new{ x = margin, y = H - size.h - margin, w = size.w, h = size.h }
    sheet.overlap_offset = { self.sheet_area.x, self.sheet_area.y }
    self[1] = OverlapGroup:new{ dimen = self.dimen:copy(), allow_mirroring = false, sheet }
end

function BookMenu:onShow()
    UIManager:setDirty(self, "ui", self.sheet_area)
end

function BookMenu:dismiss()
    UIManager:close(self, "ui", self.sheet_area)
end

function BookMenu:onTapOutside(_, ges)
    if not ges.pos:intersectWith(self.sheet_area) then self:dismiss() end
    return true
end

function BookMenu:onSwipeOutside()
    self:dismiss()
    return true
end

return BookMenu
