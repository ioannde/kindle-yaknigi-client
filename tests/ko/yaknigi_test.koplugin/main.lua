-- Drives the real KOReader UI through the plugin against the mock server, in CI.
-- Writes screenshots and timings to YAKNIGI_TEST_OUT and "PASS" there at the end;
-- any failure exits at once with a non-zero code.
local Event = require("ui/event")
local Catalogue = require("yaknigi/catalogue")
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

    -- The screen turned: for books, the open one and the next, never for the library.
    local TextStyle = require("yaknigi/textstyle")
    local function landscape() return Screen:getWidth() > Screen:getHeight() end
    open(menu, "Книга номер 0")
    tap_at(math.floor(Screen:getWidth() / 2), math.floor(Screen:getHeight() * 0.1))
    wait("the panels", is_named("YaknigiChrome"))
    tap_widget(top().text_button)
    wait("the text panel", is_named("YaknigiTextPanel"))
    UIManager:forceRePaint()
    tap_widget(top().advanced)
    UIManager:forceRePaint()
    shot("15d-panel-screen")
    tap_widget(top().rotation_cells[2])
    wait("the book turned", landscape)
    wait("the book without the panel", is_named("ReaderUI"))
    UIManager:forceRePaint()
    if G_reader_settings:readSetting("copt_rotation_mode") ~= 1 then fail("the turn was not saved") end
    shot("15e-book-landscape")
    tap_at(math.floor(Screen:getWidth() / 2), math.floor(Screen:getHeight() * 0.1))
    wait("the panels on their side", is_named("YaknigiChrome"))
    UIManager:forceRePaint()
    shot("15f-chrome-landscape")
    tap_widget(top().text_button)
    wait("the text panel on its side", is_named("YaknigiTextPanel"))
    UIManager:forceRePaint()
    shot("15g-panel-landscape")
    tap_widget(top().advanced)
    UIManager:forceRePaint()
    shot("15h-panel-more-landscape")
    top():close()
    wait("the book again", is_named("ReaderUI"))
    UIManager:forceRePaint()
    reader():onHome()
    menu = library_with(21)
    if landscape() then fail("the library came on its side") end
    UIManager:forceRePaint()
    shot("15i-library-after-landscape")
    open(menu, "Книга номер 0")
    if not landscape() then fail("the next opening was upright") end
    TextStyle.set_rotation(reader(), TextStyle.ROTATIONS[1].key)
    if landscape() then fail("the book did not stand up again") end
    reader():onHome()
    menu = library_with(21)
    wait("the position after turning", function() return not waiting() end)
    moment()

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

--- The row of the settings, on the page that shows it.
local function settings_row(settings, key)
    settings.page = 1
    settings:changed()
    for _ = 1, settings.pages do
        UIManager:forceRePaint()
        local row = settings.rows[key]
        if row and row.painted then return row end
        settings:turn(1)
    end
    fail("no row " .. key .. " in the settings")
end

