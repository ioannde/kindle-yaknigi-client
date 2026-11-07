-- A serial as one book, as in Yandex's app. Yandex keeps every episode as a book of its own, with
-- its own document and its own positions, so here their spines are laid end to end. Inside the
-- plugin everything counts in that long spine; only what goes to Yandex or comes from it is
-- translated, here, into an episode and a place in it.
local Opf = require("yaknigi/opf")

local Serial = {}

local ROOT = "OEBPS/"
local OPF_PATH = ROOT .. "content.opf"
local CONTAINER = '<?xml version="1.0"?><container version="1.0" '
    .. 'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="'
    .. OPF_PATH .. '" media-type="application/oebps-package+xml"/></rootfiles></container>'

local function escape(text)
    return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function episode_title(episode, number)
    if type(episode.title) == "string" and episode.title ~= "" then return episode.title end
    return "Эпизод " .. tostring(episode.position or number)
end

--- The one page of an episode that cannot be read here.
function Serial.locked_page(title)
    return '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>'
        .. escape(title) .. "</title></head><body><h2>" .. escape(title)
        .. "</h2><p>Этот эпизод сейчас недоступен.</p></body></html>"
end

--- An episode's table of contents, for the place of its directory in the long book.
local function inner_contents(ncx, directory, number)
    local map = type(ncx) == "string" and ncx:match("<navMap[^>]*>(.*)</navMap>")
    if not map then return "" end
    local _, points = map:gsub("<navPoint[%s>]", "")
    -- One entry says no more than the episode's own title.
    if points < 2 then return "" end
    map = map:gsub("(<content[^>]-src%s*=%s*[\"'])", "%1" .. directory)
    map = map:gsub("(<navPoint[^>]-%sid%s*=%s*[\"'])", "%1e" .. number .. "_")
    map = map:gsub("%s+playOrder%s*=%s*[\"'][^\"']*[\"']", "")
    return map
end

