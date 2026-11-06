-- Drives the real KOReader UI through the plugin against the mock server, in CI.
-- Writes screenshots and timings to YAKNIGI_TEST_OUT and "PASS" there at the end;
-- any failure exits at once with a non-zero code.
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
