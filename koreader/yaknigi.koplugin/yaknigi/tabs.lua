-- The bar at the bottom of the screens outside the book.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")

local Kit = require("yaknigi/kit")

local Tabs = {}


local ALL = {
    { id = "library", caption = "Библиотека", icon = "tab.library" },
    { id = "feed", caption = "Яндекс Книги", icon = "yandex-books" },
    { id = "search", caption = "Поиск", icon = "tab.search" },
    { id = "settings", caption = "Настройки", icon = "tab.settings" },
}

function Tabs.height()
    return Kit.px(64) + Kit.px(1)
end

--- Returns the bar and its cells by id. on_select gets the id of the tab tapped.
function Tabs.bar(width, selected, on_select)
    local cell_w = math.floor(width / #ALL)
    local side = Kit.px(30)
    local row = HorizontalGroup:new{ align = "center" }
    local cells = {}
    for i, tab in ipairs(ALL) do
        local on = tab.id == selected
        local content = VerticalGroup:new{ align = "center",
            -- The .idle drawings are in the colour of the idle captions, COLOR_DARK_GRAY.
            Kit.icon(tab.icon .. (on and "" or ".idle"), side),
            Kit.gap(Kit.px(3)),
            Kit.text(tab.caption, 13, {
                bold = on,
                color = not on and Blitbuffer.COLOR_DARK_GRAY or nil,
                max_width = cell_w - Kit.px(4),
            }),
        }
        local w = i == #ALL and width - cell_w * (#ALL - 1) or cell_w
        cells[tab.id] = Kit.Tappable:new{
            callback = function() on_select(tab.id) end,
            CenterContainer:new{ dimen = Geom:new{ w = w, h = Kit.px(64) }, content },
        }
        row[i] = cells[tab.id]
    end
    return VerticalGroup:new{ align = "left", Kit.line(width), row }, cells
end

return Tabs
