-- Search through all of Yandex's books, and the lists it leads to (a series, an author's books,
-- the episodes of a serial): what has come so far, for the library to show.
local Catalogue = {}

--- "1 книга", "2 книги", "5 книг".
function Catalogue.count(n, one, few, many)
    local tens, units = n % 100, n % 10
    local word = many
    if tens < 11 or tens > 14 then
        if units == 1 then word = one
        elseif units >= 2 and units <= 4 then word = few end
    end
    return n .. " " .. word
end

--- A new search. Without a query there is nothing to ask until one is typed.
function Catalogue.new(query)
    return { query = query, items = {}, seen = {}, cursor = "", finished = query == nil }
end

--- The list of a series, an author, a serial, a shelf or of the shelves: kind is "series", "author",
-- "serial", "bookshelf" or "bookshelves".
function Catalogue.collection(kind, uuid, title)
    return { kind = kind, uuid = uuid, title = title, items = {}, seen = {}, cursor = "", finished = false }
end

--- Returns true when a request is to be made now: not while one is under way, nor after
-- the last page.
function Catalogue.start(state)
    if state.loading or state.finished then return false end
    state.loading = true
    state.failed = nil
    return true
end

--- From the first page again, for a list that has changed. What is on its way is of the old list.
function Catalogue.renew(state)
    state.items, state.seen, state.cursor = {}, {}, ""
    state.finished, state.loading, state.failed = false, false, nil
    state.round = (state.round or 0) + 1
end

function Catalogue.fail(state, kind)
    state.loading = false
    state.failed = kind
end

-- Search gives the big picture only. Every cover has a small one beside it, as in a library
-- card, and a list on a slow network should not wait for the big ones.
local function thumb(url)
    return (url:gsub("%-ipad(%.%w+)", "-thumb%1", 1):gsub("%-large(%.%w+)", "-thumb%1", 1))
end

local function picture(url)
    if type(url) ~= "string" then return nil end
    return { small = thumb(url), large = url }
end

