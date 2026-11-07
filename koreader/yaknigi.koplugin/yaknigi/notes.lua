-- Bookmarks and highlights of the open book: a plain list with a clear way back.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local Screen = Device.screen

local Kit = require("yaknigi/kit")

local Notes = InputContainer:extend{
    name = "YaknigiNotes",
    covers_fullscreen = true,
    ui = nil,
    shell = nil,
    page = 1,
}

function Notes:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.ui.annotation:updatePageNumbers(true)
    self:build()
end

function Notes:row(item, width, height)
    local side = Kit.px(56)
    local text_w = width - side - Kit.px(8)
    local grey = Blitbuffer.COLOR_DARK_GRAY
    local face = Kit.face(17)
    local lines = VerticalGroup:new{ align = "left",
        TextBoxWidget:new{
            text = item.drawer and (item.text or "") or "Закладка",
            face = face,
            bold = not item.drawer,
            width = text_w,
            height = math.floor(face.size * 1.3 * 2),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        },
    }
    if item.note and item.note ~= "" then
        lines[#lines + 1] = Kit.text(item.note, 15, { max_width = text_w })
    end
    local where = {}
    if item.chapter and item.chapter ~= "" then where[1] = item.chapter end
    -- A skeleton's page numbers say nothing about the book.
    if item.pageno and not self.shell:hasStubs() then where[#where + 1] = "стр. " .. item.pageno end
    lines[#lines + 1] = Kit.text(table.concat(where, " · "), 14, { color = grey, max_width = text_w })
    local tap = Kit.Tappable:new{
        callback = function() self:open(item) end,
        CenterContainer:new{
            dimen = Geom:new{ w = text_w, h = height },
            Kit.fixed(lines, text_w),
        },
    }
    local remove = Kit.icon_button("close", side, function() self:askRemove(item) end)
    return HorizontalGroup:new{ align = "center", tap, HorizontalSpan:new{ width = Kit.px(8) }, remove },
        tap, remove
end

function Notes:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = Kit.px(16)
    local inner = W - 2 * pad
    local side = Kit.px(56)
    local header_h, footer_h, row_h = Kit.px(60), Kit.px(56), Kit.px(112)
    local items = self.ui.annotation.annotations or {}
    local per_page = math.floor((H - header_h - footer_h - Kit.px(2)) / row_h)
    local pages = math.max(1, math.ceil(#items / per_page))
    self.page = math.max(1, math.min(self.page, pages))
    self.pages = pages

    self.back = Kit.icon_button("chevron.left", side, function() self:close() end, { edge = "left", margin = pad })
    local header = HorizontalGroup:new{ align = "center",
        self.back,
        CenterContainer:new{
            dimen = Geom:new{ w = W - 2 * side, h = header_h },
            Kit.text("Заметки", 20, { bold = true }),
        },
    }

    local body = VerticalGroup:new{ align = "left" }
    self.opens, self.removes = {}, {}
    if #items == 0 then
        body[1] = CenterContainer:new{
            dimen = Geom:new{ w = inner, h = H - header_h - footer_h - Kit.px(2) },
            Kit.text("Здесь будут закладки и выделенный текст", 18, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = inner }),
        }
    end
    local first = (self.page - 1) * per_page + 1
    for i = first, math.min(#items, first + per_page - 1) do
        local row, tap, remove = self:row(items[i], inner, row_h)
        self.opens[#self.opens + 1] = tap
        self.removes[#self.removes + 1] = remove
        body[#body + 1] = row
        body[#body + 1] = Kit.line(inner)
    end

    local frame = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        VerticalGroup:new{ align = "left", overlap_offset = { 0, 0 }, header, Kit.line(W) },
        FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { pad, header_h + Kit.px(1) }, body },
    }
    self.prev_button, self.next_button = nil, nil
    if pages > 1 then
        local pager
        pager, self.prev_button, self.next_button = Kit.pager(self.page, pages, inner, footer_h,
            function(delta) self:turn(delta) end)
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
            overlap_offset = { pad, H - footer_h }, pager }
    end
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, frame }
end

function Notes:turn(delta)
    local page = self.page + delta
    if page < 1 or page > self.pages then return end
    self.page = page
    logger.info("yaknigi: notes page", page, "of", self.pages)
    self:build()
    UIManager:setDirty(self, "partial")
end

function Notes:onSwipe(_, ges)
    if ges.direction == "west" then self:turn(1)
    elseif ges.direction == "east" then self:turn(-1)
    elseif ges.direction == "south" then self:close() end
    return true
end

function Notes:onShow()
    logger.info("yaknigi: notes open")
    UIManager:setDirty(self, "ui")
end

function Notes:close()
    logger.info("yaknigi: notes closed")
    UIManager:close(self, "ui")
end

function Notes:open(item)
    local ui = self.ui
    self:close()
    UIManager:nextTick(function()
        ui.link:addCurrentLocationToStack()
        ui.bookmark:gotoBookmark(item.page, item.pos0)
    end)
end

function Notes:askRemove(item)
    UIManager:show(ConfirmBox:new{
        text = item.drawer and "Удалить выделение?" or "Удалить закладку?",
        ok_text = "Удалить",
        cancel_text = "Отмена",
        ok_callback = function() self:remove(item) end,
    })
end

function Notes:remove(item)
    self.ui.bookmark:removeItem(item)
    -- A bookmark taken away here makes no event of its own.
    self.ui:handleEvent(require("ui/event"):new("YaknigiNotesChanged"))
    logger.info("yaknigi: note removed")
    self:build()
    UIManager:setDirty(self, "ui")
end

return Notes