--- Lays episodes end to end. Each of them is { uuid, title, position, document, container, opf,
-- ncx, card } as it came, or with locked = true and no book at all. Returns a manifest, with
-- episodes = { { uuid, document, first, count, prefix, card, title, locked } }: first counts
-- itemrefs of the whole from zero, as Yandex's positions do.
function Serial.merge(serial_uuid, title, episodes)
    local items, itemrefs, points, parts = {}, {}, {}, {}
    local cover_id
    local first = 0
    for number, episode in ipairs(episodes) do
        local directory = episode.uuid .. "/"
        local name = episode_title(episode, number)
        local part = { uuid = episode.uuid, document = episode.document, first = first, card = episode.card,
                       title = name, locked = episode.locked or nil, position = episode.position }
        local entry, inner = nil, ""
        if episode.locked then
            local id = "e" .. number .. "_locked"
            items[#items + 1] = ('<item id="%s" href="%slocked.xhtml" media-type="application/xhtml+xml"/>'):format(id, directory)
            itemrefs[#itemrefs + 1] = ('<itemref idref="%s"/>'):format(id)
            part.count, part.prefix = 1, ""
            entry = directory .. "locked.xhtml"
        else
            local book = Opf.parse(episode.opf)
            local by_id = {}
            for _, item in ipairs(book.items) do
                if item.media ~= "application/x-dtbncx+xml" then
                    local id = ("e%d_%s"):format(number, item.id)
                    by_id[item.id] = id
                    local media = item.media
                    if media == "" and Opf.is_html(item) then media = "application/xhtml+xml" end
                    items[#items + 1] = ('<item id="%s" href="%s%s" media-type="%s"/>'):format(
                        escape(id), directory, escape(item.href), escape(media))
                    if item.href == book.cover and not cover_id then cover_id = id end
                end
            end
            local count = 0
            for ref in episode.opf:gmatch("<%s*itemref%s[^>]*>") do
                local idref = ref:match("idref%s*=%s*[\"']([^\"']*)[\"']")
                if idref and by_id[idref] then
                    itemrefs[#itemrefs + 1] = ('<itemref idref="%s"/>'):format(escape(by_id[idref]))
                    count = count + 1
                end
            end
            part.count = count
            part.prefix = Opf.dirname(Opf.rootfile(episode.container or "") or OPF_PATH)
            entry = book.spine[1] and directory .. book.spine[1]
            inner = inner_contents(episode.ncx, directory .. Opf.dirname(book.ncx or ""), number)
        end
        if entry then
            points[#points + 1] = ('<navPoint id="ep%d"><navLabel><text>%s</text></navLabel><content src="%s"/>%s</navPoint>')
                :format(number, escape(name), escape(entry), inner)
        end
        first = first + part.count
        parts[number] = part
    end
    local any_document
    for _, part in ipairs(parts) do any_document = any_document or part.document end
    return {
        document_uuid = any_document,
        total = #parts,
        episodes = parts,
        container = CONTAINER,
        opf = '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" '
            .. 'unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>' .. escape(title)
            .. '</dc:title><dc:identifier id="id">' .. escape(serial_uuid) .. "</dc:identifier><dc:language>ru</dc:language>"
            .. (cover_id and ('<meta name="cover" content="%s"/>'):format(escape(cover_id)) or "")
            .. "</metadata><manifest>" .. table.concat(items)
            .. '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx">'
            .. table.concat(itemrefs) .. "</spine></package>",
        ncx = '<?xml version="1.0" encoding="utf-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
            .. "<head></head><docTitle><text>" .. escape(title) .. "</text></docTitle><navMap>"
            .. table.concat(points) .. "</navMap></ncx>",
    }
end

--- The episode a file of the long book belongs to, and its path in that episode.
function Serial.file_of(manifest, path)
    local uuid, rest = path:match("^" .. ROOT .. "([^/]+)/(.*)$")
    if not uuid then return nil end
    for _, part in ipairs(manifest.episodes or {}) do
        if part.uuid == uuid then return part, part.prefix .. rest end
    end
    return nil
end

--- The directory of what belongs to the same episode, nil for an ordinary book's file.
function Serial.part_of(path)
    return path:match("^" .. ROOT .. "([^/]+)/")
end

local function with_step(cfi, step)
    return (cfi:gsub("^(/%d+/)%d+!", function(head) return head .. (step + 1) * 2 .. "!" end, 1))
end

--- A position of Yandex's, in an episode, as a position in the long book. nil if unknown here.
function Serial.to_merged(manifest, episode_uuid, cfi)
    if type(cfi) ~= "string" then return nil end
    local step = tonumber(cfi:match("^/%d+/(%d+)!"))
    if not step then return nil end
    for _, part in ipairs(manifest.episodes or {}) do
        if part.uuid == episode_uuid then
            local index = math.floor(step / 2) - 1
            if index < 0 or index >= part.count then index = 0 end
            return with_step(cfi, part.first + index)
        end
    end
    return nil
end

--- A position in the long book as Yandex's: the episode, and the position in it.
function Serial.to_episode(manifest, cfi)
    local step = type(cfi) == "string" and tonumber(cfi:match("^/%d+/(%d+)!"))
    if not step then return nil end
    local index = math.floor(step / 2) - 1
    for _, part in ipairs(manifest.episodes or {}) do
        if index >= part.first and index < part.first + part.count then
            return part, with_step(cfi, index - part.first)
        end
    end
    return nil
end

--- Whether the card of a book is a serial's.
function Serial.is_serial(card)
    return type(card) == "table" and type(card.book) == "table" and card.book.source_type == "serial"
end

--- A serial's card with its position in the long book, as an ordinary book's card has it. It
-- has none until the episodes are known, as when it was never opened here.
function Serial.view_with(manifest, card)
    local copy = {}
    for key, value in pairs(card) do copy[key] = value end
    copy.cfi = manifest and Serial.to_merged(manifest, card.current_episode_uuid, card.cfi) or nil
    return copy
end

-- What was read of each directory: sorting the library asks many times over.
local seen_manifests = {}

--- The same, for what the book's directory holds. Any other card comes back as it is.
function Serial.view(dir, card)
    if not Serial.is_serial(card) then return card end
    local path = dir .. "/manifest.json"
    local attributes = require("libs/libkoreader-lfs").attributes(path)
    if not attributes then return Serial.view_with(nil, card) end
    local seen = seen_manifests[dir]
    if not seen or seen.modified ~= attributes.modification or seen.size ~= attributes.size then
        local f = io.open(path, "rb")
        if not f then return Serial.view_with(nil, card) end
        local text = f:read("*a")
        f:close()
        local ok, manifest = pcall(require("rapidjson").decode, text)
        seen = { modified = attributes.modification, size = attributes.size,
                 manifest = ok and type(manifest) == "table" and { episodes = manifest.episodes } or nil }
        seen_manifests[dir] = seen
    end
    return Serial.view_with(seen.manifest, card)
end

--- Whether the episodes known here are not all that Yandex may now have.
function Serial.stale(manifest, card)
    if not manifest or not manifest.episodes then return true end
    local total = tonumber(card.book and card.book.episodes_count)
    if total and total ~= manifest.total then return true end
    -- What was closed may have been opened.
    for _, part in ipairs(manifest.episodes) do
        if part.locked then return true end
    end
    return false
end

--- Whether a book already read here would have its places moved by a new manifest. New episodes
-- only come after the old, and move nothing.
function Serial.shifted(old, new)
    local now = {}
    for _, part in ipairs(new.episodes) do now[part.uuid] = part end
    for _, part in ipairs(old and old.episodes or {}) do
        local same = now[part.uuid]
        if not same or same.first ~= part.first or same.count ~= part.count then return true end
    end
    return false
end

local function read_json_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local ok, data = pcall(require("rapidjson").decode, text)
    return ok and type(data) == "table" and data or nil
end

local function write_json_file(path, data)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return end
    f:write(require("rapidjson").encode(data))
    f:close()
    os.rename(tmp, path)
end

--- Places counted in the old numbering mean nothing in the new. Yandex has the positions and the
-- notes that went to it, and gives them back in the new one.
local function forget_places(store)
    pcall(function() require("docsettings"):open(store.epub):purge() end)
    for _, name in ipairs { "server_cfi", "sent", "to_send", "news", "checked" } do
        os.remove(store.dir .. "/" .. name)
    end
end

--- Gets a serial's episodes and makes it a book, in store. One request an episode the first time;
-- what has come stays, so an interrupted first opening goes on where it stopped. on_progress
-- (done, total) is called as it goes. Returns true; or nil, kind, detail.
function Serial.load(store, api, card, on_progress)
    local list, cursor = {}, ""
    repeat
        local page, kind, detail = api:collection("serial", store.id, cursor)
        if not page then return nil, kind, detail end
        for _, episode in ipairs(page.episodes) do list[#list + 1] = episode end
        cursor = page.cursor
    until cursor == ""
    if #list == 0 then return nil, "http", "a serial without episodes" end
    table.sort(list, function(a, b) return (tonumber(a.position) or 0) < (tonumber(b.position) or 0) end)

    local cache = store.dir .. "/episodes"
    os.execute("mkdir -p '" .. cache .. "'")
    local episodes = {}
    for number, entry in ipairs(list) do
        if on_progress then on_progress(number, #list) end
        local episode = {
            uuid = entry.uuid,
            title = entry.title,
            position = entry.position,
            card = type(entry.library_card) == "table" and entry.library_card.uuid or nil,
        }
        if entry.can_be_read == false or not tostring(entry.uuid):match("^[%w_%-]+$") then
            episode.locked = true
        else
            local path = cache .. "/" .. entry.uuid .. ".json"
            local manifest = read_json_file(path)
            if not manifest then
                local kind, detail
                manifest, kind, detail = api:manifest(entry.uuid)
                if not manifest then
                    -- The list has just come with this token, so a refusal is about the episode
                    -- and is no reason to lose the others, or to sign out.
                    if kind == "network" then return nil, kind, detail end
                    episode.locked = true
                else
                    write_json_file(path, manifest)
                end
            end
            if manifest then
                episode.document = manifest.document_uuid
                episode.container, episode.opf, episode.ncx = manifest.container, manifest.opf, manifest.ncx
            end
        end
        episodes[number] = episode
    end

    local merged = Serial.merge(store.id, card.book and card.book.title or "?", episodes)
    if not merged.document_uuid then return nil, "denied" end
    local old = store.manifest
    if not old or old.opf ~= merged.opf then
        if Serial.shifted(old, merged) then forget_places(store) end
        -- What is built is of the old list; book.epub is made anew on opening.
        os.remove(store.dir .. "/state")
    end
    local ok, err = store:set_manifest(merged)
    if not ok then return nil, "disk", err end
    -- Episodes used to be saved each as a book. Their notes and positions stay where they are.
    if not old then
        local root = store.dir:match("^(.*)/[^/]+$")
        for _, part in ipairs(merged.episodes) do
            require("yaknigi/storage").remove_book(root .. "/" .. part.uuid)
        end
    end
    return true
end

--- What a sent position needs of the episode. finish: the page's end, which may be in the next
-- episode, and then the page ends where it starts. nil for a page Yandex has no episode for.
function Serial.position(manifest, start, finish)
    local part, here = Serial.to_episode(manifest, start)
    if not part or part.locked then return nil end
    local other, there = Serial.to_episode(manifest, finish)
    return {
        book = part.uuid,
        document = part.document,
        card = part.card,
        start = here,
        finish = other == part and there or here,
    }
end

--- The api, for comparing notes in the long book: Yandex keeps them by episode.
function Serial.notes_api(api, manifest, serial_uuid)
    local of_episode = {}
    for _, part in ipairs(manifest.episodes) do of_episode[part.uuid] = part end
    local wrapper = {}
    function wrapper:notes(list)
        local entries, kind, detail = api:notes(list)
        if not entries then return nil, kind, detail end
        local out = {}
        for _, entry in ipairs(entries) do
            local book = type(entry.book) == "table" and entry.book.uuid or nil
            local uuid = (book and of_episode[book] and book)
                or (of_episode[entry.book_uuid or ""] and entry.book_uuid)
                or (of_episode[entry.book_init_uuid or ""] and entry.book_init_uuid)
            local cfi = uuid and Serial.to_merged(manifest, uuid, entry.cfi)
            if cfi then
                local copy = {}
                for key, value in pairs(entry) do copy[key] = value end
                copy.cfi, copy.book, copy.book_init_uuid = cfi, nil, nil
                copy.book_uuid = serial_uuid
                out[#out + 1] = copy
            elseif entry.state ~= "exists" then
                out[#out + 1] = entry
            end
        end
        return out
    end
    function wrapper:create_note(kind, _, note)
        local part, here = Serial.to_episode(manifest, note.cfi)
        if not part or part.locked then return nil, "http", "no episode for this note" end
        local copy = {}
        for key, value in pairs(note) do copy[key] = value end
        copy.cfi = here
        return api:create_note(kind, part.uuid, copy)
    end
    function wrapper:update_quote(uuid, quote)
        local part, here = Serial.to_episode(manifest, quote.cfi)
        if not part then return nil, "http", "no episode for this note" end
        local copy = {}
        for key, value in pairs(quote) do copy[key] = value end
        copy.cfi = here
        return api:update_quote(uuid, copy)
    end
    function wrapper:delete_note(kind, uuid) return api:delete_note(kind, uuid) end
    return wrapper
end

return Serial
