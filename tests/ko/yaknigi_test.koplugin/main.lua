-- Drives the real KOReader UI through the plugin against the mock server, in CI.
-- Writes screenshots and timings to YAKNIGI_TEST_OUT and "PASS" there at the end;
-- any failure exits at once with a non-zero code.
local Event = require("ui/event")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local socket = require("socket")

local OUT = os.getenv("YAKNIGI_TEST_OUT")
local started = false

local Driver = WidgetContainer:extend{ name = "yaknigi_test", is_doc_only = false }

local function say(...)
    print("[driver]", ...)
    io.stdout:flush()
end

local function fail(text)
    say("FAIL:", text)
    if OUT then pcall(function() Screen:shot(OUT .. "/failure.png") end) end
    os.exit(1)
end

local function shot(name)
    UIManager:forceRePaint()
    Screen:shot(OUT .. "/" .. name .. ".png")
end

local function top() return UIManager:getTopmostVisibleWidget() or {} end

local function reader()
    return require("apps/reader/readerui").instance
end

-- Runs in a coroutine; lets the UI loop run until cond() is true.
local function wait(what, cond, seconds)
    local co = coroutine.running()
    local deadline = socket.gettime() + (seconds or 30)
    local function check()
        local ok, value = pcall(cond)
        if not ok then fail(what .. ": " .. tostring(value)) end
        if value then
            coroutine.resume(co, value)
        elseif socket.gettime() > deadline then
            fail("timed out waiting for " .. what)
        else
            UIManager:scheduleIn(0.05, check)
        end
    end
    UIManager:nextTick(check)
    return coroutine.yield()
end

local function fragment()
    local xp = reader().document:getXPointer()
    return tonumber(xp:match("DocFragment%[(%d+)%]")), xp
end

local function page_text()
    local doc = reader().document
    local text = doc:getTextFromXPointer(doc:getXPointer()) or ""
    return text
end

local function library_with(count)
    return wait("library with " .. count .. " books", function()
        local w = top()
        return w.item_table and #w.item_table == count and w
    end)
end

local function tap_at(x, y)
    UIManager:forceRePaint() -- a finger only ever taps what is on the screen
    UIManager:sendEvent(Event:new("Gesture", {
        ges = "tap",
        pos = Geom:new{ x = x, y = y, w = 0, h = 0 },
        time = require("ui/time").now(),
    }))
end

local function tap_widget(widget)
    UIManager:forceRePaint() -- a widget learns its place when painted
    local d = widget.dimen
    tap_at(d.x + math.floor(d.w / 2), d.y + math.floor(d.h / 2))
    UIManager:forceRePaint()
end

--- Any gesture, with what the detector would give it.
local function gesture(name, x, y, extra)
    UIManager:forceRePaint()
    local ges = {
        ges = name,
        pos = Geom:new{ x = x, y = y, w = 0, h = 0 },
        time = require("ui/time").now(),
    }
    for key, point in pairs(extra or {}) do
        ges[key] = Geom:new{ x = point[1], y = point[2], w = 0, h = 0 }
    end
    UIManager:sendEvent(Event:new("Gesture", ges))
    UIManager:forceRePaint()
end

local function near(got, want, what)
    if math.abs(got - want) > 0.03 then fail(what .. ": " .. tostring(got) .. ", wanted " .. tostring(want)) end
end

local function is_named(name) return function() return top().name == name end end

local function find_item(menu, needle)
    for _, item in ipairs(menu.item_table) do
        if item.text:find(needle, 1, true) then return item end
    end
    fail("no book " .. needle)
end

-- The question about a position from another device, once it is up.
local function asked()
    return wait("the question about the other device", function()
        local w = top()
        return w.ok_text == "Перейти" and w
    end, 15)
end

local function answer(box, go)
    local callback = go and box.ok_callback or box.cancel_callback
    callback()
    UIManager:close(box)
end

local function open(menu, needle)
    local t0 = socket.gettime()
    menu:onMenuSelect(find_item(menu, needle))
    wait("the reader", function()
        return reader() and reader().document and top().name == "ReaderUI"
    end)
    return socket.gettime() - t0
end

-- The reading screen, driven by taps at the place a finger would touch.
local function mock_get(path)
    local http = require("socket.http")
    local body, code = http.request(os.getenv("YB_OAUTH_BASE") .. path)
    if code ~= 200 then fail("mock server: " .. tostring(code) .. " for " .. path) end
    return body ~= "" and require("rapidjson").decode(body) or nil
end

