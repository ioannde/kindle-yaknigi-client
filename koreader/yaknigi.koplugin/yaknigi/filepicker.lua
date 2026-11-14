-- A book of one's own to send to Yandex Books, picked from the device's folders: the folders that
-- have books in them, then the books of this one, the newest first. A tap on a book sends it; it
-- says on its row that it is going and then that it went.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
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
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Device = require("device")
local Screen = Device.screen

local Kit = require("yaknigi/kit")
local Status = require("yaknigi/status")
local Upload = require("yaknigi/upload")

local BAR_H, PATH_H, FOLDER_H, FILE_H, PAGER_H = 56, 40, 68, 84, 56

local FilePicker = InputContainer:extend{
    name = "YaknigiFilePicker",
    covers_fullscreen = true,
    root = nil, -- the folder it starts in and goes no higher than
    root_name = nil, -- what the root is called in the path line
    avoid = nil, -- folders not to look into
    on_pick = nil, -- function(path)
    state = nil, -- function(path): "sending", "sent" or nil
}

function FilePicker:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.avoid = self.avoid or {}
    self.root_name = self.root_name or Upload.file_name(self.root)
    self.pages_of = {} -- the page each folder was left on, to come back up to it
    self:go(self.root)
    self.stop_status = Status.watch(self)
end

function FilePicker:go(dir, page)
    self.dir = dir
    self.listing = Upload.list(dir, self.avoid)
    self.page = page or 1
    self:build()
end

local function row_line(width)
    return LineWidget:new{ dimen = Geom:new{ w = width, h = Kit.px(1) }, background = Blitbuffer.COLOR_LIGHT_GRAY }
end

local function gray(text, size, width)
    return Kit.text(text, size, { color = Blitbuffer.COLOR_DARK_GRAY, max_width = width })
end

