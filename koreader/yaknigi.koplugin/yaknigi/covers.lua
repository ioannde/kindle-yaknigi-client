-- Book covers on disk, fetched in a forked process so the library is never held up.
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local Http = require("yaknigi/http")
local Net = require("yaknigi/net")

pcall(ffi.cdef, "int nice(int);")

local logger = require("logger")
local socket = require("socket")

local Covers = {}

-- KOReader recognises an image by its file name, so the name has to match the content.
local function extension(data)
    if data:sub(1, 3) == "\255\216\255" then return ".jpg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return ".png" end
    return nil
end

local function base_path(root, card)
    local id = card.book and card.book.uuid
    if type(id) ~= "string" or not id:match("^[%w_%-]+$") then return nil end
    return root .. "/" .. id
end

local function readable(path)
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

-- A library's picture: 300 pixels wide is more than a cell has, at a third of the weight of
-- the next size. What the screen shows on its way to sleep is fetched by itself, on opening a book.
local PREVIEW = ".preview"
-- Most of a picture's time is waiting for the server, so two go at more than twice the speed
-- of what a screen asks for. More would spend the device's one core on the TLS handshakes.
local WORKERS = 2

--- The same picture at the other size Yandex keeps it in; a url without one stays as it is.
local function preview_url(url)
    return (url:gsub("%-%a+(%.%w+%??[^/]*)$", "-small%1"))
end

local function find_preview(base)
    for _, ext in ipairs { ".jpg", ".png" } do
        if readable(base .. PREVIEW .. ext) then return base .. PREVIEW .. ext end
    end
end

--- Path of the cover of a card, nil until it has arrived. A smaller one from before
-- previews does until its preview comes.
function Covers.find(root, card)
    local base = base_path(root, card)
    if not base then return nil end
    local preview = find_preview(base)
    if preview then return preview end
    for _, ext in ipairs { ".jpg", ".png" } do
        if readable(base .. ext) then return base .. ext end
    end
    return nil
end

-- The preview, and failing it whatever the card has, without asking for one picture twice.
local function cover_urls(card)
    local cover = card.book and card.book.cover
    local urls, seen = {}, {}
    local function add(url)
        if type(url) == "string" and not seen[url] then
            seen[url] = true
            urls[#urls + 1] = url
        end
    end
    if type(cover) == "table" then
        local any = cover.small or cover.large
        if type(any) == "string" then add(preview_url(any)) end
        add(cover.small)
        add(cover.large)
    end
    return urls
end

-- A picture bigger than this is more than the device should decode on its way to sleep.
local BIGGEST_COVER = 6 * 1024 * 1024

--- Path of the cover for the whole screen, nil until it has arrived.
function Covers.find_best(root, uuid)
    local base = base_path(root, { book = { uuid = uuid } })
    if not base then return nil end
    for _, ext in ipairs { ".jpg", ".png" } do
        if readable(base .. ".large" .. ext) then return base .. ".large" .. ext end
    end
    return nil
end

--- Downloads the first picture of urls that can be had. Returns the pid, or nil.
function Covers.fetch_best(root, uuid, urls)
    local base = base_path(root, { book = { uuid = uuid } })
    if not base or #urls == 0 then return nil end
    base = base .. ".large"
    return ffiutil.runInSubProcess(function()
        pcall(function() ffi.C.nice(10) end)
        local http = Http.new(Net.connect)
        for _, url in ipairs(urls) do
            local status, body = http:request("GET", url, { ["User-Agent"] = "okhttp/4.12.0" })
            local ext = status == 200 and #body <= BIGGEST_COVER and extension(body)
            if ext then
                local f = io.open(base .. ".tmp", "wb")
                if f then
                    f:write(body)
                    f:close()
                    os.rename(base .. ".tmp", base .. ext)
                end
                break
            end
        end
        http:close()
        os.exit(0)
    end)
end

local function download(wanted)
    return ffiutil.runInSubProcess(function()
        pcall(function() ffi.C.nice(10) end)
        local started = socket.gettime()
        local http = Http.new(Net.connect)
        for _, item in ipairs(wanted) do
            for _, url in ipairs(item.urls) do
                local status, body = http:request("GET", url, { ["User-Agent"] = "okhttp/4.12.0" })
                local ext = status == 200 and extension(body)
                if ext then
                    local f = io.open(item.base .. ".tmp", "wb")
                    if f then
                        f:write(body)
                        f:close()
                        os.rename(item.base .. ".tmp", item.base .. PREVIEW .. ext)
                        -- The smaller picture from before previews is of no more use.
                        os.remove(item.base .. ".jpg")
                        os.remove(item.base .. ".png")
                    end
                    break
                end
            end
        end
        http:close()
        logger.info("yaknigi: covers:", #wanted, "in", socket.gettime() - started, "s")
        os.exit(0)
    end)
end

--- Downloads what is missing, in the order asked. The covers' host gets no token. Returns
-- the pids; empty when there is nothing to do.
function Covers.fetch(root, cards)
    local shares = {}
    local count = 0
    for _, card in ipairs(cards) do
        local base, urls = base_path(root, card), cover_urls(card)
        if base and #urls > 0 and not find_preview(base) then
            local share = count % WORKERS + 1
            shares[share] = shares[share] or {}
            table.insert(shares[share], { base = base, urls = urls })
            count = count + 1
        end
    end
    local pids = {}
    for _, wanted in ipairs(shares) do
        pids[#pids + 1] = download(wanted)
    end
    return pids
end

--- True when none of the pids is running. Asking is also what ends a finished process.
function Covers.done(pids)
    local done = true
    for _, pid in ipairs(pids) do
        if not ffiutil.isSubProcessDone(pid) then done = false end
    end
    return done
end

--- Stops the pids. Returns those to ask about until they are gone.
function Covers.stop(pids)
    for _, pid in ipairs(pids) do ffiutil.terminateSubProcess(pid) end
    return pids
end

return Covers
