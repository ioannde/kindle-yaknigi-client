-- Opens a book as fast as possible: fetches the manifest and the chapter to read,
-- builds an EPUB around them and leaves the rest to the background worker.
local Cfi = require("yaknigi/cfi")
local Store = require("yaknigi/store")

local Session = {}

--- Returns the store ready to be opened, the stubs, and the xpointer to jump to (or
-- nil to stay at the saved position; the reader then asks, if Yandex has another).
-- On failure returns nil, kind, detail.
-- local_fragment is where the saved position is, if the book was read here before.
function Session.prepare(root, api, card, local_fragment)
    local id = card.book and card.book.uuid
    local store = Store.open(root, id)
    if not store then return nil, "http", "bad book id" end

    if not store.manifest then
        local manifest, kind, detail = api:manifest(id)
        if not manifest then return nil, kind, detail end
        local ok, err = store:set_manifest(manifest)
        if not ok then return nil, "disk", err end
    end
    if #store.paths == 0 then return nil, "http", "empty spine" end

    local moved = Session.server_moved(store, card, local_fragment ~= nil)
    local use_server = moved and not local_fragment
    local target = use_server
        and store:fragment_of_spine_index(Cfi.spine_index(card.cfi))
        or local_fragment or 1

    -- Stylesheets, this chapter and the next must be there before the first page.
    local wanted = {}
    for _, p in ipairs(store:missing(target)) do
        if p:lower():match("%.css$") then wanted[#wanted + 1] = p end
    end
    wanted[#wanted + 1] = store.paths[target]
    wanted[#wanted + 1] = store.paths[target + 1]
    for _, p in ipairs(wanted) do
        if not store:has(p) then
            local data, kind, detail = api:content(store.manifest.document_uuid, p)
            -- The next chapter and styles are a nicety; only this chapter is required.
            if data then
                local ok, err = store:write(p, data)
                if not ok then return nil, "disk", err end
            elseif p == store.paths[target] or kind == "auth" then
                return nil, kind, detail
            end
        end
    end

    local xpointer
    if use_server then
        xpointer = Cfi.to_xpointer(card.cfi, target, store:read(store.paths[target]))
    end
    local stubs, err = store:build()
    if not stubs then return nil, "disk", err end
    if use_server then
        Session.remember(store, card, true)
    else
        Session.opening_here(store, card, moved)
    end
    return store, stubs, xpointer, target
end

--- For a book already on disk: the xpointer of Yandex's newer position.
function Session.jump_for(store, card)
    local target = store:fragment_of_spine_index(Cfi.spine_index(card.cfi))
    Session.remember(store, card, true)
    return Cfi.to_xpointer(card.cfi, target, store:read(store.paths[target]))
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_file(path, data)
    local f = io.open(path, "wb")
    if not f then return end
    f:write(data)
    f:close()
end

local function write_card(dir, card)
    write_file(dir .. "/card", ("%s %s"):format(tostring(card.uuid), tostring(card.state)))
end

-- Positions sent from here since Yandex last had one of its own, one per line. The
-- library may still show the one before them, so that one and these are not news.
local function sent_positions(dir)
    local list = {}
    for line in (read_file(dir .. "/sent") or ""):gmatch("[^\n]+") do list[#list + 1] = line end
    return list
end

local function is_known(dir, cfi)
    local start = Cfi.start(cfi)
    if start == Cfi.start(read_file(dir .. "/server_cfi")) then return true end
    for _, sent in ipairs(sent_positions(dir)) do
        if sent == start then return true end
    end
    return false
end

--- Whether to go to Yandex's position rather than stay at the one saved here. Yandex's
-- wins only when it is one this device neither saw nor sent, as after reading on the
-- phone. Without a position here, it is all there is.
function Session.server_moved(store, card, has_local)
    if type(card.cfi) ~= "string" then return false end
    if read_file(store.dir .. "/server_cfi") then return not is_known(store.dir, card.cfi) end
    return not has_local
end

--- moved: the book is going to Yandex's position, so what was waiting to be sent is old.
function Session.remember(store, card, moved)
    local dir = store.dir
    write_card(dir, card)
    if moved then
        os.remove(dir .. "/sent")
        os.remove(dir .. "/to_send")
    end
    if type(card.cfi) ~= "string" then
        -- Yandex has no position yet. The first to appear is news, unless sent from here.
        if not read_file(dir .. "/server_cfi") then write_file(dir .. "/server_cfi", "") end
        return
    end
    write_file(dir .. "/server_cfi", card.cfi)
    local sent = sent_positions(dir)
    if sent[#sent] == Cfi.start(card.cfi) then os.remove(dir .. "/sent") end
end

--- Yandex has a position this device has not seen, and there is one here as well. Which
-- of them is right is for the reader to say, so it stays unseen until then.
function Session.note_news(dir, card)
    write_card(dir, card)
    write_file(dir .. "/news.tmp", ("%s %s"):format(tonumber(card.progress) or "-", card.cfi))
    os.rename(dir .. "/news.tmp", dir .. "/news")
end

--- The book opens at the position saved here. If the card has another, it is not taken
-- as news: the list may be from before this device's last answer. The reader asks Yandex.
function Session.opening_here(store, card, moved)
    if moved then
        write_card(store.dir, card)
    else
        Session.remember(store, card)
    end
end

--- Returns the card's uuid and state, as last seen when opening the book.
function Session.read_card(dir)
    local uuid, state = (read_file(dir .. "/card") or ""):match("^(%S+) (%S+)$")
    if not uuid or uuid == "nil" then return nil end
    return uuid, state ~= "nil" and state or nil
end

--- The position waiting for an answer as a card, or nil. One decided on since is old.
function Session.read_news(dir)
    local text = read_file(dir .. "/news")
    if not text then return nil end
    local progress, cfi = text:match("^(%S+) (%S+)$")
    if not cfi or is_known(dir, cfi) then
        os.remove(dir .. "/news")
        return nil
    end
    local uuid, state = Session.read_card(dir)
    return { uuid = uuid, state = state, cfi = cfi, progress = tonumber(progress) }
end

--- The reader has chosen. Once this position is overwritten it would look new again, so
-- the question must go now.
function Session.answered(store, news, moved)
    Session.remember(store, news, moved)
    os.remove(store.dir .. "/news")
end

function Session.note_sent(dir, start)
    local sent = sent_positions(dir)
    if sent[#sent] == start then return end
    sent[#sent + 1] = start
    -- Only the latest can come back; a few more cover a library that is behind.
    local from = math.max(1, #sent - 20)
    write_file(dir .. "/sent", table.concat(sent, "\n", from))
end

--- Records how far the book is read here, for the library.
function Session.save_reading(dir, ratio)
    write_file(dir .. "/reading", ("%d %d"):format(math.floor(ratio * 100 + 0.5), os.time()))
end

--- Returns the percentage read here and when, or nil if the phone has moved on since.
function Session.read_reading(dir, card)
    local percent, at = (read_file(dir .. "/reading") or ""):match("^(%d+) (%d+)$")
    if not percent then return nil end
    if read_file(dir .. "/server_cfi") and type(card.cfi) == "string" and not is_known(dir, card.cfi) then
        return nil
    end
    return tonumber(percent), tonumber(at)
end

return Session
