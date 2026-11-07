-- The way in: what to do on the phone, step by step, with the QR code the first step needs.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = Device.screen

local Kit = require("yaknigi/kit")

local STEPS = {
    "Наведите камеру телефона на QR-код и откройте ссылку.",
    "Войдите в свой аккаунт Яндекса и разрешите доступ.",
    "На телефоне появится код из 16 символов. Если он не помещается, поверните телефон боком.",
    "Нажмите «Ввести код» и наберите его здесь.",
}

local Login = InputContainer:extend{
    name = "YaknigiLogin",
    covers_fullscreen = true,
    url = nil,
    on_enter = nil, -- the code is asked for
}

local function step(number, text, width)
    local mark = Kit.px(44)
    return HorizontalGroup:new{
        align = "top",
        CenterContainer:new{
            dimen = Geom:new{ w = mark, h = Kit.px(30) },
            Kit.text(tostring(number), 22, { bold = true }),
        },
        HorizontalSpan:new{ width = Kit.px(8) },
        TextBoxWidget:new{ text = text, face = Kit.face(21), width = width - mark - Kit.px(8) },
    }
end

function Login:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    local inner = W - 2 * Kit.px(40)
    local button_h = Kit.px(56)

    self.enter_button = Kit.Tappable:new{
        callback = self.on_enter,
        FrameContainer:new{
            background = Blitbuffer.COLOR_BLACK,
            bordersize = 0, padding = 0,
            radius = math.floor(button_h / 2),
            CenterContainer:new{
                dimen = Geom:new{ w = inner, h = button_h },
                Kit.text("Ввести код", 20, { bold = true, color = Blitbuffer.COLOR_WHITE }),
            },
        },
    }
    self.later_button = Kit.button(Kit.text("Не сейчас", 19), inner, button_h, function()
        UIManager:close(self)
    end)

    local center = function(widget)
        return CenterContainer:new{ dimen = Geom:new{ w = inner, h = widget:getSize().h }, widget }
    end
    local title = center(Kit.text("Вход в Яндекс", 26, { bold = true }))
    local steps = VerticalGroup:new{ align = "left" }
    for i, text in ipairs(STEPS) do
        steps[#steps + 1] = step(i, text, inner)
        steps[#steps + 1] = Kit.gap(Kit.px(12))
    end
    local gap = Kit.px(24)
    local taken = title:getSize().h + steps:getSize().h + 2 * gap + Kit.px(12)
        + self.enter_button:getSize().h + self.later_button:getSize().h + 2 * gap
    -- The code takes what the words leave, so nothing is cut off on a small screen.
    local side = math.min(math.floor(math.min(W, H) * 0.52), H - taken)

    local group = VerticalGroup:new{ align = "left" }
    local function add(widget) group[#group + 1] = widget end
    add(title)
    add(Kit.gap(gap))
    add(center(QRWidget:new{ text = self.url, width = side, height = side }))
    add(Kit.gap(gap))
    add(steps)
    add(Kit.gap(Kit.px(12)))
    add(self.enter_button)
    add(self.later_button)

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = 0,
        CenterContainer:new{ dimen = Geom:new{ w = W, h = H }, group },
    }
end

return Login
