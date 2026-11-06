-- What can be chosen in the settings, and what follows from each choice. The texts are
-- plain functions, so that they can be tested without KOReader.
local Prefs = {}

Prefs.PROGRESS = { "percent", "page", "page_of", "chapter", "book" }
Prefs.SLEEP_MINUTES = { 5, 10, 15, 30, 60 }
Prefs.SLEEP_SCREENS = { "cover", "page" }
-- How often the screen is flashed clean, in pages. -1 and 0 are KOReader's own values.
Prefs.REFRESH = {
    { 1, "Каждую страницу" },
    { 3, "Каждые 3 страницы" },
    { 6, "Каждые 6 страниц" },
    { 12, "Каждые 12 страниц" },
    { -1, "Каждую главу" },
    { 0, "Никогда" },
}
Prefs.DEFAULT_REFRESH = 6
-- The room above the text, where the clock stands. KOReader's margins are in unscaled pixels.
Prefs.PAGE_TOP_MARGIN = 28

local function percent(share)
    return math.floor(share * 100 + 0.5)
end

--- info: { ratio=, page=, pages=, chapter_left=, chapter_pages= }. While the book is a
-- skeleton there are no pages to speak of, only the ratio; that shows as a percentage.
-- long: for the panel, where the bare number would say nothing.
--- What to show of the progress. A second value goes to the other side of the screen.
function Prefs.progress_text(format, info, long)
    if info.page and info.pages then
        if format == "page_of" then
            return ("%d из %d"):format(info.page, info.pages)
        elseif format == "page" then
            return long and ("Страница %d"):format(info.page) or tostring(info.page)
        elseif format == "book" then
            local left = info.pages - info.page
            return ("До конца книги: %d стр."):format(left), ("%d%%"):format(percent(left / math.max(1, info.pages)))
        elseif format == "chapter" and info.chapter_left then
            return ("До конца главы: %d стр."):format(info.chapter_left),
                ("%d%%"):format(percent(info.chapter_left / math.max(1, info.chapter_pages)))
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

--- What comes after value in list, and the first after the last.
function Prefs.following(list, value)
    for i, v in ipairs(list) do
        if v == value then return list[i % #list + 1] end
    end
    return list[1]
end

--- A tap on the progress on the page: the next way of showing it.
function Prefs.next_progress()
    local format = Prefs.following(Prefs.PROGRESS, Prefs.progress_format())
    G_reader_settings:saveSetting("yaknigi_progress", format)
    return format
end

--- Where to get a cover for the whole screen, best first. The API names a small picture and
-- a medium one; every cover also has its original beside them, under the same name.
-- cover: { small=, large=, url= }, as in a library card or a found book.
function Prefs.sleep_cover_urls(cover)
    local urls, seen = {}, {}
    local function add(url)
        if type(url) == "string" and not seen[url] then
            seen[url] = true
            urls[#urls + 1] = url
        end
    end
    local function sized(url, size)
        if type(url) ~= "string" then return nil end
        local changed = url:gsub("%-%a+(%.%w+%??[^/]*)$", "-" .. size .. "%1")
        return changed
    end
    if type(cover) ~= "table" then return urls end
    local any = cover.large or cover.url or cover.small
    add(sized(any, "original"))
    add(sized(any, "ipad"))
    add(cover.large)
    add(cover.url)
    add(cover.small)
    return urls
end

function Prefs.refresh_rate()
    return G_reader_settings:readSetting("full_refresh_count") or Prefs.DEFAULT_REFRESH
end

--- Takes effect at once, for the light theme and the dark one alike.
function Prefs.set_refresh_rate(rate)
    require("ui/uimanager"):setRefreshRate(rate, rate)
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
    -- The picture whole, on white: KOReader then flashes the screen white before showing it.
    s:saveSetting("screensaver_img_background", "white")
    s:saveSetting("screensaver_stretch_images", false)
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
    -- Not in settings.reader.lua: a change there would replace everything the reader has chosen.
    G_reader_settings:saveSetting("copt_t_page_margin", Prefs.PAGE_TOP_MARGIN)
    Prefs.apply_sleep_screen()
end

return Prefs
