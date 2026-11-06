--[[--
Yandex Books: sign in, browse the library and read, with books opening at once.

@module koplugin.yaknigi
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
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
local Crypt = require("yaknigi/crypt")
local Session = require("yaknigi/session")
local Store = require("yaknigi/store")

local ROOT = DataStorage:getDataDir() .. "/yaknigi"
local BOOKS = ROOT .. "/books"
local LIBRARY_CACHE = ROOT .. "/library.json"
os.execute("mkdir -p '" .. BOOKS .. "'")

-- The app mode shows the library instead of the file manager, and leaves with it.
local APP_MODE = os.getenv("YAKNIGI_APP") == "1"
local POLL_SECONDS = 2

-- Survives the ReaderUI being rebuilt on reload. Keyed by book id.
local workers = {}

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
    if kind == "not_found" then return "Сериалы здесь пока не открываются." end
    if kind == "disk" then return "Не удалось записать на устройство." end
    return "Яндекс Книги вернули ошибку."
end

-- Sign-in ---------------------------------------------------------------------

function Yaknigi:showLogin()
    local verifier = Crypt.new_verifier()
    local url = Api.login_url(verifier)
    local dialog
    local function ask_code()
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
            self:showLibrary()
            return
        end
        message(kind == "bad_code" and "Код не подошёл." or error_text(kind), 3)
        retry()
    end)
end

-- Library ---------------------------------------------------------------------

local function card_title(card)
    local book = card.book or {}
    local authors = {}
    for _, a in ipairs(book.authors_objects or book.authors or {}) do
        if type(a) == "table" and a.name then authors[#authors + 1] = a.name end
    end
    local title = book.title or "?"
    if #authors > 0 then title = title .. " — " .. table.concat(authors, ", ") end
    return title
end

local function sorted_cards(cards)
    -- Same-format timestamps sort as text; books never opened go last.
    local function stamp(c) return tostring(c.accessed_at or "") end
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

function Yaknigi:libraryItems(cards)
    local items = {}
    for _, card in ipairs(sorted_cards(cards)) do
        local store = card.book and card.book.uuid and Store.open(BOOKS, card.book.uuid)
        local progress = tonumber(card.progress)
        items[#items + 1] = {
            text = ((store and store:is_whole()) and "✓ " or "") .. card_title(card),
            mandatory = progress and progress > 0 and (math.floor(progress) .. "%") or nil,
            card = card,
        }
    end
    return items
end

function Yaknigi:showLibrary()
    if self.library then UIManager:close(self.library) end
    local signed_in = saved_token() ~= nil
    local cached = signed_in and read_json(LIBRARY_CACHE) or nil
    local items
    if not signed_in then
        items = { { text = "Войдите по QR-коду, затем коснитесь экрана", sign_in = true } }
    else
        items = cached and self:libraryItems(cached) or {}
    end
    local menu
    menu = Menu:new{
        title = "Яндекс Книги",
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        single_line = true,
        onMenuSelect = function(_menu, item)
            if item.sign_in then self:showLogin() else self:openCard(item.card) end
        end,
        close_callback = function()
            UIManager:close(menu)
            self.library = nil
            if APP_MODE then UIManager:quit() end
        end,
        title_bar_left_icon = "cre.render.reload",
        onLeftButtonTap = function() self:refreshLibrary(true) end,
    }
    self.library = menu
    UIManager:show(menu)
    if signed_in then
        UIManager:nextTick(function() self:refreshLibrary(cached == nil) end)
    else
        UIManager:nextTick(function() self:showLogin() end)
    end
end

function Yaknigi:refreshLibrary(tell_failure)
    local function fetch()
        local api = Api.new(saved_token())
        local cards, kind = api:library()
        api:close()
        if not cards then
            if kind == "auth" then
                save_token(nil)
                self:showLibrary()
            elseif tell_failure then
                message(error_text(kind), 3)
            end
            return
        end
        write_json(LIBRARY_CACHE, cards)
        if self.library then
            self.library:switchItemTable(nil, self:libraryItems(cards))
        end
    end
    if tell_failure then
        NetworkMgr:runWhenOnline(fetch)
    elseif NetworkMgr:isOnline() then
        fetch()
    end
end

local function saved_fragment(path)
    if not DocSettings:hasSidecarFile(path) then return nil end
    local xp = DocSettings:open(path):readSetting("last_xpointer")
    return xp and tonumber(xp:match("DocFragment%[(%d+)%]"))
end

function Yaknigi:openCard(card)
    local id = card.book and card.book.uuid
    local store = Store.open(BOOKS, id)
    if store and store:is_whole() then
        -- Nothing to wait for, not even the network.
        local fresh = card.cfi and card.accessed_at ~= Session.read_stamp(store)
        self:showBook(store, fresh and Session.jump_for(store, card) or nil)
        return
    end
    NetworkMgr:runWhenOnline(function() self:loadAndOpen(card, store) end)
end

function Yaknigi:loadAndOpen(card, store)
    local wait = InfoMessage:new{ text = "Открываю…" }
    UIManager:show(wait)
    UIManager:forceRePaint()

    local api = Api.new(saved_token())
    local fragment = store and saved_fragment(store.epub)
    local result, stubs, xpointer, target = Session.prepare(BOOKS, api, card, fragment)
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
    self:showBook(result, xpointer, target, stubs)
end

function Yaknigi:showBook(store, xpointer, target, stubs)
    if self.library then
        UIManager:close(self.library)
        self.library = nil
    end
    workers[store.id] = workers[store.id] or {}
    local state = workers[store.id]
    state.target = target or state.target
    state.stubs = stubs or {}
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(store.epub, nil, false, nil, function(ui)
        if xpointer then ui.rolling:onGotoXPointer(xpointer) end
    end)
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

function Yaknigi:onReaderReady()
    local store = self:readerStore()
    if not store or not store.manifest then return end
    self.store = store
    self:keepChapter()
    local state = workers[store.id] or {}
    workers[store.id] = state
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
    if needed then
        if store:has(store.paths[needed]) then
            local stubs = store:build()
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

function Yaknigi:onCloseDocument()
    self:stopPoll()
end

-- Plugin ----------------------------------------------------------------------

function Yaknigi:init()
    if self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    -- Every return from a book makes a new file manager, which brings the library back.
    if APP_MODE and not self.ui.document then
        UIManager:nextTick(function() self:showLibrary() end)
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
