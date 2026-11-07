-- Yandex Books and OAuth requests.
local Crypt = require("yaknigi/crypt")
local Http = require("yaknigi/http")
local Net = require("yaknigi/net")
local json = require("rapidjson")
local logger = require("logger")

local API_BASE = os.getenv("YB_API_BASE") or "https://api.bookmate.yandex.net/api/v5"
local GRAPHQL_URL = os.getenv("YB_GRAPHQL_URL") or "https://api-gateway.bookmate.yandex.net/graphql"
local OAUTH_BASE = os.getenv("YB_OAUTH_BASE") or "https://oauth.yandex.ru"
local CLIENT_ID = "CLIENT_ID_REMOVED" -- public; PKCE needs no secret
local REDIRECT = "https://oauth.yandex.ru/verification_code"

local Api = {}
Api.__index = Api

--- Each Api owns one connection; a forked subprocess must create its own.
function Api.new(token)
    return setmetatable({ token = token, http = Http.new(Net.connect) }, Api)
end

function Api:close()
    self.http:close()
end

local function encode(s)
    return (s:gsub("[^%w%-_%.~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

function Api:headers(content_type)
    return {
        ["Auth-Token"] = self.token,
        ["App-Platform"] = "android",
        ["App-Language"] = "ru",
        ["App-Locale"] = "ru",
        ["Device-Os"] = "Android",
        ["Bookmate-Version"] = "20200305",
        ["User-Agent"] = "okhttp/4.12.0",
        ["Content-Type"] = content_type,
    }
end

function Api:get(url)
    local status, body = self.http:request("GET", url, self:headers())
    if not status then return nil, "network", body end
    if status == 401 or status == 403 then return nil, "auth" end
    if status == 404 then return nil, "not_found" end
    if status ~= 200 then return nil, "http", tostring(status) end
    return body
end

function Api:get_json(url)
    local body, kind, detail = self:get(url)
    if not body then return nil, kind, detail end
    local data, err = json.decode(body)
    if data == nil then return nil, "http", err end
    return data
end

-- JSON null decodes to a truthy value; absent is what the rest of the code expects.
local function drop_nulls(node)
    for k, v in pairs(node) do
        if v == json.null then
            node[k] = nil
        elseif type(v) == "table" then
            drop_nulls(v)
        end
    end
    return node
end

local function status_error(status, detail)
    if not status then return nil, "network", detail end
    if status == 401 or status == 403 then return nil, "auth" end
    if status == 404 then return nil, "not_found" end
    return nil, "http", tostring(status)
end

-- Yandex takes only queries it knows, to the letter, or answers "Whitelist: query not found".
local PROGRESS_UPDATED = "mutation ProgressUpdated($textbookProgresses: [TextbookProgressUpdatedInput!], $textSerialProgresses: [TextSerialProgressUpdatedInput!], $audiobookProgresses: [AudiobookProgressUpdatedInput!], $comicbookProgresses: [ComicbookProgressUpdatedInput!]) { progressUpdated(textbookProgresses: $textbookProgresses, textSerialProgresses: $textSerialProgresses, audiobookProgresses: $audiobookProgresses, comicbookProgresses: $comicbookProgresses) { value } }"

local SEARCH = "query Search($query: SearchParamsInput!) { search(query: $query) { page { __typename ...searchSnippetAudioBookFragment ...searchSnippetTextBookFragment ...searchSnippetComicBookFragment ...searchSnippetTextSerialFragment ...bookshelfFragment ...personFragment ...publisherFragment ...seriesFragment ...topicFragment ...userFragment } cursor rankedFilter { filterType } misspell { correctedText correctionType } } }  fragment coverFragment on Cover { url ratio backgroundColorHex }  fragment personFragment on Person { avatar { __typename ...coverFragment } name uuid worksCount roles }  fragment bookFragment on Book { annotation name cover { __typename ...coverFragment } uuid initUuid authors { __typename ...personFragment } editorAnnotation }  fragment publisherFragment on Publisher { avatar { __typename ...coverFragment } name uuid worksCount }  fragment publisherBookFragment on Book { publisher { __typename ...publisherFragment } }  fragment translatorsBookFragment on Book { translators { __typename ...personFragment } }  fragment topicsBookFragment on Book { topics { name totalBook uuid } }  fragment subscriptionLevelsFragment on Book { subscriptionLevels }  fragment snippetBookFragment on Book { __typename ...bookFragment ...publisherBookFragment ...translatorsBookFragment ...topicsBookFragment ...subscriptionLevelsFragment }  fragment narratorsAudioBookFragment on AudioBook { narrators { __typename ...personFragment } }  fragment progressFragment on Progress { finished inLibrary progress isPublic }  fragment progressAudioBookFragment on AudioBook { progress { __typename ...progressFragment } }  fragment listenersCountAudioBookFragment on AudioBook { listenersCount }  fragment subscriptionsFragment on Availability { subscriptions { types } }  fragment ageRestrictionFragment on Availability { ageRestriction { name value } }  fragment snippetAudioBookFragment on AudioBook { __typename book { __typename ...snippetBookFragment } ...narratorsAudioBookFragment ...progressAudioBookFragment ...listenersCountAudioBookFragment availability { __typename ...subscriptionsFragment ...ageRestrictionFragment } }  fragment bookTagsFragment on Book { tags { name value } }  fragment searchSnippetAudioBookFragment on AudioBook { __typename ...snippetAudioBookFragment book { __typename ...bookTagsFragment } }  fragment progressTextBookFragment on TextBook { progress { __typename ...progressFragment } }  fragment readersCountTextBookFragment on TextBook { readersCount }  fragment snippetTextBookFragment on TextBook { __typename book { __typename ...snippetBookFragment } availability { __typename ...subscriptionsFragment ...ageRestrictionFragment } ...progressTextBookFragment ...readersCountTextBookFragment }  fragment searchSnippetTextBookFragment on TextBook { __typename ...snippetTextBookFragment book { __typename ...bookTagsFragment } }  fragment progressComicBookFragment on ComicBook { progress { __typename ...progressFragment } }  fragment readersCountComicBookFragment on ComicBook { readersCount }  fragment snippetComicBookFragment on ComicBook { __typename book { __typename ...snippetBookFragment } ...progressComicBookFragment ...readersCountComicBookFragment availability { __typename ...subscriptionsFragment ...ageRestrictionFragment } }  fragment searchSnippetComicBookFragment on ComicBook { __typename ...snippetComicBookFragment book { __typename ...bookTagsFragment } }  fragment textSerialFragment on TextSerial { availability { __typename ...ageRestrictionFragment } book { __typename ...bookFragment } }  fragment episodesTextSerialFragment on TextSerial { episodes { total } }  fragment readersCountTextSerialFragment on TextSerial { readersCount }  fragment snippetTextSerialFragment on TextSerial { __typename book { __typename ...snippetBookFragment } availability { __typename ...subscriptionsFragment ...ageRestrictionFragment } ...textSerialFragment ...episodesTextSerialFragment ...readersCountTextSerialFragment }  fragment searchSnippetTextSerialFragment on TextSerial { __typename ...snippetTextSerialFragment book { __typename ...bookTagsFragment } }  fragment userFragment on User { avatar { __typename ...coverFragment } name uuid followersCount login }  fragment bookshelfFragment on Bookshelf { cover { __typename ...coverFragment } name uuid user { __typename ...userFragment } posts { total } followersCount description }  fragment seriesFragment on Series { authors { __typename ...personFragment } cover { __typename ...coverFragment } name uuid items { followersCount total } }  fragment topicFragment on Topic { name slug totalBook uuid parent { name slug totalBook uuid } }"

local SHOWCASE = "query Showcase($showcaseParamsInput: ShowcaseParamsInput!, $showcaseItemsCursor: String!, $sectionItemsCursor: String = \"\" ) { showcase(params: $showcaseParamsInput) { __typename ...fragmentShowcase ...childrenFragmentShowcase ...parentsFragmentShowcase items(cursor: $showcaseItemsCursor) { page { __typename ...featuredSectionFragment ...notificationFragment ...shelvesSectionFragment ...simpleSectionFragment ...statisticsSectionFragment ...topSectionFragment ...seriesSectionFragment ...ratingSectionFragment } cursor } } }  fragment fragmentShowcase on Showcase { name uuid availableFilters }  fragment childrenFragmentShowcase on Showcase { children { __typename ...fragmentShowcase } }  fragment parentsFragmentShowcase on Showcase { parents { __typename ...fragmentShowcase } }  fragment ageRestrictionFragment on Availability { ageRestriction { name value } }  fragment coverFragment on Cover { url ratio backgroundColorHex }  fragment personFragment on Person { avatar { __typename ...coverFragment } name uuid worksCount roles }  fragment bookFragment on Book { annotation name cover { __typename ...coverFragment } uuid initUuid authors { __typename ...personFragment } editorAnnotation }  fragment audioBookFragment on AudioBook { availability { __typename ...ageRestrictionFragment } book { __typename ...bookFragment } }  fragment comicBookFragment on ComicBook { availability { __typename ...ageRestrictionFragment } book { __typename ...bookFragment } }  fragment textBookFragment on TextBook { availability { __typename ...ageRestrictionFragment } book { __typename ...bookFragment } }  fragment textSerialFragment on TextSerial { availability { __typename ...ageRestrictionFragment } book { __typename ...bookFragment } }  fragment notificationFragment on Notification { consumer notificationPayloadId payload templateId feedbackToken }  fragment featuredSectionFragment on FeaturedSection { items(cursor: $sectionItemsCursor) { cursor page { __typename ...audioBookFragment ...comicBookFragment ...textBookFragment ...textSerialFragment ...notificationFragment } } name uuid }  fragment userFragment on User { avatar { __typename ...coverFragment } name uuid followersCount login }  fragment bookshelfFragment on Bookshelf { cover { __typename ...coverFragment } name uuid user { __typename ...userFragment } posts { total } followersCount description }  fragment shelvesSectionFragment on ShelvesSection { items(cursor: $sectionItemsCursor) { cursor page { __typename ...bookshelfFragment } } name uuid }  fragment seriesFragment on Series { authors { __typename ...personFragment } cover { __typename ...coverFragment } name uuid items { followersCount total } }  fragment simpleSectionFragment on SimpleSection { availableFilters items(cursor: $sectionItemsCursor) { cursor page { __typename ...audioBookFragment ...comicBookFragment ...textBookFragment ...textSerialFragment ...seriesFragment } } name uuid }  fragment statisticsSectionFragment on StatisticsSection { daysReadingInMonth updatedAt name uuid }  fragment topSectionFragment on TopSection { items(cursor: $sectionItemsCursor) { cursor page { __typename ...audioBookFragment ...comicBookFragment ...textBookFragment ...textSerialFragment } } name uuid }  fragment seriesSectionFragment on SeriesSection { items(cursor: $sectionItemsCursor) { cursor page { __typename ...seriesFragment } } name uuid }  fragment ratingSectionFragment on RatingSection { items(cursor: $sectionItemsCursor) { cursor page { __typename ...audioBookFragment ...comicBookFragment ...textBookFragment ...textSerialFragment } } name uuid }"

local ROOT_SHOWCASES = "query RootShowcases($rootShowcaseParamsInput: RootShowcaseParamsInput!) { rootShowcases(params: $rootShowcaseParamsInput) { children { __typename ...fragmentShowcase ...childrenFragmentShowcase ...parentsFragmentShowcase } notification { __typename ...notificationFragment } } }  fragment fragmentShowcase on Showcase { name uuid availableFilters }  fragment childrenFragmentShowcase on Showcase { children { __typename ...fragmentShowcase } }  fragment parentsFragmentShowcase on Showcase { parents { __typename ...fragmentShowcase } }  fragment notificationFragment on Notification { consumer notificationPayloadId payload templateId feedbackToken }"

--- Tells Yandex where the book is being read. Takes two requests, as in the phone app:
-- ProgressUpdated moves the position that other devices see; the library card holds the
-- percentage and the time of reading, and ignores the position it is sent.
function Api:send_position(p)
    local progress = {
        cfi = { start = p.start, ["end"] = p.finish },
        consumptionType = "CONSUMPTION",
        documentUuid = p.document,
        uuid = p.serial or p.book,
        episodeUuid = p.serial and p.book or nil,
        readAt = p.read_at,
        sessionId = p.session,
        timespent = p.timespent,
        timezoneId = "UTC",
    }
    local status, body = self.http:request("POST", GRAPHQL_URL, self:headers("application/json"), json.encode({
        operationName = "ProgressUpdated",
        query = PROGRESS_UPDATED,
        variables = p.serial and { textSerialProgresses = { progress } } or { textbookProgresses = { progress } },
    }))
    if status ~= 200 then return status_error(status, body) end
    local answer = json.decode(body)
    -- GraphQL says what went wrong in a successful response.
    if type(answer) ~= "table" or (answer.errors and answer.errors ~= json.null) then
        logger.warn("yaknigi: Yandex refused the position:", answer and answer.errors and answer.errors[1] and answer.errors[1].message)
        return nil, "http", "graphql"
    end

    local form = {
        "lc[progress]=" .. p.progress,
        "lc[cfi]=" .. encode(p.range),
    }
    if p.state then form[#form + 1] = "lc[state]=" .. encode(p.state) end
    local function put(card, fields)
        local encoded = {}
        for i, field in ipairs(fields) do
            encoded[i] = field:gsub("%[", "%%5B"):gsub("%]", "%%5D")
        end
        return self.http:request("PUT", API_BASE .. "/profile/library_cards/" .. encode(card),
            self:headers("application/x-www-form-urlencoded"), table.concat(encoded, "&"))
    end
    status, body = put(p.card, form)
    if status ~= 200 then return status_error(status, body) end
    -- A serial has a card of its own, which says which episode is being read.
    if p.serial_card then
        status, body = put(p.serial_card, {
            "lc[state]=reading",
            "lc[progress]=" .. p.progress,
            "lc[public]=true",
            "lc[is_in_child_library]=false",
            "lc[cfi]=" .. encode(p.range),
            "lc[current_episode_uuid]=" .. encode(p.book),
        })
        if status ~= 200 then return status_error(status, body) end
    end
    return true
end

--- Returns one library card as it is now.
function Api:card(uuid)
    local data, kind, detail = self:get_json(API_BASE .. "/profile/library_cards/" .. encode(uuid))
    if not data then return nil, kind, detail end
    if type(data.library_card) ~= "table" then return nil, "http", "no card" end
    return drop_nulls(data.library_card)
end

--- Returns every library card, fetching all pages.
function Api:library()
    local cards = {}
    local page = 1
    while true do
        local data, kind, detail = self:get_json(API_BASE .. "/profile/library_cards?page=" .. page)
        if not data then return nil, kind, detail end
        local got = data.library_cards
        if type(got) ~= "table" or #got == 0 then break end
        for _, c in ipairs(got) do cards[#cards + 1] = drop_nulls(c) end
        page = page + 1
    end
    return cards
end

--- Looks through all of Yandex's books. Returns { page = found books, cursor = where the
-- next page starts, or empty after the last one }.
function Api:search(text, cursor)
    local status, body = self.http:request("POST", GRAPHQL_URL, self:headers("application/json"), json.encode({
        operationName = "Search",
        query = SEARCH,
        variables = { query = {
            cursor = cursor or "",
            noMisspell = false,
            query = text,
            types = { "TEXTBOOK", "SERIAL", "SERIES", "AUTHOR" }, -- audiobooks and comics cannot be read here
        } },
    }))
    if status ~= 200 then return status_error(status, body) end
    local ok, answer = pcall(json.decode, body)
    if not ok or type(answer) ~= "table" or (answer.errors and answer.errors ~= json.null) then
        logger.warn("yaknigi: Yandex refused the search:", ok and type(answer) == "table" and type(answer.errors) == "table"
            and answer.errors[1] and answer.errors[1].message)
        return nil, "http", "graphql"
    end
    local found = type(answer.data) == "table" and answer.data.search
    if type(found) ~= "table" or type(found.page) ~= "table" then return nil, "http", "no results" end
    drop_nulls(found)
    return { page = found.page, cursor = found.cursor }
end

-- The parts of the phone app's feeds that are the same for each request of them.
local function graphql_data(self, name, query, variables)
    local status, body = self.http:request("POST", GRAPHQL_URL, self:headers("application/json"), json.encode({
        operationName = name,
        query = query,
        variables = variables,
    }))
    if status ~= 200 then return status_error(status, body) end
    local ok, answer = pcall(json.decode, body)
    if not ok or type(answer) ~= "table" or (answer.errors and answer.errors ~= json.null) then
        logger.warn("yaknigi: Yandex refused", name, ok and type(answer) == "table" and type(answer.errors) == "table"
            and answer.errors[1] and answer.errors[1].message)
        return nil, "http", "graphql"
    end
    if type(answer.data) ~= "table" then return nil, "http", "no data" end
    return drop_nulls(answer.data)
end

--- The id of the feed to show, nil if Yandex does not say.
function Api:root_showcase()
    local data, kind, detail = graphql_data(self, "RootShowcases", ROOT_SHOWCASES,
        { rootShowcaseParamsInput = { notificationFilters = json.array{} } })
    if not data then return nil, kind, detail end
    local root = data.rootShowcases
    local first = type(root) == "table" and type(root.children) == "table" and root.children[1]
    return type(first) == "table" and type(first.uuid) == "string" and first.uuid or nil
end

--- One page of a feed. Returns { page = its sections, cursor = where the next page starts }.
function Api:showcase(uuid, cursor)
    local data, kind, detail = graphql_data(self, "Showcase", SHOWCASE, {
        showcaseParamsInput = {
            contentFilter = json.array{},
            isSearch = false,
            notificationFilters = json.array{},
            uuid = uuid,
        },
        showcaseItemsCursor = cursor or "",
    })
    if not data then return nil, kind, detail end
    local showcase = data.showcase
    local items = type(showcase) == "table" and showcase.items
    if type(items) ~= "table" or type(items.page) ~= "table" then return nil, "http", "no sections" end
    return { page = items.page, cursor = items.cursor }
end

--- Puts a book into the library, visible to others as those added on the phone are.
function Api:add_book(book_uuid)
    local status, body = self.http:request("POST", API_BASE .. "/profile/library_cards",
        self:headers("application/x-www-form-urlencoded"),
        "book_uuid=" .. encode(book_uuid) .. "&lc%5Bstate%5D=pending&lc%5Bprogress%5D=0"
            .. "&lc%5Bpublic%5D=true&lc%5Bis_in_child_library%5D=false")
    if status == 403 then return nil, "denied" end
    if status ~= 200 and status ~= 201 then return status_error(status, body) end
    local ok, data = pcall(json.decode, body)
    local card = ok and type(data) == "table" and data.library_card
    if type(card) ~= "table" or type(card.book) ~= "table" then return nil, "http", "no card" end
    return drop_nulls(card)
end

local LIST_PAGE = 50

--- Whether a series holds books to read. If Yandex does not say, it stays in the results:
-- better an empty list than a series that cannot be found.
function Api:series_has_books(uuid)
    local data = self:get_json(API_BASE .. "/series/" .. encode(uuid))
    if type(data) ~= "table" or type(data.series) ~= "table" or type(data.series.kinds) ~= "table" then return true end
    for _, kind in ipairs(data.series.kinds) do
        if kind == "books" then return true end
    end
    return false
end

--- A page of a list: kind is "series", "author", "serial", "bookshelf" or "bookshelves" (which
-- has no uuid), and the cursor the page's number as text. Returns { books, parts, episodes,
-- bookshelves or series as Yandex gives them, cursor = the next page, empty after the last }.
function Api:collection(kind, uuid, cursor)
    local number = tonumber(cursor) or 1
    local paging = "page=" .. number .. "&per_page=" .. LIST_PAGE
    local id = encode(uuid or "")
    local url, field
    if kind == "bookshelves" then
        -- As in the app: one's own shelves, then those one follows.
        url, field = "/profile/bookshelves/following?" .. paging, "bookshelves"
    elseif kind == "bookshelf" then
        url, field = "/bookshelves/" .. id .. "/books?" .. paging, "books"
    elseif kind == "series" then
        url, field = "/series/" .. id .. "/parts?" .. paging, "parts"
    elseif kind == "author" then
        url, field = "/authors/" .. id .. "/books?role=author&" .. paging, "books"
    else
        url, field = "/books/" .. id .. "/episodes?" .. paging, "episodes"
    end
    local data, failure, detail = self:get_json(API_BASE .. url)
    if not data then return nil, failure, detail end
    local got = type(data[field]) == "table" and drop_nulls(data[field]) or {}
    local answer = { [field] = got, cursor = #got >= LIST_PAGE and tostring(number + 1) or "" }
    if kind == "bookshelves" and number == 1 then
        local own, why, more = self:get_json(API_BASE .. "/profile/bookshelves?page=1&per_page=" .. LIST_PAGE)
        if not own then return nil, why, more end
        local shelves = type(own.bookshelves) == "table" and drop_nulls(own.bookshelves) or {}
        local seen = {}
        for _, shelf in ipairs(shelves) do seen[shelf.uuid] = true end
        for _, shelf in ipairs(got) do
            if not seen[shelf.uuid] then shelves[#shelves + 1] = shelf end
        end
        answer.bookshelves = shelves
    end
    -- An author's series stand before the books. Having none is not a reason to show nothing.
    if kind == "author" and number == 1 then
        local series = self:get_json(API_BASE .. "/authors/" .. id .. "/series?role=author")
        if type(series) == "table" and type(series.series) == "table" then answer.series = drop_nulls(series.series) end
    end
    return answer
end

--- Puts a serial into the library with all its episodes, as the phone app does; a serial that is
-- there gets the episodes it has not got. Returns all their cards, the serial's first.
function Api:add_serial(serial_uuid)
    local data, kind, detail = self:get_json(API_BASE .. "/books/" .. encode(serial_uuid))
    if not data then return nil, kind, detail end
    local book = type(data.book) == "table" and data.book or {}
    if book.can_be_read == false then return nil, "denied" end
    local card
    if type(book.library_card_uuid) == "string" then
        card, kind, detail = self:card(book.library_card_uuid)
    else
        card, kind, detail = self:add_book(serial_uuid)
    end
    if not card then return nil, kind, detail end
    local cards = { card }
    local cursor = ""
    repeat
        local page
        page, kind, detail = self:collection("serial", serial_uuid, cursor)
        if not page then return nil, kind, detail end
        for _, episode in ipairs(page.episodes) do
            local mine = type(episode.library_card) == "table" and episode.library_card.uuid
            if mine then
                card, kind, detail = self:card(mine)
            else
                card, kind, detail = self:add_book(episode.uuid)
            end
            if not card then return nil, kind, detail end
            cards[#cards + 1] = card
        end
        cursor = page.cursor
    until cursor == ""
    return cards
end

--- Takes a book out of the library. A card already gone is as good as taken out.
function Api:remove_card(card_uuid)
    local status, body = self.http:request("DELETE", API_BASE .. "/profile/library_cards/" .. encode(card_uuid),
        self:headers())
    if status == 200 or status == 204 or status == 404 then return true end
    return status_error(status, body)
end

--- Returns the library card to read a found book by. The library here may be behind the
-- phone's, so Yandex is asked first; a book is added only if it is neither there already
-- nor out of the reader's reach, as it would then sit in the library unreadable.
function Api:card_for_reading(book_uuid)
    local data, kind, detail = self:get_json(API_BASE .. "/books/" .. encode(book_uuid))
    if not data then return nil, kind, detail end
    local book = type(data.book) == "table" and data.book or {}
    if type(book.library_card_uuid) == "string" then return self:card(book.library_card_uuid) end
    if book.can_be_read == false then return nil, "denied" end
    return self:add_book(book_uuid)
end

local function find_key(node)
    if type(node) == "string" then
        local ok, bin = pcall(Crypt.base64_decode, node)
        if ok and bin and #bin == 32 then return bin end
    elseif type(node) == "table" then
        for _, v in pairs(node) do
            local key = find_key(v)
            if key then return key end
        end
    end
end

local function bytes(arr)
    local parts = {}
    -- string.char takes limited arguments; go in slices.
    for i = 1, #arr, 4096 do
        parts[#parts + 1] = string.char(unpack(arr, i, math.min(i + 4095, #arr)))
    end
    return table.concat(parts)
end

--- Fetches the decrypted manifest of a book.
-- Returns { document_uuid=, container=, opf=, ncx= }.
function Api:manifest(book_uuid)
    local meta, kind, detail = self:get_json(API_BASE .. "/books/" .. encode(book_uuid) .. "/metadata/v4")
    if not meta then return nil, kind, detail end
    if type(meta.opf) ~= "table" or type(meta.document_uuid) ~= "string" then
        return nil, "http", "manifest without opf"
    end
    local secret
    secret, kind, detail = self:get_json(API_BASE .. "/metadata_secret")
    if not secret then return nil, kind, detail end
    local key = find_key(secret)
    if not key then return nil, "http", "no key" end

    local out = { document_uuid = meta.document_uuid }
    for _, name in ipairs { "container", "opf", "ncx" } do
        if type(meta[name]) == "table" and #meta[name] > 0 then
            out[name] = Crypt.aes256_cbc_ivprefix(key, bytes(meta[name]))
            if not out[name] then return nil, "http", "cannot decrypt " .. name end
        end
    end
    if not out.opf then return nil, "http", "manifest without opf" end
    return out
end

--- All of the reader's quotes or bookmarks, of all books, with those deleted. Yandex gives them
-- in pages, each picking up after the last change seen.
function Api:notes(list)
    local all, since = {}, 0
    for _ = 1, 200 do
        local page, kind, detail = self:get_json(API_BASE .. "/" .. list .. "/incremental_sync?changes_count=" .. since)
        if not page then return nil, kind, detail end
        local entries = page[list]
        if type(entries) ~= "table" then return nil, "http", "no " .. list end
        local last = since
        for _, entry in ipairs(entries) do
            all[#all + 1] = drop_nulls(entry)
            if (entry.changes_count or 0) > last then last = entry.changes_count end
        end
        if last == since then return all end
        since = last
    end
    return nil, "http", "too many pages of " .. list
end

local function form(fields)
    local parts = {}
    for i, field in ipairs(fields) do parts[i] = encode(field[1]) .. "=" .. encode(tostring(field[2])) end
    return table.concat(parts, "&")
end

local function note_answer(self, method, url, fields, name)
    local status, body = self.http:request(method, url, self:headers("application/x-www-form-urlencoded"), form(fields))
    if status ~= 200 then return status_error(status, body) end
    local answer = json.decode(body)
    return type(answer) == "table" and answer[name] or nil, "http", "no " .. name
end

--- Writes a new highlight or bookmark. Returns what Yandex made of it. As from the phone, a
-- highlight starts public, and that field's name really has no closing bracket.
function Api:create_note(kind, book, note)
    local url = API_BASE .. "/books/" .. encode(book) .. "/" .. kind .. "s"
    if kind == "bookmark" then
        return note_answer(self, "POST", url, {
            { "bookmark[cfi]", note.cfi },
            { "bookmark[content]", note.content or "" },
            { "bookmark[progress]", note.progress or 0 },
        }, kind)
    end
    return note_answer(self, "POST", url, {
        { "quote[content]", note.content or "" },
        { "quote[comment]", note.comment or "" },
        { "quote[cfi]", note.cfi },
        { "quote[color]", 2 },
        { "quote[permanent_hidden", note.hidden and "true" or "false" },
        { "quote[progress]", note.progress or 0 },
    }, kind)
end

--- Changes a highlight. Yandex takes the whole of it each time, so what is not being changed has
-- to be sent as it stands: left out, a private highlight could turn public.
function Api:update_quote(uuid, quote)
    return note_answer(self, "PUT", API_BASE .. "/quotes/" .. encode(uuid), {
        { "quote[content]", quote.content or "" },
        { "quote[comment]", quote.comment or "" },
        { "quote[cfi]", quote.cfi },
        { "quote[color]", quote.color or 2 },
        { "quote[permanent_hidden", quote.hidden and "true" or "false" },
    }, "quote")
end

--- Deletes a highlight or bookmark. One already gone is as good as deleted.
function Api:delete_note(kind, uuid)
    local status, body = self.http:request("DELETE", API_BASE .. "/" .. kind .. "s/" .. encode(uuid), self:headers())
    if status == 200 or status == 204 or status == 404 then return true end
    return status_error(status, body)
end

--- Fetches one file of a book, by its path in the book.
function Api:content(document_uuid, path)
    return self:get(API_BASE .. "/documents/" .. encode(document_uuid) .. "/content?path=" .. encode(path))
end

--- Returns the URL to sign in at, for the given PKCE verifier.
function Api.login_url(verifier)
    return OAUTH_BASE .. "/authorize?response_type=code&client_id=" .. CLIENT_ID
        .. "&redirect_uri=" .. encode(REDIRECT)
        .. "&code_challenge=" .. Crypt.pkce_challenge(verifier)
        .. "&code_challenge_method=S256"
end

--- Trades a confirmation code for a token. Returns the token, or nil and a kind:
-- "bad_code" when the code was refused, "network" or "http" otherwise.
function Api.exchange_code(code, verifier)
    local http = Http.new(Net.connect)
    local body = "grant_type=authorization_code&code=" .. encode(code)
        .. "&client_id=" .. CLIENT_ID .. "&code_verifier=" .. encode(verifier)
    local status, resp = http:request("POST", OAUTH_BASE .. "/token",
        { ["Content-Type"] = "application/x-www-form-urlencoded" }, body)
    http:close()
    if not status then return nil, "network" end
    if status == 400 then return nil, "bad_code" end
    if status ~= 200 then return nil, "http" end
    local data = json.decode(resp)
    if type(data) ~= "table" or type(data.access_token) ~= "string" then return nil, "http" end
    return data.access_token
end

return Api
