-- The table of contents, laid out as the settings are: a header with the way back, a list of
-- rows with the page at the right, turned page by page. The current chapter stands in bold.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Kit = require("yaknigi/kit")
local Status = require("yaknigi/status")

local ROW_H, BAR_H, PAGER_H, INDENT, MAX_DEPTH = 66, 56, 56, 20, 4

local Toc = InputContainer:extend{
    name = "YaknigiToc",
    covers_fullscreen = true,
    ui = nil,
    shell = nil,
}

function Toc:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    local toc = self.ui.toc
    toc:fillToc()
    self.items = toc.toc or {}
    self.current = #self.items > 0 and toc:getTocIndexByPage(self.ui.document:getCurrentPage()) or nil
    -- A skeleton's page numbers say nothing yet of the book.
    self.show_pages = not self.shell:hasStubs()
    self.stop_status = Status.watch(self)
    self.page = nil
    self:build()
end

function Toc:row(index, item)
    local W, h = self.dimen.w, Kit.px(ROW_H)
    local pad = Kit.px(16)
    local number = self.show_pages and Kit.text(tostring(item.page), 15, { color = Blitbuffer.COLOR_DARK_GRAY }) or nil
    local number_w = number and number:getSize().w + Kit.px(12) or 0
    local indent = Kit.px(INDENT) * math.min((item.depth or 1) - 1, MAX_DEPTH)
    local box = Geom:new{ w = W, h = h }
    local content = OverlapGroup:new{
        dimen = box:copy(),
        allow_mirroring = false,
        LeftContainer:new{ dimen = box:copy(),
            HorizontalGroup:new{ align = "center",
                HorizontalSpan:new{ width = pad + indent },
                TextBoxWidget:new{
                    text = self.ui.toc:cleanUpTocTitle(item.title or "", true),
                    face = Kit.face(17),
                    bold = index == self.current,
                    width = W - 2 * pad - indent - number_w,
                    height = h - Kit.px(8),
                    height_adjust = true,
                    height_overflow_show_ellipsis = true,
                },
            },
        },
    }
    if number then
        content[2] = RightContainer:new{ dimen = box:copy(),
            HorizontalGroup:new{ align = "center", number, HorizontalSpan:new{ width = pad } },
        }
    end
    return Kit.Tappable:new{ callback = function() self:go(item) end, content }
end

function Toc:build()
    local W, H = self.dimen.w, self.dimen.h
    local bar_h = Kit.px(BAR_H)
    self.back = Kit.icon_button("chevron.left", bar_h, function() self:close() end,
        { edge = "left", margin = Kit.px(16), width = Kit.px(56) })
    local header = VerticalGroup:new{ align = "left",
        Status:new{ width = W },
        OverlapGroup:new{ dimen = Geom:new{ w = W, h = bar_h }, allow_mirroring = false,
            CenterContainer:new{ dimen = Geom:new{ w = W, h = bar_h },
                Kit.text("Оглавление", 20, { bold = true, max_width = W - 2 * Kit.px(64) }) },
            self.back,
        },
        Kit.line(W),
    }
    local header_h = header:getSize().h

    local row_h = Kit.px(ROW_H) + Kit.px(1)
    local room = H - header_h
    local per_page = math.max(1, math.floor(room / row_h))
    if #self.items > per_page then
        per_page = math.max(1, math.floor((room - Kit.px(PAGER_H)) / row_h))
    end
    self.pages = math.max(1, math.ceil(#self.items / per_page))
    -- It opens where the reader is.
    self.page = self.page or math.ceil((self.current or 1) / per_page)
    self.page = math.max(1, math.min(self.page, self.pages))

    local frame = OverlapGroup:new{ dimen = self.dimen:copy(), allow_mirroring = false,
        VerticalGroup:new{ align = "left", overlap_offset = { 0, 0 }, header },
    }
    self.rows = {}
    if #self.items == 0 then
        frame[2] = FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { 0, header_h },
            CenterContainer:new{ dimen = Geom:new{ w = W, h = room },
                Kit.text("В этой книге нет оглавления", 17, { color = Blitbuffer.COLOR_DARK_GRAY }) } }
    else
        local body = VerticalGroup:new{ align = "left" }
        for i = (self.page - 1) * per_page + 1, math.min(self.page * per_page, #self.items) do
            self.rows[i] = self:row(i, self.items[i])
            body[#body + 1] = self.rows[i]
            body[#body + 1] = LineWidget:new{ dimen = Geom:new{ w = W, h = Kit.px(1) },
                background = Blitbuffer.COLOR_LIGHT_GRAY }
        end
        frame[2] = FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { 0, header_h }, body }
    end
    self.pager_prev, self.pager_next = nil, nil
    if self.pages > 1 then
        local pager_h = Kit.px(PAGER_H)
        local pager
        pager, self.pager_prev, self.pager_next = Kit.pager(self.page, self.pages, W, pager_h, function(delta)
            self:turn(delta)
        end)
        frame[3] = FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { 0, H - pager_h }, pager }
    end
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, frame }
end

function Toc:turn(delta)
    local page = self.page + delta
    if page < 1 or page > self.pages then return end
    self.page = page
    self:build()
    UIManager:setDirty(self, "partial")
end

function Toc:onSwipe(_, ges)
    if ges.direction == "west" or ges.direction == "north" then self:turn(1)
    elseif ges.direction == "east" or ges.direction == "south" then self:turn(-1) end
    return true
end

function Toc:go(item)
    local ui = self.ui
    self:close()
    ui.link:addCurrentLocationToStack()
    if item.xpointer then
        ui:handleEvent(Event:new("GotoXPointer", item.xpointer, item.xpointer))
    else
        ui:handleEvent(Event:new("GotoPage", item.page))
    end
end

function Toc:onShow()
    UIManager:setDirty(self, "partial")
end

function Toc:close()
    UIManager:close(self, "partial")
end

function Toc:onCloseWidget()
    self.stop_status()
end

return Toc
