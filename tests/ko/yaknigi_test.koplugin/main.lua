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

local function is_named(name) return function() return top().name == name end end

local function find_item(menu, needle)
    for _, item in ipairs(menu.item_table) do
        if item.text:find(needle, 1, true) then return item end
    end
    fail("no book " .. needle)
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
local function test_reading_screen()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local doc = reader().document

    -- A plain page: no KOReader panel opens from any band of the screen.
    shot("10-reading")
    local page = doc:getCurrentPage()
    tap_at(W - 40, 40) -- top right, KOReader's menu band: turns the page
    wait("a page turn from the top band", function() return doc:getCurrentPage() == page + 1 end)
    if top().name ~= "ReaderUI" then fail("top band opened " .. tostring(top().name)) end
    tap_at(40, H - 40) -- bottom left, KOReader's settings band: turns back
    wait("a page back from the bottom band", function() return doc:getCurrentPage() == page end)
    if top().name ~= "ReaderUI" then fail("bottom band opened " .. tostring(top().name)) end

    -- The middle brings up the panels, a tap on the text takes them away.
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    local chrome = top()
    shot("11-chrome")
    tap_at(W / 2, H / 2)
    wait("the panels to close", is_named("ReaderUI"))

    -- Bookmark.
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    chrome = top()
    tap_widget(chrome.bookmark_button)
    if not reader().bookmark:isPageBookmarked() then fail("the bookmark was not set") end
    shot("12-chrome-bookmarked")
    tap_widget(chrome.bookmark_button)
    if reader().bookmark:isPageBookmarked() then fail("the bookmark was not removed") end

    -- Slider: a tap at the middle goes to the middle of the book.
    local pages = doc:getPageCount()
    tap_at(chrome.slider.dimen.x + math.floor(chrome.slider.width / 2), chrome.slider.dimen.y + 5)
    local now = doc:getCurrentPage()
    if math.abs(now - pages / 2) > pages * 0.02 then fail("slider went to " .. now .. " of " .. pages) end
    shot("13-chrome-slider")
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
    tap_at(W / 2, 100)
    wait("the page", is_named("ReaderUI"))

    -- Night mode, there and back.
    tap_at(W / 2, H / 2)
    wait("the panels", is_named("YaknigiChrome"))
    tap_widget(top().text_button)
    wait("the text panel", is_named("YaknigiTextPanel"))
    panel = top()
    tap_widget(panel.theme[2])
    if not G_reader_settings:isTrue("night_mode") then fail("night mode did not turn on") end
    shot("18-night")
    tap_widget(top().theme[1])
    if G_reader_settings:isTrue("night_mode") then fail("night mode did not turn off") end
    tap_at(W / 2, 100)
    wait("the page", is_named("ReaderUI"))
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
    tap_at(40, 40) -- the corner of the way back from a book: not a way out of the app
    UIManager:forceRePaint()
    if top() ~= menu then fail("a tap in the library's corner closed it") end
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

    -- Back to the library in app mode, reopen: nothing is fetched, and it is quick.
    reader():onHome()
    menu = wait("the library again", function()
        local w = top()
        return w.item_table and #w.item_table == 21 and w
    end)
    if not find_item(menu, "Книга номер 0").text:find("✓", 1, true) then fail("no mark on a whole book") end
    seconds = open(menu, "Книга номер 0")
    say(("second open: %.3fs"):format(seconds))
    n, xp = fragment()
    if n ~= 31 then fail("position lost after reopening: " .. tostring(xp)) end

    -- Reaching an unfetched chapter: a stub at first, then the real one.
    reader():onHome()
    menu = library_with(21)
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

    -- Text settings are one for all books, even a book with its own settings saved.
    G_reader_settings:saveSetting("copt_line_spacing", 130)
    reader():onHome()
    menu = library_with(21)
    open(menu, "Книга номер 0")
    if reader().document.configurable.line_spacing ~= 130 then
        fail("text settings are per book: " .. tostring(reader().document.configurable.line_spacing))
    end

    -- Leaving through the library's close button quits the app.
    reader():onHome()
    menu = library_with(21)
    local f = io.open(OUT .. "/PASS", "w")
    f:write("ok\n")
    f:close()
    say("PASS")
    menu:onClose()
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
    UIManager:scheduleIn(240, function() fail("the whole test timed out") end)
    logger.info("yaknigi test driver armed")
end

return Driver
