-- A book found in the catalogue, before it goes into the library: a stray tap in the search
-- results should not add anything.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Kit = require("yaknigi/kit")
local Library = require("yaknigi/library")
local Status = require("yaknigi/status")

local HEADER_H, TOP_H, BUTTON_H, NOTE_H = 60, 230, 60, 34

local BookCard = InputContainer:extend{
    name = "YaknigiBookCard",
    covers_fullscreen = true,
    item = nil,
    on_read = nil,
}

function BookCard:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local W, H = self.dimen.w, self.dimen.h
    local pad = Kit.px(16)
    local inner = W - 2 * pad
    local item = self.item
    local header_h = Status.height() + Kit.px(HEADER_H)
    self.stop_status = Status.watch(self)

    self.back_button = Kit.icon_button("chevron.left", Kit.px(HEADER_H), function() UIManager:close(self) end,
        { edge = "left", margin = pad, width = Kit.px(56) })
    local header = VerticalGroup:new{ align = "left", Status:new{ width = W }, self.back_button }

    local cover_h = Kit.px(TOP_H) - Kit.px(30)
    local cover_w = math.floor(cover_h * 2 / 3)
    local gap = Kit.px(18)
    local text_w = inner - cover_w - gap
    local lines = VerticalGroup:new{ align = "left",
        TextBoxWidget:new{
            text = item.title,
            face = Kit.face(24),
            bold = true,
            width = text_w,
            height = math.floor(Kit.face(24).size * 1.3 * 5),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        },
    }
    if item.authors ~= "" then
        lines[#lines + 1] = Kit.gap(Kit.px(6))
        lines[#lines + 1] = Kit.text(item.authors, 17, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = text_w })
    end
    local top = CenterContainer:new{
        dimen = Geom:new{ w = inner, h = Kit.px(TOP_H) },
        HorizontalGroup:new{ align = "center",
            Library.cover_box(item, cover_w, cover_h),
            HorizontalSpan:new{ width = gap },
            Kit.fixed(lines, text_w),
        },
    }

    local button_h = Kit.px(BUTTON_H)
    self.read_button = Kit.Tappable:new{
        callback = function() self.on_read() end,
        FrameContainer:new{
            background = Blitbuffer.COLOR_BLACK,
            bordersize = 0,
            padding = 0,
            radius = Kit.px(8),
            CenterContainer:new{
                dimen = Geom:new{ w = inner, h = button_h },
                Kit.text("Читать", 22, { bold = true, color = Blitbuffer.COLOR_WHITE }),
            },
        },
    }
    local note_h = Kit.px(NOTE_H)
    local foot = VerticalGroup:new{ align = "center",
        self.read_button,
        CenterContainer:new{
            dimen = Geom:new{ w = inner, h = note_h },
            Kit.text("Книга появится в вашей библиотеке", 15, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = inner }),
        },
    }

    local body_top = header_h + Kit.px(1)
    local foot_top = H - button_h - note_h - Kit.px(12)
    local frame = OverlapGroup:new{
        dimen = self.dimen:copy(),
        allow_mirroring = false,
        VerticalGroup:new{ align = "left", overlap_offset = { 0, 0 }, header, Kit.line(W) },
        FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { pad, body_top }, top },
        FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { pad, foot_top }, foot },
    }
    if item.annotation and item.annotation ~= "" then
        local annotation_top = body_top + Kit.px(TOP_H)
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { pad, annotation_top },
            TextBoxWidget:new{
                text = item.annotation,
                face = Kit.face(17),
                width = inner,
                height = foot_top - annotation_top - Kit.px(12),
                height_adjust = true,
                height_overflow_show_ellipsis = true,
            },
        }
    end
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, frame }
end

function BookCard:onShow()
    UIManager:setDirty(self, "partial")
end

function BookCard:onCloseWidget()
    self.stop_status()
    UIManager:setDirty(nil, "partial") -- the library is back, and the screen must show it
end

return BookCard
