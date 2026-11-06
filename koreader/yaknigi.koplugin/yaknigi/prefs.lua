-- What can be chosen in the settings, and what follows from each choice. The texts are
-- plain functions, so that they can be tested without KOReader.
local Prefs = {}

Prefs.PROGRESS = { "percent", "page", "page_of", "chapter", "book" }
Prefs.SLEEP_MINUTES = { 5, 10, 15, 30, 60 }
Prefs.SLEEP_SCREENS = { "cover", "page" }

local function percent(share)
    return math.floor(share * 100 + 0.5)
end

--- info: { ratio=, page=, pages=, chapter_left=, chapter_pages= }. While the book is a
-- skeleton there are no pages to speak of, only the ratio; that shows as a percentage.
-- long: for the panel, where the bare number would say nothing.
function Prefs.progress_text(format, info, long)
    if info.page and info.pages then
        if format == "page_of" then
            return ("%d из %d"):format(info.page, info.pages)
        elseif format == "page" then
            return long and ("Страница %d"):format(info.page) or tostring(info.page)
        elseif format == "book" then
            local left = info.pages - info.page
            return ("До конца книги: %d стр. · %d%%"):format(left, percent(left / math.max(1, info.pages)))
        elseif format == "chapter" and info.chapter_left then
            return ("До конца главы: %d стр. · %d%%"):format(info.chapter_left,
                percent(info.chapter_left / math.max(1, info.chapter_pages)))
        end
    end
    return ("%d%%%s"):format(percent(info.ratio), long and " книги" or "")
end

--- Wi-Fi up and connected, up with no connection, or off: on a Kindle, the airplane mode.
function Prefs.network_symbol(wifi_on, connected)
    if not wifi_on then return "\u{F072}" end
    return connected and "\u{ECA8}" or "\u{ECA9}"
end

function Prefs.progress_format()
    return G_reader_settings:readSetting("yaknigi_progress") or "percent"
end

function Prefs.reading_clock()
    return G_reader_settings:nilOrTrue("yaknigi_reading_clock")
end

function Prefs.sleep_screen()
    return G_reader_settings:readSetting("yaknigi_sleep_screen") or "cover"
end

function Prefs.sleep_minutes()
    return math.floor((G_reader_settings:readSetting("auto_suspend_timeout_seconds") or 900) / 60 + 0.5)
end

--- Applies the sleep screen. cover: the picture of the book just opened, if there is one.
-- KOReader's own screensaver does the showing; these are its settings.
function Prefs.apply_sleep_screen(cover)
    local s = G_reader_settings
    if cover then s:saveSetting("yaknigi_last_cover", cover) end
    cover = s:readSetting("yaknigi_last_cover")
    local file = cover and io.open(cover, "rb")
    if file then file:close() end
    if Prefs.sleep_screen() == "cover" and file then
        s:saveSetting("screensaver_type", "document_cover")
        s:saveSetting("screensaver_document_cover", cover)
    else
        s:saveSetting("screensaver_type", "disable") -- the page stays as it is
    end
    s:saveSetting("screensaver_show_message", false)
    s:saveSetting("screensaver_delay", "disable") -- waking up takes it away at once
    s:flush()
end

--- Takes effect at once, in the same steps as the autosuspend plugin's own menu.
function Prefs.set_sleep_minutes(ui, minutes)
    local seconds = minutes * 60
    G_reader_settings:saveSetting("auto_suspend_timeout_seconds", seconds)
    local auto = ui and ui.autosuspend
    if auto then
        auto:_unschedule()
        auto:_unschedule_kindle()
        auto.auto_suspend_timeout_seconds = seconds
        auto:_start()
        auto:_start_kindle()
    end
end

--- What the app wants unless told otherwise.
function Prefs.init()
    if G_reader_settings:hasNot("swipe_animations") then
        G_reader_settings:saveSetting("swipe_animations", true)
    end
    Prefs.apply_sleep_screen()
end

return Prefs
