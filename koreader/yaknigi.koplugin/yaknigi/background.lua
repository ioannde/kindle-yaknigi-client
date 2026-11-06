-- Fetches the rest of a book in a forked process while the user reads.
--
-- The child never touches the UI. It reads a "priority" file before each download so
-- the reader can pull the chapter the user just turned to to the front of the queue.
-- Once the book is whole it replaces book.epub and renders it with the parent's
-- settings, so that the parent's later reload finds a ready cache and takes no time.
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local logger = require("logger")
local Api = require("yaknigi/api")
local Store = require("yaknigi/store")

pcall(ffi.cdef, "int nice(int); int getppid(void);")

local Background = {}

local function read_number(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = tonumber(f:read("*a"))
    f:close()
    return n
end

function Background.set_priority(store, fragment)
    local tmp = store.dir .. "/priority.tmp"
    local f = io.open(tmp, "wb")
    if not f then return end
    f:write(tostring(fragment))
    f:close()
    os.rename(tmp, store.dir .. "/priority")
end

--- Downloads until nothing is missing. Returns true when the book is complete.
function Background.fetch_all(store, api, around)
    local failures = 0
    local failed = {}
    local parent = ffi.C.getppid()
    while true do
        -- KOReader has quit: nothing will use this, and the Kindle UI needs the memory.
        if ffi.C.getppid() ~= parent then return false end
        local center = read_number(store.dir .. "/priority") or around
        local path
        for _, p in ipairs(store:missing(center)) do
            if not failed[p] then path = p; break end
        end
        if not path then break end
        local data, kind = api:content(store.manifest.document_uuid, path)
        if data then
            store:write(path, data)
            failures = 0
        else
            -- A resource can be missing on the server; do not stop for that, but
            -- when the network is gone there is no point in trying every file.
            failed[path] = true
            failures = failures + 1
            logger.warn("yaknigi: fetch failed:", kind)
            if kind == "auth" or failures >= 5 then return false end
        end
    end
    -- Only a chapter is essential; crengine shows a book without some image.
    for _, p in ipairs(store.paths) do
        if not store:has(p) then return false end
    end
    return true
end

--- Starts the worker. document may be nil to skip pre-rendering.
-- Returns the pid, or nil.
function Background.start(store, token, around, document)
    return ffiutil.runInSubProcess(function()
        pcall(function() ffi.C.nice(10) end)
        local api = Api.new(token)
        local whole = Background.fetch_all(store, api, around)
        api:close()
        if not whole then os.exit(0) end
        if not store:build() then os.exit(1) end
        if document then
            -- Same document view and settings as the parent: the cache's key matches.
            document:setCallback()
            document:enablePartialRerendering(false)
            local view = document._document
            if view:loadDocument(store.epub) then
                view:renderDocument()
                view:updateTocAndPageMap()
                view:close() -- writes the cache
            end
        end
        os.exit(0)
    end)
end

--- Saves a whole book for reading without the network, with nobody reading it: the first
-- opening lays it out. Writes { kind } to result. Returns the pid, or nil.
function Background.save(root, id, token, result)
    return ffiutil.runInSubProcess(function()
        pcall(function() ffi.C.nice(10) end)
        local function finish(kind)
            local f = io.open(result, "wb")
            if f then
                f:write(kind)
                f:close()
            end
            os.exit(0)
        end
        local store = Store.open(root, id)
        if not store then finish("http") end
        local api = Api.new(token)
        if not store.manifest then
            local manifest, kind = api:manifest(id)
            if not manifest then finish(kind or "network") end
            if not store:set_manifest(manifest) then finish("disk") end
        end
        local whole = Background.fetch_all(store, api, 1)
        api:close()
        if not whole then finish("network") end
        if not store:build() then finish("disk") end
        finish("ok")
    end)
end

return Background
