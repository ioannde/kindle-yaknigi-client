-- Opens a book as fast as possible: fetches the manifest and the chapter to read,
-- builds an EPUB around them and leaves the rest to the background worker.
local Cfi = require("yaknigi/cfi")
local Store = require("yaknigi/store")

local Session = {}

--- Returns the store ready to be opened, the stubs, and the xpointer to jump to (or
-- nil to stay at the saved position). On failure returns nil, kind, detail.
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

    local use_server = Session.server_moved(store, card, local_fragment ~= nil)
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
    Session.remember(store, card)
    return store, stubs, xpointer, target
end

--- For a book already on disk: the xpointer of Yandex's newer position.
function Session.jump_for(store, card)
    local target = store:fragment_of_spine_index(Cfi.spine_index(card.cfi))
    Session.remember(store, card)
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

--- Whether to go to Yandex's position rather than stay at the one saved here. Yandex's
-- wins only when it differs from the last one seen, as it does after reading on the phone:
-- the position is not sent back, so it says nothing about reading on this device. Without
-- a position here, it is all there is.
function Session.server_moved(store, card, has_local)
    if type(card.cfi) ~= "string" then return false end
    local seen = read_file(store.dir .. "/server_cfi")
    if seen then return seen ~= card.cfi end
    return not has_local
end

function Session.remember(store, card)
    if type(card.cfi) == "string" then write_file(store.dir .. "/server_cfi", card.cfi) end
end

--- Records how far the book is read here, for the library.
function Session.save_reading(dir, ratio)
    write_file(dir .. "/reading", ("%d %d"):format(math.floor(ratio * 100 + 0.5), os.time()))
end

--- Returns the percentage read here and when, or nil if the phone has moved on since.
function Session.read_reading(dir, card)
    local percent, at = (read_file(dir .. "/reading") or ""):match("^(%d+) (%d+)$")
    if not percent then return nil end
    local seen = read_file(dir .. "/server_cfi")
    if seen and type(card.cfi) == "string" and seen ~= card.cfi then return nil end
    return tonumber(percent), tonumber(at)
end

return Session
