-- Search through all of Yandex's books: what has been found so far, for the library to show.
local Catalogue = {}

--- A new search. Without a query there is nothing to ask until one is typed.
function Catalogue.new(query)
    return { query = query, items = {}, seen = {}, cursor = "", finished = query == nil }
end

--- Returns true when a request is to be made now: not while one is under way, nor after
-- the last page.
function Catalogue.start(state)
    if state.loading or state.finished then return false end
    state.loading = true
    state.failed = nil
    return true
end

function Catalogue.fail(state, kind)
    state.loading = false
    state.failed = kind
end

-- Search gives the big picture only. Every cover has a small one beside it, as in a library
-- card, and a list on a slow network should not wait for the big ones.
local function thumb(url)
    return (url:gsub("%-ipad(%.%w+)", "-thumb%1", 1))
end

--- What the library needs of a found book. Nil for what cannot be opened.
function Catalogue.item(found)
    local book = type(found) == "table" and found.book
    if type(book) ~= "table" or type(book.uuid) ~= "string" then return nil end
    local title = type(book.name) == "string" and book.name or "?"
    local names = {}
    for _, author in ipairs(type(book.authors) == "table" and book.authors or {}) do
        if type(author) == "table" and type(author.name) == "string" then names[#names + 1] = author.name end
    end
    local url = type(book.cover) == "table" and book.cover.url
    local in_library = type(found.progress) == "table" and found.progress.inLibrary == true
    return {
        found = true,
        text = title,
        title = title,
        authors = table.concat(names, ", "),
        annotation = type(book.annotation) == "string" and book.annotation or nil,
        in_library = in_library,
        mandatory = in_library and "в библиотеке" or nil,
        -- Enough of a library card for the covers to work with.
        card = { book = {
            uuid = book.uuid,
            title = title,
            cover = type(url) == "string" and { small = thumb(url), large = url } or nil,
        } },
    }
end

--- Takes in a page of results. Returns the books that were not there yet.
function Catalogue.add(state, items, cursor)
    local new = {}
    for _, item in ipairs(items) do
        local id = item.card.book.uuid
        if not state.seen[id] then
            state.seen[id] = true
            state.items[#state.items + 1] = item
            new[#new + 1] = item
        end
    end
    state.loading = false
    state.failed = nil
    -- A cursor that goes nowhere must not have the list asking for ever.
    state.finished = type(cursor) ~= "string" or cursor == "" or cursor == state.cursor or #new == 0
    state.cursor = type(cursor) == "string" and cursor or state.cursor
    return new
end

--- The books as cards, for the covers.
function Catalogue.cards(items)
    local cards = {}
    for i, item in ipairs(items) do cards[i] = item.card end
    return cards
end

function Catalogue.mark_added(item, card)
    item.in_library = true
    item.mandatory = "в библиотеке"
    item.card = card
end

return Catalogue