local function url_encode(s)
    return (s:gsub("[^%w%-_%.~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

local function plain(text)
    return (text:gsub("%s+", " "):gsub("^ ", ""))
end

-- Every position sent must point at the very words the page starts with, as a phone reads
-- them. The server works that out on its own, from the chapter's source.
local function test_positions_match_the_text()
    local doc = reader().document
    local plugin = reader().yaknigi
    local kinds = {}
    for _ = 1, 60 do
        reader().rolling:onGotoViewRel(1)
        UIManager:forceRePaint()
        local xp = doc:getXPointer()
        local next_xp = doc:getPageXPointer(doc:getCurrentPage() + 1)
        local start = plugin:positionOf(xp)
        if not start then fail("no position for " .. xp) end
        local words = plain(doc:getTextFromXPointers(xp, next_xp) or ""):sub(1, 40)
        local answer = mock_get("/test/text_at?cfi=" .. url_encode(start))
        local there = answer.text and plain(answer.text) or "(nothing)"
        -- Cut at a whole letter: the two sides are compared in bytes.
        local prefix = words:sub(1, 30):gsub("[\128-\255]+$", "")
        if prefix ~= "" and there:sub(1, #prefix) ~= prefix then
            fail(("position %s from %s points elsewhere: page starts %q, position has %q")
                :format(start, xp, words, there:sub(1, 40)))
        end
        kinds[start:match("/(%d+):%d+$")] = true
    end
    if not (kinds["1"] and (kinds["3"] or kinds["5"]) ) then
        fail("the pages tried did not start in different text nodes")
    end
    say("positions match the text")
end

local function test_position_upload()
    local BOOK = "book0"
    local dir = reader().yaknigi.store.dir
    local doc = reader().document
    local function position() return mock_get("/test/position?book=" .. BOOK) end
    local function moment()
        local t0 = socket.gettime()
        wait("a moment", function() return socket.gettime() - t0 > 2 end)
    end
    local function waiting()
        local f = io.open(dir .. "/to_send")
        if f then f:close() end
        return f ~= nil
    end

    -- Opening a book and leaving it again says nothing new.
    reader():onHome()
    local menu = library_with(21)
    wait("the position after paging through", function() return position().writes ~= nil and not waiting() end, 15)
    moment()
    local sent = position()
    open(menu, "Книга номер 0")
    local expected_page = reader().document:getCurrentPage()
    reader():onHome()
    menu = library_with(21)
    moment()
    if position().writes ~= sent.writes then fail("an unread book was sent again") end

    -- Reading goes up as soon as the book is left.
    open(menu, "Книга номер 0")
    doc = reader().document
    if doc:getCurrentPage() ~= expected_page then
        fail("its own position taken for reading on the phone: page " .. doc:getCurrentPage() .. ", was " .. expected_page)
    end
    reader().rolling:onGotoViewRel(5)
    UIManager:forceRePaint()
    local read_to = doc:getCurrentPage()
    local want = reader().yaknigi:positionOf(doc:getXPointer())
    reader():onHome()
    -- Two requests, one after the other: the position, then the library card.
    local want_cfi = require("yaknigi/cfi").point_range(want)
    wait("the position on the server", function() return position().start == want end, 15)
    wait("the position on the card", function() return position().sent_cfi == want_cfi end, 15)
    sent = position()
    if sent.state ~= "reading" then fail("state " .. tostring(sent.state)) end
    if sent.progress < 1 then fail("progress " .. tostring(sent.progress)) end
    wait("nothing left to send", function() return not waiting() end, 15)
    menu = library_with(21)

    -- And it is not taken for a move on the phone, with the list before or after the upload.
    open(menu, "Книга номер 0")
    if reader().document:getCurrentPage() ~= read_to then
        fail("its own upload moved the book: page " .. reader().document:getCurrentPage() .. ", was " .. read_to)
    end

    -- No network: the position waits, and goes with the next refresh.
    mock_get("/test/fail_writes?n=1")
    reader().rolling:onGotoViewRel(5)
    UIManager:forceRePaint()
    want = reader().yaknigi:positionOf(reader().document:getXPointer())
    read_to = reader().document:getCurrentPage()
    reader():onHome()
    wait("the position sent after the failure", function() return position().start == want end, 20)
    wait("nothing left to send after the failure", function() return not waiting() end, 15)
    menu = library_with(21)

    -- Read on the phone while this one waited: nothing is lost before the reader chooses.
    mock_get("/test/fail_writes?n=100")
    open(menu, "Книга номер 0")
    reader().rolling:onGotoViewRel(5)
    UIManager:forceRePaint()
    read_to = reader().document:getCurrentPage()
    reader():onHome()
    wait("the position to wait", waiting, 15)
    moment() -- the attempts on leaving are over
    if not waiting() then fail("the position did not wait") end
    local phone = "/6/72!/2/4/2/4/1:0"
    mock_get("/test/phone_read?book=" .. BOOK .. "&start=" .. url_encode(phone))
    mock_get("/test/fail_writes?n=0")
    menu = library_with(21)
    menu.on_refresh()
    wait("the library to show the phone's position", function()
        return (find_item(top(), "Книга номер 0").card.cfi or ""):find("/6/72!", 1, true)
    end, 15)
    if position().start ~= phone then fail("the phone's reading was overwritten: " .. tostring(position().start)) end
    if not waiting() then fail("the reading here was dropped without asking") end
    menu = library_with(21)
    menu:onMenuSelect(find_item(menu, "Книга номер 0"))
    local box = asked()
    if reader().document:getCurrentPage() ~= read_to then
        fail("moved before the answer: page " .. reader().document:getCurrentPage() .. ", was " .. read_to)
    end
    if not box.text:find("здесь", 1, true) then fail("question without percentages: " .. box.text) end
    answer(box, true)
    local n = fragment()
    if n ~= 36 then fail("the phone's position was not taken: chapter " .. tostring(n)) end
    if waiting() then fail("the reading here was kept after going to the phone's") end
    moment()
    if position().start ~= phone then fail("going there sent a position: " .. tostring(position().start)) end
    if top().ok_text then fail("asked again after the answer") end

    -- Taken: reopening does not ask.
    reader():onHome()
    menu = library_with(21)
    moment()
    open(menu, "Книга номер 0")
    moment()
    if top().ok_text then fail("asked about a position already taken") end
    if fragment() ~= 36 then fail("left the phone's position: " .. tostring(fragment())) end

    -- The book opened before the list had heard of the phone: it asks all the same.
    reader():onHome()
    menu = library_with(21)
    moment()
    phone = "/6/40!/2/4/2/4/1:0"
    mock_get("/test/phone_read?book=" .. BOOK .. "&start=" .. url_encode(phone))
    menu:onMenuSelect(find_item(menu, "Книга номер 0"))
    box = asked()
    if fragment() ~= 36 then fail("moved without asking: " .. tostring(fragment())) end

    -- Stayed: no asking again, and what is read from here goes to Yandex.
    answer(box, false)
    moment()
    if top().ok_text then fail("asked again after staying") end
    if fragment() ~= 36 then fail("moved after staying: " .. tostring(fragment())) end
    reader().rolling:onGotoViewRel(3)
    UIManager:forceRePaint()
    want = reader().yaknigi:positionOf(reader().document:getXPointer())
    reader():onHome()
    wait("the position sent after staying", function() return position().start == want end, 15)
    wait("nothing left to send after staying", function() return not waiting() end, 15)
    menu = library_with(21)
    open(menu, "Книга номер 0")
    moment()
    if top().ok_text then fail("asked about its own position") end

    -- Read on the phone while this one slept, and it is noticed on waking.
    phone = "/6/42!/2/4/2/4/1:0"
    mock_get("/test/phone_read?book=" .. BOOK .. "&start=" .. url_encode(phone))
    UIManager:broadcastEvent(Event:new("Suspend"))
    UIManager:broadcastEvent(Event:new("Resume"))
    answer(asked(), true)
    if fragment() ~= 21 then fail("waking did not lead to the phone's position: " .. tostring(fragment())) end

    -- Wi-Fi is still coming back when the device wakes.
    moment()
    phone = "/6/44!/2/4/2/4/1:0"
    mock_get("/test/phone_read?book=" .. BOOK .. "&start=" .. url_encode(phone))
    mock_get("/test/fail_card?n=1")
    UIManager:broadcastEvent(Event:new("Resume"))
    answer(asked(), true)
    if fragment() ~= 22 then fail("no second try after waking: " .. tostring(fragment())) end

    -- A page turned without waking, or before the answer: the phone's reading stays.
    moment()
    phone = "/6/46!/2/4/2/4/1:0"
    mock_get("/test/phone_read?book=" .. BOOK .. "&start=" .. url_encode(phone))
    reader().rolling:onGotoViewRel(1)
    UIManager:forceRePaint()
    reader().yaknigi:onSaveSettings()
    box = asked()
    if position().start ~= phone then fail("a turned page overwrote the phone: " .. tostring(position().start)) end
    answer(box, true)
    if fragment() ~= 23 then fail("the phone's position after a turned page: " .. tostring(fragment())) end
    say("position upload works")
end

local function test_reading_screen()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local doc = reader().document

    -- A plain page: no KOReader panel opens from any band of the screen.
    shot("10-reading")
    local page = doc:getCurrentPage()
    tap_at(W - 40, math.floor(H * 0.3))
    wait("a page turn on the right", function() return doc:getCurrentPage() == page + 1 end)
    if top().name ~= "ReaderUI" then fail("a page turn opened " .. tostring(top().name)) end
    tap_at(40, math.floor(H * 0.92)) -- bottom left, KOReader's settings band: turns back
    wait("a page back from the bottom band", function() return doc:getCurrentPage() == page end)
    if top().name ~= "ReaderUI" then fail("bottom band opened " .. tostring(top().name)) end
    -- The progress stands at both sides of the last line, and a tap on it does not turn the page.
    tap_at(40, H - 20)
    UIManager:forceRePaint()
    if doc:getCurrentPage() ~= page then fail("a tap on the progress turned the page") end
    if top().name ~= "ReaderUI" then fail("a tap on the progress opened " .. tostring(top().name)) end

    -- The top of the screen brings up the panels, whichever column.
    for _, x in ipairs { 40, math.floor(W / 2), W - 40 } do
        tap_at(x, math.floor(H * 0.15))
        wait("the panels from the top at x=" .. x, is_named("YaknigiChrome"))
        if doc:getCurrentPage() ~= page then fail("the top of the screen turned the page") end
        tap_at(W / 2, H / 2)
        wait("the panels to close", is_named("ReaderUI"))
    end

    -- The middle brings up the panels, a tap on the text takes them away.
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    local chrome = top()
    shot("11-chrome")
    tap_at(W / 2, H / 2)
    wait("the panels to close", is_named("ReaderUI"))

    -- Bookmark.
    tap_at(W - math.floor(W * 0.05), math.floor(W * 0.05))
    if top().name ~= "ReaderUI" then fail("the corner opened " .. tostring(top().name)) end
    if not reader().bookmark:isPageBookmarked() then fail("the bookmark was not set") end
    shot("12-page-bookmarked")
    -- The ribbon hangs from the top, away from the corner, with a notch in its end.
    do
        local function dark(x, y) return Screen.bb:getPixel(x, y):getColor8().a < 128 end
        local gap, width = math.floor(W * 0.045), math.floor(W * 0.033)
        local middle = W - gap - math.floor(width / 2)
        if not dark(middle, 2) then fail("no ribbon at the top of the page") end
        if dark(W - 2, 2) then fail("the mark is in the very corner") end
        local tip = math.min(math.floor(W * 0.045), Screen:scaleBySize(28)) - 2
        if dark(middle, tip) then fail("the ribbon has no notch") end
        if not dark(W - gap - width + 1, tip) then fail("the ribbon has no legs") end
    end
    tap_at(W - math.floor(W * 0.05), math.floor(W * 0.05))
    if reader().bookmark:isPageBookmarked() then fail("the bookmark was not removed") end
    -- Beside the corner it is the top of the page again.
    tap_at(W - math.floor(W * 0.15), math.floor(W * 0.05))
    wait("the panels beside the corner", is_named("YaknigiChrome"))
    if reader().bookmark:isPageBookmarked() then fail("a bookmark beside the corner") end
    tap_at(W / 2, H / 2)
    wait("the panels to close", is_named("ReaderUI"))
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    chrome = top()

    -- Slider: a tap at the middle goes to the middle of the book.
    local pages = doc:getPageCount()
    tap_at(chrome.slider.dimen.x + math.floor(chrome.slider.width / 2), chrome.slider.dimen.y + 5)
    local now = doc:getCurrentPage()
    if math.abs(now - pages / 2) > pages * 0.02 then fail("slider went to " .. now .. " of " .. pages) end
    shot("13-chrome-slider")

    -- A quick drag is a swipe, and the finger may leave the strip: where it left counts.
    chrome = top()
    local bar = chrome.slider.dimen
    local mid_y = bar.y + math.floor(bar.h / 2)
    local function at(share) return bar.x + math.floor(bar.w * share) end
    gesture("swipe", at(0.5), mid_y, { end_pos = { at(0.75), mid_y - 300 } })
    near(doc:getCurrentPage() / pages, 0.75, "a swipe along the slider")
    -- A slow one ends in a release, a finger that rested first in a hold's.
    chrome = top()
    bar = chrome.slider.dimen
    gesture("pan", at(0.4), bar.y + 5, { start_pos = { at(0.75), bar.y + 5 } })
    gesture("pan_release", at(0.4), bar.y + 5)
    near(doc:getCurrentPage() / pages, 0.4, "a slow drag")
    chrome = top()
    bar = chrome.slider.dimen
    gesture("hold_pan", at(0.6), bar.y + 5, { start_pos = { at(0.4), bar.y + 5 } })
    gesture("hold_release", at(0.6), bar.y + 5)
    near(doc:getCurrentPage() / pages, 0.6, "a drag after resting")
    -- A drag that began elsewhere is not the slider's.
    chrome = top()
    bar = chrome.slider.dimen
    local before = doc:getCurrentPage()
    gesture("pan", at(0.1), bar.y + 5, { start_pos = { at(0.1), 300 } })
    if top().slider and top().slider.dragging then fail("the slider took another drag") end
    if doc:getCurrentPage() ~= before then fail("another drag moved the book") end
    shot("13b-chrome-slider-knob")
    tap_at(W / 2, H / 2)
    wait("the panels to close", is_named("ReaderUI"))
    reader().rolling:onGotoXPointer("/body/DocFragment[31]")

    -- Notes: several pages of them, and always a way out.
    local bookmark = reader().bookmark
    local start_page = doc:getCurrentPage()
    for i = 1, 14 do
        bookmark:toggleBookmark(start_page + i * 2)
    end
    local here = doc:getXPointer()
    reader().annotation:addItem{
        page = here, pos0 = here, pos1 = here, drawer = "lighten", chapter = "",
        datetime = "2026-11-06 12:00:00", note = "Заметка к этому месту",
        text = string.rep("Длинное выделение, которое не помещается в две строки. ", 12),
    }
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    tap_widget(top().notes_button)
    wait("the notes", is_named("YaknigiNotes"))
    local notes = top()
    shot("19-notes")
    if notes.pages < 2 then fail("expected notes over pages, got " .. notes.pages) end
    tap_widget(notes.next_button)
    if notes.page ~= 2 then fail("the arrow did not turn the notes") end
    shot("19b-notes-page-2")
    tap_widget(notes.prev_button)
    if notes.page ~= 1 then fail("the arrow did not turn the notes back") end
    tap_widget(notes.back)
    wait("the page after the notes", is_named("ReaderUI"))
    if doc:getCurrentPage() ~= start_page then fail("leaving the notes moved the page") end

    -- A tap on a note goes to it; the cross removes it after asking.
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    tap_widget(top().notes_button)
    wait("the notes", is_named("YaknigiNotes"))
    notes = top()
    tap_widget(notes.opens[2]) -- the first is on this very page
    wait("the page of the note", is_named("ReaderUI"))
    wait("the jump to the note", function() return doc:getCurrentPage() ~= start_page end)
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    tap_widget(top().notes_button)
    wait("the notes", is_named("YaknigiNotes"))
    notes = top()
    local count = #reader().annotation.annotations
    tap_widget(notes.removes[1])
    local box = wait("the question", function() return top().ok_callback and top() end)
    shot("19c-notes-remove")
    box.ok_callback()
    UIManager:close(box)
    if #reader().annotation.annotations ~= count - 1 then fail("the note was not removed") end
    wait("the notes again", is_named("YaknigiNotes"))
    tap_widget(notes.back)
    wait("the page after the notes", is_named("ReaderUI"))
    reader().annotation.annotations = {}
    reader().rolling:onGotoXPointer("/body/DocFragment[31]")

    -- KOReader's own lists, closed by their cross at the top right, as a finger would.
    local function close_stock(what)
        wait(what, function() return top().name ~= "YaknigiChrome" and top().name ~= "ReaderUI" end)
        UIManager:forceRePaint()
        tap_at(W - 30, 30)
        UIManager:forceRePaint()
        wait(what .. " to close", is_named("ReaderUI"), 5)
    end
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    tap_widget(top().chapter_row)
    wait("the contents", function() return top().name ~= "YaknigiChrome" and top().name ~= "ReaderUI" end)
    shot("14-contents")
    close_stock("the contents")
    -- The way to it that does not have to be found.
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    tap_widget(top().toc_button)
    wait("the contents", function() return top().name ~= "YaknigiChrome" and top().name ~= "ReaderUI" end)
    close_stock("the contents")
    bookmark:onShowBookmark()
    close_stock("KOReader's bookmarks")

    -- KOReader's own Exit leaves no screens: that must bring the library, not end the app.
    reader():handleEvent(Event:new("Exit"))
    local after_exit = library_with(21)
    open(after_exit, "Книга номер 0")
    reader().rolling:onGotoXPointer("/body/DocFragment[31]")
    doc = reader().document

    -- The text panel. Each change must reach the document and stay for other books.
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    tap_widget(top().text_button)
    wait("the text panel", is_named("YaknigiTextPanel"))
    local panel = top()
    shot("15-text-panel")
    local config = doc.configurable
    local size = config.font_size
    tap_widget(panel.size_up)
    if config.font_size ~= size + 1 then fail("size is " .. tostring(config.font_size)) end
    if G_reader_settings:readSetting("copt_font_size") ~= size + 1 then fail("size is not the default") end
    tap_widget(panel.size_down)
    tap_widget(panel.font_next)
    local font = reader().font.font_face
    if font == "Noto Serif" then fail("the font did not change") end
    shot("16-text-panel-font")
    tap_widget(panel.font_prev)
    if reader().font.font_face ~= "Noto Serif" then fail("the font did not come back") end
    tap_widget(panel.spacing[3])
    if config.line_spacing ~= 130 then fail("spacing is " .. tostring(config.line_spacing)) end
    tap_widget(panel.spacing[2])
    tap_widget(panel.margins[3])
    if config.h_page_margins[1] ~= 35 then fail("margins are " .. tostring(config.h_page_margins[1])) end
    shot("17-text-panel-wide")
    tap_widget(panel.margins[2])
    -- The warmth and the light follow a drag, not only a tap, wherever it ends.
    local powerd = require("device"):getPowerDevice()
    local function drag_test(name, read)
        local slider = top()[name]
        if not slider then
            say("note: no " .. name .. " slider on this device")
            return
        end
        local d = slider.dimen
        local y = d.y + math.floor(d.h / 2)
        local function x_of(share) return d.x + slider.knob + math.floor(slider.track * share) end
        gesture("pan", x_of(0.3), y, { start_pos = { x_of(0.8), y } })
        near(read(), 0.3, name .. " during a drag")
        gesture("swipe", x_of(0.8), y, { end_pos = { x_of(0.2), y + 400 } })
        near(read(), 0.2, name .. " after a swipe")
        slider = top()[name]
        d = slider.dimen
        gesture("hold_pan", x_of(0.6), y, { start_pos = { x_of(0.2), y } })
        gesture("hold_release", x_of(0.6), y)
        near(read(), 0.6, name .. " after a hold")
    end
    drag_test("light", function() return powerd:frontlightIntensity() / powerd.fl_max end)
    drag_test("warmth", function() return powerd:frontlightWarmth() / 100 end)
    shot("17b-text-panel-sliders")
    tap_at(W / 2, 100)
    wait("the page", is_named("ReaderUI"))

    -- Night mode, there and back.
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    tap_widget(top().text_button)
    wait("the text panel", is_named("YaknigiTextPanel"))
    panel = top()
    UIManager:broadcastEvent(Event:new("ToggleNightMode"))
    if not G_reader_settings:isTrue("night_mode") then fail("night mode did not turn on") end
    UIManager:setDirty("all", "full")
    shot("18-night")
    UIManager:broadcastEvent(Event:new("ToggleNightMode"))
    if G_reader_settings:isTrue("night_mode") then fail("night mode did not turn off") end
    UIManager:setDirty("all", "full")
    tap_at(W / 2, 100)
    wait("the page", is_named("ReaderUI"))

    -- The progress is changed where it is: by a tap on it.
    local footer = reader().view.footer
    local function line() return footer.genFooterText() end
    local cur, count = doc:getCurrentPage(), doc:getPageCount()
    G_reader_settings:saveSetting("yaknigi_progress", "percent")
    if line():find(":%d%d") then fail("a clock in the footer: " .. line()) end
    if not reader().view.view_modules.yaknigi_clock then fail("no clock at the top of the page") end
    local function tap_progress()
        tap_at(W / 2, H - 8)
        if top().name ~= "ReaderUI" then fail("a tap on the progress opened " .. tostring(top().name)) end
        UIManager:forceRePaint()
        return line()
    end
    if doc:getCurrentPage() ~= cur then fail("a tap on the progress turned the page") end
    if tap_progress() ~= tostring(cur) then fail("page: " .. line()) end
    if tap_progress() ~= ("%d из %d"):format(cur, count) then fail("page of pages: " .. line()) end
    if not tap_progress():match("^До конца главы: %d+ стр%. %d+%%$") then fail("chapter: " .. line()) end
    say("the page says:", line())
    shot("18b-progress-chapter")
    if not tap_progress():find("До конца книги: " .. (count - cur) .. " стр. ", 1, true) then fail("book: " .. line()) end
    say("the page says:", line())
    if not tap_progress():match("^%d+%%$") then fail("percent again: " .. line()) end
    if doc:getCurrentPage() ~= cur then fail("tapping the progress turned the page") end
    if G_reader_settings:readSetting("yaknigi_progress") ~= "percent" then fail("the progress is not kept") end
    -- The panels have the same tap.
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    tap_widget(top().progress_label)
    if G_reader_settings:readSetting("yaknigi_progress") ~= "page" then fail("the panels' progress does not change") end
    G_reader_settings:saveSetting("yaknigi_progress", "percent")
    tap_at(W / 2, H / 2)
    wait("the panels to close", is_named("ReaderUI"))

    -- While the device sleeps nothing is drawn over the screensaver, not even the time.
    local Device = require("device")
    local dirty, set_dirty = 0, UIManager.setDirty
    UIManager.setDirty = function(...) dirty = dirty + 1; return set_dirty(...) end
    local update, updates = footer.onUpdateFooter, 0
    footer.onUpdateFooter = function(...) updates = updates + 1; return update(...) end
    Device.screen_saver_mode = true
    reader().yaknigi.shell:paintClock()
    reader().yaknigi.shell:onWake()
    Device.screen_saver_mode = false
    UIManager.setDirty, footer.onUpdateFooter = set_dirty, nil
    if dirty ~= 0 or updates ~= 0 then fail("drawn over the screensaver: " .. dirty .. " " .. updates) end

    -- The time's refresh leaves nothing of the last minute, and touches nothing else.
    do
        local mode, region
        UIManager.setDirty = function(_, _, refresh, where) mode, region = refresh, where end
        reader().yaknigi.shell:paintClock()
        UIManager.setDirty = set_dirty
        if mode ~= "flashui" then fail("the clock's refresh is " .. tostring(mode)) end
        if region.w > W / 4 then fail("the clock flashes " .. region.w .. " wide") end
    end

    -- The settings, from the panels' menu.
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    top():showMore()
    UIManager:forceRePaint()
    shot("19-more-menu")
    local Settings = require("yaknigi/settings")
    UIManager:close(top())
    local app_closed = false
    UIManager:show(Settings:new{ ui = reader(), all_rows = true, on_close_app = function() app_closed = true end })
    UIManager:forceRePaint()
    local settings = top()
    if settings.name ~= "YaknigiSettings" then fail("no settings: " .. tostring(settings.name)) end
    shot("20-settings")

    -- The button at the top: out of the app, to sleep, off. Each is asked for, none is done here.
    local Power = require("yaknigi/power")
    local function power_choice(id)
        tap_widget(settings.power)
        UIManager:forceRePaint()
        return settings.power_dialog.buttontable:getButtonById(id)
    end
    local suspend, power_off, slept, off = UIManager.suspend, Power.off, false, false
    UIManager.suspend = function() slept = true end
    Power.off = function() off = true end
    local choice = power_choice("sleep")
    shot("20a-settings-power")
    tap_widget(choice)
    wait("the sleep asked for", function() return slept end)
    tap_widget(power_choice("off"))
    wait("the power off asked for", function() return off end)
    UIManager.suspend, Power.off = suspend, power_off
    if top() ~= settings then fail("the settings are not back after the power menu") end
    if app_closed then fail("the app closed by itself") end

    -- The settings say nothing of the progress any more: that is changed on the page.
    if settings.rows.progress then fail("the progress is still in the settings") end
    tap_widget(settings.rows.clock)
    if G_reader_settings:isTrue("yaknigi_reading_clock") then fail("the clock did not go off") end
    tap_widget(settings.rows.clock)
    if not G_reader_settings:isTrue("yaknigi_reading_clock") then fail("the clock did not come back") end
    shot("20b-settings-switched")

    -- A row with choices opens them, a choice comes back to the list.
    tap_widget(settings.rows.refresh)
    if not settings.choice then fail("the choices of the refresh did not open") end
    UIManager:forceRePaint()
    shot("20c-settings-refresh")
    tap_widget(settings.back)
    if settings.choice then fail("back does not leave the choices") end
    tap_widget(settings.rows.refresh)
    tap_widget(settings.options[2])
    if settings.choice then fail("a choice did not come back to the list") end
    if UIManager:getRefreshRate() ~= 3 then fail("refresh rate: " .. tostring(UIManager:getRefreshRate())) end
    if G_reader_settings:readSetting("full_refresh_count") ~= 3 then fail("refresh rate not saved") end
    tap_widget(settings.rows.refresh)
    tap_widget(settings.options[3])
    if UIManager:getRefreshRate() ~= 6 then fail("refresh rate back: " .. tostring(UIManager:getRefreshRate())) end

    tap_widget(settings.rows.sleep_time)
    tap_widget(settings.options[4])
    if reader().autosuspend and reader().autosuspend.auto_suspend_timeout_seconds ~= 30 * 60 then
        fail("sleep time did not reach the plugin")
    end
    if G_reader_settings:readSetting("auto_suspend_timeout_seconds") ~= 30 * 60 then fail("sleep time not saved") end

    -- The sleep screen: the cover of the open book, or the page as it is.
    tap_widget(settings.rows.sleep_screen)
    tap_widget(settings.options[2])
    if G_reader_settings:readSetting("screensaver_type") ~= "disable" then fail("sleep screen stays on the cover") end
    tap_widget(settings.rows.sleep_screen)
    tap_widget(settings.options[1])
    if G_reader_settings:readSetting("screensaver_type") ~= "document_cover" then fail("sleep screen: no cover") end
    -- The original of the cover comes after the book has opened.
    local cover = wait("the cover's original", function()
        local file = G_reader_settings:readSetting("screensaver_document_cover")
        return file and file:find(".large.", 1, true) and file
    end, 15)
    say("sleep screen shows", cover:match("[^/]*$"))
    if G_reader_settings:readSetting("screensaver_img_background") ~= "white" then fail("no flash before the sleep screen") end

    -- What does not fit turns page, here on a list made short: the device's strip and fonts
    -- may leave less room than the emulator has.
    local short = Settings:new{ ui = reader(), all_rows = true, body_height = Screen:scaleBySize(330) }
    UIManager:show(short)
    UIManager:forceRePaint()
    if short.pages < 2 then fail("the short list has " .. short.pages .. " page") end
    shot("20d-settings-short")
    local function swipe(direction)
        UIManager:forceRePaint()
        UIManager:sendEvent(Event:new("Gesture", {
            ges = "swipe",
            direction = direction,
            distance = 200,
            pos = Geom:new{ x = W / 2, y = H / 2, w = 0, h = 0 },
            time = require("ui/time").now(),
        }))
        UIManager:forceRePaint()
    end
    swipe("west")
    if short.page ~= 2 then fail("a swipe does not turn the settings: " .. short.page) end
    shot("20e-settings-short-2")
    swipe("east")
    if short.page ~= 1 then fail("a swipe does not turn the settings back: " .. short.page) end
    tap_widget(short.pager_next)
    if short.page ~= 2 then fail("the arrow does not turn the settings: " .. short.page) end
    for _ = 1, short.pages do swipe("west") end
    if short.page ~= short.pages or not short.rows.sleep_time then fail("the last row cannot be reached") end
    short:close()
    UIManager:forceRePaint()
    settings:close()
    UIManager:forceRePaint()
    if top().name ~= "YaknigiChrome" then fail("settings did not go back to the panels") end
    tap_at(W / 2, H / 2)
    wait("the panels to close", is_named("ReaderUI"))
    -- This is KOReader's own screen, as it would come up on the way to sleep.
    local Screensaver = require("ui/screensaver")
    local ok, err = pcall(function()
        Screensaver:setup("suspend")
        Screensaver:show()
        UIManager:forceRePaint()
        shot("21-sleep-cover")
        Screensaver:close_widget()
        shot("21b-after-sleep")
        Screensaver:cleanup()
    end)
    require("device").screen_saver_mode = false
    if not ok then fail("sleep screen: " .. tostring(err)) end
    UIManager:forceRePaint()
    G_reader_settings:saveSetting("yaknigi_progress", "percent")
    footer:onUpdateFooter(true)
end

local function script()
    local plugin = require("apps/filemanager/filemanager").instance.yaknigi
    if not plugin then fail("plugin is not loaded") end

    -- Sign-in: the QR, then the code. The mock checks PKCE against this challenge.
    local qr = wait("the QR code", function()
        local w = top()
        return w.text and w.text:find("code_challenge=", 1, true) and w
    end)
    shot("01-login-qr")
    local challenge = qr.text:match("code_challenge=([^&]+)")
    local http = require("socket.http")
    http.request(os.getenv("YB_OAUTH_BASE") .. "/challenge?c=" .. challenge)
    qr:onTapClose()
    -- The keyboard is the topmost widget, above the dialog it belongs to.
    local dialog = wait("the code dialog", function()
        for _, window in ipairs(UIManager._window_stack) do
            if window.widget.getInputText then return window.widget end
        end
    end)
    shot("02-login-code")
    dialog:setInputText("abc123")
    local sign_in
    for _, b in ipairs(dialog.buttons[1]) do
        if b.text == "Войти" then sign_in = b end
    end
    sign_in.callback()

    -- Library, with 21 books over 3 pages, most recent first.
    local menu = library_with(21)
    shot("03-library")
    if not menu.item_table[1].text:find("Книга номер 0", 1, true) then
        fail("library is not sorted by last read: " .. menu.item_table[1].text)
    end
    if menu.item_table[1].mandatory ~= "77%" then
        fail("no progress in the library: " .. tostring(menu.item_table[1].mandatory))
    end

    -- A serial explains itself rather than failing silently.
    wait("the covers", function()
        for _, item in ipairs(menu.item_table) do
            if not item.cover then return false end
        end
        return true
    end)

    -- The first screen: the book to go back to, covers of the shelves, the rest as a list.
    if menu.view ~= "home" then fail("the library does not start at its first screen") end
    if not menu.strips.reading or not menu.strips.want then fail("no covers of the shelves") end
    shot("03-library-home")
    tap_widget(menu.shelf_rows.finished)
    if menu.view ~= "finished" or #menu.rows ~= 4 then fail("the finished books: " .. #menu.rows) end
    shot("03d-library-finished")
    tap_widget(menu.back_button)
    if menu.view ~= "home" then fail("the way back from a shelf") end

    -- Search within a shelf, in any case.
    local function search(query)
        wait("the search box", function() return menu.search_box and UIManager:isWidgetShown(menu.search_box) end)
        menu.search_box:setText(query)
        tap_widget(menu.search_box.find_button)
        wait("the search results", function() return menu.query == (query ~= "" and query or nil) end)
        UIManager:forceRePaint()
    end
    -- The emulator counts as having a real keyboard; a Kindle has only this one.
    G_reader_settings:saveSetting("virtual_keyboard_enabled", true)
    menu:openShelf("all")
    tap_widget(menu.search_bar)
    wait("the keyboard", function() return top().name == "VirtualKeyboard" or top().keyboard_layer end)
    UIManager:forceRePaint()
    shot("03e-library-keyboard")
    -- The box opens right over the bar.
    if menu.search_box.dimen.y ~= menu.search_bar.dimen.y - math.floor((menu.search_box.dimen.h - menu.search_bar.dimen.h) / 2) then
        fail("the search box is not where the bar is")
    end
    G_reader_settings:saveSetting("virtual_keyboard_enabled", false)
    if G_reader_settings:readSetting("keyboard_layout") ~= "ru" then fail("search does not start in Russian") end
    search("КНИГА НОМЕР 12")
    if menu.view ~= "all" or #menu.rows ~= 1 or not menu.rows[1].title:find("номер 12", 1, true) then
        fail("search found " .. #menu.rows)
    end
    shot("03f-library-found")
    tap_widget(menu.search_bar)
    search("нет такой книги")
    if #menu.rows ~= 0 then fail("search found what is not there") end
    shot("03g-library-not-found")
    tap_widget(menu.clear_button)
    if menu.query or #menu.rows == 0 then fail("the search was not cleared") end

    tap_widget(menu.next_button)
    if menu.page ~= 2 then fail("the arrow did not turn the library") end
    shot("03b-library-page-2")
    for _ = 2, menu.total_pages do -- one more than needed: stays on the last page
        tap_widget(menu.next_button)
    end
    if menu.page ~= menu.total_pages then fail("library went to page " .. menu.page) end
    for _ = 2, menu.total_pages do
        tap_widget(menu.prev_button)
    end
    if menu.page ~= 1 then fail("the arrow did not turn the library back") end
    tap_at(40, 100) -- the corner of the way back from a book: not a way out of the app
    UIManager:forceRePaint()
    if top() ~= menu then fail("a tap in the library's corner closed it") end
    tap_at(40, 100) -- and on the first screen it does nothing at all
    UIManager:forceRePaint()
    if top() ~= menu or menu.view ~= "home" then fail("a second tap in the corner did something") end
    shot("03c-library-covers")

    menu:onMenuSelect(find_item(menu, "Сериал"))
    wait("the serial message", function() return (top().text or ""):find("Сериалы", 1, true) end)
    shot("04-serial")
    UIManager:close(top())

    -- First open: goes to the position from Yandex without the whole book.
    local seconds = open(menu, "Книга номер 0")
    say(("first open: %.3fs"):format(seconds))
    local n, xp = fragment()
    say("position:", xp)
    if n ~= 31 then fail("expected chapter 31, got " .. tostring(xp)) end
    if not xp:find("p[3]", 1, true) and not xp:find("p/", 1, true) then
        say("note: paragraph not exact:", xp)
    end
    local text = page_text()
    if not text:find("Глава 31", 1, true) then fail("wrong text: " .. text:sub(1, 80)) end
    shot("05-reader-first-open")
    local plugin_r = reader().yaknigi
    local store = plugin_r.store
    if not store then fail("no store in the reader") end
    if store:is_whole() then fail("book is already whole: nothing went to the background") end
    local pages_skeleton = reader().document:getPageCount()

    -- The rest arrives in the background and the reader swaps to it.
    local t0 = socket.gettime()
    wait("the whole book", function() return store:is_whole() end, 60)
    say(("whole book on disk after %.1fs"):format(socket.gettime() - t0))
    wait("the swap", function()
        return reader() and reader().document:getPageCount() > pages_skeleton
    end, 30)
    wait("the reader after the swap", function() return top().name == "ReaderUI" end)
    say(("swapped after %.1fs; pages %d -> %d"):format(socket.gettime() - t0,
        pages_skeleton, reader().document:getPageCount()))
    n, xp = fragment()
    if n ~= 31 then fail("position lost in the swap: " .. tostring(xp)) end
    shot("06-reader-whole")
    test_reading_screen()
    n, xp = fragment()
    if n ~= 31 then fail("left the chapter in the panels: " .. tostring(xp)) end

    -- TOC and paging work on the swapped document.
    local before = reader().document:getCurrentPage()
    reader().rolling:onGotoViewRel(1)
    if reader().document:getCurrentPage() == before then fail("paging does nothing") end

    -- Read on, back to the library in app mode, reopen: the book is where it was left,
    -- though Yandex still has the old position. Nothing is fetched, and it is quick.
    reader().rolling:onGotoViewRel(3)
    local read_to = reader().document:getCurrentPage()
    local percent = math.floor(reader().yaknigi.shell:progress() * 100 + 0.5)
    -- The library is up the moment "back" is tapped, while the book is still closing, and
    -- nothing of KOReader is ever painted.
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    tap_at(screen_w / 2, screen_h / 2)
    wait("the panels", is_named("YaknigiChrome"))
    tap_widget(top().back)
    local first_library = top()
    if not first_library.item_table then fail("back shows " .. tostring(first_library.name)) end
    menu = wait("the library again", function()
        local w = top()
        return w ~= first_library and w.item_table and #w.item_table == 21 and w
    end)
    local file_manager = require("apps/filemanager/filemanager").instance
    if not rawget(file_manager, "paintTo") then fail("the file manager can be painted") end
    shot("30b-library-after-back")
    if find_item(menu, "Книга номер 0").mandatory ~= percent .. "%" then
        fail("the library does not show how far the book is read: "
            .. tostring(find_item(menu, "Книга номер 0").mandatory) .. ", read " .. percent)
    end
    if not find_item(menu, "Книга номер 0").text:find("✓", 1, true) then fail("no mark on a whole book") end
    seconds = open(menu, "Книга номер 0")
    say(("second open: %.3fs"):format(seconds))
    if reader().document:getCurrentPage() ~= read_to then
        fail(("position lost after reopening: page %d, left at %d"):format(reader().document:getCurrentPage(), read_to))
    end

    test_positions_match_the_text()
    test_position_upload()

    -- Reaching an unfetched chapter: a stub at first, then the real one.
    reader():onHome()
    menu = library_with(21)
    mock_get("/test/chapter_delay?s=1")
    open(menu, "Книга номер 2")
    if reader().yaknigi.store:is_whole() then fail("second book is already whole") end
    local rolling = reader().rolling
    rolling:onGotoXPointer("/body/DocFragment[35]/body/p")
    n, xp = fragment()
    say("after jump:", xp)
    if n ~= 35 then fail("jump failed: " .. tostring(xp)) end
    shot("07-stub")
    t0 = socket.gettime()
    wait("the chapter behind the stub", function()
        return reader() and top().name == "ReaderUI" and page_text():find("Глава 35", 1, true)
    end, 30)
    n, xp = fragment()
    if n ~= 35 then fail("left the chapter: " .. tostring(xp)) end
    say(("chapter arrived after %.1fs"):format(socket.gettime() - t0))
    shot("08-after-stub")

    -- The phone is in a chapter that has not arrived: on its stub, then at the place itself.
    local far = reader().yaknigi.store
    local far_chapter
    for i = #far.paths, 1, -1 do
        if not far:has(far.paths[i]) then far_chapter = i; break end
    end
    if not far_chapter then fail("every chapter has arrived too soon") end
    say("the phone's chapter is not here yet:", far_chapter)
    mock_get("/test/phone_read?book=book2&start=" .. url_encode(("/6/%d!/2/4/2/40/1:0"):format(far_chapter * 2)))
    UIManager:broadcastEvent(Event:new("Resume"))
    answer(asked(), true)
    n, xp = fragment()
    if n ~= far_chapter then fail("not waiting in the chapter: " .. tostring(xp)) end
    mock_get("/test/chapter_delay?s=0.1")
    wait("the phone's chapter", function()
        -- A page of a long paragraph may not show where it starts, so no looking for words.
        return reader() and reader().document and top().name == "ReaderUI"
            and not reader().yaknigi:stubs()[far_chapter]
    end, 30)
    local doc = reader().document
    n, xp = fragment()
    if n ~= far_chapter then fail("left the phone's chapter: " .. tostring(xp)) end
    if doc:getPageFromXPointer(xp) <= doc:getPageFromXPointer(("/body/DocFragment[%d]"):format(far_chapter)) then
        fail("at the start of the phone's chapter, not at its place: " .. xp)
    end

    -- Text settings are one for all books, even a book with its own settings saved.
    G_reader_settings:saveSetting("copt_line_spacing", 130)
    reader():onHome()
    menu = library_with(21)
    if not menu.item_table[1].text:find("Книга номер 2", 1, true) then
        fail("the book just read is not first: " .. menu.item_table[1].text)
    end
    -- Back from a book, the library is where it was left.
    menu:openShelf("all")
    menu:search("номер 0")
    open(menu, "Книга номер 0")
    if reader().document.configurable.line_spacing ~= 130 then
        fail("text settings are per book: " .. tostring(reader().document.configurable.line_spacing))
    end

    -- Leaving through the library's close button quits the app.
    reader():onHome()
    menu = library_with(21)
    if menu.view ~= "all" or menu.query ~= "номер 0" then fail("the library forgot where it was") end

    -- All of Yandex's books, from their tab. A failure can be tried again.
    menu:goHome()
    UIManager:forceRePaint()
    mock_get("/test/fail_search?n=1")
    tap_widget(menu.tab_cells.search)
    wait("the catalogue's box", function() return menu.search_box and UIManager:isWidgetShown(menu.search_box) end)
    if menu.search_box.hint ~= "Поиск по всем книгам" then fail("search on its tab: " .. menu.search_box.hint) end
    -- Nothing typed: the button waits for something to look for.
    tap_widget(menu.search_box.find_button)
    if not menu.search_box or menu.query then fail("searched for nothing") end
    search("достоевский")
    if menu.view ~= "catalogue" then fail("the search tab is not the catalogue: " .. menu.view) end
    wait("the search to fail", function() return menu.retry_button end)
    UIManager:forceRePaint()
    shot("20-catalogue-failed")
    tap_widget(menu.retry_button)
    wait("the books found", function() return #menu.rows > 0 end)
    local added = function() return #mock_get("/test/added").added end
    if #menu.catalogue.items ~= 25 then fail("the first page of results: " .. #menu.catalogue.items) end
    if menu.rows[1].mandatory ~= "в библиотеке" or menu.rows[2].mandatory then
        fail("the mark of a book in the library")
    end
    wait("the covers found", function()
        for _, item in ipairs(menu.rows) do
            if not item.cover then return false end
        end
        return true
    end)
    UIManager:forceRePaint()
    shot("21-catalogue")

    -- Pages go on as the next results arrive, to the very last.
    local pages_seen = 1
    while menu.page < menu.total_pages or not menu.catalogue.finished do
        wait("more results", function() return menu.page < menu.total_pages or menu.catalogue.finished end)
        if menu.page < menu.total_pages then
            tap_widget(menu.next_button)
            pages_seen = pages_seen + 1
            if pages_seen > 30 then fail("the results do not end") end
        end
    end
    if #menu.catalogue.items ~= 60 then fail("all results: " .. #menu.catalogue.items) end
    shot("21b-catalogue-last-page")
    for _ = 2, menu.total_pages do tap_widget(menu.prev_button) end
    if menu.page ~= 1 then fail("back through the results: " .. menu.page) end

    -- A book not in the library: its card first, and nothing added by looking.
    local new_book = menu.catalogue.items[2]
    menu:onMenuSelect(new_book)
    wait("the book's card", is_named("YaknigiBookCard"))
    local card_screen = top()
    UIManager:forceRePaint()
    shot("22-catalogue-book")
    tap_widget(card_screen.back_button)
    wait("the way back from the card", function() return top() == menu end)
    if added() ~= 0 then fail("looking at a book added it") end
    menu:onMenuSelect(new_book)
    wait("the book's card again", is_named("YaknigiBookCard"))
    tap_widget(top().read_button)
    wait("the found book to open", function()
        return reader() and reader().document and top().name == "ReaderUI"
            and reader().document.file:find("/found1/", 1, true)
    end)
    if added() ~= 1 then fail("the book was not added once: " .. added()) end
    shot("23-catalogue-opened")

    -- Back in the results, where they were left; now it is in the library.
    reader():onHome()
    menu = library_with(22)
    if menu.view ~= "catalogue" or menu.query ~= "достоевский" then fail("the results were forgotten") end
    new_book = menu.catalogue.items[2]
    if new_book.mandatory ~= "в библиотеке" then fail("the added book has no mark") end
    menu:onMenuSelect(new_book)
    wait("the added book to open at once", function()
        return reader() and reader().document and top().name == "ReaderUI"
            and reader().document.file:find("/found1/", 1, true)
    end)
    if added() ~= 1 then fail("the book was added twice: " .. added()) end
    reader():onHome()
    menu = library_with(22)

    -- A book in the library opens without its card.
    menu:onMenuSelect(menu.catalogue.items[1])
    wait("a book from the library to open", function()
        return reader() and reader().document and top().name == "ReaderUI"
            and reader().document.file:find("/book5/", 1, true)
    end)
    reader():onHome()
    menu = library_with(22)

    -- Added on the phone since the library was loaded: not added again.
    menu:onMenuSelect(menu.catalogue.items[3])
    wait("a book added elsewhere to open", function()
        return reader() and reader().document and top().name == "ReaderUI"
            and reader().document.file:find("/book7/", 1, true)
    end)
    if added() ~= 1 then fail("a book already in the library was added: " .. added()) end
    reader():onHome()
    menu = library_with(22)

    -- A book out of reach stays out of the library, and the reader is told why.
    local denied = menu.catalogue.items[4]
    menu:onMenuSelect(denied)
    wait("the card of a book out of reach", is_named("YaknigiBookCard"))
    local denied_card = top()
    tap_widget(denied_card.read_button)
    wait("the refusal", function() return (top().text or ""):find("недоступна", 1, true) end)
    shot("24-catalogue-denied")
    UIManager:close(top())
    if added() ~= 1 then fail("a book out of reach was added") end
    UIManager:close(denied_card)

    -- Nothing found, and the cross goes straight to typing anew.
    tap_widget(menu.search_bar)
    search("нет такой книги")
    wait("nothing found", function() return menu.catalogue.finished end)
    UIManager:forceRePaint()
    if #menu.rows ~= 0 then fail("found what is not there") end
    shot("25-catalogue-not-found")
    tap_widget(menu.clear_button)
    wait("the box to type anew", function() return menu.search_box end)
    if menu.query or menu.search_box:getText() ~= "" then fail("the search was not cleared") end
    -- The Enter key on the keyboard looks for it too.
    menu.search_box:setText("нет такой книги")
    menu.search_box.input:addChars("\n")
    wait("Enter to search", function() return menu.query == "нет такой книги" and not menu.search_box end)
    wait("nothing found again", function() return menu.catalogue.finished end)
    -- A tap elsewhere leaves the search as it was.
    tap_widget(menu.search_bar)
    wait("the box", function() return menu.search_box end)
    local kept = menu.query
    tap_at(math.floor(Screen:getWidth() / 2), math.floor(Screen:getHeight() / 2))
    if menu.search_box or menu.query ~= kept then fail("a tap elsewhere did not leave the search") end
    UIManager:forceRePaint()
    tap_widget(menu.clear_button)
    wait("the box after the cross", function() return menu.search_box end)
    menu.search_box:dismiss()
    UIManager:forceRePaint()
    if menu.back_button then fail("the search tab has a way back") end
    tap_widget(menu.tab_cells.library)
    if menu.view ~= "home" then fail("the library's tab from the catalogue") end
    -- A shelf still searches only itself.
    menu:openShelf("finished")
    tap_widget(menu.search_bar)
    wait("the shelf's box", function() return menu.search_box end)
    if menu.search_box.hint ~= "Поиск по библиотеке" then fail("search on a shelf: " .. menu.search_box.hint) end
    shot("44-search-box-aligned")
    menu.search_box:dismiss()

    -- The book being read, docked above the tabs.
    menu:goHome()
    UIManager:forceRePaint()
    shot("48-library-dock")
    if menu.refresh_button == nil then fail("no way to refresh the library") end
    local docked = menu.dock_item
    if not docked then fail("nothing in the dock") end
    for _, item in ipairs(menu.rows) do
        if item == docked then fail("the docked book is in the strip too") end
    end
    local docked_id = docked.card.book.uuid
    tap_widget(menu.dock_widget)
    wait("the docked book to open", function()
        return reader() and reader().document and top().name == "ReaderUI"
            and reader().document.file:find("/" .. docked_id .. "/", 1, true)
    end)
    reader():onHome()
    menu = library_with(22)
    UIManager:forceRePaint()

    -- The feed, on its tab: only what can be read here, and a failure can be tried again.
    mock_get("/test/fail_showcase?n=1")
    tap_widget(menu.tab_cells.feed)
    if menu.view ~= "feed" then fail("the feed's tab: " .. menu.view) end
    wait("the feed to fail", function() return menu.retry_button end)
    UIManager:forceRePaint()
    shot("49-feed-failed")
    tap_widget(menu.retry_button)
    wait("the feed", function() return menu.feed_sections and #menu.feed_sections > 0 end)
    wait("the feed's covers", function()
        for _, item in ipairs(menu.rows) do
            if not item.cover then return false end
        end
        return #menu.rows > 0
    end)
    UIManager:forceRePaint()
    shot("50-feed")
    local names = {}
    for _, section in ipairs(menu.feed.sections) do names[#names + 1] = section.name end
    if table.concat(names, ",") ~= "Новинки,Популярное,Классика,Детективы" then
        fail("the feed's sections: " .. table.concat(names, ","))
    end
    if menu.feed.sections[1].items[1].card.book.uuid ~= "found5" then fail("the first of the feed") end
    tap_widget(menu.next_button)
    wait("the next of the feed", function() return #menu.feed.sections == 7 and menu.feed.finished end)
    UIManager:forceRePaint()
    if menu.total_pages ~= 3 then fail("the feed's pages: " .. menu.total_pages) end
    shot("51-feed-page-2")
    -- Away and back, the feed is where it was; its tab from itself goes to the start.
    tap_widget(menu.tab_cells.library)
    UIManager:forceRePaint()
    tap_widget(menu.tab_cells.feed)
    if menu.view ~= "feed" or menu.page ~= 2 then fail("the feed lost its page: " .. menu.page) end
    UIManager:forceRePaint()
    tap_widget(menu.tab_cells.feed)
    if menu.page ~= 1 then fail("the feed's tab did not go to its start") end
    UIManager:forceRePaint()
    -- A section as a list. What is in the library says so.
    tap_widget(menu.feed_sections[2])
    if menu.view ~= "feed_section" or menu.section.name ~= "Популярное" then fail("no section") end
    wait("the section's covers", function()
        for _, item in ipairs(menu.rows) do
            if not item.cover then return false end
        end
        return #menu.rows > 0
    end)
    UIManager:forceRePaint()
    shot("52-feed-section")
    tap_widget(menu.back_button)
    if menu.view ~= "feed" then fail("the way back from a section") end
    UIManager:forceRePaint()

    -- A book from the feed opens at its text, with the picture before it a page back.
    tap_widget(menu.feed_sections[1])
    UIManager:forceRePaint()
    local with_cover
    for _, item in ipairs(menu.section.items) do
        if item.card.book.uuid == "found7" then with_cover = item end
    end
    if not with_cover then fail("the book with a picture is not in the feed") end
    menu:onMenuSelect(with_cover)
    wait("the feed's book card", is_named("YaknigiBookCard"))
    UIManager:forceRePaint()
    tap_widget(top().read_button)
    wait("the feed's book to open", function()
        return reader() and reader().document and top().name == "ReaderUI"
            and reader().document.file:find("/found7/", 1, true)
    end)
    if fragment() ~= 2 then fail("the book did not open at its text: " .. tostring(fragment())) end
    UIManager:forceRePaint()
    shot("53-opened-at-text")
    reader().rolling:onGotoViewRel(-1)
    UIManager:forceRePaint()
    wait("the page before the text", function() return fragment() == 1 end)
    shot("54a-cover-page-at-once")
    -- The picture itself, not the empty box that stands for it until it comes.
    wait("the picture to show", function()
        if not reader() or top().name ~= "ReaderUI" then return false end
        UIManager:forceRePaint()
        local W, H = Screen:getWidth(), Screen:getHeight()
        local dark = 0
        -- Below the clock and above the progress. The mock's picture is small, at the top.
        for y = math.floor(H * 0.03), math.floor(H * 0.9), 8 do
            for x = 0, W - 1, 8 do
                if Screen.bb:getPixel(x, y):getColor8().a < 200 then dark = dark + 1 end
            end
        end
        return dark > 50
    end, 40)
    if fragment() ~= 1 then fail("the picture moved the page: " .. tostring(fragment())) end
    shot("54-cover-a-page-back")
    reader():onHome()
    menu = library_with(23)
    if menu.view ~= "feed_section" then fail("the section was forgotten: " .. menu.view) end
    UIManager:forceRePaint()
    tap_widget(menu.tab_cells.library)
    UIManager:forceRePaint()

    -- The settings, a tab like the others, and the way out of the account.
    tap_widget(menu.tab_cells.settings)
    UIManager:forceRePaint()
    local settings = top()
    if settings.name ~= "YaknigiSettings" then fail("no settings from the library") end
    if not settings.rows.sign_out then fail("no way out of the account in the settings") end
    shot("46-settings-library")
    -- Airplane mode, as far as it can be seen: the Wi-Fi is off.
    local NetworkMgr = require("ui/network/manager")
    local wifi_on = NetworkMgr.isWifiOn
    NetworkMgr.isWifiOn = function() return false end
    settings:build()
    UIManager:setDirty(settings, "ui")
    shot("47-settings-wifi-off")
    NetworkMgr.isWifiOn = wifi_on
    if settings.back then fail("the settings' tab has a way back") end
    UIManager:forceRePaint()
    tap_widget(settings.tab_cells.library)
    wait("the library after the settings", function() return top() == menu end)
    if menu.view ~= "home" then fail("the library's tab from the settings: " .. menu.view) end
    UIManager:forceRePaint()
    tap_widget(menu.tab_cells.settings)
    settings = top()
    UIManager:forceRePaint()
    for _ = 2, settings.pages do
        tap_widget(settings.pager_next)
        UIManager:forceRePaint()
    end
    shot("55-settings-last-page")
    local f = io.open(OUT .. "/PASS", "w")
    f:write("ok\n")
    f:close()
    say("PASS")
    -- The app ends where it says so, and the run would not end if it did not.
    tap_widget(settings.power)
    UIManager:forceRePaint()
    tap_widget(settings.power_dialog.buttontable:getButtonById("exit"))
end

function Driver:init()
    if started or not OUT then return end
    started = true
    UIManager:scheduleIn(1, function()
        local co = coroutine.create(function()
            local ok, err = xpcall(script, debug.traceback)
            if not ok then fail(err) end
        end)
        local ok, err = coroutine.resume(co)
        if not ok then fail(err) end
    end)
    UIManager:scheduleIn(300, function() fail("the whole test timed out") end)
    logger.info("yaknigi test driver armed")
end

return Driver
