-- The panels over the text, shown on a tap in the middle of the page: a bar with the
-- book and a way back at the top, the chapter and progress with actions at the bottom.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local Screen = Device.screen

local Kit = require("yaknigi/kit")
local Notes = require("yaknigi/notes")
local Settings = require("yaknigi/settings")
local TextPanel = require("yaknigi/textpanel")

local Chrome = InputContainer:extend{
    name = "YaknigiChrome",
    ui = nil,
    shell = nil,
}

function Chrome:init()
    local full = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.dimen = full
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = full } },
        SwipeOutside = { GestureRange:new{ ges = "swipe", range = full } },
    }
    self:build()
end

function Chrome:build()
    local W = Screen:getWidth()
    local pad = Kit.px(16)
    local inner = W - 2 * pad
    local ui = self.ui
    local doc = ui.document
    local props = doc:getProps() or {}

    -- Top bar: back to the library, what is being read, more.
    local side = Kit.px(56)
    local icon_w = Kit.px(44) -- the drawings stand at the panel's edges, the title close to them
    local title_width = inner - 2 * icon_w - Kit.px(16)
    local names = VerticalGroup:new{ align = "left",
        Kit.text(props.title or "", 18, { bold = true, max_width = title_width }),
    }
    if props.authors and props.authors ~= "" then
        names[2] = Kit.text(props.authors:gsub("\n", ", "), 15, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = title_width })
    end
    self.back = Kit.icon_button("chevron.left", side, function() self:goBack() end, { edge = "left", width = icon_w })
    self.more = Kit.icon_button("appbar.menu", side, function() self:showMore() end, { edge = "right", width = icon_w })
    self.top_panel = Kit.panel(W, VerticalGroup:new{ align = "left",
        HorizontalGroup:new{ align = "center",
            self.back,
            HorizontalSpan:new{ width = Kit.px(8) },
            Kit.fixed(names, title_width),
            HorizontalSpan:new{ width = Kit.px(8) },
            self.more,
        },
    }, pad)

    -- Bottom panel.
    local page = doc:getCurrentPage()
    local chapter = ui.toc:getTocTitleByPage(page)
    local stubs = self.shell:hasStubs()
    local left = not stubs and ui.toc:getChapterPagesLeft(page)
    local tail = left and ("ещё " .. left .. " стр.") or ""
    local tail_widget = Kit.text(tail, 15, { color = Blitbuffer.COLOR_DARK_GRAY })
    local icon_side = Kit.px(30)
    local toc_icon = IconWidget:new{ icon = "appbar.navigation", width = icon_side, height = icon_side }
    local chapter_width = inner - icon_side - Kit.px(12) - tail_widget:getSize().w - Kit.px(12)
    self.chapter_row = Kit.Tappable:new{
        callback = function() self:after(function() ui.toc:onShowToc() end) end,
        HorizontalGroup:new{ align = "center",
            toc_icon,
            HorizontalSpan:new{ width = Kit.px(12) },
            Kit.fixed(Kit.text(chapter ~= "" and chapter or "Без названия", 17, { max_width = chapter_width }), chapter_width),
            HorizontalSpan:new{ width = Kit.px(12) },
            tail_widget,
        },
    }
    local ratio = self.shell:progress()
    self.slider = Kit.Slider:new{
        width = inner,
        ratio = ratio,
        show_dirty = self,
        on_commit = function(r) self:jump(r) end,
    }
    local cell = math.floor(inner / 4)
    local icon = Kit.px(36)
    local bookmarked = ui.bookmark:isPageBookmarked()
    self.notes_button = Kit.action(IconWidget:new{ icon = "bookmark", width = icon, height = icon }, "Заметки", cell,
        function() self:after(function() UIManager:show(Notes:new{ ui = ui, shell = self.shell }) end) end)
    self.bookmark_button = Kit.action(IconWidget:new{ icon = bookmarked and "star.full" or "star.empty", width = icon, height = icon },
        bookmarked and "В закладках" or "Закладка", cell, function() self:toggleBookmark() end)
    self.search_button = Kit.action(IconWidget:new{ icon = "appbar.search", width = icon, height = icon }, "Поиск", cell,
        function() self:after(function() ui.search:onShowFulltextSearchInput() end) end)
    self.text_button = Kit.action(Kit.text("Aa", 26, { bold = true }), "Текст", cell,
        function() self:after(function() UIManager:show(TextPanel:new{ ui = ui, shell = self.shell }) end) end)

    self.bottom_panel = Kit.panel(W, VerticalGroup:new{ align = "center",
        self.chapter_row,
        self.slider,
        Kit.text(self.shell:progressText(true), 15, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = inner }),
        Kit.gap(Kit.px(8)),
        HorizontalGroup:new{ align = "center",
            self.notes_button, self.bookmark_button, self.search_button, self.text_button,
        },
    }, pad)

    local top_h = self.top_panel:getSize().h
    local bottom_h = self.bottom_panel:getSize().h
    local Hh = Screen:getHeight()
    self.top_area = Geom:new{ x = 0, y = 0, w = W, h = top_h + Kit.px(1) }
    self.bottom_area = Geom:new{ x = 0, y = Hh - bottom_h - Kit.px(1), w = W, h = bottom_h + Kit.px(1) }
    local top = VerticalGroup:new{ align = "left", self.top_panel, Kit.line(W), overlap_offset = { 0, 0 } }
    local bottom = VerticalGroup:new{ align = "left", Kit.line(W), self.bottom_panel, overlap_offset = { 0, self.bottom_area.y } }
    self[1] = OverlapGroup:new{ dimen = self.dimen:copy(), allow_mirroring = false, top, bottom }
end

function Chrome:paintDirty()
    UIManager:setDirty(self, "ui", self.top_area)
    UIManager:setDirty(self, "ui", self.bottom_area)
end

function Chrome:rebuild()
    self:build()
    self:paintDirty()
end

function Chrome:onShow()
    self:paintDirty()
end

function Chrome:dismiss()
    UIManager:close(self, "ui", self.top_area:combine(self.bottom_area))
end

--- Closes the panels, then runs what would otherwise open on top of them.
function Chrome:after(action)
    self:dismiss()
    UIManager:nextTick(action)
end

function Chrome:goBack()
    logger.info("yaknigi: back to the library")
    self:dismiss()
    UIManager:nextTick(function() self.ui:onHome() end)
end

function Chrome:jump(ratio)
    self.shell:gotoRatio(ratio)
    self:rebuild()
end

function Chrome:toggleBookmark()
    self.ui.bookmark:onToggleBookmark()
    self:rebuild()
end

function Chrome:showMore()
    local ui = self.ui
    local dialog
    local function item(text, action)
        return { {
            text = text,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                self:after(action)
            end,
        } }
    end
    dialog = ButtonDialog:new{
        buttons = {
            item("Оглавление", function() ui.toc:onShowToc() end),
            item("Перейти на страницу", function() ui.gotopage:onShowGotoDialog() end),
            item("Настройки", function() UIManager:show(Settings:new{ ui = ui }) end),
            item("Настройки KOReader", function() ui.menu:onShowMenu() end),
        },
    }
    UIManager:show(dialog)
end

function Chrome:onTapOutside(_, ges)
    if ges.pos:intersectWith(self.top_area) or ges.pos:intersectWith(self.bottom_area) then
        return true
    end
    self:dismiss()
    return true
end

function Chrome:onSwipeOutside()
    self:dismiss()
    return true
end

return Chrome
