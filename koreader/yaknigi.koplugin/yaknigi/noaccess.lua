-- Said when Yandex refuses to open a book: what is known of why, and what can be done.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Kit = require("yaknigi/kit")

local NoAccess = InputContainer:extend{
    name = "YaknigiNoAccess",
    covers_fullscreen = true,
    verdict = "unknown", -- as in yaknigi/access
    book_title = nil,
}

local TEXTS = {
    none = {
        title = "Нет активной подписки",
        text = "Яндекс Книги не дают открыть эту книгу. На аккаунте сейчас нет активной подписки, скорее всего дело в этом.\n\n"
            .. "Оформить её можно в приложении Яндекс Книг на телефоне, на Kindle нельзя. После этого попробуйте открыть книгу снова.",
    },
    active = {
        title = "Книга недоступна",
        text = "Яндекс Книги не дают открыть эту книгу, хотя подписка активна.\n\n"
            .. "Обычно это значит, что книга не входит в вашу подписку или недоступна в вашей стране.",
    },
    unknown = {
        title = "Книга недоступна",
        text = "Яндекс Книги не дают открыть эту книгу. Скорее всего, она не входит в подписку или подписка закончилась.\n\n"
            .. "Проверить это можно в приложении Яндекс Книг на телефоне.",
    },
}

function NoAccess:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    local inner = W - 2 * Kit.px(32)
    local words = TEXTS[self.verdict] or TEXTS.unknown
    self.close_button = Kit.pill("Понятно", inner, Kit.px(56), function() UIManager:close(self) end)

    local group = VerticalGroup:new{ align = "center" }
    group[#group + 1] = CenterContainer:new{
        dimen = Geom:new{ w = inner, h = Kit.px(84) },
        Kit.text(words.title, 24, { bold = true, max_width = inner }),
    }
    if self.book_title and self.book_title ~= "" then
        group[#group + 1] = TextBoxWidget:new{
            text = "«" .. self.book_title .. "»",
            face = Kit.face(19),
            bold = true,
            width = inner,
            alignment = "center",
        }
        group[#group + 1] = Kit.gap(Kit.px(16))
    end
    group[#group + 1] = TextBoxWidget:new{
        text = words.text,
        face = Kit.face(19),
        width = inner,
        alignment = "center",
    }
    group[#group + 1] = Kit.gap(Kit.px(32))
    group[#group + 1] = self.close_button
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0,
        CenterContainer:new{ dimen = Geom:new{ w = W, h = H }, group },
    }
end

function NoAccess:onShow()
    UIManager:setDirty(self, "full")
end

return NoAccess
