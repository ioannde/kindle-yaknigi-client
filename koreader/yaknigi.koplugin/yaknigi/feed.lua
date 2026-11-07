-- Yandex's own feed of recommendations: what has come of it so far, for the library to show.
local Catalogue = require("yaknigi/catalogue")

local Feed = {}

-- The feed the phone app opens with, should the list of feeds not come.
Feed.ROOT = "EKSEfw9w"
-- Sections with fewer books than this have mostly lost them to the filter: audiobooks.
local FEWEST_BOOKS = 3
-- At least as many as stand in a row of the feed on any screen, for the covers to be got.
Feed.ROW_COVERS = 8
-- Pages can hold only audiobooks, but not without end.
local EMPTY_PAGES_AT_MOST = 3

function Feed.new()
    return { sections = {}, cursor = "", finished = false }
end

--- A feed saved earlier. It shows at once and is asked for again before anything else.
function Feed.from_saved(saved)
    local state = Feed.new()
    if type(saved) ~= "table" or type(saved.sections) ~= "table" then return state end
    state.sections = saved.sections
    state.cursor = type(saved.cursor) == "string" and saved.cursor or ""
    state.uuid = type(saved.uuid) == "string" and saved.uuid or nil
    state.finished = state.cursor == ""
    state.stale = true
    return state
end

--- Asks for it from the start, keeping what is on the screen until the answer comes.
function Feed.renew(state)
    state.stale = true
end

--- The cursor to ask with now, nil if nothing is to be asked: one request at a time, and
-- none after the last page.
function Feed.start(state)
    if state.loading then return nil end
    local cursor
    if state.stale then
        cursor = ""
    elseif not state.finished then
        cursor = state.cursor
    else
        return nil
    end
    state.loading = true
    state.failed = nil
    state.asked = cursor
    return cursor
end

function Feed.fail(state, text)
    state.loading = false
    state.failed = text
end

--- What can be shown of a page of the feed: named sections of books that can be read.
function Feed.sections(page)
    local sections = {}
    for _, section in ipairs(type(page) == "table" and page or {}) do
        local list = type(section) == "table" and type(section.items) == "table" and section.items.page
        -- A featured section's name is an internal one, and it holds advertised picks.
        if type(list) == "table" and type(section.name) == "string" and section.name ~= ""
            and section.__typename ~= "FeaturedSection" then
            local books, seen = {}, {}
            for _, entry in ipairs(list) do
                local readable = type(entry) == "table" and (entry.__typename == "TextBook" or entry.__typename == "TextSerial")
                local item = readable and Catalogue.item(entry)
                if item and not seen[item.card.book.uuid] then
                    seen[item.card.book.uuid] = true
                    books[#books + 1] = item
                end
            end
            if #books >= FEWEST_BOOKS then
                sections[#sections + 1] = { name = section.name, items = books }
            end
        end
    end
    return sections
end

--- Takes in an answer. Returns the sections that were not there yet.
function Feed.add(state, sections, cursor)
    if state.asked == "" then
        state.sections = {}
        state.empty_pages = 0
    end
    for _, section in ipairs(sections) do state.sections[#state.sections + 1] = section end
    state.empty_pages = #sections == 0 and (state.empty_pages or 0) + 1 or 0
    state.loading = false
    state.failed = nil
    state.stale = nil
    local before = state.asked
    -- A cursor that goes nowhere must not have the list asking for ever.
    state.finished = type(cursor) ~= "string" or cursor == "" or cursor == before
        or state.empty_pages >= EMPTY_PAGES_AT_MOST
    state.cursor = type(cursor) == "string" and cursor or ""
    return sections
end

--- All the books, or as many of each section as stand in its row, as cards for the covers.
function Feed.cards(sections, each)
    local cards = {}
    for _, section in ipairs(sections) do
        for i, item in ipairs(section.items) do
            if each and i > each then break end
            cards[#cards + 1] = item.card
        end
    end
    return cards
end

function Feed.items(state)
    local items = {}
    for _, section in ipairs(state.sections) do
        for _, item in ipairs(section.items) do items[#items + 1] = item end
    end
    return items
end

return Feed
