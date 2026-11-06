-- Book covers on disk, fetched in a forked process so the library is never held up.
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local Http = require("yaknigi/http")
local Net = require("yaknigi/net")

pcall(ffi.cdef, "int nice(int);")

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

--- Path of the cover of a card, nil until it has arrived.
function Covers.find(root, card)
    local base = base_path(root, card)
    if not base then return nil end
    for _, ext in ipairs { ".jpg", ".png" } do
        if readable(base .. ext) then return base .. ext end
    end
    return nil
end

local function cover_url(card)
    local cover = card.book and card.book.cover
    if type(cover) ~= "table" then return nil end
    local url = cover.small or cover.large
    return type(url) == "string" and url or nil
end

--- Downloads what is missing. The covers' host gets no token. Returns the pid, or nil
-- when there is nothing to do.
function Covers.fetch(root, cards)
    local wanted = {}
    for _, card in ipairs(cards) do
        local base, url = base_path(root, card), cover_url(card)
        if base and url and not Covers.find(root, card) then
            wanted[#wanted + 1] = { base = base, url = url }
        end
    end
    if #wanted == 0 then return nil end
    return ffiutil.runInSubProcess(function()
        pcall(function() ffi.C.nice(10) end)
        local http = Http.new(Net.connect)
        for _, item in ipairs(wanted) do
            local status, body = http:request("GET", item.url, { ["User-Agent"] = "okhttp/4.12.0" })
            local ext = status == 200 and extension(body)
            if ext then
                local f = io.open(item.base .. ".tmp", "wb")
                if f then
                    f:write(body)
                    f:close()
                    os.rename(item.base .. ".tmp", item.base .. ext)
                end
            end
        end
        http:close()
        os.exit(0)
    end)
end

return Covers