--- The parts of the path below the root, for the path line and the title.
function FilePicker:parts()
    local parts = { self.root_name }
    local rest = self.dir:sub(#self.root + 2)
    for part in rest:gmatch("[^/]+") do parts[#parts + 1] = part end
    return parts
end

--- A row: an icon, a name with a line under it, something at the right, the whole to tap.
function FilePicker:row(height, icon, texts, right, callback, right_room)
    local W, pad = self.dimen.w, Kit.px(16)
    local box = Geom:new{ w = W, h = height }
    local content = OverlapGroup:new{ dimen = box:copy(), allow_mirroring = false,
        LeftContainer:new{ dimen = box:copy(),
            HorizontalGroup:new{ align = "center",
                HorizontalSpan:new{ width = pad },
                Kit.icon(icon, Kit.px(28)),
                HorizontalSpan:new{ width = Kit.px(14) },
                texts,
            },
        },
    }
    if right then
        content[2] = RightContainer:new{ dimen = box:copy(),
            HorizontalGroup:new{ align = "center", right, HorizontalSpan:new{ width = pad - (right_room or 0) } } }
    end
    local widget = Kit.Tappable:new{ callback = callback, content }
    return widget, VerticalGroup:new{ align = "left", widget, row_line(W) }
end

function FilePicker:listRows()
    local W, pad = self.dimen.w, Kit.px(16)
    local text_x = pad + Kit.px(28) + Kit.px(14)
    local list = {}
    self.rows_by_key = {}
    if self.dir ~= self.root then
        local parent = self.dir:match("^(.+)/[^/]+$")
        local parent_name = parent == self.root and self.root_name or Upload.file_name(parent)
        local texts = VerticalGroup:new{ align = "left",
            Kit.text("Наверх, в " .. parent_name, 17, { max_width = W - text_x - pad }),
            Kit.gap(Kit.px(4)),
            gray("Папка выше", 13),
        }
        local widget, row = self:row(Kit.px(FOLDER_H), "chevron.left", texts, nil, function() self:up() end)
        self.rows_by_key.up = widget
        list[#list + 1] = row
    end
    for _, folder in ipairs(self.listing.folders) do
        local right, right_room = Kit.value_and_chevron(nil)
        local text_w = W - text_x - pad - right:getSize().w - Kit.px(12)
        local texts = VerticalGroup:new{ align = "left",
            Kit.text(folder.name, 17, { max_width = text_w }),
            Kit.gap(Kit.px(4)),
            gray("Папка · " .. folder.count .. " " .. Upload.books_word(folder.count), 13, text_w),
        }
        local widget, row = self:row(Kit.px(FOLDER_H), "folder", texts, right, function()
            self.pages_of[self.dir] = self.page
            self:go(folder.path)
            UIManager:setDirty(self, "ui")
        end, right_room)
        self.rows_by_key["dir:" .. folder.path] = widget
        list[#list + 1] = row
    end
    local now = os.time()
    for _, file in ipairs(self.listing.files) do
        local state = self.state and self.state(file.path)
        local right
        if state == "sending" then
            right = HorizontalGroup:new{ align = "center", Kit.icon("wait", Kit.px(22), { dim = true }),
                HorizontalSpan:new{ width = Kit.px(6) }, gray("Загружаю…", 14) }
        elseif state == "sent" then
            right = HorizontalGroup:new{ align = "center", Kit.icon("check", Kit.px(22)),
                HorizontalSpan:new{ width = Kit.px(6) }, Kit.text("Загружена", 14) }
        end
        local right_w = right and right:getSize().w + Kit.px(12) or 0
        local text_w = W - text_x - pad - right_w
        local meta = Upload.kind(file.name):upper() .. " · " .. Upload.size_text(file.size or 0)
            .. " · " .. Upload.date_text(file.time, now)
        local name = require("ui/widget/textboxwidget"):new{
            text = file.name, face = Kit.face(17), width = text_w, height_adjust = true,
            height = Kit.px(2 * 24), height_overflow_show_ellipsis = true,
        }
        local texts = VerticalGroup:new{ align = "left", name, Kit.gap(Kit.px(4)), gray(meta, 13, text_w) }
        local h = math.max(Kit.px(FILE_H), texts:getSize().h + 2 * Kit.px(10))
        local widget, row = self:row(h, "book", texts, right, function()
            if not state and self.on_pick then self.on_pick(file.path) end
        end)
        self.rows_by_key["file:" .. file.path] = widget
        list[#list + 1] = row
    end
    if #list == 0 then
        local box = Geom:new{ w = W, h = Kit.px(120) }
        list[1] = CenterContainer:new{ dimen = box, gray("Здесь нет книг EPUB или FB2", 16, W - 2 * pad) }
    end
    return list
end

local function paginate(rows, height)
    local pages, page, used = {}, {}, 0
    for _, row in ipairs(rows) do
        local h = row:getSize().h
        if used + h > height and #page > 0 then
            pages[#pages + 1] = page
            page, used = {}, 0
        end
        page[#page + 1] = row
        used = used + h
    end
    pages[#pages + 1] = page
    return pages
end

function FilePicker:build()
    local W, pad = self.dimen.w, Kit.px(16)
    local bar_h = Kit.px(BAR_H)
    local parts = self:parts()
    local title = #parts == 1 and "Загрузить книгу" or parts[#parts]
    self.back = Kit.icon_button("chevron.left", bar_h, function()
        if self.dir == self.root then self:close() else self:up() end
    end, { edge = "left", margin = pad, width = Kit.px(56) })
    local path_line = HorizontalGroup:new{ align = "center" }
    if #parts > 1 then
        path_line[1] = gray(table.concat(parts, " / ", 1, #parts - 1) .. " / ", 15)
    end
    path_line[#path_line + 1] = Kit.text(parts[#parts], 15, { bold = true, color = Blitbuffer.COLOR_DARK_GRAY })
    local path_w = path_line:getSize().w
    if path_w > W - 2 * pad then
        -- Too long a way down: the end of it is what matters.
        path_line = HorizontalGroup:new{ align = "center",
            gray("… / ", 15),
            Kit.text(parts[#parts], 15, { bold = true, color = Blitbuffer.COLOR_DARK_GRAY,
                max_width = W - 2 * pad - Kit.px(40) }) }
    end
    local header = VerticalGroup:new{ align = "left",
        Status:new{ width = W },
        OverlapGroup:new{ dimen = Geom:new{ w = W, h = bar_h }, allow_mirroring = false,
            CenterContainer:new{ dimen = Geom:new{ w = W, h = bar_h },
                Kit.text(title, 20, { bold = true, max_width = W - 2 * Kit.px(64) }) },
            self.back,
        },
        LeftContainer:new{ dimen = Geom:new{ w = W, h = Kit.px(PATH_H) },
            HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = pad }, path_line } },
        Kit.line(W),
    }
    local header_h = header:getSize().h
    local rows = self:listRows()
    local room = self.dimen.h - header_h
    local pages = paginate(rows, room)
    if #pages > 1 then pages = paginate(rows, room - Kit.px(PAGER_H)) end
    self.pages = #pages
    self.page = math.max(1, math.min(self.page, self.pages))
    local body = VerticalGroup:new{ align = "left" }
    for _, row in ipairs(pages[self.page]) do body[#body + 1] = row end
    -- Only what is on this page can be tapped by the tests.
    self.rows = {}
    for key, widget in pairs(self.rows_by_key) do
        for _, row in ipairs(pages[self.page]) do
            if row[1] == widget then self.rows[key] = widget end
        end
    end

    local frame = OverlapGroup:new{ dimen = self.dimen:copy(), allow_mirroring = false,
        VerticalGroup:new{ align = "left", overlap_offset = { 0, 0 }, header },
        FrameContainer:new{ bordersize = 0, padding = 0, overlap_offset = { 0, header_h }, body },
    }
    self.pager_prev, self.pager_next = nil, nil
    if self.pages > 1 then
        local pager_h = Kit.px(PAGER_H)
        local pager
        pager, self.pager_prev, self.pager_next = Kit.pager(self.page, self.pages, W, pager_h, function(delta)
            self:turn(delta)
        end)
        frame[#frame + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
            overlap_offset = { 0, self.dimen.h - pager_h }, pager }
    end
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = 0, padding = 0, frame }
end

function FilePicker:up()
    if self.dir == self.root then return end
    local parent = self.dir:match("^(.+)/[^/]+$")
    self:go(parent, self.pages_of[parent])
    UIManager:setDirty(self, "ui")
end

function FilePicker:turn(delta)
    local page = self.page + delta
    if page < 1 or page > self.pages then return end
    self.page = page
    self:build()
    UIManager:setDirty(self, "partial")
end

--- A book's state changed, or a new one came: the list is read again, on the same page.
function FilePicker:refresh()
    if self.gone then return end
    self:go(self.dir, self.page)
    UIManager:setDirty(self, "ui")
end

function FilePicker:onSwipe(_, ges)
    if ges.direction == "west" or ges.direction == "north" then self:turn(1)
    elseif ges.direction == "east" then self:turn(-1) end
    return true
end

function FilePicker:onShow()
    UIManager:setDirty(self, "partial")
end

function FilePicker:close()
    UIManager:close(self, "partial")
end

function FilePicker:onCloseWidget()
    self.gone = true
    self.stop_status()
end

return FilePicker
