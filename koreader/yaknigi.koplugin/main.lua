--[[--
Yandex Books: sign in, browse the library and read, with books opening at once.

@module koplugin.yaknigi
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local QRMessage = require("ui/widget/qrmessage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local json = require("rapidjson")

local Api = require("yaknigi/api")
local Background = require("yaknigi/background")
local BookCard = require("yaknigi/bookcard")
local Catalogue = require("yaknigi/catalogue")
local Covers = require("yaknigi/covers")
local Cfi = require("yaknigi/cfi")
local Crypt = require("yaknigi/crypt")
local Feed = require("yaknigi/feed")
local Library = require("yaknigi/library")
local NoteSync = require("yaknigi/notesync")
local NotesLocal = require("yaknigi/notes_local")
local Prefs = require("yaknigi/prefs")
local Settings = require("yaknigi/settings")
local BookMenu = require("yaknigi/bookmenu")
local Storage = require("yaknigi/storage")
local Shelves = require("yaknigi/shelves")
local Session = require("yaknigi/session")
local Shell = require("yaknigi/shell")
local Store = require("yaknigi/store")
local Sync = require("yaknigi/sync")

local ROOT = DataStorage:getDataDir() .. "/yaknigi"
local BOOKS = ROOT .. "/books"
local COVERS = ROOT .. "/covers"
local LIBRARY_CACHE = ROOT .. "/library.json"
local LIBRARY_RESULT = ROOT .. "/library.result"
local CATALOGUE_RESULT = ROOT .. "/catalogue.result"
local FEED_CACHE = ROOT .. "/feed.json"
local FEED_RESULT = ROOT .. "/feed.result"
local TAKE_RESULT = ROOT .. "/take.result"
local ADD_RESULT = ROOT .. "/add.result"
local SAVE_RESULT = ROOT .. "/save.result"
local REMOVE_RESULT = ROOT .. "/remove.result"
local STORAGE_RESULT = ROOT .. "/storage.result"
os.execute("mkdir -p '" .. BOOKS .. "' '" .. COVERS .. "'")

-- The app mode shows the library instead of the file manager, and leaves with it.
local APP_MODE = os.getenv("YAKNIGI_APP") == "1"
local POLL_SECONDS = 2
local COVER_POLL_SECONDS = 1
local NOTES_AFTER_OPENING_SECONDS = 2
local NOTES_AFTER_CHANGE_SECONDS = 3
local NOTES_AFTER_WAKING_SECONDS = 10
-- Wi-Fi takes a while to come back after sleep. Pauses between tries to reach Yandex.
local WAKE_RETRY_SECONDS = { 5, 15, 30 }
-- Which screen of the library was open, for coming back to it from a book.
local library_place = {}
-- The library on the screen, for answers that arrive after the reader was opened and left.
local shown_library = nil
local catalogue_requests = 0
local feed_requests = 0
local add_requests = 0
local remove_requests = 0
local save_requests = 0
local storage_requests = 0
-- The books being saved on the device, by book id.
local saving = {}
-- The cards of the episodes, by book id: the library shows only the serial they are of.
local episode_cards = {}
-- What to open as soon as the library is back: the next episode, after the last one is closed.
local open_next = nil

-- KOReader quits when its last screen closes, which its own Exit and any failure to open
-- something would do. Only "Закрыть приложение" should end the app: go back to the library.
if APP_MODE then
    -- A crash or a dead battery should cost a minute of reading, not KOReader's usual 15.
    G_reader_settings:saveSetting("auto_save_settings_interval_minutes", 1)
    Prefs.init()

    UIManager._gated_quit = function(this)
        -- UIManager:quit() empties the stack too, and only sets the exit code first. That
        -- is someone asking to end the app, and they must get what they asked for.
        if this._exit_code then return true end
        logger.warn("yaknigi: no screens left, back to the library")
        require("apps/reader/readerui"):showFileManager()
        return false
    end

    -- Nothing of the picture is to stay on the page: a flash to white, then what was underneath.
    local Screensaver = require("ui/screensaver")
    local close_widget = Screensaver.close_widget
    Screensaver.close_widget = function(this)
        local shown = this.screensaver_widget ~= nil
        close_widget(this)
        if shown then
            Screen:clear()
            Screen:refreshFull(0, 0, Screen:getWidth(), Screen:getHeight())
            UIManager:setDirty("all", "full")
        end
    end
end

-- Survives the ReaderUI being rebuilt on reload. Keyed by book id.
local workers = {}
-- What is known of a book's cover from the card it was opened by. Keyed by book id.
local book_covers = {}

local Yaknigi = WidgetContainer:extend{
    name = "yaknigi",
    is_doc_only = false,
}

local function settings()
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/yaknigi.lua")
end

local function saved_token()
    return settings():readSetting("token")
end

local function save_token(token)
    local s = settings()
    if token then s:saveSetting("token", token) else s:delSetting("token") end
    s:flush()
end

local function message(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

local function opening_text(card)
    local title = card and card.book and card.book.title
    return title and title ~= "" and ("Открываю «" .. title .. "»") or "Открываю…"
end

-- What the reader says while the book is opened: the title, where KOReader says the file's path.
local opening_message = "Открываю…"
local function install_opening_message(ReaderUI)
    if ReaderUI.yaknigi_opening_message then return end
    ReaderUI.yaknigi_opening_message = true
    local show_coroutine = ReaderUI.showReaderCoroutine
    ReaderUI.showReaderCoroutine = function(this, file, provider, seamless)
        if not seamless then
            -- Its message is the first thing it shows, and only that is replaced.
            local show = UIManager.show
            UIManager.show = function(manager, widget, ...)
                UIManager.show = show
                widget:free()
                return show(manager, InfoMessage:new{ text = opening_message, timeout = 0.0 }, ...)
            end
        end
        return show_coroutine(this, file, provider, seamless)
    end
end

local function read_json(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    local ok, parsed = pcall(json.decode, data)
    return ok and parsed or nil
end

local function write_json(path, value)
    local f = io.open(path .. ".tmp", "wb")
    if not f then return end
    f:write(json.encode(value))
    f:close()
    os.rename(path .. ".tmp", path)
end

local function error_text(kind)
    if kind == "network" then return "Нет связи с Яндекс Книгами." end
    if kind == "not_found" then return "Эта книга не открывается." end
    if kind == "disk" then return "Не удалось записать на устройство." end
    return "Яндекс Книги вернули ошибку."
end

-- Sign-in ---------------------------------------------------------------------

function Yaknigi:showLogin()
    local verifier = Crypt.new_verifier()
    local url = Api.login_url(verifier)
    local dialog
    local function ask_code()
        G_reader_settings:saveSetting("keyboard_layout", "en") -- the code is in Latin letters
        dialog = InputDialog:new{
            title = "Вход в Яндекс",
            description = "Откройте ссылку из QR-кода на телефоне, войдите и введите код, который там появится.",
            input_hint = "Код",
            buttons = { {
                {
                    text = "Показать QR",
                    callback = function()
                        UIManager:close(dialog)
                        self:showLoginQr(url, ask_code)
                    end,
                },
                {
                    text = "Войти",
                    is_enter_default = true,
                    callback = function()
                        local code = dialog:getInputText():gsub("%s+", ""):lower()
                        if code == "" then return end
                        UIManager:close(dialog)
                        self:finishLogin(code, verifier, ask_code)
                    end,
                },
            } },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end
    self:showLoginQr(url, ask_code)
end

function Yaknigi:showLoginQr(url, on_dismiss)
    local side = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.8)
    UIManager:show(QRMessage:new{
        text = url,
        width = side,
        height = side,
        -- Runs while the QR is being closed; the dialog must not be shown from inside that.
        dismiss_callback = function() UIManager:nextTick(on_dismiss) end,
    })
end

function Yaknigi:finishLogin(code, verifier, retry)
    NetworkMgr:runWhenOnline(function()
        local token, kind = Api.exchange_code(code, verifier)
        if token then
            save_token(token)
            library_place = {} -- another account may have other books
            self:showLibrary()
            return
        end
        message(kind == "bad_code" and "Код не подошёл." or error_text(kind), 3)
        retry()
    end)
end

-- Library ---------------------------------------------------------------------

local function card_authors(card)
    local book = card.book or {}
    local authors = {}
    for _, a in ipairs(book.authors_objects or book.authors or {}) do
        if type(a) == "table" and a.name then authors[#authors + 1] = a.name end
    end
    return table.concat(authors, ", ")
end

local function book_dir(card)
    local id = card.book and card.book.uuid
    if type(id) ~= "string" or not id:match("^[%w_%-]+$") then return nil end
    return BOOKS .. "/" .. id
end

local function reading_here(card)
    local dir = book_dir(card)
    if not dir then return nil end
    return Session.read_reading(dir, card)
end

local function sorted_cards(cards)
    -- Latest read here or elsewhere first; books never opened go last.
    local function stamp(c)
        local _, here = reading_here(c)
        return math.max(tonumber(c.accessed_at) or 0, here or 0)
    end
    local ordered = {}
    for i, c in ipairs(cards) do ordered[i] = { card = c, index = i } end
    table.sort(ordered, function(a, b)
        local sa, sb = stamp(a.card), stamp(b.card)
        if sa ~= sb then return sa > sb end
        return a.index < b.index
    end)
    local out = {}
    for i, o in ipairs(ordered) do out[i] = o.card end
    return out
end

local function is_whole(card)
    -- Runs for every book on each refresh, so it only looks at the one file. Store.open
    -- would start a shell for each.
    local dir = book_dir(card)
    if not dir then return false end
    local f = io.open(dir .. "/state", "rb")
    if not f then return false end
    local state = f:read("*a")
    f:close()
    return state == "whole"
end

--- What is shown on its own, leaving out the episodes: there can be hundreds.
local function without_episodes(cards)
    local shown = {}
    for _, card in ipairs(cards) do
        if not (card.book and card.book.parent_uuid) then shown[#shown + 1] = card end
    end
    return shown
end

function Yaknigi:libraryItems(cards)
    local items = {}
    local saved_episode = {}
    episode_cards = {}
    for _, card in ipairs(cards) do
        local book = card.book
        if book and book.parent_uuid then
            episode_cards[book.uuid] = card
            saved_episode[book.parent_uuid] = saved_episode[book.parent_uuid] or is_whole(card)
        end
    end
    for _, card in ipairs(sorted_cards(without_episodes(cards))) do
        local here = reading_here(card)
        local progress = here or tonumber(card.progress)
        local title = card.book and card.book.title or "?"
        local serial = card.book and card.book.source_type == "serial"
        local whole = is_whole(card) or (serial and saved_episode[card.book.uuid]) or false
        local mandatory = progress and (here or progress > 0) and (math.floor(progress) .. "%") or nil
        local episode, episodes = tonumber(card.current_episode_position), serial and tonumber(card.book.episodes_count)
        if serial and episode and episodes then mandatory = "эп. " .. episode .. " из " .. episodes end
        items[#items + 1] = {
            kind = serial and "serial" or nil,
            percent = serial and progress or nil,
            text = (whole and "✓ " or "") .. title,
            title = title,
            authors = card_authors(card),
            mandatory = mandatory,
            shelf = Shelves.of(card.state, card.progress, here),
            whole = whole,
            cover = Covers.find(COVERS, card),
            card = card,
        }
    end
    return items
end

function Yaknigi:fetchCovers(cards)
    if not NetworkMgr:isOnline() then return end
    -- What was asked last is what is being looked at: it goes first, and all that was under
    -- way starts again behind it. A library's covers must not hold up a search's.
    local queue, seen = {}, {}
    for _, list in ipairs { cards, self.covers_queue or {} } do
        for _, card in ipairs(list) do
            local id = card.book and card.book.uuid
            if id and not seen[id] then
                seen[id] = true
                queue[#queue + 1] = card
            end
        end
    end
    self.covers_queue = queue
    if self.covers_pids then self:reapCovers(Covers.stop(self.covers_pids)) end
    self.covers_pids = Covers.fetch(COVERS, queue)
    -- Also with nothing to fetch: books found anew know nothing of the covers already here.
    self:scheduleCoverPoll(self.covers_pids)
end

--- A stopped process stays until it has been asked about.
function Yaknigi:reapCovers(pids)
    if Covers.done(pids) then return end
    UIManager:scheduleIn(COVER_POLL_SECONDS, function() self:reapCovers(pids) end)
end

-- Shows covers as they arrive, without touching the screen when none did.
function Yaknigi:scheduleCoverPoll(pids)
    UIManager:scheduleIn(COVER_POLL_SECONDS, function()
        -- Others have taken over from these.
        if pids ~= self.covers_pids or not self.library then return end
        local library = self.library
        local done = Covers.done(pids)
        local view = library.view
        local apart = view == "catalogue" or view == "collection" or view == "feed" or view == "feed_section"
        -- Only what is on the screen is worth redrawing it.
        local shown = {}
        for _, item in ipairs(library.rows or {}) do shown[item] = true end
        local changed = false
        local function look(item, matters)
            -- Also a preview in the place of a smaller cover from before.
            local cover = Covers.find(COVERS, item.card)
            if cover and cover ~= item.cover then
                item.cover = cover
                if matters then changed = true end
            end
        end
        for _, item in ipairs(library.item_table or {}) do
            look(item, not apart or item == library.dock_item)
        end
        if library.catalogue then
            for _, item in ipairs(library.catalogue.items) do look(item, shown[item]) end
        end
        if library.collection then
            for _, item in ipairs(library.collection.items) do look(item, shown[item]) end
        end
        if library.feed then
            for _, item in ipairs(Feed.items(library.feed)) do look(item, shown[item]) end
        end
        if changed then library:refreshScreen() end
        if done then
            self.covers_pids, self.covers_queue = nil, nil
        else
            self:scheduleCoverPoll(pids)
        end
    end)
end

function Yaknigi:signOut()
    UIManager:show(ConfirmBox:new{
        text = "Выйти из аккаунта Яндекса?",
        ok_callback = function()
            save_token(nil)
            library_place = {}
            os.remove(FEED_CACHE)
            self:showLibrary()
        end,
    })
end

--- The settings as a tab of the library.
function Yaknigi:showSettings()
    UIManager:show(Settings:new{
        ui = self.ui,
        on_sign_out = saved_token() and function() self:signOut() end or nil,
        storage = self:storageActions(),
        on_close_app = function()
            if self.library then self.library:onClose() end
        end,
        on_tab = function(id)
            if self.library then self.library:selectTab(id) end
        end,
    })
end

--- The library on the screen. quiet: only that, as when it comes up over a book being closed,
-- and the file manager that comes after will show it again and bring it up to date.
function Yaknigi:showLibrary(quiet)
    if self.library then UIManager:close(self.library) end
    if shown_library and shown_library ~= self.library then UIManager:close(shown_library) end
    local signed_in = saved_token() ~= nil
    local cached = signed_in and read_json(LIBRARY_CACHE) or nil
    local items = {}
    if signed_in and cached then items = self:libraryItems(cached) end
    local library
    library = Library:new{
        item_table = items,
        place = library_place,
        on_sign_in = not signed_in and function() self:showLogin() end or nil,
        onMenuSelect = function(_library, item, from_dock) self:openItem(item, from_dock) end,
        on_catalogue = function(state) self:askCatalogue(state) end,
        on_feed = function(state) self:askFeed(state) end,
        load_feed = function() return self:savedFeed() end,
        on_covers = function(cards) self:fetchCovers(cards) end,
        close_callback = function()
            UIManager:close(library)
            self.library = nil
            shown_library = nil
            logger.info("yaknigi: closed from the library")
            if APP_MODE then UIManager:quit() end
        end,
        on_refresh = function() self:refreshLibrary(true) end,
        on_settings = function() self:showSettings() end,
        on_book_menu = function(item) self:showBookMenu(item) end,
        on_add = function(item) self:addFound(item) end,
        on_save = function(item) self:saveFound(item) end,
        book_status = function(item)
            local id = item.card and item.card.book and item.card.book.uuid
            if id and saving[id] then return "saving" end
            if item.card and is_whole(item.card) then return "whole" end
        end,
    }
    self.library = library
    shown_library = library
    UIManager:show(library)
    if quiet then return end
    if signed_in then
        UIManager:nextTick(function() self:refreshLibrary(cached == nil) end)
        if cached then UIManager:nextTick(function() self:fetchCovers(without_episodes(cached)) end) end
        -- Back from a book, to what had been found: the covers that came meanwhile, or did not.
        if library.catalogue then
            for _, item in ipairs(library.catalogue.items) do
                item.cover = item.cover or Covers.find(COVERS, item.card)
            end
            library:refreshScreen()
            local cards = Catalogue.cards(library.catalogue.items)
            UIManager:nextTick(function() self:fetchCovers(cards) end)
        end
        if library.collection then
            self:freshenList(library.collection)
            library:refreshScreen()
            local cards = Catalogue.cards(library.collection.items)
            UIManager:nextTick(function() self:fetchCovers(cards) end)
        end
        if library.feed then
            for _, item in ipairs(Feed.items(library.feed)) do
                item.cover = Covers.find(COVERS, item.card)
            end
            library:refreshScreen()
            if library.view == "feed_section" then
                local cards = Catalogue.cards(library.section.items)
                UIManager:nextTick(function() self:fetchCovers(cards) end)
            end
            -- Coming back to the feed: left for a book before it got here, it is asked anew.
            if library.view == "feed" then UIManager:nextTick(function() library:askForMore() end) end
        end
    else
        UIManager:nextTick(function() self:showLogin() end)
    end
end

--- Out of the book: the library is up at once, whatever closing the book takes.
function Yaknigi:leaveBook()
    if self.store and self.shell then Session.save_reading(self.store.dir, self.shell:progress()) end
    self:showLibrary(true)
    UIManager:forceRePaint()
end

-- The request runs in a forked process: on a slow network it would hold up every tap.
function Yaknigi:refreshLibrary(tell_failure)
    local function start()
        if self.library_pid and not ffiutil.isSubProcessDone(self.library_pid) then return end
        os.remove(LIBRARY_RESULT)
        local token = saved_token()
        self.library_pid = ffiutil.runInSubProcess(function()
            local api = Api.new(token)
            local cards, kind = api:library()
            -- What could not be sent earlier, before the list is saved: the list then holds it.
            if cards then Sync.send_waiting(api, BOOKS, cards) end
            api:close()
            if cards then write_json(LIBRARY_CACHE, cards) end
            write_json(LIBRARY_RESULT, { kind = kind or "ok" })
            os.exit(0)
        end)
        if self.library_pid then self:pollLibrary(tell_failure) end
    end
    if tell_failure then
        NetworkMgr:runWhenOnline(start)
    elseif NetworkMgr:isOnline() then
        start()
    end
end

function Yaknigi:pollLibrary(tell_failure)
    UIManager:scheduleIn(0.5, function()
        if not ffiutil.isSubProcessDone(self.library_pid) then
            self:pollLibrary(tell_failure)
            return
        end
        -- Left for a book meanwhile, or signed out: the next visit will ask again.
        if not self.library or not saved_token() then return end
        local result = read_json(LIBRARY_RESULT) or {}
        local kind = result.kind or "network"
        if kind == "ok" then
            local cards = read_json(LIBRARY_CACHE)
            if not cards then return end
            if #cards == 0 then self.library.message = "Библиотека пуста. Книги можно найти через поиск." end
            self.library:switchItemTable(nil, self:libraryItems(cards))
            self:fetchCovers(without_episodes(cards))
        elseif kind == "auth" then
            save_token(nil)
            self:showLibrary()
        elseif tell_failure then
            message(error_text(kind), 3)
            self.library:setMessage(error_text(kind))
        end
    end)
end

-- Catalogue -------------------------------------------------------------------

local function catalogue_error(kind, state)
    if kind == "network" then return "Нет связи с Яндекс Книгами." end
    return state.kind and "Этот список сейчас не открывается." or "Поиск сейчас не работает."
end

--- Asks for a page of what was searched for, or of a list. Runs in the forked process.
local function ask_page(api, state, cursor)
    if state.kind then
        local page, kind = api:collection(state.kind, state.uuid, cursor)
        if not page then return nil, kind end
        return { items = Catalogue.from_page(state.kind, page), cursor = page.cursor }
    end
    local answer, kind = api:search(state.query, cursor)
    if not answer then return nil, kind end
    local items = {}
    for _, found in ipairs(answer.page) do
        local item = Catalogue.item(found)
        -- Search does not say which series are of audiobooks only.
        if item and (item.kind ~= "series" or api:series_has_books(item.uuid)) then items[#items + 1] = item end
    end
    return { items = items, cursor = answer.cursor or "" }
end

--- Gets the next books found, if they are not on their way already. In a forked process,
-- as all slow requests; every request has its file, for an old search not to answer a new one.
function Yaknigi:askCatalogue(state)
    if not Catalogue.start(state) then return end
    local function start()
        catalogue_requests = catalogue_requests + 1
        local path = CATALOGUE_RESULT .. catalogue_requests
        local token, cursor = saved_token(), state.cursor
        local pid = ffiutil.runInSubProcess(function()
            local api = Api.new(token)
            local answer, kind = ask_page(api, state, cursor)
            api:close()
            if answer then
                write_json(path, { kind = "ok", items = answer.items, cursor = answer.cursor })
            else
                write_json(path, { kind = kind or "network" })
            end
            os.exit(0)
        end)
        if pid then
            self:pollCatalogue(state, pid, path)
        else
            Catalogue.fail(state, catalogue_error("http", state))
        end
    end
    if state.cursor == "" then
        NetworkMgr:runWhenOnline(start)
    elseif NetworkMgr:isOnline() then
        start()
    else
        Catalogue.fail(state, catalogue_error("network", state))
    end
end

function Yaknigi:pollCatalogue(state, pid, path)
    UIManager:scheduleIn(0.3, function()
        if not ffiutil.isSubProcessDone(pid) then
            self:pollCatalogue(state, pid, path)
            return
        end
        local result = read_json(path) or {}
        os.remove(path)
        local library = shown_library
        local current = library and (library.catalogue == state or library.collection == state)
        if result.kind == "auth" then
            Catalogue.fail(state, catalogue_error("http", state))
            if current then
                save_token(nil)
                if self.library == library then self:showLibrary() end
            end
            return
        end
        local new
        if result.kind == "ok" then
            new = Catalogue.add(state, result.items, result.cursor)
            for _, item in ipairs(new) do item.cover = Covers.find(COVERS, item.card) end
            self:freshenList(state)
        else
            Catalogue.fail(state, catalogue_error(result.kind or "network", state))
        end
        if not current then return end
        if (library.view == "catalogue" and library.catalogue == state)
            or (library.view == "collection" and library.collection == state) then
            library:refreshScreen()
        end
        if new and self.library == library then self:fetchCovers(Catalogue.cards(new)) end
    end)
end

-- Feed ------------------------------------------------------------------------

local function feed_error(kind)
    if kind == "network" then return "Нет связи с Яндекс Книгами." end
    return "Рекомендации сейчас не открываются."
end

--- The feed as saved last time, for it to be there at once: the first thing asked is its start.
function Yaknigi:savedFeed()
    local state = Feed.from_saved(read_json(FEED_CACHE))
    for _, item in ipairs(Feed.items(state)) do
        item.cover = Covers.find(COVERS, item.card)
    end
    return state
end

--- Gets what comes next of the feed, in a forked process as all slow requests.
function Yaknigi:askFeed(state)
    if state.loading then return end
    local has_something = #state.sections > 0
    local function start()
        local cursor = Feed.start(state)
        if not cursor then return end
        feed_requests = feed_requests + 1
        local path = FEED_RESULT .. feed_requests
        local token, uuid = saved_token(), state.uuid
        local pid = ffiutil.runInSubProcess(function()
            local api = Api.new(token)
            -- Which feed to show is asked once; Yandex has only ever had the one.
            uuid = uuid or api:root_showcase() or Feed.ROOT
            local answer, kind = api:showcase(uuid, cursor)
            api:close()
            if answer then
                write_json(path, { kind = "ok", uuid = uuid, sections = Feed.sections(answer.page), cursor = answer.cursor or "" })
            else
                write_json(path, { kind = kind or "network" })
            end
            os.exit(0)
        end)
        if pid then
            self:pollFeed(state, pid, path)
        else
            Feed.fail(state, feed_error("http"))
        end
    end
    if NetworkMgr:isOnline() then
        start()
    elseif has_something then
        -- What was saved is there to look at, and nothing is worth a question about the Wi-Fi.
        return
    else
        Feed.fail(state, feed_error("network"))
        NetworkMgr:runWhenOnline(start)
    end
end

function Yaknigi:pollFeed(state, pid, path)
    UIManager:scheduleIn(0.3, function()
        if not ffiutil.isSubProcessDone(pid) then
            self:pollFeed(state, pid, path)
            return
        end
        local result = read_json(path) or {}
        os.remove(path)
        local library = shown_library
        local current = library and library.feed == state
        if result.kind == "auth" then
            Feed.fail(state, feed_error("http"))
            if current then
                save_token(nil)
                library_place = {}
                if self.library == library then self:showLibrary() end
            end
            return
        end
        if result.kind ~= "ok" then
            Feed.fail(state, feed_error(result.kind or "network"))
            if current and library.view == "feed" then library:refreshScreen() end
            return
        end
        local first_page = state.asked == ""
        state.uuid = result.uuid
        local new = Feed.add(state, result.sections, result.cursor)
        if first_page then
            write_json(FEED_CACHE, { uuid = state.uuid, sections = state.sections, cursor = state.cursor })
        end
        -- The same books as before, in new tables.
        for _, item in ipairs(Feed.items(state)) do
            item.cover = item.cover or Covers.find(COVERS, item.card)
        end
        if not current then return end
        if library.view == "feed" then
            library:refreshScreen()
            library:askForMore() -- a page may have held nothing to read here
        end
        if self.library == library then self:fetchCovers(Feed.cards(new, Feed.ROW_COVERS)) end
    end)
end

-- Opening what was found -------------------------------------------------------

function Yaknigi:ownedCard(book_uuid)
    if episode_cards[book_uuid] then return episode_cards[book_uuid] end
    local library = shown_library or self.library
    for _, item in ipairs(library and library.item_table or {}) do
        local book = item.card and item.card.book
        if book and book.uuid == book_uuid then return item.card end
    end
end

--- The episodes of a list as they stand here now: which are in the library, and how far read.
function Yaknigi:freshenList(state)
    if state.kind ~= "serial" then return end
    for _, item in ipairs(state.items) do
        local card = item.kind == "episode" and episode_cards[item.card.book.uuid]
        if card then
            local here = reading_here(card)
            local progress = here or tonumber(card.progress) or 0
            item.card = card
            item.in_library = true
            item.mandatory = progress > 0 and (math.floor(progress) .. "%") or nil
        end
    end
end

--- Opens the list that this leads to, on the screen where it was tapped.
function Yaknigi:openList(kind, uuid, title)
    local library = shown_library or self.library
    if not library then return end
    library:openCollection(Catalogue.collection(kind, uuid, title))
end

--- A tap on what is in a list. A serial shows its episodes, except where it stands for what is
-- being read: there it goes on with the episode.
function Yaknigi:openItem(item, from_dock)
    if item.kind == "author" or item.kind == "series" then
        return self:openList(item.kind, item.uuid, item.title)
    end
    if item.kind == "serial" then
        local current = from_dock and episode_cards[item.card.current_episode_uuid or ""]
        if current then return self:openCard(current) end
        return self:openList("serial", item.card.book.uuid, item.title)
    end
    if item.found then self:openFound(item) else self:openCard(item.card) end
end

--- A book from the library opens at once. Any other shows what it is first, as opening it
-- means adding it to the library.
function Yaknigi:openFound(item)
    book_covers[item.card.book.uuid] = item.card.book.cover
    local card = self:ownedCard(item.card.book.uuid)
    if card then
        self:openCard(card)
    elseif item.in_library then
        self:takeFound(item)
    else
        local screen
        screen = BookCard:new{
            item = item,
            on_read = function() self:takeFound(item, screen) end,
        }
        UIManager:show(screen)
    end
end

--- Gets the card of a book, from Yandex and into the library if need be. An episode comes with
-- its whole serial, as on the phone. Returns the card, what went wrong, and all the new cards.
local function take_card(api, serial, uuid)
    if not serial then
        local card, kind = api:card_for_reading(uuid)
        return card, kind, card and { card }
    end
    local cards, kind = api:add_serial(serial)
    if not cards then return nil, kind end
    for _, card in ipairs(cards) do
        if card.book and card.book.uuid == uuid then return card, nil, cards end
    end
    return nil, "http"
end

--- The serial something found is of, if it is.
local function serial_of_item(item)
    if item.kind == "serial" then return item.card.book.uuid end
    return item.kind == "episode" and item.serial or nil
end

--- Gets a library card for a found book and opens it.
function Yaknigi:takeFound(item, screen)
    NetworkMgr:runWhenOnline(function()
        if self.taking then return end
        self.taking = true
        local wait = InfoMessage:new{ text = opening_text(item.card) }
        UIManager:show(wait)
        os.remove(TAKE_RESULT)
        local token, uuid, serial = saved_token(), item.card.book.uuid, serial_of_item(item)
        local pid = ffiutil.runInSubProcess(function()
            local api = Api.new(token)
            local card, kind, cards = take_card(api, serial, uuid)
            api:close()
            write_json(TAKE_RESULT, { kind = kind or "ok", card = card, cards = cards })
            os.exit(0)
        end)
        if not pid then
            self.taking = false
            UIManager:close(wait)
            message(error_text("http"), 3)
            return
        end
        self:pollTake(item, screen, wait, pid)
    end)
end

function Yaknigi:pollTake(item, screen, wait, pid)
    UIManager:scheduleIn(0.2, function()
        if not ffiutil.isSubProcessDone(pid) then
            self:pollTake(item, screen, wait, pid)
            return
        end
        self.taking = false
        UIManager:close(wait)
        local result = read_json(TAKE_RESULT) or {}
        local kind = result.kind or "network"
        if not self.library then return end
        if kind == "ok" and result.card then
            if screen then UIManager:close(screen) end
            Catalogue.mark_added(item, result.card)
            -- So that the library has it now, whatever becomes of opening it.
            self:rememberCards(result.cards)
            self:openCard(result.card)
        elseif kind == "auth" then
            if screen then UIManager:close(screen) end
            save_token(nil)
            self:showLibrary()
        elseif kind == "denied" then
            message("Эта книга недоступна по вашей подписке.", 3)
        elseif kind == "network" then
            message(error_text(kind), 3)
        else
            message("Яндекс Книги не дали открыть эту книгу.", 3)
        end
    end)
end

--- A new card goes into the library's list at once, and the screen shows it.
function Yaknigi:rememberCards(new)
    local cards = read_json(LIBRARY_CACHE) or {}
    local known = {}
    for _, mine in ipairs(cards) do known[mine.uuid] = true end
    local changed = false
    for i = #new, 1, -1 do
        if not known[new[i].uuid] then
            table.insert(cards, 1, new[i])
            changed = true
        end
    end
    if changed then write_json(LIBRARY_CACHE, cards) end
    self:showCards(cards)
    if shown_library and shown_library.collection then self:freshenList(shown_library.collection) end
end

--- What the library shows, from the list as it now is.
function Yaknigi:showCards(cards)
    if shown_library then shown_library:switchItemTable(nil, self:libraryItems(cards or read_json(LIBRARY_CACHE) or {})) end
end

--- A word at the top of the screen, that goes by itself and does not get in the way.
local function toast(text)
    UIManager:show(Notification:new{ text = text })
end

local function quoted(title)
    return "«" .. (title or "Книга") .. "»"
end

--- Puts a book found into the library, without opening it. then(card) goes on from there.
function Yaknigi:addFound(item, after)
    NetworkMgr:runWhenOnline(function()
        if item.adding then return end
        item.adding = true
        if shown_library then shown_library:refreshScreen() end
        add_requests = add_requests + 1
        local path = ADD_RESULT .. add_requests
        local token, uuid, serial = saved_token(), item.card.book.uuid, serial_of_item(item)
        local pid = ffiutil.runInSubProcess(function()
            local api = Api.new(token)
            local card, kind, cards = take_card(api, serial, uuid)
            api:close()
            write_json(path, { kind = kind or "ok", card = card, cards = cards })
            os.exit(0)
        end)
        if not pid then
            item.adding = nil
            if shown_library then shown_library:refreshScreen() end
            message(error_text("http"), 3)
            return
        end
        self:pollAdd(item, path, pid, after)
    end)
end

function Yaknigi:pollAdd(item, path, pid, after)
    UIManager:scheduleIn(0.2, function()
        if not ffiutil.isSubProcessDone(pid) then
            self:pollAdd(item, path, pid, after)
            return
        end
        item.adding = nil
        local result = read_json(path) or {}
        os.remove(path)
        local kind = result.kind or "network"
        if kind == "ok" and result.card then
            local title = item.title
            Catalogue.mark_added(item, result.card)
            self:rememberCards(result.cards)
            if after then
                after(result.card)
            else
                toast(quoted(title) .. " в библиотеке")
            end
            return
        end
        if shown_library then shown_library:refreshScreen() end
        if kind == "auth" then
            save_token(nil)
            self:showLibrary()
        elseif kind == "denied" then
            message("Эта книга недоступна по вашей подписке.", 3)
        elseif kind == "network" then
            message(error_text(kind), 3)
        else
            message("Яндекс Книги не дали добавить эту книгу.", 3)
        end
    end)
end

--- Saves a book of the feed or the search: it may yet have no card here.
function Yaknigi:saveFound(item)
    local uuid = item.card.book.uuid
    local card = self:ownedCard(uuid) or (item.card.uuid and item.card)
    if card then
        self:saveBook(card)
    else
        self:addFound(item, function(new_card) self:saveBook(new_card) end)
    end
end

--- Gets all of a book for reading with no network, in a process of its own. A book being read
-- has one at it already, which is left to finish.
function Yaknigi:saveBook(card)
    local id = card.book and card.book.uuid
    if not id or saving[id] or is_whole(card) then return end
    NetworkMgr:runWhenOnline(function()
        if saving[id] then return end
        local state = workers[id] or {}
        workers[id] = state
        local path
        if not (state.pid and not ffiutil.isSubProcessDone(state.pid)) then
            save_requests = save_requests + 1
            path = SAVE_RESULT .. save_requests
            state.pid = Background.save(BOOKS, id, saved_token(), path)
            if not state.pid then
                message(error_text("http"), 3)
                return
            end
        end
        local entry = { pid = state.pid }
        saving[id] = entry
        self:showCards()
        self:pollSave(id, entry, card, path)
    end)
end

function Yaknigi:pollSave(id, entry, card, path)
    UIManager:scheduleIn(POLL_SECONDS, function()
        if not ffiutil.isSubProcessDone(entry.pid) then
            self:pollSave(id, entry, card, path)
            return
        end
        if path then os.remove(path) end
        -- Stopped by clearing the device: there is nothing to tell.
        if saving[id] ~= entry then return end
        saving[id] = nil
        -- Over a book being read it can wait: the library will show it.
        if shown_library then
            local title = card.book.title
            if is_whole(card) then
                toast(quoted(title) .. " сохранена на устройстве")
            else
                message("Не удалось сохранить " .. quoted(title) .. ".", 3)
            end
            self:showCards()
        end
    end)
end

--- Stops what is downloading books: their files are about to go.
local function stop_workers(only_id)
    local function ask(pid)
        if ffiutil.isSubProcessDone(pid) then return end
        UIManager:scheduleIn(1, function() ask(pid) end)
    end
    for id, state in pairs(workers) do
        if not only_id or id == only_id then
            if state.pid and not ffiutil.isSubProcessDone(state.pid) then
                ffiutil.terminateSubProcess(state.pid)
                ask(state.pid)
            end
            workers[id] = nil
            saving[id] = nil
        end
    end
end

--- Takes a book's text off the device. The place in it stays, as do its notes.
function Yaknigi:removeFromDevice(card)
    local id = card.book.uuid
    stop_workers(id)
    local dir = book_dir(card)
    if dir then Storage.remove_book(dir) end
    self:showCards()
end

--- Takes a book out of the library, in Yandex's as well.
function Yaknigi:removeFromLibrary(card)
    NetworkMgr:runWhenOnline(function()
        local wait = InfoMessage:new{ text = "Удаляю " .. quoted(card.book.title) .. "…" }
        UIManager:show(wait)
        remove_requests = remove_requests + 1
        local path = REMOVE_RESULT .. remove_requests
        local token = saved_token()
        -- The episodes of a serial have their cards, and go with it.
        local episodes = {}
        for _, mine in ipairs(read_json(LIBRARY_CACHE) or {}) do
            if mine.book and mine.book.parent_uuid == card.book.uuid then episodes[#episodes + 1] = mine end
        end
        local pid = ffiutil.runInSubProcess(function()
            local api = Api.new(token)
            local ok, kind = api:remove_card(card.uuid)
            for _, episode in ipairs(episodes) do
                if ok then ok, kind = api:remove_card(episode.uuid) end
            end
            api:close()
            write_json(path, { kind = ok and "ok" or kind or "network" })
            os.exit(0)
        end)
        if not pid then
            UIManager:close(wait)
            message(error_text("http"), 3)
            return
        end
        self:pollRemove(card, episodes, wait, path, pid)
    end)
end

function Yaknigi:pollRemove(card, episodes, wait, path, pid)
    UIManager:scheduleIn(0.2, function()
        if not ffiutil.isSubProcessDone(pid) then
            self:pollRemove(card, episodes, wait, path, pid)
            return
        end
        UIManager:close(wait)
        local result = read_json(path) or {}
        os.remove(path)
        local kind = result.kind or "network"
        if kind == "auth" then
            save_token(nil)
            self:showLibrary()
            return
        elseif kind ~= "ok" then
            message(kind == "network" and error_text(kind) or "Яндекс Книги не дали удалить эту книгу.", 3)
            return
        end
        local gone = { [card.uuid] = true }
        local gone_books = { [card.book.uuid] = true }
        for _, episode in ipairs(episodes) do
            gone[episode.uuid] = true
            gone_books[episode.book.uuid] = true
        end
        local cards = {}
        for _, mine in ipairs(read_json(LIBRARY_CACHE) or {}) do
            if not gone[mine.uuid] then cards[#cards + 1] = mine end
        end
        write_json(LIBRARY_CACHE, cards)
        for _, episode in ipairs(episodes) do self:removeFromDevice(episode) end
        self:removeFromDevice(card)
        -- Where it was found it can be added again.
        if shown_library then
            local function forget(items)
                for _, item in ipairs(items) do
                    if item.card and item.card.book and gone_books[item.card.book.uuid] then
                        Catalogue.mark_removed(item)
                    end
                end
            end
            if shown_library.catalogue then forget(shown_library.catalogue.items) end
            if shown_library.collection then forget(shown_library.collection.items) end
            if shown_library.feed then forget(Feed.items(shown_library.feed)) end
        end
        self:showCards(cards)
        toast(quoted(card.book.title) .. " удалена из библиотеки")
    end)
end

--- What can be done with a book. Reading is a tap on the book itself.
function Yaknigi:showBookMenu(item)
    local uuid = item.card.book.uuid
    local card = self:ownedCard(uuid) or item.card
    local function read()
        if item.kind == "serial" then self:openItem(item)
        elseif card.uuid then self:openCard(card)
        else self:openFound(item) end
    end
    local serial, episode = item.kind == "serial", item.kind == "episode"
    local entries = { {
        key = "about",
        text = "О книге",
        icon = "info",
        action = function()
            local screen
            screen = BookCard:new{
                item = {
                    title = item.title,
                    authors = item.authors,
                    cover = item.cover,
                    annotation = item.annotation or card.book.annotation,
                },
                owned = card.uuid ~= nil,
                on_read = function()
                    UIManager:close(screen)
                    read()
                end,
            }
            UIManager:show(screen)
        end,
    } }
    if serial then
        -- Its episodes are what is saved, each on its own.
    elseif saving[uuid] then
        entries[#entries + 1] = { key = "saving", text = "Сохраняю…", file = "wait", disabled = true }
    elseif is_whole(card) then
        entries[#entries + 1] = { key = "remove_device", text = "Удалить с устройства", file = "cloud.off",
            action = function() self:removeFromDevice(card) end }
    else
        entries[#entries + 1] = { key = "save", text = "Сохранить на устройство", file = "cloud.down",
            action = function() self:saveBook(card) end }
    end
    for _, link in ipairs(Catalogue.links(card.book)) do
        local is_series = link.kind == "series"
        entries[#entries + 1] = {
            key = link.kind,
            text = (is_series and "Серия " or "Автор: ") .. (is_series and quoted(link.title) or link.title),
            icon = "chevron.right",
            action = function() self:openList(link.kind, link.uuid, link.title) end,
        }
    end
    -- An episode goes only with its serial, as on the phone.
    if card.uuid and not episode then
        entries[#entries + 1] = { key = "remove_library", text = "Удалить из библиотеки", file = "trash",
            action = function()
                UIManager:show(ConfirmBox:new{
                    text = serial
                        and "Удалить " .. quoted(item.title) .. " из библиотеки со всеми эпизодами? Они исчезнут и в приложении на телефоне."
                        or "Удалить " .. quoted(item.title) .. " из библиотеки? Она исчезнет и в приложении на телефоне.",
                    ok_text = "Удалить",
                    ok_callback = function() self:removeFromLibrary(card) end,
                })
            end }
    end
    self.book_menu = BookMenu:new{ title = item.title, authors = item.authors, entries = entries }
    UIManager:show(self.book_menu)
end

-- Memory ----------------------------------------------------------------------

local function storage_paths()
    return {
        cache = DataStorage:getDataDir() .. "/cache",
        root = ROOT,
        books = BOOKS,
        covers = COVERS,
        keep_cover = G_reader_settings:readSetting("yaknigi_last_cover"),
    }
end

--- Runs work in a process of its own, and gives what it returns to done.
local function in_background(work, done)
    storage_requests = storage_requests + 1
    local path = STORAGE_RESULT .. storage_requests
    local pid = ffiutil.runInSubProcess(function()
        local ok, value = pcall(work)
        write_json(path, { value = ok and value or nil })
        os.exit(0)
    end)
    if not pid then
        done(nil)
        return
    end
    local function wait()
        if not ffiutil.isSubProcessDone(pid) then
            UIManager:scheduleIn(0.2, wait)
            return
        end
        local result = read_json(path) or {}
        os.remove(path)
        done(result.value)
    end
    UIManager:scheduleIn(0.2, wait)
end

--- What the settings can do about the memory. Only from the library, with no book open: the
-- engine has the open book's layout in use, and its text.
function Yaknigi:storageActions()
    return {
        measure = function(done)
            local paths = storage_paths()
            in_background(function() return Storage.measure(paths) end, function(sizes)
                done(sizes or {})
            end)
        end,
        clear = function(picks, done)
            if picks.partial or picks.books then stop_workers() end
            if picks.covers and self.covers_pids then
                self:reapCovers(Covers.stop(self.covers_pids))
                self.covers_pids, self.covers_queue = nil, nil
            end
            local paths = storage_paths()
            in_background(function() return Storage.clear(paths, picks) end, function(freed)
                -- KOReader's own clearing does this: it remembers what it has put there.
                if picks.junk then require("cache").cached = {} end
                self:afterClearing(picks)
                done(freed or 0)
            end)
        end,
    }
end

--- What is shown stands on what has just gone.
function Yaknigi:afterClearing(picks)
    local cards = read_json(LIBRARY_CACHE) or {}
    self:showCards(cards)
    if not picks.covers or not shown_library then return end
    local function look(items)
        for _, item in ipairs(items) do
            item.cover = item.card and Covers.find(COVERS, item.card) or nil
        end
    end
    if shown_library.catalogue then look(shown_library.catalogue.items) end
    if shown_library.collection then look(shown_library.collection.items) end
    if shown_library.feed then look(Feed.items(shown_library.feed)) end
    shown_library:refreshScreen()
    self:fetchCovers(cards)
end

local function saved_fragment(path)
    if not DocSettings:hasSidecarFile(path) then return nil end
    local xp = DocSettings:open(path):readSetting("last_xpointer")
    return xp and tonumber(xp:match("DocFragment%[(%d+)%]"))
end

function Yaknigi:openCard(card)
    local id = card.book and card.book.uuid
    -- A serial has nothing to read in itself.
    if card.book and card.book.source_type == "serial" then
        return self:openList("serial", id, card.book.title)
    end
    if id then book_covers[id] = card.book.cover or book_covers[id] end
    opening_message = opening_text(card)
    local store = Store.open(BOOKS, id)
    if store and store:is_whole() then
        -- Nothing to wait for, not even the network. The reader asks Yandex once it is open.
        local has_local = saved_fragment(store.epub) ~= nil
        local moved = Session.server_moved(store, card, has_local)
        if moved and not has_local then
            self:showBook(store, Session.jump_for(store, card))
            return
        end
        Session.opening_here(store, card, moved)
        -- Never read here nor anywhere: past the cover, as a book being read for the first time.
        self:showBook(store, not has_local and Session.start_of(Session.first_text_on_disk(store) or 1) or nil)
        return
    end
    NetworkMgr:runWhenOnline(function() self:loadAndOpen(card, store) end)
end

function Yaknigi:loadAndOpen(card, store)
    local wait = InfoMessage:new{ text = opening_text(card) }
    UIManager:show(wait)
    UIManager:forceRePaint()

    local api = Api.new(saved_token())
    local fragment = store and saved_fragment(store.epub)
    local result, stubs, xpointer, target, text_start = Session.prepare(BOOKS, api, card, fragment)
    api:close()
    UIManager:close(wait)
    if not result then
        local kind = stubs
        if kind == "auth" then
            save_token(nil)
            self:showLibrary()
        else
            logger.warn("yaknigi: open failed:", kind, xpointer)
            message(error_text(kind), 3)
        end
        return
    end
    self:showBook(result, xpointer, target, stubs, text_start)
end

function Yaknigi:showBook(store, xpointer, target, stubs, text_start)
    if self.library then
        UIManager:close(self.library)
        self.library = nil
    end
    shown_library = nil
    workers[store.id] = workers[store.id] or {}
    local state = workers[store.id]
    state.target = target or state.target
    state.stubs = stubs or {}
    state.text_start = text_start or state.text_start
    self:applyTextDefaults(store.epub)
    local ReaderUI = require("apps/reader/readerui")
    install_opening_message(ReaderUI)
    ReaderUI:showReader(store.epub, nil, false, nil, function(ui)
        if xpointer then ui.rolling:onGotoXPointer(xpointer) end
        -- Only reading moves the position. Sending this one back would be a step behind
        -- the phone, as what comes from Yandex lands at the start of its paragraph.
        if ui.yaknigi then
            ui.yaknigi.base_xp = ui.document:getXPointer()
            ui.yaknigi:exchange()
        end
    end)
end

-- The text settings are one for all books, as in the phone app, but KOReader keeps them
-- per book. Put the current ones in this book's settings before KOReader reads them.
function Yaknigi:applyTextDefaults(path)
    if not DocSettings:hasSidecarFile(path) then return end
    local doc_settings = DocSettings:open(path)
    local font = G_reader_settings:readSetting("cre_font")
    if font then doc_settings:saveSetting("font_face", font) end
    for _, name in ipairs { "font_size", "line_spacing", "h_page_margins", "t_page_margin" } do
        local value = G_reader_settings:readSetting("copt_" .. name)
        if value ~= nil then doc_settings:saveSetting("copt_" .. name, value) end
    end
    doc_settings:flush()
end

-- Reading ---------------------------------------------------------------------

function Yaknigi:readerStore()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file then return nil end
    local id = doc.file:match("/yaknigi/books/([%w_%-]+)/book%.epub$")
    return id and Store.open(BOOKS, id) or nil
end

-- A position saved on a stub does not exist once the real chapter is in the file, and
-- KOReader would answer with page 1 of the book. Go to the start of that chapter.
function Yaknigi:keepChapter()
    local doc = self.ui.document
    local saved = self.ui.doc_settings:readSetting("last_xpointer")
    if not saved or doc:isXPointerInDocument(saved) then return end
    local fragment = saved:match("^/body/DocFragment%[%d+%]")
    if fragment then self.ui.rolling:onGotoXPointer(fragment) end
end

function Yaknigi:stubs()
    local state = self.store and workers[self.store.id]
    return state and state.stubs or {}
end

function Yaknigi:paths()
    return self.store and self.store.paths or {}
end

--- What is known of this book's cover, if the card it was opened by has gone.
local function known_cover(id)
    if book_covers[id] then return book_covers[id] end
    for _, card in ipairs(read_json(LIBRARY_CACHE) or {}) do
        if card.book and card.book.uuid == id then return card.book.cover end
    end
    return nil
end

--- What shows while the device sleeps: the original of the cover, and until it has arrived
-- whatever picture of it there is. If this book has none yet, the last one stays.
function Yaknigi:chooseSleepCover(store)
    local best = Covers.find_best(COVERS, store.id)
    local cover = best or store:cover_file() or Covers.find(COVERS, { book = { uuid = store.id } })
    if cover then Prefs.apply_sleep_screen(cover) end
    if best or not NetworkMgr:isOnline() then return end
    local pid = Covers.fetch_best(COVERS, store.id, Prefs.sleep_cover_urls(known_cover(store.id)))
    if not pid then return end
    local function wait()
        if not ffiutil.isSubProcessDone(pid) then
            UIManager:scheduleIn(POLL_SECONDS, wait)
            return
        end
        local arrived = not self.closed and Covers.find_best(COVERS, store.id)
        if arrived then Prefs.apply_sleep_screen(arrived) end
    end
    UIManager:scheduleIn(POLL_SECONDS, wait)
end

--- The card of the serial an episode is of, and the next episode's. Looks through the list only
-- once for a book being read.
local function serial_cards(book_id)
    local cards = read_json(LIBRARY_CACHE) or {}
    local this
    for _, card in ipairs(cards) do
        if card.book and card.book.uuid == book_id then this = card end
    end
    local parent = this and this.book.parent_uuid
    if not parent then return nil end
    local serial, following
    for _, card in ipairs(cards) do
        local book = card.book or {}
        if book.uuid == parent then serial = card end
        if book.parent_uuid == parent and this.book.position and book.position == this.book.position + 1 then
            following = card
        end
    end
    return serial, following
end

--- At the end of an episode, the next one is what is on offer, not KOReader's questions.
function Yaknigi:offerNextEpisode(following)
    local status = self.ui.status
    if not following or not status then return end
    status.onEndOfBook = function()
        UIManager:show(ConfirmBox:new{
            text = "Эпизод окончен. Читать дальше: " .. quoted(following.book.title) .. "?",
            ok_text = "Читать",
            cancel_text = "Остаться",
            ok_callback = function()
                open_next = following
                self:leaveBook()
                UIManager:nextTick(function() self.ui:onHome() end)
            end,
        })
        return true
    end
end

function Yaknigi:onReaderReady()
    local store = self:readerStore()
    if not store or not store.manifest then return end
    self.store = store
    local serial, following = serial_cards(store.id)
    self.serial_card = serial
    self:offerNextEpisode(following)
    self.reading_session = Sync.new_session()
    self.queued_at = os.time()
    self:keepChapter()
    if APP_MODE then
        self.shell = Shell.new(self.ui, self)
        self.shell:install()
        self:chooseSleepCover(store)
        -- Not in the way of the first page.
        UIManager:scheduleIn(NOTES_AFTER_OPENING_SECONDS, function() self:syncNotes() end)
    end
    local state = workers[store.id] or {}
    workers[store.id] = state
    self:jumpIfWaiting(state)
    UIManager:nextTick(function() self:askAboutNews() end)
    if store:is_whole() and not next(state.stubs or {}) then return end

    -- Reopened without going through the library: work out what is a stub.
    if not state.stubs then
        state.stubs = {}
        for i, p in ipairs(store.paths) do
            if not store:has(p) then state.stubs[i] = true end
        end
    end
    self:startWorker(state, store)
    self:schedulePoll()
end

function Yaknigi:startWorker(state, store)
    if state.pid and not ffiutil.isSubProcessDone(state.pid) then return end
    if store:is_whole() then return end
    local token = saved_token()
    if not token then return end
    state.pid = Background.start(store, token, state.target or 1, self.ui.document)
    logger.info("yaknigi: background worker", state.pid)
end

function Yaknigi:schedulePoll()
    if self.polling then return end
    self.polling = function() self:poll() end
    UIManager:scheduleIn(POLL_SECONDS, self.polling)
end

function Yaknigi:stopPoll()
    if self.polling then
        UIManager:unschedule(self.polling)
        self.polling = nil
    end
end

function Yaknigi:currentFragment()
    local xp = self.ui.document:getXPointer()
    return xp and tonumber(xp:match("DocFragment%[(%d+)%]"))
end

function Yaknigi:poll()
    self.polling = nil
    local store = self.store
    local state = store and workers[store.id]
    if not state or self.ui.tearing_down then return end

    local top = UIManager:getTopmostVisibleWidget() or {}
    local reading = top.name == "ReaderUI"
    local running = state.pid and not ffiutil.isSubProcessDone(state.pid)

    -- The worker finished and rendered the whole book: switch to it. Its cache makes
    -- this as quick as turning a page, so no need to wait for the reader to be idle.
    if not running and store:is_whole() and reading and next(state.stubs) then
        logger.info("yaknigi: swapping to the whole book")
        state.stubs = {}
        self.ui:reloadDocument(nil, true)
        return
    end

    -- The reader is at the edge of what is in the file: put in what has arrived.
    local fragment = reading and self:currentFragment()
    if fragment and state.stubs[fragment] then
        Background.set_priority(store, fragment)
    end
    local needed = fragment and (state.stubs[fragment] and fragment
        or state.stubs[fragment + 1] and fragment + 1)
    -- Paged back to the cover, which came after the book had opened: put it in, once.
    if fragment and not needed and state.text_start and fragment < state.text_start and not state.front_built then
        local pictures = store:pictures_of(store.paths[fragment])
        local arrived = #pictures > 0
        for _, p in ipairs(pictures) do arrived = arrived and store:has(p) end
        if arrived then
            state.front_built = true
            needed = fragment
        end
    end
    if needed then
        if store:has(store.paths[needed]) then
            local started = os.time()
            local stubs = store:build()
            logger.info("yaknigi: rebuilt for a new chapter in about", os.time() - started, "s")
            if stubs then
                state.stubs = stubs
                self.ui:reloadDocument(nil, true)
                return
            end
        end
    end

    if not running and not store:is_whole() then
        -- Stopped early, most likely because of the network; try again in a while.
        state.retry_at = state.retry_at or (os.time() + 30)
        if os.time() >= state.retry_at and NetworkMgr:isOnline() then
            state.retry_at = nil
            self:startWorker(state, store)
        end
    end
    self:schedulePoll()
end

function Yaknigi:onPageUpdate()
    local store = self.store
    local state = store and workers[store.id]
    if not state or not next(state.stubs or {}) then return end
    local fragment = self:currentFragment()
    if fragment and state.stubs[fragment] then
        Background.set_priority(store, fragment)
    end
end

-- The position for Yandex: where an xpointer is, counted in its spine.
function Yaknigi:positionOf(xp)
    local store = self.store
    local fragment = xp and tonumber(xp:match("DocFragment%[(%d+)%]"))
    local path = fragment and store.paths[fragment]
    local spine = fragment and store:spine_index_of_fragment(fragment)
    if not path or not spine or not store:has(path) then return nil end
    local inner = Cfi.locate(store:read(path), xp)
    return inner and Cfi.at(spine, inner)
end

--- If reading has moved on, sets the new position aside and tries to send it. Whatever
-- does not go now goes from the library's next refresh.
function Yaknigi:sendPosition()
    local doc, store = self.ui.document, self.store
    local xp = doc:getXPointer()
    if not self.base_xp then self.base_xp = xp; return end
    if xp == self.base_xp then return end
    local token = saved_token()
    local card, state = Session.read_card(store.dir)
    local start = self:positionOf(xp)
    if not token or not card or not start or not store.manifest.document_uuid then return end

    local now = os.time()
    if start ~= self.queued then
        self.queued = start
        Sync.queue(store.dir, {
            start = start,
            finish = self:positionOf(doc:getPageXPointer(doc:getCurrentPage() + 1)) or start,
            range = Cfi.point_range(start),
            progress = math.max(0, math.min(100, math.floor(self.shell:progress() * 100 + 0.5))),
            card = card,
            book = store.id,
            document = store.manifest.document_uuid,
            serial = self.serial_card and self.serial_card.book.uuid or nil,
            serial_card = self.serial_card and self.serial_card.uuid or nil,
            state = state ~= "finished" and "reading" or nil,
            read_at = os.date("!%Y-%m-%dT%H:%M:%S.000+00:00", now),
            session = self.reading_session or Sync.new_session(),
        }, now - (self.queued_at or now))
        self.queued_at = now
    end
    if Sync.waiting(store.dir) then self:exchange() end
end

function Yaknigi:notesContext()
    return {
        ui = self.ui,
        store = self.store,
        stubs = self:stubs(),
        position = function(xp) return self:positionOf(xp) end,
        progress = math.max(0, math.min(100, math.floor(self.shell:progress() * 100 + 0.5))),
    }
end

--- Compares this book's notes with Yandex's, in a forked process. As the book closes, nobody is
-- left to hear the answer; the next time, the comparison finds the same things done.
function Yaknigi:syncNotes(closing)
    local store = self.store
    if self.closed or not store or not self.shell then return end
    if self.notes_pid and not ffiutil.isSubProcessDone(self.notes_pid) then
        self.notes_again = not closing
        return
    end
    local token = saved_token()
    if not token then return end
    local known = NotesLocal.known(self.ui)
    local notes = NotesLocal.collect(self:notesContext(), known)
    local path = store.dir .. "/notes_answer"
    local book = store.id
    os.remove(path)
    self.notes_dirty = false
    self.notes_pid = ffiutil.runInSubProcess(function()
        local api = Api.new(token)
        local ok, result, kind = pcall(NoteSync.run, api, book, notes, known)
        api:close()
        if ok and result then
            write_json(path, result)
        else
            logger.info("yaknigi: notes not compared:", ok and kind or result)
        end
        os.exit(0)
    end, false, closing)
    if closing then
        self.notes_pid = nil
    elseif self.notes_pid then
        self:pollNotes(path)
    end
end

function Yaknigi:pollNotes(path)
    UIManager:scheduleIn(0.5, function()
        if self.closed then return end
        if not ffiutil.isSubProcessDone(self.notes_pid) then
            self:pollNotes(path)
            return
        end
        self.notes_pid = nil
        local result = read_json(path)
        os.remove(path)
        if result then
            self:applyNotes(result)
        else
            self.notes_dirty = true -- no network, say: tried again on the way to sleep or out
        end
        if self.notes_again then
            self.notes_again = false
            self:syncNotes()
        end
    end)
end

function Yaknigi:applyNotes(result)
    -- These changes came from Yandex, and are not news to send back to it.
    self.notes_applying = true
    local ok, changed = pcall(NotesLocal.apply, self:notesContext(), result)
    self.notes_applying = false
    if not ok then
        logger.warn("yaknigi: notes not applied:", changed)
    elseif changed then
        UIManager:setDirty(self.ui, "ui")
        self.ui:saveSettings()
    end
end

function Yaknigi:notesChanged()
    if self.notes_applying or not self.shell then return end
    self.notes_dirty = true
    if self.notes_soon then UIManager:unschedule(self.notes_soon) end
    self.notes_soon = function()
        self.notes_soon = nil
        self:syncNotes()
    end
    UIManager:scheduleIn(NOTES_AFTER_CHANGE_SECONDS, self.notes_soon)
end

function Yaknigi:onAnnotationsModified()
    self:notesChanged()
end

function Yaknigi:onYaknigiNotesChanged()
    self:notesChanged()
end

--- In a forked process, as the network may be slow or not there: finds out where Yandex
-- has the book, and sends what is waiting if that does not overwrite other reading.
function Yaknigi:exchange()
    local store = self.store
    if self.closed or not store or not self.shell then return end
    if self.send_pid and not ffiutil.isSubProcessDone(self.send_pid) then
        -- It may have heard from Yandex before the device went to sleep, say.
        self.exchange_again = true
        return
    end
    local token = saved_token()
    local card = Session.read_card(store.dir)
    if not token or not card then return end
    local dir = store.dir
    os.remove(dir .. "/checked")
    self.send_pid = ffiutil.runInSubProcess(function()
        local api = Api.new(token)
        local ok, kind = Sync.exchange(api, dir, card)
        api:close()
        if not ok then logger.info("yaknigi: position not sent:", kind) end
        os.exit(0)
    end)
    if self.send_pid then self:pollExchange() end
end

function Yaknigi:pollExchange()
    UIManager:scheduleIn(0.5, function()
        if self.closed then return end
        if not ffiutil.isSubProcessDone(self.send_pid) then
            self:pollExchange()
            return
        end
        if self.exchange_again then
            self.exchange_again = false
            self:exchange()
            return
        end
        self:askAboutNews()
        local f = io.open(self.store.dir .. "/checked", "rb")
        if f then
            f:close()
            self.wake_try = nil
        elseif self.wake_try then
            local pause = WAKE_RETRY_SECONDS[self.wake_try]
            self.wake_try = pause and self.wake_try + 1 or nil
            if pause then UIManager:scheduleIn(pause, function() self:exchange() end) end
        end
    end)
end

--- Yandex has the book at a place this device has not seen: asks whether to go there.
-- Until it is answered, nothing read here is sent.
function Yaknigi:askAboutNews()
    if self.closed or self.prompt or not self.shell or not self.ui.document then return end
    local news = Session.read_news(self.store.dir)
    if not news then return end
    local here = math.floor(self.shell:progress() * 100 + 0.5)
    local where = news.progress and ("\nТам %d%%, здесь %d%%."):format(news.progress, here) or ""
    self.prompt = ConfirmBox:new{
        text = "Эту книгу читали на другом устройстве." .. where .. "\nПерейти туда?",
        ok_text = "Перейти",
        cancel_text = "Остаться",
        dismissable = false,
        ok_callback = function()
            self.prompt = nil
            self:goToNews()
        end,
        cancel_callback = function()
            self.prompt = nil
            self:stayHere()
        end,
    }
    UIManager:show(self.prompt)
end

function Yaknigi:goToNews()
    local store = self.store
    local news = Session.read_news(store.dir)
    if not news then return end
    Session.answered(store, news, true)
    self.queued = nil
    self.ui.link:addCurrentLocationToStack()
    local state = workers[store.id]
    state.jump_cfi = news.cfi
    self:jumpIfWaiting(state)
    if not state.jump_cfi then return end
    -- That chapter has not arrived. Wait on its stub: the reader is rebuilt when it does.
    local target = store:fragment_of_spine_index(Cfi.spine_index(news.cfi))
    Background.set_priority(store, target)
    self.ui.rolling:onGotoXPointer(("/body/DocFragment[%d]"):format(target))
    self.base_xp = self.ui.document:getXPointer()
end

--- Goes to the place asked for, if its chapter is in the book by now.
function Yaknigi:jumpIfWaiting(state)
    local cfi, store = state.jump_cfi, self.store
    if not cfi then return end
    local target = store:fragment_of_spine_index(Cfi.spine_index(cfi))
    if (state.stubs or {})[target] or not store:has(store.paths[target]) then return end
    state.jump_cfi = nil
    self.ui.rolling:onGotoXPointer(Cfi.to_xpointer(cfi, target, store:read(store.paths[target])))
    self.base_xp = self.ui.document:getXPointer()
end

function Yaknigi:stayHere()
    local store = self.store
    local news = Session.read_news(store.dir)
    if not news then return end
    Session.answered(store, news)
    workers[store.id].jump_cfi = nil
    -- What was held back can go now.
    if Sync.waiting(store.dir) then self:exchange() end
end

function Yaknigi:saveReading()
    if self.shell and self.store and self.ui.document then
        Session.save_reading(self.store.dir, self.shell:progress())
        self:sendPosition()
    end
end

function Yaknigi:onSuspend()
    -- The phone may be next: do not leave it a position behind.
    self:saveReading()
    self.wake_try = nil
    if self.notes_dirty then self:syncNotes() end
end

function Yaknigi:onResume()
    -- The phone may have been read while this one slept.
    self.wake_try = 1
    self:exchange()
    -- Wi-Fi takes a while to come back.
    UIManager:scheduleIn(NOTES_AFTER_WAKING_SECONDS, function() self:syncNotes() end)
    -- The time on the page is hours behind.
    if self.shell and self.ui.view then self.shell:onWake() end
end

function Yaknigi:onCloseDocument()
    self:stopPoll()
    if self.shell then self.shell:stop() end
    -- KOReader closes the document before its last SaveSettings, so that one is too late.
    self:saveReading()
    if self.notes_soon then UIManager:unschedule(self.notes_soon) end
    if self.notes_dirty then self:syncNotes(true) end
    self.closed = true
    if self.prompt then
        UIManager:close(self.prompt)
        self.prompt = nil
    end
end

function Yaknigi:onSaveSettings()
    self:saveReading()
end

function Yaknigi:onSetDimensions()
    -- The screen was rotated; KOReader has laid out its zones for the new shape.
    if self.shell then
        UIManager:nextTick(function() self.shell:registerZone() end)
    end
end

-- Plugin ----------------------------------------------------------------------

function Yaknigi:init()
    if self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    -- Every return from a book makes a new file manager, which brings the library back.
    if APP_MODE and not self.ui.document then
        -- It stands under the library and is never to be seen, not even for a moment.
        self.ui.paintTo = function() end
        UIManager:nextTick(function()
            self:showLibrary()
            local card = open_next
            open_next = nil
            if card then UIManager:nextTick(function() self:openCard(card) end) end
        end)
    end
end

function Yaknigi:addToMainMenu(menu_items)
    menu_items.yaknigi = {
        text = "Яндекс Книги",
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = "Библиотека",
                callback = function() self:showLibrary() end,
            },
            {
                text = "Выйти из аккаунта",
                enabled_func = function() return saved_token() ~= nil end,
                keep_menu_open = true,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = "Выйти из аккаунта Яндекса?",
                        ok_callback = function() save_token(nil) end,
                    })
                end,
            },
        },
    }
end

return Yaknigi
