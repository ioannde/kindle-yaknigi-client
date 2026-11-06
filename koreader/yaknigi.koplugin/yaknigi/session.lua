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

    -- A new position from Yandex (read on the phone) wins over the saved one. Without
    -- any saved one, Yandex's is all there is.
    local server_changed = card.accessed_at ~= nil and card.accessed_at ~= Session.read_stamp(store)
    local use_server = card.cfi ~= nil and (server_changed or local_fragment == nil)
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
    Session.write_stamp(store, card.accessed_at)
    return store, stubs, xpointer, target
end

--- For a book already on disk: the xpointer of Yandex's newer position.
function Session.jump_for(store, card)
    local target = store:fragment_of_spine_index(Cfi.spine_index(card.cfi))
    Session.write_stamp(store, card.accessed_at)
    return Cfi.to_xpointer(card.cfi, target, store:read(store.paths[target]))
end

function Session.read_stamp(store)
    local f = io.open(store.dir .. "/server_position", "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

function Session.write_stamp(store, stamp)
    if not stamp then return end
    local f = io.open(store.dir .. "/server_position", "wb")
    if not f then return end
    f:write(tostring(stamp))
    f:close()
end

return Session