--- Alignment, hyphenation and the tap zones, on the second page of the panel in the book.
local function test_reading_settings()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local Settings = require("yaknigi/settings")
    local DocSettings = require("docsettings")
    local doc = reader().document

    -- They are of the book, and the settings of the app no longer have them.
    local app = Settings:new{ ui = reader(), all_rows = true }
    for _, entry in ipairs(app:entries()) do
        for _, key in ipairs { "text_align", "hyphenation", "tap_mode", "koreader" } do
            if entry.key == key then fail("the settings of the app still have " .. key) end
        end
    end
    app:onCloseWidget()

    local function open_more()
        tap_at(math.floor(W / 2), math.floor(H * 0.1))
        wait("the panels", is_named("YaknigiChrome"))
        tap_widget(top().text_button)
        wait("the text panel", is_named("YaknigiTextPanel"))
        UIManager:forceRePaint()
        tap_widget(top().advanced)
        UIManager:forceRePaint()
        if not top().align_cells then fail("no second page in the panel") end
        return top()
    end
    local panel = open_more()
    shot("15a-panel-more")

    local tweak = reader().styletweak
    local css_before = tweak.css_text or ""
    if #panel.align_cells ~= 3 then fail("the alignments: " .. #panel.align_cells) end
    tap_widget(panel.align_cells[3])
    if not (tweak.css_text or ""):find("text-align: left", 1, true) then fail("the book is not aligned left") end
    if not G_reader_settings:readSetting("style_tweaks").text_align_most_left then fail("left not saved") end
    UIManager:forceRePaint()
    shot("15b-aligned-left")
    tap_widget(panel.align_cells[2])
    if not (tweak.css_text or ""):find("text-align: justify", 1, true) then fail("the book is not justified") end
    if (tweak.css_text or ""):find("text-align: left", 1, true) then fail("left is still there") end
    UIManager:forceRePaint()
    tap_widget(panel.align_cells[1])
    if (tweak.css_text or "") ~= css_before then fail("as in the book is not what it was") end
    UIManager:forceRePaint()

    -- A book's own settings do not stand against the ones for all books.
    tap_widget(panel.hyphenation_cells[2])
    if reader().typography.hyphenation ~= false then fail("hyphenation is still on") end
    if G_reader_settings:readSetting("hyphenation") ~= false then fail("hyphenation not saved") end
    UIManager:forceRePaint()
    reader():saveSettings()
    local own = DocSettings:open(doc.file)
    own:saveSetting("hyphenation", true)
    own:saveSetting("style_tweaks", { text_align_all_left = true })
    own:flush()
    reader().yaknigi:applyTextDefaults(doc.file)
    own = DocSettings:open(doc.file)
    if own:readSetting("hyphenation") ~= false then fail("the next opening would have hyphenation") end
    if own:readSetting("style_tweaks") then fail("the next opening would have the book's own alignment") end
    tap_widget(panel.hyphenation_cells[1])
    if reader().typography.hyphenation ~= true then fail("hyphenation did not come back") end
    UIManager:forceRePaint()

    -- Back to the first page, and on again.
    tap_widget(panel.back_button)
    UIManager:forceRePaint()
    if not panel.advanced or panel.page then fail("back did not go to the first page") end
    tap_widget(panel.advanced)
    UIManager:forceRePaint()

    -- Pages turned from top and bottom.
    tap_widget(panel.tap_cells[2])
    if G_reader_settings:readSetting("page_turns_tap_zones") ~= "top_bottom" then fail("top and bottom not saved") end
    UIManager:forceRePaint()
    shot("15c-panel-tap-zones")
    panel:close()
    wait("the book", is_named("ReaderUI"))
    UIManager:forceRePaint()
    local page = doc:getCurrentPage()
    local function turns(x, y, to, what)
        tap_at(math.floor(x), math.floor(y))
        wait(what, function() return doc:getCurrentPage() == to end)
        if top().name ~= "ReaderUI" then fail(what .. " opened " .. tostring(top().name)) end
    end
    turns(W / 2, H * 0.7, page + 1, "the middle of the bottom half turning on")
    turns(W / 2, H * 0.3, page, "the middle of the top half turning back")
    turns(W * 0.3, H * 0.7, page + 1, "what was the rest of the back zone turning on")
    turns(40, H * 0.3, page, "the left of the top half turning back")
    turns(W - 40, H * 0.7, page + 1, "the right of the bottom half turning on")
    turns(W - 40, H * 0.3, page, "the right of the top half turning back")
    tap_at(math.floor(W / 2), math.floor(H * 0.1))
    wait("the panels from the top", is_named("YaknigiChrome"))
    UIManager:close(top())
    UIManager:forceRePaint()

    panel = open_more()
    tap_widget(panel.tap_cells[1])
    if G_reader_settings:readSetting("page_turns_tap_zones") ~= "default" then fail("left and right not saved") end
    if G_reader_settings:readSetting("page_turns_tap_zone_forward_size_ratio") then fail("a ratio was left behind") end

    -- KOReader's own settings now live here, and only here.
    UIManager:forceRePaint()
    tap_widget(panel.menu_button)
    wait("KOReader's menu", function() return reader().menu.menu_container end)
    UIManager:forceRePaint()
    reader().menu:onCloseReaderMenu()
    wait("the book again", is_named("ReaderUI"))
    UIManager:forceRePaint()
    turns(W - 40, H * 0.3, page + 1, "the right turning on again")
    turns(40, H * 0.3, page, "the left turning back again")
    tap_at(math.floor(W / 2), math.floor(H / 2))
    wait("the panels from the middle", is_named("YaknigiChrome"))
    UIManager:close(top())
    UIManager:forceRePaint()
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
    test_reading_settings()
    if doc:getCurrentPage() ~= page then fail("the reading settings left another page") end

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
    wait("the contents", is_named("YaknigiToc"))
    shot("14-contents")
    tap_widget(top().back)
    wait("the contents to close", is_named("ReaderUI"), 5)
    bookmark:onShowBookmark()
    close_stock("KOReader's bookmarks")

    -- KOReader's own Exit leaves no screens: that must bring the library, not end the app.
    reader():handleEvent(Event:new("Exit"))
    local after_exit = library_with(21)
    -- While it opens: what the book is called, not where its file is.
    local said = {}
    local show_widget = UIManager.show
    UIManager.show = function(manager, widget, ...)
        if widget.text then said[#said + 1] = widget.text end
        return show_widget(manager, widget, ...)
    end
    open(after_exit, "Книга номер 0")
    UIManager.show = show_widget
    local said_title = false
    for _, text in ipairs(said) do
        if text:find("epub", 1, true) or text:find("Opening", 1, true) then fail("opening says: " .. text) end
        said_title = said_title or text:find("Открываю «Книга номер 0»", 1, true) ~= nil
    end
    if not said_title then fail("opening does not name the book") end
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
        local refresh
        UIManager.setDirty = function(_, _, asked) refresh = asked end
        reader().yaknigi.shell:paintClock()
        UIManager.setDirty = set_dirty
        local counted = UIManager.refresh_counted
        local mode, region = refresh()
        if not UIManager.refresh_counted then fail("the clock brings the next flash closer") end
        UIManager.refresh_counted = counted
        if mode ~= "partial" then fail("the clock's refresh is " .. tostring(mode)) end
        if region.w > W / 4 then fail("the clock flashes " .. region.w .. " wide") end
    end

    -- Links: a note opens over the page and a tap closes it; a link leading to another page
    -- offers the way back, until the reader has read on from there.
    do
        local start = reader().document:getCurrentPage()
        local doc = reader().document
        local note, far
        for fragment = 4, 8 do
            reader().rolling:onGotoXPointer("/body/DocFragment[" .. fragment .. "]")
            UIManager:forceRePaint()
            for _, link in ipairs(doc:getPageLinks() or {}) do
                if link.section and link.section:find("n5", 1, true) then note = link
                elseif link.section then far = link end
            end
            if note then break end
        end
        if not note or not far then fail("the mock's links are not on the page") end
        local function tap_link(link)
            tap_at((link.start_x + link.end_x) / 2, (link.start_y + link.end_y) / 2)
        end
        local page = doc:getCurrentPage()
        local shell = reader().yaknigi.shell
        tap_link(note)
        wait("the note", function() return top().html ~= nil end)
        if not top().html:find("Текст сноски", 1, true) then fail("the wrong note: " .. top().html:sub(1, 80)) end
        UIManager:forceRePaint()
        shot("19-footnote")
        tap_at(W / 2, H / 4)
        wait("the note to close", is_named("ReaderUI"), 5)
        if doc:getCurrentPage() ~= page then fail("the note has moved the page") end

        tap_link(far)
        wait("the link", function() return doc:getCurrentPage() ~= page end)
        UIManager:forceRePaint()
        if not shell:linkBackShown() then fail("no way back from a link") end
        shot("19-link-back")
        local box = shell.link_back_box
        tap_at(box.x + box.w / 2, box.y + box.h / 2)
        wait("the way back", function() return doc:getCurrentPage() == page end)
        UIManager:forceRePaint()
        if shell:linkBackShown() then fail("the way back is still offered") end

        tap_link(far)
        wait("the link again", function() return doc:getCurrentPage() ~= page end)
        reader():handleEvent(Event:new("GotoPage", doc:getCurrentPage() + 5))
        UIManager:forceRePaint()
        if shell:linkBackShown() then fail("the way back is offered long after") end
        reader():handleEvent(Event:new("GotoPage", start))
        UIManager:forceRePaint()
    end

    -- The table of contents: ours, opened where the reader is, and it goes where it is told.
    do
        tap_at(W / 2, H / 2)
        wait("the panels", is_named("YaknigiChrome"))
        tap_widget(top().toc_button)
        wait("the table of contents", is_named("YaknigiToc"))
        local toc = top()
        UIManager:forceRePaint()
        if not toc.rows[toc.current] then fail("the table of contents is not at the current chapter") end
        shot("19a-toc")
        local before = reader().document:getCurrentPage()
        local target
        for i, row in pairs(toc.rows) do
            if i ~= toc.current and toc.items[i].page ~= before then target = row end
        end
        if toc.pager_next then
            tap_widget(toc.pager_next)
            UIManager:forceRePaint()
            shot("19b-toc-next-page")
            tap_widget(toc.pager_prev)
            UIManager:forceRePaint()
            for i, row in pairs(toc.rows) do
                if i ~= toc.current and toc.items[i].page ~= before then target = row end
            end
        end
        tap_widget(target)
        wait("the chapter from the contents", function()
            return top() ~= toc and reader().document:getCurrentPage() ~= before
        end)
        reader():handleEvent(Event:new("GotoPage", before))
        UIManager:forceRePaint()
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
    tap_widget(settings_row(settings, "clock"))
    if G_reader_settings:isTrue("yaknigi_reading_clock") then fail("the clock did not go off") end
    tap_widget(settings_row(settings, "clock"))
    if not G_reader_settings:isTrue("yaknigi_reading_clock") then fail("the clock did not come back") end
    shot("20b-settings-switched")

    -- The fonts: each in itself, and one turned off leaves the text panel's list.
    local Fonts = require("yaknigi/fonts")
    tap_widget(settings_row(settings, "fonts"))
    if not (settings.choice and settings.choice.fonts_screen) then fail("the fonts did not open") end
    local first_font = settings.font_list[1]
    if not first_font or #settings.font_list < 2 then fail("fonts: " .. #settings.font_list) end
    tap_widget(settings.font_rows[first_font])
    for _, name in ipairs(Fonts.shown()) do
        if name == first_font then fail("a font turned off is still in the list") end
    end
    UIManager:forceRePaint()
    shot("20f-settings-fonts")
    tap_widget(settings.font_rows[first_font])
    if Fonts.shown()[1] ~= first_font then fail("the font did not come back") end
    tap_widget(settings.back)
    if settings.choice then fail("back does not leave the fonts") end

    -- A row with choices opens them, a choice comes back to the list.
    tap_widget(settings_row(settings, "refresh"))
    if not settings.choice then fail("the choices of the refresh did not open") end
    UIManager:forceRePaint()
    shot("20c-settings-refresh")
    tap_widget(settings.back)
    if settings.choice then fail("back does not leave the choices") end
    tap_widget(settings_row(settings, "refresh"))
    tap_widget(settings.options[2])
    if settings.choice then fail("a choice did not come back to the list") end
    if UIManager:getRefreshRate() ~= 3 then fail("refresh rate: " .. tostring(UIManager:getRefreshRate())) end
    if G_reader_settings:readSetting("full_refresh_count") ~= 3 then fail("refresh rate not saved") end
    tap_widget(settings_row(settings, "refresh"))
    tap_widget(settings.options[3])
    if UIManager:getRefreshRate() ~= 6 then fail("refresh rate back: " .. tostring(UIManager:getRefreshRate())) end

    tap_widget(settings_row(settings, "sleep_time"))
    tap_widget(settings.options[4])
    if reader().autosuspend and reader().autosuspend.auto_suspend_timeout_seconds ~= 30 * 60 then
        fail("sleep time did not reach the plugin")
    end
    if G_reader_settings:readSetting("auto_suspend_timeout_seconds") ~= 30 * 60 then fail("sleep time not saved") end

    -- The sleep screen: the cover of the open book, or the page as it is.
    tap_widget(settings_row(settings, "sleep_screen"))
    -- The cover, the collection, one's own picture, the page.
    if #settings.options ~= 4 then fail("the sleep screens: " .. #settings.options) end
    tap_widget(settings.options[4])
    if G_reader_settings:readSetting("screensaver_type") ~= "disable" then fail("sleep screen stays on the cover") end
    tap_widget(settings_row(settings, "sleep_screen"))
    tap_widget(settings.options[1])
    if G_reader_settings:readSetting("screensaver_type") ~= "document_cover" then fail("sleep screen: no cover") end
    -- The original of the cover comes after the book has opened.
    local cover = wait("the cover's original", function()
        local file = G_reader_settings:readSetting("screensaver_document_cover")
        return file and file:find(".large.", 1, true) and file
    end, 15)
    say("sleep screen shows", cover:match("[^/]*$"))
    if G_reader_settings:readSetting("screensaver_img_background") ~= "white" then fail("no flash before the sleep screen") end
    if G_reader_settings:isTrue("screensaver_stretch_images") then fail("a book's cover is stretched") end

    -- One's own picture: until there is one, the cover; then the newest in its folder.
    local Prefs = require("yaknigi/prefs")
    local lfs = require("libs/libkoreader-lfs")
    tap_widget(settings_row(settings, "sleep_screen"))
    tap_widget(settings.options[3])
    local own_dir = Prefs.own_sleep_dir()
    if lfs.attributes(own_dir, "mode") ~= "directory" then fail("no folder for one's own picture") end
    if G_reader_settings:readSetting("screensaver_document_cover") ~= cover then
        fail("no picture of one's own yet, and not the cover")
    end
    local function copy_cover(to, time)
        os.execute(string.format("cp '%s' '%s'", cover, to))
        lfs.touch(to, time, time)
    end
    copy_cover(own_dir .. "/old.jpg", 1000)
    copy_cover(own_dir .. "/new.JPG", 2000)
    copy_cover(own_dir .. "/._hidden.jpg", 3000)
    copy_cover(own_dir .. "/notes.txt", 4000)
    local Screensaver = require("ui/screensaver")
    -- Copied after the choice: found on the way to sleep.
    Screensaver:setup("suspend")
    if Screensaver.image_file ~= own_dir .. "/new.JPG" then
        fail("the picture of one's own: " .. tostring(Screensaver.image_file))
    end
    Screensaver:cleanup()
    if not G_reader_settings:isTrue("screensaver_stretch_images") then fail("one's own picture does not fill the screen") end
    for _, name in ipairs{ "old.jpg", "new.JPG", "._hidden.jpg", "notes.txt" } do os.remove(own_dir .. "/" .. name) end
    Prefs.apply_sleep_screen()
    if G_reader_settings:readSetting("screensaver_document_cover") ~= cover then fail("the cover is not back") end

    -- The collection comes with the package, and each sleep picks from it at random.
    settings:changed()
    tap_widget(settings_row(settings, "sleep_screen"))
    shot("20f-sleep-screens")
    tap_widget(settings.options[2])
    if G_reader_settings:readSetting("yaknigi_sleep_screen") ~= "faces" then fail("the collection not chosen") end
    local portraits, kinds = 0, {}
    for name in lfs.dir(Prefs.FACES_DIR) do
        if name:find("%.jpg$") then portraits = portraits + 1 end
    end
    if portraits ~= 7 then fail("the portraits in the package: " .. portraits) end
    -- KOReader seeds the choice with the time, in seconds: these sleeps are an hour apart.
    local real_time, hours = os.time, 0
    for _ = 1, 40 do
        hours = hours + 1
        os.time = function() return real_time() + hours * 3600 end
        Screensaver:setup("suspend")
        local file = tostring(Screensaver.image_file)
        if file:sub(1, #Prefs.FACES_DIR + 1) ~= Prefs.FACES_DIR .. "/" then fail("the collection's picture: " .. file) end
        kinds[file] = true
        Screensaver:cleanup()
    end
    os.time = real_time
    local picked = 0
    for _ in pairs(kinds) do picked = picked + 1 end
    if picked < 3 then fail("the same portraits at each sleep: " .. picked) end
    if not G_reader_settings:isTrue("screensaver_stretch_images") then fail("the collection does not fill the screen") end
    -- As it is seen: a portrait, the whole screen of it.
    Screensaver:setup("suspend")
    Screensaver:show()
    UIManager:forceRePaint()
    shot("20g-sleep-portrait")
    Screensaver:close_widget()
    Screensaver:cleanup()
    UIManager:forceRePaint()
    G_reader_settings:saveSetting("yaknigi_sleep_screen", "cover")
    Prefs.apply_sleep_screen()
    settings:changed()

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

-- The picture at the right of a row, the book's menu, and what is kept on the device.
--- What search finds besides books, and the lists all that leads to.
local function test_lists()
    local function to_library()
        tap_widget(top().tab_cells.library)
        return wait("the library", function() return top().item_table and top().view == "home" and top() end)
    end
    local function here(item)
        return reader() and reader().document and top().name == "ReaderUI"
            and reader().document.file:find("/" .. item .. "/", 1, true)
    end
    local function finished(menu, title)
        return wait("the list of " .. title, function()
            return menu.view == "collection" and menu.collection.title == title and menu.collection.finished
        end)
    end
    local function of_kind(menu, kind)
        for _, row in ipairs(menu.rows) do
            if row.kind == kind then return row end
        end
        fail("nothing of kind " .. kind)
    end
    local menu = to_library()
    local cards_before = #menu.item_table

    menu:search("подборка")
    wait("what was found", function() return menu.catalogue.finished and #menu.rows > 0 end)
    local titles = {}
    for _, item in ipairs(menu.catalogue.items) do titles[#titles + 1] = item.title end
    if table.concat(titles, "|") ~= "Автор подборки|Подборка|Новый сериал|Полка незнакомца|Полка 2|Полка 3|Все полки|Найденная книга 20" then
        fail("what was found: " .. table.concat(titles, "|"))
    end
    if of_kind(menu, "author").kind_text ~= "Автор · 751 произведение" then fail("the author's line") end
    if of_kind(menu, "series").kind_text ~= "Серия · 2 книги" then fail("the series' line") end
    if of_kind(menu, "serial").kind_text ~= "Сериал · 2 эпизода" then fail("the serial's line") end
    if of_kind(menu, "bookshelf").kind_text ~= "Полка · 2 книги" then fail("the shelf's line") end
    if of_kind(menu, "bookshelf").authors ~= "Незнакомец" then fail("whose the shelf is") end
    wait("the pictures", function()
        for _, row in ipairs(menu.rows) do
            if not row.cover then return false end
        end
        return true
    end)
    UIManager:forceRePaint()
    shot("70-search-kinds")

    -- From an author to a series, and the same way back.
    tap_widget(menu.row_buttons[of_kind(menu, "author")])
    finished(menu, "Автор подборки")
    titles = {}
    for _, row in ipairs(menu.rows) do titles[#titles + 1] = row.title end
    if table.concat(titles, "|") ~= "Подборка|Найденная книга 20|Найденная книга 22" then
        fail("the author's list: " .. table.concat(titles, "|"))
    end
    if menu:currentTab() ~= "search" then fail("the list left its tab") end
    UIManager:forceRePaint()
    shot("71-author")
    tap_widget(menu.row_buttons[of_kind(menu, "series")])
    finished(menu, "Подборка")
    titles = {}
    for _, row in ipairs(menu.rows) do titles[#titles + 1] = row.title end
    if table.concat(titles, "|") ~= "Найденная книга 20|Послушать|Найденная книга 21|Найденная книга 23" then
        fail("the series: a book's audio stays out, what cannot be read is there: " .. table.concat(titles, "|"))
    end
    if menu.rows[3].kind_text ~= "Книга 3" or menu.rows[3].unavailable then fail("a book of the series") end
    if menu.rows[2].mandatory ~= "только аудио" or menu.rows[2].kind_text ~= "Книга 2" then fail("the part with only audio") end
    if menu.rows[4].mandatory ~= "недоступна" then fail("the book that cannot be read") end
    UIManager:forceRePaint()
    shot("72-series")
    local closed_view = menu.view
    tap_widget(menu.row_buttons[menu.rows[4]])
    wait("the word that it is closed", is_named("YaknigiNoAccess"))
    shot("72-series-closed")
    tap_widget(top().close_button)
    wait("the word to go", function() return top() == menu end)
    if menu.view ~= closed_view then fail("an unavailable book opened something") end
    menu:goBack()
    finished(menu, "Автор подборки")

    -- A book leads to its series and its author.
    menu.on_book_menu(menu.rows[2])
    wait("the menu with the links", is_named("YaknigiBookMenu"))
    local links = top().rows
    if not links.series or not links.author then fail("no way from a book to its series and author") end
    UIManager:forceRePaint()
    shot("73-book-links")
    tap_widget(links.series)
    finished(menu, "Подборка")
    menu:goBack()
    finished(menu, "Автор подборки")
    menu:goBack()
    if menu.view ~= "catalogue" or menu.query ~= "подборка" then fail("the way back to the results: " .. menu.view) end

    -- The rest of the shelves are a list of their own, and a shelf found can be followed.
    tap_widget(menu.next_button)
    wait("the second page of results, with pictures", function()
        if menu.page ~= 2 or #menu.rows == 0 then return false end
        for _, row in ipairs(menu.rows) do
            if not row.cover then return false end
        end
        return true
    end)
    UIManager:forceRePaint()
    shot("70a-search-shelves")
    tap_widget(menu.row_buttons[of_kind(menu, "found_shelves")])
    finished(menu, "Полки: «подборка»")
    if #menu.rows ~= 4 then fail("the shelves found: " .. #menu.rows) end
    UIManager:forceRePaint()
    shot("70b-found-shelves")
    tap_widget(menu.row_buttons[menu.rows[1]])
    finished(menu, "Полка незнакомца")
    local function found_shelf_following(value)
        wait("the shelf found, its following " .. tostring(value), function()
            return menu.collection.finished and menu.collection.shelf
                and menu.collection.shelf.following == value and menu.shelf_button and top() == menu
        end)
    end
    local function found_shelf_row(key)
        return wait("the found shelf's sheet with " .. key, function()
            return top().name == "YaknigiBookMenu" and top().rows[key]
        end)
    end
    found_shelf_following(false)
    tap_widget(menu.shelf_button)
    tap_widget(found_shelf_row("follow"))
    wait("the following of a shelf found", function() return mock_get("/test/shelves")["shelf-3"].following == true end)
    found_shelf_following(true)
    tap_widget(menu.shelf_button)
    tap_widget(found_shelf_row("unfollow"))
    wait("the unfollowing of a shelf found", function() return mock_get("/test/shelves")["shelf-3"].following == false end)
    found_shelf_following(false)
    menu:goBack()
    finished(menu, "Полки: «подборка»")
    menu:goBack()
    if menu.view ~= "catalogue" or menu.query ~= "подборка" then fail("back from the shelves found: " .. menu.view) end
    if menu.page ~= 2 then fail("the results lost their page: " .. menu.page) end
    tap_widget(menu.prev_button)
    wait("the first page of results", function() return menu.page == 1 and #menu.rows > 0 end)

    -- A serial is added with its episodes, the serial first.
    local serial = of_kind(menu, "serial")
    tap_widget(menu.row_buttons[serial])
    wait("the serial to be added", function() return serial.in_library end)
    local taken = mock_get("/test/serial").taken
    if table.concat(taken, ","):sub(-20) ~= "serial-2,ep2-1,ep2-2" then fail("what was added: " .. table.concat(taken, ",")) end
    wait("the word about it to go", function() return top() == menu end)
    if #menu.item_table ~= cards_before + 1 then fail("episodes stand in the library by themselves") end

    -- A serial is one book, as on the phone: its episodes end to end.
    local function all_here()
        return reader() and reader().yaknigi and top().name == "ReaderUI"
            and reader().yaknigi.store and reader().yaknigi.store:is_whole()
            and not next(reader().yaknigi:stubs() or {})
    end
    local function toc_titles()
        local titles = {}
        for _, entry in ipairs(reader().document:getToc()) do titles[#titles + 1] = entry.title end
        return table.concat(titles, "|")
    end
    menu:onMenuSelect(serial)
    wait("the serial", function() return here("serial-2") end, 60)
    wait("all of the serial", all_here, 60)
    local store = reader().yaknigi.store
    local serial_dir = store.dir
    if #store.paths ~= 6 then fail("the chapters of the serial: " .. #store.paths) end
    if toc_titles() ~= "Эпизод 1|Эпизод 2" then fail("the contents of the serial: " .. toc_titles()) end
    UIManager:forceRePaint()
    shot("74-serial")

    local shown = store:read(store.paths[1])
    if not shown or not shown:find("<body>", 1, true) then fail("an episode's chapter is not a page") end
    -- At Yandex a place is in an episode: the second chapter of the second, here the fifth.
    reader().yaknigi:sendPosition() -- the place it was opened at
    reader().rolling:onGotoXPointer("/body/DocFragment[5]")
    reader().yaknigi:sendPosition()
    wait("the place to reach the serial", function()
        local updates = mock_get("/test/serial").updates
        local update = updates["c-serial-2"]
        return update and update.current_episode_uuid == "ep2-2" and updates["c-ep2-2"]
    end, 60)
    local told = mock_get("/test/serial")
    if not told.progress or told.progress.uuid ~= "serial-2" or told.progress.episode ~= "ep2-2" then
        fail("the serial's progress was not sent as a serial's")
    end
    if not told.updates["c-serial-2"].sent_cfi:find("^/6/4!") then
        fail("the place on the serial's card: " .. told.updates["c-serial-2"].sent_cfi)
    end
    local sent = mock_get("/test/position?book=ep2-2")
    if not tostring(sent.start):find("^/6/4!") then fail("the place sent: " .. tostring(sent.start)) end
    -- What is shown counts as the phone does: the episode. The slider goes over all of it.
    do
        local yaknigi, shell = reader().yaknigi, reader().yaknigi.shell
        local part, spine = yaknigi:currentEpisode()
        if not part or part.uuid ~= "ep2-2" or spine ~= 4 then fail("the episode being read") end
        local from, to = yaknigi:episodePages(part)
        local expected = (reader().document:getCurrentPage() - from) / (to - from)
        if math.abs(shell:progress() - expected) > 0.001 then fail("the share of the episode: " .. shell:progress()) end
        if shell:place() <= shell:progress() then fail("the slider's place in all of the serial") end
        local format = G_reader_settings:readSetting("yaknigi_progress")
        G_reader_settings:saveSetting("yaknigi_progress", "book")
        local left, right = shell:progressText()
        G_reader_settings:saveSetting("yaknigi_progress", format)
        if not left:find("До конца эпизода", 1, true) then fail("the words for an episode: " .. left) end
        if right ~= ("%d%%"):format(math.floor(expected * 100 + 0.5)) then fail("the percent of an episode: " .. right) end
    end

    -- That same place coming back from Yandex is not news of reading elsewhere.
    os.remove(serial_dir .. "/checked")
    reader().yaknigi:exchange()
    wait("the answer about the place", function()
        local f = io.open(serial_dir .. "/checked", "rb")
        if f then f:close() end
        return f ~= nil
    end, 30)
    local news = io.open(serial_dir .. "/news", "rb")
    if news then news:close(); fail("what was sent came back as news") end
    reader():onHome()
    wait("the library after the serial", function() return top().item_table and top() end)
    menu = to_library()

    -- Read on the phone: second chapter of the second episode. Two episodes are closed, one by
    -- the list and one by the answer, and neither costs the others or the account.
    menu:onMenuSelect(find_item(menu, "Сериал"))
    wait("the serial read elsewhere", function() return here("serial-1") end, 60)
    wait("the place from the phone", function() return fragment() == 5 end, 30)
    wait("all of that serial", all_here, 60)
    store = reader().yaknigi.store
    if toc_titles() ~= "Эпизод 1|Эпизод 2|Эпизод 3|Эпизод 4" then fail("the contents with what is closed: " .. toc_titles()) end
    for _, closed in ipairs { 7, 8 } do
        if not store.paths[closed]:find("locked", 1, true) or not store:read(store.paths[closed]):find("недоступен", 1, true) then
            fail("a closed episode's page: " .. store.paths[closed])
        end
    end
    reader().yaknigi:sendPosition() -- the place it was opened at
    os.remove(store.dir .. "/to_send")
    reader().rolling:onGotoXPointer("/body/DocFragment[7]")
    UIManager:forceRePaint()
    shot("75-serial-closed")
    reader().yaknigi:sendPosition()
    local waiting = io.open(store.dir .. "/to_send", "rb")
    if waiting then waiting:close(); fail("a place in a closed episode was to be sent") end
    reader():onHome()
    wait("the library once more", function() return top().item_table and top() end)
    menu = to_library()

    -- Out of the library, all together.
    menu:openShelf("all")
    wait("the shelf", function() return #menu.rows > 0 end)
    local row
    local guard = 0
    while not row do
        for _, candidate in ipairs(menu.rows) do
            if candidate.title == "Новый сериал" then row = candidate end
        end
        if not row then
            guard = guard + 1
            if guard > 10 then fail("the new serial is not on the shelf") end
            menu:show("all", nil, menu.page + 1)
        end
    end
    tap_widget(menu.row_buttons[row])
    wait("the serial's menu", is_named("YaknigiBookMenu"))
    local sheet = top()
    if not sheet.rows.remove_device then fail("a serial with all of it here is not saved") end
    -- Taken off the device and saved again, with no book at all to start from.
    tap_widget(sheet.rows.remove_device)
    wait("the menu to go", function() return top() == menu end)
    os.remove(serial_dir .. "/manifest.json")
    menu.on_book_menu(row)
    wait("the serial's menu again", is_named("YaknigiBookMenu"))
    if not top().rows.save then fail("a serial cannot be saved") end
    tap_widget(top().rows.save)
    wait("the menu to go again", function() return top() == menu end)
    wait("the serial to be saved", function()
        for _, item in ipairs(menu.item_table) do
            if item.title == "Новый сериал" and menu.book_status(item) == "whole" then row = item; return true end
        end
    end, 60)
    menu.on_book_menu(row)
    wait("the serial's menu once more", is_named("YaknigiBookMenu"))
    sheet = top()
    if not sheet.rows.remove_device then fail("a saved serial is not known as saved") end
    if not sheet.rows.remove_library then fail("a serial cannot be removed") end
    tap_widget(sheet.rows.remove_library)
    wait("the question", function() return top().ok_callback end)
    if not top().text:find("эпизодами", 1, true) then fail("the question does not mention the episodes") end
    answer(top(), true)
    wait("the serial to go", function() return #menu.item_table == cards_before end)
    local removed = table.concat(mock_get("/test/removed").removed, ",")
    if not removed:find("c-serial-2,c-ep2-1,c-ep2-2", 1, true) then fail("what Yandex was told to remove: " .. removed) end

    -- The shelves of Yandex's: one's own and those followed, each once.
    menu:goHome()
    wait("the home screen", function() return menu.shelf_rows.bookshelves end)
    UIManager:forceRePaint()
    shot("76-home-shelves")
    tap_widget(menu.shelf_rows.bookshelves)
    finished(menu, "Полки")
    titles = {}
    for _, shelf in ipairs(menu.rows) do titles[#titles + 1] = shelf.title end
    if table.concat(titles, "|") ~= "Моя полка|Чужая полка" then fail("the shelves: " .. table.concat(titles, "|")) end
    if menu.rows[1].kind_text ~= "Моя полка · 2 книги" then fail("one's own shelf: " .. tostring(menu.rows[1].kind_text)) end
    if menu.rows[2].kind_text ~= "Подписка · 21 книга" then fail("a followed shelf: " .. tostring(menu.rows[2].kind_text)) end
    UIManager:forceRePaint()
    shot("77-shelves")
    tap_widget(menu.row_buttons[menu.rows[1]])
    finished(menu, "Моя полка")
    if #menu.rows ~= 2 then fail("the books of the shelf") end
    UIManager:forceRePaint()
    shot("78-shelf")
    local function shelves() return mock_get("/test/shelves") end
    local function shelf_named(title)
        for uuid, shelf in pairs(shelves()) do
            if shelf.title == title then return uuid, shelf end
        end
    end
    local function name_dialog()
        return wait("the shelf's name", function()
            for _, window in ipairs(UIManager._window_stack) do
                if window.widget.getInputText then return window.widget end
            end
        end)
    end
    local function press(dialog, text)
        for _, button in ipairs(dialog.buttons[1]) do
            if button.text == text then button.callback() return end
        end
        fail("no button " .. text)
    end
    local function sheet_with(key)
        return wait("the sheet with " .. key, function()
            local rows = top().rows
            return top().name == "YaknigiBookMenu" and rows[key]
        end)
    end

    -- On one's own shelf the books have their menu, with the way off the shelf.
    if not menu.shelf_button then fail("no menu of one's own shelf") end
    menu.on_book_menu(menu.rows[1])
    sheet_with("remove_shelf")
    if not top().rows.add_library then fail("a book not in the library cannot be added from its menu") end
    UIManager:forceRePaint()
    shot("79-book-on-shelf-menu")
    top():dismiss()

    -- A new shelf: from the list of them, under a name with spaces round it.
    menu:goBack()
    finished(menu, "Полки")
    if not menu.shelf_button then fail("no way to make a shelf") end
    tap_widget(menu.shelf_button)
    local dialog = name_dialog()
    UIManager:forceRePaint()
    shot("80-new-shelf")
    dialog:setInputText("  Полка из теста ")
    press(dialog, "Создать")
    wait("the new shelf in the list", function()
        return menu.view == "collection" and menu.collection.finished and #menu.rows == 3
    end)
    local new_uuid, new_shelf = shelf_named("Полка из теста")
    if not new_uuid then fail("the shelf was not made") end
    if new_shelf.state ~= "hidden" or new_shelf.annotation ~= "" then fail("what the new shelf says") end
    if menu.rows[2].title ~= "Полка из теста" or menu.rows[2].kind_text ~= "Моя полка · 0 книг" then
        fail("the new shelf's row: " .. tostring(menu.rows[2].title) .. " " .. tostring(menu.rows[2].kind_text))
    end
    UIManager:forceRePaint()
    shot("81-shelves-with-new")

    -- A book onto it, from a book's menu.
    tap_widget(menu.row_buttons[menu.rows[1]])
    finished(menu, "Моя полка")
    menu.on_book_menu(menu.rows[1])
    tap_widget(sheet_with("add_shelf"))
    local choice = sheet_with("shelf:" .. new_uuid)
    UIManager:forceRePaint()
    shot("82-choose-shelf")
    tap_widget(choice)
    wait("the book on the shelf", function()
        local posts = shelves()[new_uuid].posts
        return posts[1] and posts[1][2] == "found20"
    end)
    wait("the shelf's books anew", function() return menu.collection.finished end)

    -- And off it again: the shelf, empty, says so, and is one's own to name and to delete.
    menu:goBack()
    wait("the shelves anew", function()
        return menu.view == "collection" and menu.collection.finished and menu.rows[2]
            and menu.rows[2].kind_text == "Моя полка · 1 книга"
    end)
    tap_widget(menu.row_buttons[menu.rows[2]])
    finished(menu, "Полка из теста")
    if #menu.rows ~= 1 then fail("the book is not shown on the shelf") end
    menu.on_book_menu(menu.rows[1])
    tap_widget(sheet_with("remove_shelf"))
    wait("the book off the shelf", function() return #shelves()[new_uuid].posts == 0 end)
    wait("the empty shelf", function() return menu.collection.finished and #menu.rows == 0 end)
    UIManager:forceRePaint()
    shot("83-empty-own-shelf")
    tap_widget(menu.shelf_button)
    tap_widget(sheet_with("rename"))
    UIManager:forceRePaint()
    dialog = name_dialog()
    if dialog:getInputText() ~= "Полка из теста" then fail("the name to change: " .. dialog:getInputText()) end
    dialog:setInputText("Новое имя")
    press(dialog, "Сохранить")
    wait("the new name", function() return shelves()[new_uuid].title == "Новое имя" end)
    finished(menu, "Новое имя")
    local renamed = shelves()[new_uuid]
    if renamed.state ~= "hidden" or renamed.annotation ~= "" then fail("what else renaming changed") end
    tap_widget(menu.shelf_button)
    sheet_with("delete")
    UIManager:forceRePaint()
    shot("84-own-shelf-menu")
    tap_widget(top().rows.delete)
    local confirm = wait("the question about the shelf", function()
        return top().ok_text == "Удалить" and top()
    end)
    UIManager:forceRePaint()
    shot("85-delete-shelf")
    answer(confirm, true)
    wait("the shelf to go", function() return shelves()[new_uuid] == nil end)
    wait("the list without it", function()
        return menu.view == "collection" and menu.collection.kind == "bookshelves"
            and menu.collection.finished and #menu.rows == 2
    end)

    -- Someone else's shelf can only be followed or not.
    tap_widget(menu.row_buttons[menu.rows[2]])
    finished(menu, "Чужая полка")
    wait("the other shelf's menu", function() return menu.shelf_button end)
    tap_widget(menu.shelf_button)
    if not sheet_with("unfollow") or top().rows.rename or top().rows.delete then fail("the menu of another's shelf") end
    UIManager:forceRePaint()
    shot("86-followed-shelf-menu")
    tap_widget(top().rows.unfollow)
    wait("the unfollowing", function() return shelves()["shelf-2"].following == false end)
    -- The server knows a moment before the reader does.
    wait("the shelf anew, unfollowed", function()
        return menu.collection.finished and menu.collection.shelf and menu.collection.shelf.following == false
            and menu.shelf_button and top() == menu
    end)
    tap_widget(menu.shelf_button)
    tap_widget(sheet_with("follow"))
    wait("the following", function() return shelves()["shelf-2"].following == true end)
    wait("the shelf anew, followed", function()
        return menu.collection.finished and menu.collection.shelf and menu.collection.shelf.following == true
            and top() == menu
    end)

    -- A list that is closed is no reason to sign out.
    local function saved_token()
        local LuaSettings = require("luasettings")
        local DataStorage = require("datastorage")
        return LuaSettings:open(DataStorage:getSettingsDir() .. "/yaknigi.lua"):readSetting("token")
    end
    local token_before = saved_token()
    local closed = Catalogue.collection("bookshelf", "closed", "Закрытая полка")
    menu:openCollection(closed)
    wait("the closed list", function() return closed.failed end)
    if closed.failed ~= "Этот список закрыт." then fail("a closed list says: " .. closed.failed) end
    if saved_token() ~= token_before or not saved_token() then fail("a 403 signed the reader out") end
    if top() ~= menu then fail("a 403 led away from the library") end
    menu:goBack()

    menu:goBack()
    finished(menu, "Полки")
    menu:goBack()
    if menu.view ~= "home" then fail("the way back from the shelves: " .. menu.view) end

    tap_widget(menu.tab_cells.settings)
    wait("the settings after the lists", is_named("YaknigiSettings"))
    UIManager:forceRePaint()
end

-- Highlights, notes and bookmarks at both ends. The server stands for the phone.
local function test_notes()
    local Cfi = require("yaknigi/cfi")
    local Event = require("ui/event")
    local function open_it()
        tap_widget(top().tab_cells.library)
        local menu = wait("the library", function() return top().item_table and top().view == "home" and top() end)
        menu:onMenuSelect(find_item(menu, "Книга номер 6"))
        wait("the book", function() return reader() and reader().document and top().name == "ReaderUI" end, 60)
        wait("the plugin to know the book", function() return reader().yaknigi.store and reader().yaknigi.shell end)
    end
    -- The made-up notes of the tests before went to the server when their list was looked at.
    for _, note in ipairs(mock_get("/test/notes").notes) do
        mock_get("/test/note_remove?uuid=" .. note.uuid)
    end
    open_it()
    local ui = reader()
    local plugin, doc, store = ui.yaknigi, ui.document, ui.yaknigi.store
    local BOOK = store.id
    local function server() return mock_get("/test/notes") end
    local function here()
        local out = {}
        for _, item in ipairs(ui.annotation.annotations) do out[#out + 1] = item end
        return out
    end
    local function settled()
        wait("the comparison to end", function()
            return not plugin.notes_soon and not plugin.notes_again
                and not (plugin.notes_pid)
        end, 40)
    end
    local function compare()
        settled()
        plugin:syncNotes()
        settled()
    end
    local function modified(item, extra)
        extra = extra or {}
        extra[1] = item
        ui:handleEvent(Event:new("AnnotationsModified", extra))
    end
    local function by_uuid(uuid)
        for _, item in ipairs(here()) do
            if item.yaknigi == uuid then return item end
        end
    end
    local function at_server(uuid)
        for _, note in ipairs(server().notes) do
            if note.uuid == uuid then return note end
        end
    end

    local number = fragment()
    local path = store.paths[number]
    wait("the chapter", function() return store:has(path) and not plugin:stubs()[number] end, 60)
    local spine = store:spine_index_of_fragment(number)
    local html = store:read(path)
    local function place(a, b, paragraph)
        local head = "/2/4/2/" .. (paragraph or 2) .. "/1:"
        local first = Cfi.to_point(html, number, head .. a)
        local last = Cfi.to_point(html, number, head .. b)
        return first, last, doc:getTextFromXPointers(first, last), Cfi.make_range(spine, head .. a, head .. b)
    end

    -- A highlight made while the rest of the book is coming lives through the swap to the whole
    -- book, which closes this reader, and reaches Yandex once.
    do
        local a, b, text, early_cfi = place(200, 230)
        local early = { page = a, pos0 = a, pos1 = b, text = text, drawer = "lighten", color = "gray" }
        modified(early, { nb_highlights_added = 1, index_modified = ui.annotation:addItem(early) })
        local before = ui
        ui = wait("the swap to the whole book", function()
            local now = reader()
            return now and now ~= before and now.document and now.yaknigi.shell and top().name == "ReaderUI" and now
        end, 60)
        plugin, doc, store = ui.yaknigi, ui.document, ui.yaknigi.store
        local there = wait("the early highlight at Yandex", function() return server().notes[1] end, 20)
        if there.cfi ~= early_cfi then fail("the early highlight's place: " .. there.cfi) end
        local item = wait("the early highlight to be linked", function() return by_uuid(there.uuid) end, 20)
        if #here() ~= 1 or #server().notes ~= 1 then fail("the swap doubled or lost a highlight") end
        settled()
        ui.bookmark:removeItem(item)
        wait("the early highlight to go", function() return not server().notes[1] end, 20)
        settled()
    end
    settled()
    -- A place in the chapter, as a phone would give it, is the same words in crengine.
    local function matches(inner)
        local first = Cfi.to_point(html, number, inner)
        if not first then fail("no place for " .. inner) end
        local shifted = inner:gsub(":(%d+)$", function(n) return ":" .. tonumber(n) + 12 end)
        local words = doc:getTextFromXPointers(first, Cfi.to_point(html, number, shifted)) or ""
        local there = mock_get("/test/text_at?cfi=" .. url_encode(Cfi.at(spine, inner))).text or "(nothing)"
        if plain(there):sub(1, #plain(words)) ~= plain(words) or words == "" then
            fail(("%s holds %q here and %q at the server"):format(inner, words, there:sub(1, 40)))
        end
    end
    for _, inner in ipairs({ "/2/4/2/2/1:10", "/2/4/2/6/1:5", "/2/4/2/6/2/1:5", "/2/4/2/6/4/1:7", "/2/4/2/6/5:3",
                             "/2/4/2/4/1:200", "/2/4/2/10/1:30", "/2/4/2/10/1:400" }) do
        matches(inner)
    end
    local _, tail = Cfi.to_point(html, number, "/2/4/2/6/5:3")
    local before_entity = select(2, tail:sub(1, tail:find("&amp;", 1, true) - 1):gsub("[^\128-\191]", ""))
    matches("/2/4/2/6/5:" .. before_entity + 3)

    -- A highlight made here reaches Yandex, with a place the phone can read.
    local first, last, words, cfi = place(10, 40)
    local mine = { page = first, pos0 = first, pos1 = last, text = words, drawer = "lighten", color = "gray" }
    modified(mine, { nb_highlights_added = 1, index_modified = ui.annotation:addItem(mine) })
    local sent = wait("the highlight at Yandex", function() return server().notes[1] end, 20)
    if sent.cfi ~= cfi then fail("the place sent: " .. sent.cfi .. " and not " .. cfi) end
    if sent.content ~= words or sent.color ~= 2 then fail("what was sent of a highlight") end
    if not sent.permanent_hidden then fail("a new highlight is not private by default") end
    wait("the highlight to be linked", function() return mine.yaknigi == sent.uuid end, 20)
    settled()
    if mine.yaknigi_hidden ~= true then fail("the highlight does not know it is private") end

    -- A note written here. A highlight made public on the phone stays public, and this device hears.
    mock_get("/test/note_edit?hidden=0&uuid=" .. sent.uuid)
    mine.note = "Заметка с киндла"
    modified(mine, { nb_highlights_added = -1, nb_notes_added = 1 })
    wait("the note at Yandex", function() return at_server(sent.uuid).comment == "Заметка с киндла" end, 20)
    if at_server(sent.uuid).permanent_hidden then fail("a public highlight turned private") end
    if at_server(sent.uuid).color ~= 2 then fail("the colour changed") end
    settled()
    if mine.yaknigi_hidden ~= false then fail("the phone's privacy did not come") end

    -- A tap on it: its privacy changes, there too.
    local function index_of(item)
        for i, one in ipairs(ui.annotation.annotations) do
            if one == item then return i end
        end
    end
    ui.highlight:showChooseHighlightDialog({ index_of(mine) })
    wait("the highlight's dialog", is_named("yaknigi_highlight"))
    UIManager:forceRePaint()
    shot("81-highlight-dialog")
    tap_widget(top().buttontable:getButtonById("private"))
    wait("the privacy at Yandex", function() return at_server(sent.uuid).permanent_hidden end, 20)
    settled()
    if mine.yaknigi_hidden ~= true then fail("the tap did not change the highlight") end

    -- A bookmark here.
    ui.bookmark:onToggleBookmark()
    local mark = wait("the bookmark at Yandex", function()
        for _, note in ipairs(server().notes) do
            if note.kind_here == "bookmark" then return note end
        end
    end, 20)
    if not mark.cfi:find("^/6/" .. (spine + 1) * 2 .. "!,/") then fail("the bookmark's place: " .. mark.cfi) end
    if mark.content == "" or mark.content:find("^%s") then fail("no words with the bookmark") end
    wait("the bookmark to be linked", function() return by_uuid(mark.uuid) end, 20)
    settled()

    -- Written on the phone, and coming here.
    local _, _, phone_words, phone_cfi = place(50, 90)
    local function add(kind, what_cfi, content, comment)
        return mock_get(("/test/note_add?kind=%s&book=%s&cfi=%s&content=%s%s"):format(kind, BOOK,
            url_encode(what_cfi), url_encode(content or ""), comment and "&comment=" .. url_encode(comment) or ""))
    end
    local phone_quote = add("quote", phone_cfi, phone_words, "С телефона")
    local phone_mark = add("bookmark", select(4, place(1, 1, 4)), "Н")
    local elsewhere = add("quote", select(4, place(100, 120)), "совсем другие слова")
    -- A private one, over several paragraphs, as the phone's was.
    local across_first = Cfi.to_point(html, number, "/2/4/2/4/1:5")
    local across_last = Cfi.to_point(html, number, "/2/4/2/10/1:20")
    local across = add("quote", Cfi.make_range(spine, "/2/4/2/4/1:5", "/2/4/2/10/1:20"),
        doc:getTextFromXPointers(across_first, across_last))
    mock_get("/test/note_edit?hidden=1&uuid=" .. across.uuid)
    -- From a first letter in its own element, as the phone's was: non-breaking spaces at Yandex
    -- are plain ones, so the words there are not the same bytes as those in the book.
    local capital_first = Cfi.to_point(html, number, "/2/4/2/18/2/1:0")
    local capital_last = Cfi.to_point(html, number, "/2/4/2/20/1:20")
    local capital_words = doc:getTextFromXPointers(capital_first, capital_last)
    if not capital_words:find("^Глава %d+, абзац 7%.\194\160") then
        fail("crengine's words from a first letter: " .. #capital_words .. " bytes")
    end
    local capital = add("quote", Cfi.make_range(spine, "/2/4/2/18/2/1:0", "/2/4/2/20/1:20"),
        (capital_words:gsub("\194\160", " ")))
    compare()
    if not by_uuid(capital.uuid) then fail("the highlight from a first letter did not come") end
    local got = by_uuid(phone_quote.uuid)
    if not got then fail("the phone's highlight did not come") end
    if got.note ~= "С телефона" or got.text ~= phone_words or not got.drawer then fail("what came of a highlight") end
    if doc:getTextFromXPointers(got.pos0, got.pos1) ~= phone_words then fail("the highlight came to other words") end
    if not by_uuid(phone_mark.uuid) then fail("the phone's bookmark did not come") end
    if by_uuid(elsewhere.uuid) then fail("a note whose words are not at its place was put there") end
    if got.yaknigi_hidden ~= false then fail("a public highlight from the phone came as private") end
    local private_here = by_uuid(across.uuid)
    if not private_here then fail("the private highlight over several paragraphs did not come") end
    if private_here.yaknigi_hidden ~= true then fail("it came as public") end
    if not at_server(across.uuid).permanent_hidden then fail("it was made public at Yandex") end
    compare()
    if not at_server(elsewhere.uuid) then fail("a note not placed here was deleted at Yandex") end
    mock_get("/test/note_remove?uuid=" .. elsewhere.uuid)
    UIManager:forceRePaint()
    shot("80-notes-from-phone")

    -- The lock in the list changes that highlight alone.
    UIManager:show(require("yaknigi/notes"):new{ ui = ui, shell = plugin.shell })
    wait("the list of notes", is_named("YaknigiNotes"))
    local list = top()
    settled()
    UIManager:forceRePaint()
    shot("82-notes-privacy")
    local first_highlight
    for _, item in ipairs(ui.annotation.annotations) do
        if item.drawer then first_highlight = item; break end
    end
    local was, others = first_highlight.yaknigi_hidden, {}
    for _, note in ipairs(server().notes) do others[note.uuid] = note.permanent_hidden end
    tap_widget(list.locks[1])
    wait("the lock's change at Yandex", function()
        return at_server(first_highlight.yaknigi).permanent_hidden == not was
    end, 20)
    settled()
    if first_highlight.yaknigi_hidden ~= not was then fail("the lock did not change the highlight") end
    for _, note in ipairs(server().notes) do
        if note.uuid ~= first_highlight.yaknigi and note.permanent_hidden ~= others[note.uuid] then
            fail("the lock changed another note")
        end
    end
    list:close()
    wait("the book after the list", function() return top().name == "ReaderUI" end)

    -- Nothing has changed: nothing is written.
    local writes, made = server().writes, server().made
    compare()
    if server().writes ~= writes or server().made ~= made then fail("a comparison with no news wrote to Yandex") end

    -- No list to be had: nothing happens at either end, and it goes through later.
    mock_get("/test/fail_notes?n=2")
    local count_here = #here()
    plugin:syncNotes()
    settled()
    if #here() ~= count_here or not plugin.notes_dirty then fail("a failed comparison") end
    mock_get("/test/fail_notes?n=0")

    -- A comment changed on the phone.
    mock_get("/test/note_edit?comment=" .. url_encode("Другой текст") .. "&uuid=" .. phone_quote.uuid)
    compare()
    if got.note ~= "Другой текст" then fail("the phone's comment did not come: " .. tostring(got.note)) end

    -- Deleted on the phone.
    mock_get("/test/note_remove?uuid=" .. phone_quote.uuid)
    mock_get("/test/note_remove?uuid=" .. phone_mark.uuid)
    mock_get("/test/note_remove?uuid=" .. across.uuid)
    mock_get("/test/note_remove?uuid=" .. capital.uuid)
    compare()
    if by_uuid(phone_quote.uuid) or by_uuid(phone_mark.uuid) then fail("what the phone deleted stays") end

    -- Deleted here.
    ui.bookmark:removeItem(by_uuid(sent.uuid))
    wait("the highlight to go from Yandex", function() return not at_server(sent.uuid) end, 20)
    settled()
    ui.bookmark:onToggleBookmark()
    wait("the bookmark to go from Yandex", function() return not at_server(mark.uuid) end, 20)
    settled()
    if #server().notes ~= 0 or #here() ~= 0 then fail("something is left: " .. #server().notes .. " and " .. #here()) end

    -- The book closed at once: goes all the same, and is not sent twice the next time.
    local a, b, late_words = place(120, 150)
    local late = { page = a, pos0 = a, pos1 = b, text = late_words, drawer = "lighten", color = "gray", note = "Вдогонку" }
    -- With the setting off, a new highlight is public.
    G_reader_settings:saveSetting("yaknigi_private_notes", false)
    modified(late, { nb_notes_added = 1, index_modified = ui.annotation:addItem(late) })
    ui:onHome()
    local away = wait("the highlight sent on closing", function() return server().notes[1] end, 20)
    if away.permanent_hidden then fail("with the setting off a new highlight went as private") end
    G_reader_settings:delSetting("yaknigi_private_notes")
    wait("the library after the book", function() return top().item_table and top() end)
    open_it()
    ui = reader()
    plugin, doc = ui.yaknigi, ui.document
    wait("the note to know itself", function() return by_uuid(away.uuid) end, 30)
    settled()
    if #server().notes ~= 1 or #here() ~= 1 then fail("sent twice: " .. #server().notes .. " and " .. #here()) end

    -- Linked and remembered after reopening: a comment changed on the phone still comes.
    mock_get("/test/note_edit?comment=" .. url_encode("Снова") .. "&uuid=" .. away.uuid)
    ui:onHome()
    wait("the library again", function() return top().item_table and top() end)
    open_it()
    ui = reader()
    plugin, doc = ui.yaknigi, ui.document
    wait("the comment after reopening", function()
        local item = by_uuid(away.uuid)
        return item and item.note == "Снова"
    end, 30)
    settled()
    ui.bookmark:removeItem(by_uuid(away.uuid))
    wait("the last note to go", function() return #server().notes == 0 end, 20)
    settled()
    ui:onHome()
    tap_widget(wait("the library in the end", function() return top().item_table and top() end).tab_cells.settings)
    wait("the settings after the notes", is_named("YaknigiSettings"))
    UIManager:forceRePaint()
    say("notes go both ways")
end

local function test_books_and_memory(settings)
    local lfs = require("libs/libkoreader-lfs")
    local books = require("datastorage"):getDataDir() .. "/yaknigi/books"
    local function exists(path) return lfs.attributes(path) ~= nil end
    local function count(name) return #mock_get("/test/" .. name)[name] end
    local function to_library()
        tap_widget(top().tab_cells.library)
        return wait("the library", function() return top().item_table and top().view == "home" and top() end)
    end
    local menu = to_library()

    -- In the results: not yet in the library, a plus.
    menu:search("достоевский")
    wait("the results", function() return menu.view == "catalogue" and #menu.rows > 0 end)
    local item
    for _, row in ipairs(menu.rows) do
        if not row.in_library and not menu:inLibrary(row) and row.card.book.uuid ~= "found-denied" then
            item = row
            break
        end
    end
    if not item then fail("no book outside the library on the first page") end
    -- Found again, with the covers here from the first time.
    for _, row in ipairs(menu.rows) do
        if not row.cover then fail("a cover that is here is not shown: " .. row.title) end
    end
    local id = item.card.book.uuid
    local added_before = count("added")
    UIManager:forceRePaint()
    shot("56-row-plus")
    tap_widget(menu.row_buttons[item])
    wait("the book to be added", function() return item.in_library and menu:inLibrary(item) end)
    if count("added") ~= added_before + 1 then fail("the plus did not add the book once") end
    if top() ~= menu and not top().toast then fail("the plus opened something: " .. tostring(top().name)) end
    if menu.view ~= "catalogue" then fail("the plus left the results: " .. menu.view) end
    UIManager:forceRePaint()
    shot("57-row-added-toast")
    if exists(books .. "/" .. id .. "/state") then fail("the plus saved the book") end

    -- In the library: it can be saved.
    tap_widget(menu.row_buttons[item])
    wait("the book to be saving", function() return menu.book_status(item) == "saving" end)
    UIManager:forceRePaint()
    shot("58-row-saving")
    wait("the book to be saved", function() return menu.book_status(item) == "whole" end, 60)
    if not exists(books .. "/" .. id .. "/book.epub") then fail("a saved book with no file") end
    UIManager:forceRePaint()
    shot("59-row-saved")
    local card = menu:inLibrary(item).card

    -- It opens from what was saved, and is read to somewhere for the place to be kept.
    menu:onMenuSelect(item)
    wait("the saved book to open", function()
        return reader() and reader().document and top().name == "ReaderUI"
            and reader().document.file:find("/" .. id .. "/", 1, true)
    end)
    reader().rolling:onGotoXPointer("/body/DocFragment[5]")
    if fragment() ~= 5 then fail("the jump in the saved book: " .. tostring(fragment())) end
    reader():onHome()
    menu = wait("the results after reading", function()
        local w = top()
        return w.item_table and w.view == "catalogue" and w
    end)
    UIManager:forceRePaint()

    -- Saved: a check, and the menu takes it off the device with the place in it left alone.
    local place = books .. "/" .. id .. "/to_send"
    local f = io.open(place, "w")
    f:write("a place to send")
    f:close()
    tap_widget(menu.row_buttons[item])
    wait("the book's menu", is_named("YaknigiBookMenu"))
    UIManager:forceRePaint()
    shot("60-book-menu-saved")
    local sheet = top()
    if not sheet.rows.remove_device or sheet.rows.save then fail("what the menu has for a saved book") end
    tap_widget(sheet.rows.remove_device)
    wait("the book to leave the device", function() return not menu.book_status(item) and top().name ~= "YaknigiBookMenu" end)
    if exists(books .. "/" .. id .. "/book.epub") then fail("the book is still on the device") end
    if not exists(place) or not exists(books .. "/" .. id .. "/manifest.json") then
        fail("taking the text off took what was not text")
    end
    os.remove(place)

    -- And reads again, from Yandex.
    menu:onMenuSelect(item)
    wait("the book to open again", function()
        return reader() and reader().document and top().name == "ReaderUI"
            and reader().document.file:find("/" .. id .. "/", 1, true)
    end)
    wait("the place in the book to be kept", function() return fragment() == 5 end)
    say("the place survived taking the book off the device")
    reader():onHome()
    menu = wait("the library again", function() return top().item_table and top() end)
    menu = to_library()

    -- A book of the library has dots, and the menu of a book not saved offers to save it.
    menu:openShelf("all")
    wait("the shelf", function() return #menu.rows > 0 end)
    local row
    for _, candidate in ipairs(menu.rows) do
        if candidate.card.uuid == card.uuid then row = candidate end
    end
    row = row or menu.rows[1]
    local gone = row.card
    UIManager:forceRePaint()
    shot("61-rows-dots")
    tap_widget(menu.row_buttons[row])
    wait("the book's menu in the library", is_named("YaknigiBookMenu"))
    sheet = top()
    if not sheet.rows.about or not sheet.rows.save or not sheet.rows.remove_library then
        fail("what the menu has for a book not saved")
    end
    UIManager:forceRePaint()
    shot("62-book-menu")
    tap_widget(sheet.rows.about)
    wait("about the book", is_named("YaknigiBookCard"))
    UIManager:forceRePaint()
    shot("63-book-menu-about")
    tap_widget(top().back_button)
    wait("back from about", function() return top() == menu end)
    -- A tap outside takes the sheet away and opens nothing.
    tap_widget(menu.row_buttons[row])
    wait("the menu once more", is_named("YaknigiBookMenu"))
    UIManager:forceRePaint()
    tap_at(math.floor(Screen:getWidth() / 2), 5)
    wait("the menu to go", function() return top() == menu end)
    if reader() and reader().document then fail("a tap outside the menu opened the book") end

    tap_widget(menu.row_buttons[row])
    wait("the menu to remove from", is_named("YaknigiBookMenu"))
    UIManager:forceRePaint()
    local cards_before = #menu.item_table
    local removed_before = count("removed")
    tap_widget(top().rows.remove_library)
    wait("the question", function() return top().ok_callback end)
    UIManager:forceRePaint()
    shot("64-remove-confirm")
    answer(top(), true)
    wait("the book to leave the library", function() return #menu.item_table == cards_before - 1 end)
    if count("removed") ~= removed_before + 1 then fail("Yandex was not told") end
    if mock_get("/test/removed").removed[removed_before + 1] ~= gone.uuid then fail("another book was removed") end
    UIManager:forceRePaint()
    shot("65-removed")

    -- A book to save again, for the memory to have it.
    local keep = menu.rows[1]
    for _, candidate in ipairs(menu.rows) do
        if menu.book_status(candidate) ~= "whole" then keep = candidate end
    end
    if menu.book_status(keep) ~= "whole" then
        tap_widget(menu.row_buttons[keep])
        wait("the menu to save from", is_named("YaknigiBookMenu"))
        UIManager:forceRePaint()
        tap_widget(top().rows.save)
        wait("the kept book to be saved", function() return menu.book_status(keep) == "whole" end, 60)
    end
    local keep_dir = books .. "/" .. keep.card.book.uuid

    -- The memory: by default everything but the saved books.
    tap_widget(menu.tab_cells.settings)
    settings = wait("the settings", is_named("YaknigiSettings")) and top()
    settings.rows.clear_cache.callback()
    wait("what things take", function() return settings.cache.sizes and settings.cache.sizes.books_count end)
    if settings.cache.sizes.books_count < 1 or settings.cache.sizes.books <= 0 then fail("the saved book is not counted") end
    if settings.cache.picks.books then fail("the saved books go by default") end
    UIManager:forceRePaint()
    shot("66-clear-cache")
    local covers = require("datastorage"):getDataDir() .. "/yaknigi/covers"
    tap_widget(settings.clear_button)
    wait("the clearing", function() return settings.cache.freed end)
    if not exists(keep_dir .. "/book.epub") then fail("clearing took the saved book") end
    if not exists(require("datastorage"):getDataDir() .. "/cache/cr3cache") then
        fail("clearing took the engine's directory")
    end
    if not exists(covers) then fail("clearing took the covers' directory") end
    wait("what things now take", function() return settings.cache.sizes and settings.cache.sizes.books_count end)
    UIManager:forceRePaint()
    shot("67-cleared")

    -- And with the saved books, after asking.
    wait("the word about what was freed to go", function() return top() == settings end)
    tap_widget(settings.cache_rows.books)
    if not settings.cache.picks.books then fail("the switch of the saved books") end
    settings.cache.freed = nil
    tap_widget(settings.clear_button)
    wait("the question about saved books", function() return top().ok_callback end)
    if exists(keep_dir .. "/book.epub") == false then fail("cleared before asking") end
    answer(top(), true)
    wait("the books to go", function() return settings.cache.freed end)
    if exists(keep_dir .. "/book.epub") then fail("the saved book stayed") end
    if not exists(keep_dir .. "/manifest.json") then fail("the saved book's place went with it") end

    -- A book opens after all that.
    wait("the second word about what was freed to go", function() return top() == settings end)
    menu = to_library()
    menu:openShelf("all")
    wait("the shelf after clearing", function() return #menu.rows > 0 end)
    wait("the book's mark to go", function() return not menu.book_status(keep) end)
    menu:onMenuSelect(menu.rows[1])
    wait("a book to open after clearing", function()
        return reader() and reader().document and top().name == "ReaderUI"
    end)
    UIManager:forceRePaint()
    shot("68-open-after-clearing")
    reader():onHome()
    wait("the library at last", function() return top().item_table and top() end)
    UIManager:forceRePaint()
    tap_widget(top().tab_cells.settings)
    wait("the settings at last", is_named("YaknigiSettings"))
    UIManager:forceRePaint()
    if top().pages then
        for _ = 2, top().pages do
            tap_widget(top().pager_next)
            UIManager:forceRePaint()
        end
    end
end

--- A book marked as read and unmarked; what Yandex refuses is said, not assumed.
local function test_finished(plugin)
    local json = require("rapidjson")
    local Session = require("yaknigi/session")
    local root = require("datastorage"):getDataDir() .. "/yaknigi"
    local dir = root .. "/books/book0"
    local function cached()
        local f = io.open(root .. "/library.json", "rb")
        local cards = json.decode(f:read("*a"))
        f:close()
        for _, card in ipairs(cards) do
            if card.uuid == "card0" then return card end
        end
        fail("no card0 in the library's list")
    end
    local function menu()
        local card = cached()
        plugin:showBookMenu({ title = card.book.title, authors = "", card = card })
        wait("the book's menu", is_named("YaknigiBookMenu"))
        UIManager:forceRePaint()
        return top()
    end

    -- A position waiting to go keeps its time, but no longer says what state the book is in.
    local Sync = require("yaknigi/sync")
    local aside = root .. "/forget-state-test"
    require("libs/libkoreader-lfs").mkdir(aside)
    local f = io.open(aside .. "/to_send", "wb")
    f:write(json.encode({ state = "reading", start = "x", timespent = 1000 }))
    f:close()
    Sync.forget_state(aside)
    f = io.open(aside .. "/to_send", "rb")
    local waiting = json.decode(f:read("*a"))
    f:close()
    if waiting.state ~= nil then fail("a position waiting would undo the mark") end
    if waiting.timespent ~= 1000 or waiting.start ~= "x" then fail("the position waiting lost something") end
    os.remove(aside .. "/to_send")
    os.remove(aside)

    if cached().state ~= "reading" then fail("card0 to begin with: " .. tostring(cached().state)) end
    local progress = cached().progress
    local sheet = menu()
    shot("70-book-menu-finished")
    tap_widget(sheet.rows.finished)
    wait("the book marked", function() return cached().state == "finished" end)
    if mock_get("/test/marks").card0 ~= "finished" then fail("Yandex was not told of the mark") end
    if tonumber(cached().progress) ~= tonumber(progress) then fail("the mark changed what was read") end
    if select(2, Session.read_card(dir)) ~= "finished" then fail("the book's own note of the state") end

    -- The mark on the covers of read books, at the sizes they are shown in: from the dock's
    -- and the list's, with a corner, to the shelves' and the book card's, with the ribbon.
    local Library = require("yaknigi/library")
    local lfs = require("libs/libkoreader-lfs")
    local picture
    for name in lfs.dir(root .. "/covers") do
        if name:sub(1, 1) ~= "." and not picture then picture = root .. "/covers/" .. name end
    end
    local read = { title = "Книга", cover = picture, card = { state = "finished" } }
    local tags = require("ui/widget/horizontalgroup"):new{ align = "top" }
    for _, side in ipairs { 40, 56, 73, 100, 126 } do
        local w = Screen:scaleBySize(side)
        local box = Library.cover_box(read, w, math.floor(w * 3 / 2))
        if box.name ~= "YaknigiReadTag" then fail("no mark on a cover of " .. side) end
        tags[#tags + 1] = box
        tags[#tags + 1] = require("ui/widget/horizontalspan"):new{ width = Screen:scaleBySize(10) }
    end
    if Library.cover_box({ title = "Книга", cover = picture, card = { state = "reading" } }, Screen:scaleBySize(100), Screen:scaleBySize(150)).name == "YaknigiReadTag" then
        fail("a mark on a book not read")
    end
    local tag_sheet = require("ui/widget/container/framecontainer"):new{
        background = require("ffi/blitbuffer").COLOR_WHITE, bordersize = 0, padding = Screen:scaleBySize(10),
        margin = 0, require("ui/widget/container/centercontainer"):new{
            dimen = require("ui/geometry"):new{ w = Screen:getWidth() - 2 * Screen:scaleBySize(10), h = Screen:getHeight() - 2 * Screen:scaleBySize(10) },
            tags,
        },
    }
    UIManager:show(tag_sheet)
    UIManager:forceRePaint()
    shot("70a-read-ribbons")
    UIManager:close(tag_sheet)
    UIManager:forceRePaint()

    -- Yandex answers yes and does nothing.
    mock_get("/test/ignore_state?on=1")
    sheet = menu()
    shot("71-book-menu-unmark")
    tap_widget(sheet.rows.finished)
    wait("the refusal of the mark", function() return (top().text or ""):find("не приняли", 1, true) end)
    shot("72-mark-not-taken")
    UIManager:close(top())
    if cached().state ~= "finished" then fail("a mark not taken changed the library") end
    mock_get("/test/ignore_state?on=0")

    sheet = menu()
    tap_widget(sheet.rows.finished)
    wait("the mark off", function() return cached().state == "reading" end)
    if mock_get("/test/marks").card0 ~= "reading" then fail("Yandex was not told the mark is off") end
    if tonumber(cached().progress) ~= tonumber(progress) then fail("taking the mark off moved the progress") end
    UIManager:forceRePaint()
end

--- What is said of a book Yandex will not open, by what the subscription says.
local function test_no_access(plugin)
    local Catalogue = require("yaknigi/catalogue")
    -- The way here from a refused book is gone through in the catalogue's test.
    local function denied() plugin:showNoAccess("Книга вне подписки") end
    local function screen_says(verdict, name)
        wait("the refusal: " .. verdict, is_named("YaknigiNoAccess"))
        if top().verdict ~= verdict then fail("the refusal says " .. tostring(top().verdict) .. ", not " .. verdict) end
        shot(name)
        tap_widget(top().close_button)
        wait("the refusal closed", function() return top().name ~= "YaknigiNoAccess" end)
    end
    mock_get("/test/access?mode=none")
    denied()
    screen_says("none", "73-no-subscription")
    mock_get("/test/access?mode=active")
    denied()
    screen_says("active", "74-not-in-subscription")
    mock_get("/test/access?mode=fail")
    denied()
    screen_says("unknown", "75-subscription-unknown")
    mock_get("/test/access?mode=active")
    -- What the list already says cannot be read goes the same way; audio has its own words.
    plugin:openItem({ title = "Книга вне подписки", unavailable = Catalogue.UNAVAILABLE })
    screen_says("active", "76-unavailable-in-list")
    plugin:openItem({ title = "Аудио", unavailable = "Эта книга есть только в аудио: здесь её не прочитать." })
    wait("the word about audio", function() return (top().text or ""):find("аудио", 1, true) end)
    UIManager:close(top())
    UIManager:forceRePaint()
end

--- Ending as it does in the real thing short of the restart, which would end the test run.
local function test_updates(plugin)
    local http = require("socket.http")
    local Updater = require("yaknigi/updater")
    local update_dir = require("datastorage"):getDataDir() .. "/yaknigi/update"
    local base = os.getenv("YB_OAUTH_BASE")
    local function info(text)
        local w = wait("the message: " .. text, function()
            local t = top()
            return t.text and tostring(t.text):find(text, 1, true) and t
        end)
        return w
    end

    if not Updater.enabled() then fail("updates are off in a numbered version") end
    plugin:showSettings()
    local settings = wait("the settings", function()
        local w = top()
        return w.name == "YaknigiSettings" and w
    end)
    UIManager:forceRePaint()
    for _ = 2, settings.pages or 1 do
        tap_widget(settings.pager_next)
        UIManager:forceRePaint()
    end
    if not settings.rows.terms or not settings.rows.version then fail("no «О программе» in the settings") end
    shot("40-settings-about")

    local AppState = require("yaknigi/appstate")
    local function offer()
        return wait("the offer", function()
            local t = top()
            return t.name == "YaknigiUpdateOffer" and t
        end)
    end
    local function press(box, which)
        box[which .. "_callback"]()
        UIManager:close(box)
    end

    -- Nothing is out.
    plugin:checkUpdates(true)
    UIManager:close(info("последняя версия"))

    -- A later KOReader or launcher: only a new install will do.
    http.request(base .. "/test/update?mode=manual")
    plugin:checkUpdates(true)
    UIManager:close(info("вручную"))
    if Updater.pending(update_dir) then fail("an update for another base waits to be installed") end
    AppState:delSetting("update_skipped")

    -- Nothing is fetched before the answer, and to be reminded leaves everything as it was.
    http.request(base .. "/test/update?mode=good")
    plugin:checkUpdates(true)
    local box = offer()
    shot("41-update-offer")
    if Updater.pending(update_dir) then fail("the update came before it was asked for") end
    press(box, "choice1")
    if AppState:readSetting("update_skipped") then fail("«later» counted as skipping") end

    -- A skipped version is not offered by itself, but is on asking.
    plugin:checkUpdates(true)
    press(offer(), "choice2")
    if AppState:readSetting("update_skipped") ~= "9.9.9" then fail("the version was not skipped") end
    AppState:delSetting("update_checked")
    plugin:autoUpdate()
    wait("the daily check", function() return AppState:readSetting("update_checked") end)
    if top().name == "YaknigiUpdateOffer" then fail("a skipped version was offered") end

    -- The switch stops the daily check, and only that.
    AppState:saveSetting("check_updates", false)
    AppState:delSetting("update_checked")
    plugin:autoUpdate()
    UIManager:forceRePaint()
    if AppState:readSetting("update_checked") then fail("it checked with the checking off") end
    AppState:delSetting("check_updates")

    -- What came is not what the manifest promised: nothing is left to install.
    local apply, restart = Updater.apply, UIManager.restartKOReader
    local applied, restarted = false, false
    Updater.apply = function() applied = true end
    UIManager.restartKOReader = function() restarted = true end
    http.request(base .. "/test/update?mode=corrupt")
    plugin:checkUpdates(true)
    press(offer(), "cancel")
    UIManager:close(info("Не удалось загрузить"))
    if Updater.pending(update_dir) then fail("a corrupt update waits to be installed") end
    if applied or restarted then fail("a corrupt update was installed") end

    -- A good one, through a redirect: fetched, put in place, and the app restarts.
    http.request(base .. "/test/update?mode=good")
    plugin:checkUpdates(true)
    press(offer(), "cancel")
    wait("the restart", function() return restarted end)
    Updater.apply, UIManager.restartKOReader = apply, restart
    if not applied then fail("the update was not put in place") end
    if Updater.pending(update_dir) ~= "9.9.9" then fail("the update is not waiting") end
    local f = io.open(update_dir .. "/pending/yaknigi.koplugin/main.lua")
    if not f then fail("the update was not unpacked") end
    f:close()
    os.execute("rm -rf '" .. update_dir .. "'")

    -- The terms, in the settings.
    wait("the settings on top", function() return top() == settings end)
    UIManager:forceRePaint()
    tap_widget(settings_row(settings, "terms"))
    local terms = top()
    if terms.name ~= "YaknigiTerms" then fail("the terms do not open from the settings") end
    if terms.accept_button then fail("the terms ask again") end
    tap_widget(terms.close_button)
    if top() ~= settings then fail("the settings are not back after the terms") end
    UIManager:close(settings)
end

-- The panel from the top: a swipe down anywhere, the radios, the theme, sync and settings.
local function test_shade(where)
    local NetworkMgr = require("ui/network/manager")
    -- Under a toast (the sync's word) the panel is not the topmost widget.
    local function shown()
        for _, window in ipairs(UIManager._window_stack) do
            if window.widget.name == "YaknigiShade" then return window.widget end
        end
    end
    local below = top()
    local page = below.page
    local W, H = Screen:getWidth(), Screen:getHeight()
    -- A swipe as the detector gives it: with the direction.
    local function swipe(direction, from_y, to_y)
        UIManager:forceRePaint()
        local x = math.floor(W / 2)
        UIManager:sendEvent(Event:new("Gesture", {
            ges = "swipe", direction = direction, distance = math.abs(to_y - from_y),
            pos = Geom:new{ x = x, y = from_y, w = 0, h = 0 },
            end_pos = Geom:new{ x = x, y = to_y, w = 0, h = 0 },
            time = require("ui/time").now(),
        }))
        UIManager:forceRePaint()
    end
    local function pull() swipe("south", math.floor(H * 0.3), math.floor(H * 0.7)) end
    pull()
    -- What stood under it is not touched: a list is not turned back.
    local shade = wait("the panel in the " .. where, shown, 5)
    if page and below.page ~= page then fail("the swipe down turned the " .. where) end
    for _, id in ipairs({ "airplane", "wifi", "dark", "sync", "settings" }) do
        if not shade.tiles[id] then fail("no " .. id .. " on the panel in the " .. where) end
    end
    if shade.area.h >= H then fail("the panel covers the screen") end
    shot("60-shade-" .. where)
    -- A second swipe down does not bring a second panel.
    pull()
    local count = 0
    for _, window in ipairs(UIManager._window_stack) do
        if window.widget.name == "YaknigiShade" then count = count + 1 end
    end
    if count ~= 1 then fail("panels in the " .. where .. ": " .. count) end

    -- The radios, with KOReader's Wi-Fi as an emulator cannot have it.
    local saved = { NetworkMgr.isWifiOn, NetworkMgr.toggleWifiOn, NetworkMgr.toggleWifiOff }
    local wifi = true
    NetworkMgr.isWifiOn = function() return wifi end
    NetworkMgr.toggleWifiOn = function(_, done) wifi = true; if done then done() end end
    NetworkMgr.toggleWifiOff = function(_, done) wifi = false; if done then done() end end
    tap_widget(shade.tiles.airplane)
    if not shade.tiles.airplane.on or shade.tiles.wifi.on or wifi then fail("airplane mode did not turn on") end
    shot("61-shade-airplane-" .. where)
    tap_widget(shade.tiles.airplane)
    if shade.tiles.airplane.on or not shade.tiles.wifi.on or not wifi then fail("airplane mode did not turn off") end
    tap_widget(shade.tiles.wifi)
    if shade.tiles.wifi.on or shade.tiles.airplane.on then fail("Wi-Fi off is airplane mode") end
    tap_widget(shade.tiles.wifi)
    if not shade.tiles.wifi.on then fail("Wi-Fi did not turn back on") end
    NetworkMgr.isWifiOn, NetworkMgr.toggleWifiOn, NetworkMgr.toggleWifiOff = saved[1], saved[2], saved[3]

    -- The theme, and back.
    tap_widget(shade.tiles.dark)
    if not G_reader_settings:isTrue("night_mode") or not shade.tiles.dark.on then fail("no dark theme from the panel") end
    shot("62-shade-dark-" .. where)
    tap_widget(shade.tiles.dark)
    if G_reader_settings:isTrue("night_mode") then fail("the dark theme stays") end

    -- A swipe up puts it away, with what was under it as it was.
    swipe("north", math.floor(H * 0.7), math.floor(H * 0.3))
    wait("the panel gone in the " .. where, function() return top() == below end, 5)

    -- Sync goes; the settings open over what was there.
    pull()
    shade = wait("the panel again in the " .. where, shown, 5)
    tap_widget(shade.tiles.sync)
    wait("the panel gone for sync", function() return not shown() end, 5)
    pull()
    shade = wait("the panel for settings", shown, 5)
    tap_widget(shade.tiles.settings)
    local settings = wait("the settings from the panel", function()
        return top().name == "YaknigiSettings" and top()
    end, 5)
    shot("63-shade-settings-" .. where)
    UIManager:close(settings)
    wait("back from the settings", function() return top() == below end, 5)
end

local function script()
    local plugin = require("apps/filemanager/filemanager").instance.yaknigi
    if not plugin then fail("plugin is not loaded") end

    -- The terms come before anything else, and are asked for once.
    local terms = wait("the terms", function()
        local w = top()
        return w.name == "YaknigiTerms" and w
    end)
    shot("00-terms")
    if not terms.text.text:find("Неофициальный проект", 1, true) then fail("the terms have no text") end
    if not terms.text.text:find("Лицензии", 1, true) then fail("the terms do not end") end
    if require("yaknigi/terms").accepted() then fail("the terms count as accepted already") end
    local first_line = terms.text.text_widget.virtual_line_num
    terms:onSwipe(nil, { direction = "north" })
    if terms.text.text_widget.virtual_line_num == first_line then fail("the terms do not scroll") end
    shot("00a-terms-scrolled")
    tap_widget(terms.accept_button)
    if not require("yaknigi/terms").accepted() then fail("the terms were not accepted") end

    -- Sign-in: the QR, then the code. The mock checks PKCE against this challenge.
    local login = wait("the sign-in screen", function()
        local w = top()
        return w.name == "YaknigiLogin" and w.url:find("code_challenge=", 1, true) and w
    end)
    shot("01-login-qr")
    local challenge = login.url:match("code_challenge=([^&]+)")
    local http = require("socket.http")
    http.request(os.getenv("YB_OAUTH_BASE") .. "/challenge?c=" .. challenge)
    -- The keyboard is the topmost widget, above the dialog it belongs to.
    local function code_dialog(what)
        return wait(what, function()
            for _, window in ipairs(UIManager._window_stack) do
                if window.widget.getInputText then return window.widget end
            end
        end)
    end
    local function press(dialog, text)
        for _, b in ipairs(dialog.buttons[1]) do
            if b.text == text then return b.callback() end
        end
        fail("no button " .. text)
    end
    tap_widget(login.enter_button)
    local dialog = code_dialog("the code dialog")
    -- Back is back on the steps, and the steps lead to the same dialog.
    press(dialog, "Назад")
    wait("the steps again", function() return top().name == "YaknigiLogin" end)
    tap_widget(login.enter_button)
    dialog = code_dialog("the code dialog again")
    -- As long as Yandex's code really is. A code refused stays there to be corrected.
    dialog:setInputText("abcd1234efgh5678")
    shot("02-login-code")
    press(dialog, "Войти")
    local refused = wait("the code refused", function()
        for _, window in ipairs(UIManager._window_stack) do
            local w = window.widget
            if w.getInputText and w ~= dialog then return w end
        end
    end)
    if refused:getInputText() ~= "abcd1234efgh5678" then fail("the refused code is gone") end
    shot("02b-login-refused")
    refused:setInputText("abc123")
    press(refused, "Войти")
    wait("the sign-in screen closed", function()
        for _, window in ipairs(UIManager._window_stack) do
            if window.widget.name == "YaknigiLogin" then return false end
        end
        return true
    end)

    -- Library, with 21 books over 3 pages, most recent first.
    local menu = library_with(21)
    shot("03-library")
    if not menu.item_table[1].text:find("Книга номер 0", 1, true) then
        fail("library is not sorted by last read: " .. menu.item_table[1].text)
    end
    if menu.item_table[1].mandatory ~= "77%" then
        fail("no progress in the library: " .. tostring(menu.item_table[1].mandatory))
    end

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
    test_shade("library")

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
    test_shade("reader")
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
    wait("the refusal", is_named("YaknigiNoAccess"))
    if top().verdict ~= "active" then fail("the refusal with a subscription: " .. tostring(top().verdict)) end
    shot("24-catalogue-denied")
    tap_widget(top().close_button)
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
    if not settings.rows.private_notes then fail("no privacy of notes in the account section") end
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
    test_books_and_memory(settings)
    test_lists()
    test_notes()
    test_finished(plugin)
    test_no_access(plugin)
    test_updates(plugin)
    settings = top()
    local f = io.open(OUT .. "/PASS", "w")
    f:write("ok\n")
    f:close()
    say("PASS")
    -- The app ends where it says so, and the run would not end if it did not.
    tap_widget(settings.power)
    UIManager:forceRePaint()
    tap_widget(settings.power_dialog.buttontable:getButtonById("exit"))
end

--- In someone's own KOReader: the library is asked for from the menu, the reading screen stays
-- KOReader's, the place still goes to Yandex, and a new version is only told about.
-- A book of one's own goes to Yandex Books, from the library's plus or from the file browser.
local function test_own_books(plugin, menu)
    local lfs = require("libs/libkoreader-lfs")
    local books = require("datastorage"):getDataDir() .. "/test-books"
    lfs.mkdir(books)
    lfs.mkdir(books .. "/deep")
    local function put(path, data)
        local f = io.open(path, "wb")
        f:write(data)
        f:close()
    end
    local book = books .. "/deep/Своя книга.epub"
    put(book, "PK\3\4" .. ("своя книга "):rep(500))
    put(books .. "/notes.pdf", "%PDF-1.4")
    local home = G_reader_settings:readSetting("home_dir")
    G_reader_settings:saveSetting("home_dir", books)
    local function uploads() return mock_get("/test/uploads").uploads end
    local function sheet_with(key)
        return wait("the files to send", function()
            local w = top()
            return w.name == "YaknigiBookMenu" and w.rows[key] and w
        end)
    end
    local function shown(needle)
        for _, window in ipairs(UIManager._window_stack) do
            local text = window.widget.text
            if type(text) == "string" and text:find(needle, 1, true) then return window.widget end
        end
    end

    if not menu.upload_button then fail("no plus in the library") end
    tap_widget(menu.upload_button)
    local sheet = sheet_with("file:" .. book)
    if sheet.rows["file:" .. books .. "/notes.pdf"] then fail("a pdf offered to Yandex") end
    shot("p01a-own-books")
    tap_widget(sheet.rows["file:" .. book])
    local sent = wait("the book sent", function()
        local list = uploads()
        return list[#list] and list[#list].name and list[#list]
    end)
    if sent.name ~= "Своя книга.epub" or sent.type ~= "application/epub+zip" or sent.public ~= "false"
        or sent.start ~= "504b0304" or sent.size ~= lfs.attributes(book, "size") then
        fail("the book as sent: " .. require("rapidjson").encode(sent))
    end
    local told = wait("the word that it went", function() return shown("загружена в Яндекс Книги") end)
    shot("p01b-own-book-sent")
    UIManager:close(told)

    -- The same book again: Yandex has it, so it is not sent twice.
    local count = #uploads()
    tap_widget(menu.upload_button)
    tap_widget(sheet_with("file:" .. book).rows["file:" .. book])
    wait("the word that Yandex has it", function() return shown("уже есть в Яндекс Книгах") end)
    local list = uploads()
    if #list ~= count + 1 or not list[#list].checked then fail("the book was sent twice") end

    -- Held down in the file browser, an EPUB offers the same; a PDF does not.
    local added = require("apps/filemanager/filemanager").instance.file_dialog_added_buttons
    local row_func = added and added[added.index.yaknigi_upload]
    if not row_func then fail("no row in the file browser's dialog") end
    local row = row_func(book, true, {})
    if not row or row[1].text ~= "Загрузить в Яндекс Книги" then fail("the file browser's row") end
    if row_func(books .. "/notes.pdf", true, {}) or row_func(books, false, {}) then
        fail("the row for what Yandex does not take")
    end
    if home then G_reader_settings:saveSetting("home_dir", home) else G_reader_settings:delSetting("home_dir") end
    say("one's own book goes to Yandex once")
end

local function plugin_script()
    local FileManager = require("apps/filemanager/filemanager")
    local function plugin() return FileManager.instance and FileManager.instance.yaknigi end
    if not plugin() then fail("plugin is not loaded") end
    local function no_shade()
        for _, window in ipairs(UIManager._window_stack) do
            if window.widget.name == "YaknigiShade" then fail("the panel from the top in someone's KOReader") end
        end
    end
    local function swipe_down()
        local W, H = Screen:getWidth(), Screen:getHeight()
        UIManager:forceRePaint()
        UIManager:sendEvent(Event:new("Gesture", {
            ges = "swipe", direction = "south", distance = math.floor(H * 0.4),
            pos = Geom:new{ x = math.floor(W / 2), y = math.floor(H * 0.3), w = 0, h = 0 },
            end_pos = Geom:new{ x = math.floor(W / 2), y = math.floor(H * 0.7), w = 0, h = 0 },
            time = require("ui/time").now(),
        }))
        UIManager:forceRePaint()
    end

    -- KOReader's own file browser is what starts, and nothing of ours is over it.
    local t0 = socket.gettime()
    wait("a moment", function() return socket.gettime() - t0 > 2 end)
    if top() ~= FileManager.instance then fail("something over the file browser: " .. tostring(top().name)) end
    shot("p00-file-browser")
    local items = {}
    plugin():addToMainMenu(items)
    if not items.yaknigi then fail("no menu entry") end
    items.yaknigi.sub_item_table[1].callback()

    local terms = wait("the terms", function() return top().name == "YaknigiTerms" and top() end)
    tap_widget(terms.accept_button)
    local login = wait("the sign-in screen", function()
        local w = top()
        return w.name == "YaknigiLogin" and w.url:find("code_challenge=", 1, true) and w
    end)
    require("socket.http").request(os.getenv("YB_OAUTH_BASE") .. "/challenge?c=" .. login.url:match("code_challenge=([^&]+)"))
    tap_widget(login.enter_button)
    local dialog = wait("the code dialog", function()
        for _, window in ipairs(UIManager._window_stack) do
            if window.widget.getInputText then return window.widget end
        end
    end)
    dialog:setInputText("abc123")
    for _, b in ipairs(dialog.buttons[1]) do
        if b.text == "Войти" then b.callback() end
    end
    local menu = library_with(21)
    shot("p01-library")
    swipe_down()
    no_shade()
    test_own_books(plugin(), menu)

    -- KOReader's reading screen, and the place read sent all the same.
    local function position() return mock_get("/test/position?book=book0") end
    local before = position().writes
    open(menu, "Книга номер 0")
    local ui = reader()
    if not ui.yaknigi or ui.yaknigi.shell_installed then fail("the reading screen was taken over") end
    swipe_down()
    no_shade()
    for _ = 1, 3 do ui:handleEvent(Event:new("GotoViewRel", 1)) end
    UIManager:forceRePaint()
    shot("p02-reader")
    ui:onHome()
    wait("the file browser after the book", function() return FileManager.instance and top() == FileManager.instance end)
    wait("the place sent", function() return position().writes ~= before end, 20)
    say("the place goes to Yandex from KOReader's own reader")

    -- Only KOReader's own settings for the screen and sleep: none of ours.
    plugin():showLibrary()
    library_with(21)
    plugin():showSettings()
    local settings = wait("the settings", function() return top().name == "YaknigiSettings" and top() end)
    UIManager:forceRePaint()
    for _, key in ipairs({ "clock", "refresh", "sleep_screen", "sleep_time" }) do
        if settings.rows[key] then fail("an app's row in someone's KOReader: " .. key) end
    end
    for _ = 2, settings.pages or 1 do
        tap_widget(settings.pager_next)
        UIManager:forceRePaint()
    end
    if not settings.rows.check_updates then fail("no switch for looking for new versions") end
    shot("p03-settings")

    -- A new version is told about; nothing is fetched.
    local Updater = require("yaknigi/updater")
    if Updater.enabled() or not Updater.notify_only() then fail("the plugin would install updates itself") end
    require("socket.http").request(os.getenv("YB_OAUTH_BASE") .. "/test/update?mode=good")
    plugin():checkUpdates(true)
    local told = wait("the news of a version", function()
        return top().name == "YaknigiUpdateOffer" and top()
    end)
    if not tostring(told.text):find("yaknigi.koplugin.zip", 1, true) then fail("the news says not where to get it") end
    shot("p04-new-version")
    told.cancel_callback()
    UIManager:close(told)
    if require("yaknigi/appstate"):readSetting("update_skipped") ~= "9.9.9" and
        not require("yaknigi/appstate"):readSetting("update_skipped") then
        fail("«skip» was not kept")
    end
    if Updater.pending(require("datastorage"):getDataDir() .. "/yaknigi/update") then
        fail("an update was fetched in someone's KOReader")
    end

    -- The way out leads back to the file browser, and KOReader goes on.
    settings = wait("the settings again", function() return top().name == "YaknigiSettings" and top() end)
    tap_widget(settings.power)
    UIManager:forceRePaint()
    local buttons = settings.power_dialog.buttontable
    if buttons:getButtonById("off") then fail("turning the device off from someone's KOReader") end
    if buttons:getButtonById("exit").text ~= "Вернуться в KOReader" then fail("the way out is not named for KOReader") end
    tap_widget(buttons:getButtonById("exit"))
    wait("the file browser at the end", function() return FileManager.instance and top() == FileManager.instance end)
    shot("p05-back")
    local f = io.open(OUT .. "/PASS", "w")
    f:write("ok\n")
    f:close()
    say("PASS")
    UIManager:quit()
end

function Driver:init()
    if started or not OUT then return end
    started = true
    UIManager:scheduleIn(1, function()
        local co = coroutine.create(function()
            local run = os.getenv("YAKNIGI_APP") == "1" and script or plugin_script
            local ok, err = xpcall(run, debug.traceback)
            if not ok then fail(err) end
        end)
        local ok, err = coroutine.resume(co)
        if not ok then fail(err) end
    end)
    UIManager:scheduleIn(660, function() fail("the whole test timed out") end)
    logger.info("yaknigi test driver armed")
end

return Driver