local function names_of(list)
    local names = {}
    for _, person in ipairs(type(list) == "table" and list or {}) do
        if type(person) == "table" and type(person.name) == "string" then names[#names + 1] = person.name end
    end
    return table.concat(names, ", ")
end

--- What leads to a list rather than to a book: its card has only what the covers work with.
local function list_item(kind, uuid, title, authors, cover, kind_text)
    return {
        found = true,
        kind = kind,
        uuid = uuid,
        text = title,
        title = title,
        authors = authors,
        kind_text = kind_text,
        card = { book = { uuid = uuid, title = title, cover = cover } },
    }
end

local function has(list, value)
    for _, one in ipairs(type(list) == "table" and list or {}) do
        if one == value then return true end
    end
    return false
end

-- Translators and narrators come too, and those whose books are all gone.
local function person_item(found)
    if type(found.uuid) ~= "string" or not has(found.roles, "AUTHOR") then return nil end
    local works = tonumber(found.worksCount) or 0
    if works < 1 then return nil end
    local name = type(found.name) == "string" and found.name or "?"
    local url = type(found.avatar) == "table" and found.avatar.url
    -- Those with no portrait have a drawing, the same for many. A letter says more.
    if type(url) == "string" and url:find("/default", 1, true) then url = nil end
    return list_item("author", found.uuid, name, "", picture(url),
        "Автор · " .. Catalogue.count(works, "произведение", "произведения", "произведений"))
end

local function series_text(total)
    total = tonumber(total)
    return total and "Серия · " .. Catalogue.count(total, "книга", "книги", "книг") or "Серия"
end

local function series_item(found)
    if type(found.uuid) ~= "string" then return nil end
    local total = type(found.items) == "table" and found.items.total
    local url = type(found.cover) == "table" and found.cover.url
    return list_item("series", found.uuid, type(found.name) == "string" and found.name or "?",
        names_of(found.authors), picture(url), series_text(total))
end

local function serial_text(total)
    total = tonumber(total)
    return total and "Сериал · " .. Catalogue.count(total, "эпизод", "эпизода", "эпизодов") or "Сериал"
end

local function shelf_item(found)
    if type(found.uuid) ~= "string" then return nil end
    local total = tonumber(type(found.posts) == "table" and found.posts.total)
    local owner = type(found.user) == "table" and type(found.user.name) == "string" and found.user.name or nil
    local url = type(found.cover) == "table" and found.cover.url
    return list_item("bookshelf", found.uuid, type(found.name) == "string" and found.name or "?", owner, picture(url),
        total and "Полка · " .. Catalogue.count(total, "книга", "книги", "книг") or "Полка")
end

--- What the library needs of what was found. Nil for what cannot be opened here.
function Catalogue.item(found)
    if type(found) == "table" and found.__typename == "Person" then return person_item(found) end
    if type(found) == "table" and found.__typename == "Bookshelf" then return shelf_item(found) end
    if type(found) == "table" and found.__typename == "Series" then return series_item(found) end
    local book = type(found) == "table" and found.book
    if type(book) ~= "table" or type(book.uuid) ~= "string" then return nil end
    local title = type(book.name) == "string" and book.name or "?"
    local url = type(book.cover) == "table" and book.cover.url
    local persons = {}
    for _, author in ipairs(type(book.authors) == "table" and book.authors or {}) do
        if type(author) == "table" then persons[#persons + 1] = { name = author.name, uuid = author.uuid } end
    end
    if found.__typename == "TextSerial" then
        local item = list_item("serial", book.uuid, title, names_of(book.authors), picture(url),
            serial_text(type(found.episodes) == "table" and found.episodes.total))
        item.annotation = type(book.annotation) == "string" and book.annotation or nil
        item.card.book.authors_objects = persons
        return item
    end
    local in_library = type(found.progress) == "table" and found.progress.inLibrary == true
    return {
        found = true,
        text = title,
        title = title,
        authors = names_of(book.authors),
        annotation = type(book.annotation) == "string" and book.annotation or nil,
        in_library = in_library,
        mandatory = in_library and "в библиотеке" or nil,
        -- Enough of a library card for the covers to work with.
        card = { book = {
            uuid = book.uuid,
            title = title,
            cover = picture(url),
            authors_objects = persons,
        } },
    }
end

local SHELVES_SHOWN, SHELVES_AFTER = 3, 3

--- Puts the first shelves found among the first books found, and past them a way to the
-- rest. In a search they would take the page: "русская классика" is 24 shelves in 25.
function Catalogue.with_shelves(items, found, query)
    local shelves = {}
    for _, one in ipairs(found) do shelves[#shelves + 1] = Catalogue.item(one) end
    local at = math.min(SHELVES_AFTER, #items)
    for i = 1, math.min(SHELVES_SHOWN, #shelves) do table.insert(items, at + i, shelves[i]) end
    if #shelves > SHELVES_SHOWN then
        local all = list_item("found_shelves", query, "Все полки", nil, shelves[1].card.book.cover,
            ("Полки по запросу «%s»"):format(query))
        -- It names a file of the cover: the words of a query have no place there.
        all.card.book.uuid = "found-shelves-" .. shelves[1].uuid
        all.list_title = ("Полки: «%s»"):format(query)
        table.insert(items, at + SHELVES_SHOWN + 1, all)
    end
    return items
end

-- REST ---------------------------------------------------------------------------
-- The lists come from another part of Yandex, where a book is written differently.

local function rest_cover(book)
    local cover = book.cover
    if type(cover) ~= "table" or type(cover.small) ~= "string" then return nil end
    return { small = cover.small, large = cover.large }
end

local function rest_authors(book)
    if type(book.authors_objects) == "table" then return names_of(book.authors_objects) end
    return type(book.authors) == "string" and book.authors or names_of(book.authors)
end

--- What stands in a list but cannot be read: it is seen, with a word why, and goes no further.
local function make_unavailable(item, why, word)
    item.unavailable = why
    item.mandatory = word or "недоступна"
    return item
end

local UNAVAILABLE = "Эта книга сейчас недоступна."
Catalogue.UNAVAILABLE = UNAVAILABLE
local AUDIO_ONLY = "Эта книга есть только в аудио: здесь её не прочитать."

--- A book as a list gives it.
function Catalogue.rest_book(book)
    if type(book) ~= "table" or type(book.uuid) ~= "string" then return nil end
    local title = type(book.title) == "string" and book.title or "?"
    if book.source_type == "serial" then
        local item = list_item("serial", book.uuid, title, rest_authors(book), rest_cover(book),
            serial_text(book.episodes_count))
        item.annotation = type(book.annotation) == "string" and book.annotation or nil
        item.card.book.authors_objects = book.authors_objects
        if book.can_be_read == false then make_unavailable(item, UNAVAILABLE) end
        return item
    end
    local in_library = book.in_library == true
    local item = {
        found = true,
        text = title,
        title = title,
        authors = rest_authors(book),
        annotation = type(book.annotation) == "string" and book.annotation or nil,
        in_library = in_library,
        mandatory = in_library and "в библиотеке" or nil,
        card = { book = {
            uuid = book.uuid,
            title = title,
            cover = rest_cover(book),
            authors_objects = book.authors_objects,
            series_list = book.series_list,
        } },
    }
    if book.can_be_read == false then make_unavailable(item, UNAVAILABLE) end
    return item
end

--- A part of a series. A book's audio version is a part with the same number and says nothing
-- new, so it is left out: read_at holds the numbers that have something to read. A number with
-- only something else shows the reader what is missing from the series.
function Catalogue.part(part, read_at)
    if type(part) ~= "table" then return nil end
    local is_book = part.resource_type == "book"
    if not is_book and read_at and read_at[part.position] then return nil end
    local item = Catalogue.rest_book(part.resource)
    if not item then return nil end
    if not is_book then
        if part.resource_type == "audiobook" then make_unavailable(item, AUDIO_ONLY, "только аудио")
        else make_unavailable(item, UNAVAILABLE) end
    end
    local label = part.position_label or part.position
    if label and not item.kind then item.kind_text = "Книга " .. tostring(label) end
    return item
end

--- A shelf of Yandex's: its own screen of books.
function Catalogue.bookshelf(shelf)
    if type(shelf) ~= "table" or type(shelf.uuid) ~= "string" then return nil end
    local count = tonumber(shelf.books_count)
    local creator = type(shelf.creator) == "table" and shelf.creator.name
    local whose = (shelf.own or shelf.editable == true) and "Моя полка" or "Подписка"
    return list_item("bookshelf", shelf.uuid, type(shelf.title) == "string" and shelf.title or "?",
        type(creator) == "string" and creator or nil, rest_cover(shelf),
        count and (whose .. " · " .. Catalogue.count(count, "книга", "книги", "книг")) or whose)
end

function Catalogue.rest_series(series)
    if type(series) ~= "table" or type(series.uuid) ~= "string" then return nil end
    return list_item("series", series.uuid, type(series.title) == "string" and series.title or "?",
        rest_authors(series), rest_cover(series), series_text(series.parts_count))
end

--- Whether a series has books to read, going by its kinds: there are audio-only ones.
function Catalogue.has_books(series)
    return has(type(series) == "table" and series.kinds, "books")
end

--- What a page of a list holds, as the library shows it.
function Catalogue.from_page(kind, page)
    local items = {}
    local function put(item) if item then items[#items + 1] = item end end
    for _, series in ipairs(page.series or {}) do
        if Catalogue.has_books(series) then put(Catalogue.rest_series(series)) end
    end
    for _, book in ipairs(page.books or {}) do put(Catalogue.rest_book(book)) end
    local read_at = {}
    for _, part in ipairs(page.parts or {}) do
        if type(part) == "table" and part.resource_type == "book" and part.position then
            read_at[part.position] = true
        end
    end
    for _, part in ipairs(page.parts or {}) do put(Catalogue.part(part, read_at)) end
    for _, shelf in ipairs(page.bookshelves or {}) do put(Catalogue.bookshelf(shelf)) end
    return items
end

--- Where a book leads: its series and its first author, as what opens those lists.
function Catalogue.links(book)
    local links = {}
    local series = type(book) == "table" and type(book.series_list) == "table" and book.series_list[1]
    if type(series) == "table" and type(series.uuid) == "string" then
        links[#links + 1] = { kind = "series", uuid = series.uuid, title = series.title or "Серия" }
    end
    local author = type(book) == "table" and type(book.authors_objects) == "table" and book.authors_objects[1]
    if type(author) == "table" and type(author.uuid) == "string" then
        links[#links + 1] = { kind = "author", uuid = author.uuid, title = author.name or "Автор" }
    end
    return links
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

--- The book has left the library: it is again a book found, and its card is no more.
function Catalogue.mark_removed(item)
    item.in_library = nil
    item.mandatory = nil
    item.card.uuid = nil
end

return Catalogue
