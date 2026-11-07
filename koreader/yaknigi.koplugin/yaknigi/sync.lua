-- Sends the reading position to Yandex, so that the phone opens where the Kindle left off.
--
-- A position waits in the book's "to_send" file until a request gets through. There is no
-- Wi-Fi on a train, and a Kindle may sleep in the middle of a request.
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Cfi = require("yaknigi/cfi")
local Serial = require("yaknigi/serial")
local Session = require("yaknigi/session")

local Sync = {}

-- Time left over a page says nothing about reading, as the book may just be lying open.
local MAX_SECONDS_PER_UPDATE = 300

math.randomseed(os.time())

function Sync.new_session()
    return (("xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx"):gsub("x", function()
        return ("%x"):format(math.random(0, 15))
    end))
end

local function read_waiting(dir)
    local f = io.open(dir .. "/to_send", "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local ok, position = pcall(json.decode, text)
    return ok and type(position) == "table" and position or nil
end

function Sync.waiting(dir)
    return read_waiting(dir)
end

--- Sets a position aside. Reading time adds up while nothing gets through.
function Sync.queue(dir, position, seconds)
    local earlier = read_waiting(dir)
    local spent = math.max(1, math.min(MAX_SECONDS_PER_UPDATE, seconds))
    position.timespent = (earlier and earlier.timespent or 0) + spent * 1000
    local tmp = dir .. "/to_send.tmp"
    local f = io.open(tmp, "wb")
    if not f then return end
    f:write(json.encode(position))
    f:close()
    os.rename(tmp, dir .. "/to_send")
end

--- Sends what is waiting for a book. Returns the position sent, or nil and why not.
function Sync.send(api, dir)
    local position = read_waiting(dir)
    if not position then return nil, "nothing" end
    -- Before the request: the answer may be lost after the position has moved, and
    -- coming back from Yandex it would look like reading on another device.
    Session.note_sent(dir, position.start)
    local ok, kind, detail = api:send_position(position)
    if not ok then logger.info("yaknigi: send failed:", kind, detail) end
    local rejected = kind == "not_found" or (kind == "http" and detail ~= "graphql" and (tonumber(detail) or 500) < 500)
    if ok or rejected then
        local now = read_waiting(dir)
        -- Reading went on during the request: that one is still to go.
        if now and now.start == position.start then os.remove(dir .. "/to_send") end
    end
    if not ok then return nil, kind end
    return position
end

--- Asks Yandex where the book is, and sends what is waiting only if nobody has read it
-- elsewhere since. Otherwise it would overwrite that reading, so it leaves the question
-- for the reader. Leaves a "checked" file if Yandex answered.
function Sync.exchange(api, dir, card_uuid)
    local card, kind = api:card(card_uuid)
    if not card then
        if kind == "not_found" then os.remove(dir .. "/to_send") end
        return nil, kind
    end
    local f = io.open(dir .. "/checked", "wb")
    if f then f:close() end
    card = Serial.view(dir, card)
    if Session.server_moved({ dir = dir }, card, true) then
        Session.note_news(dir, card)
        return nil, "moved"
    end
    return Sync.send(api, dir)
end

--- Sends what could not go earlier, for every book. A book that has since been read on
-- another device is left alone, for the reader to choose when opening it.
-- Updates the cards to match.
function Sync.send_waiting(api, books, cards)
    local by_book = {}
    for _, card in ipairs(cards) do
        if card.book and card.book.uuid then by_book[card.book.uuid] = card end
    end
    for id in lfs.dir(books) do
        local card = by_book[id]
        local dir = books .. "/" .. id
        if card and read_waiting(dir) then
            local here = Serial.view(dir, card)
            if Session.server_moved({ dir = dir }, here, true) then
                Session.note_news(dir, here)
            else
                local position, kind = Sync.send(api, dir)
                if position then
                    -- As Yandex would say it: a serial's card counts within the episode.
                    local wire = position.wire
                    card.cfi = Cfi.point_range(wire and wire.start or position.start)
                    if wire then card.current_episode_uuid = wire.book end
                    card.progress = position.progress
                elseif kind == "network" or kind == "auth" then
                    logger.info("yaknigi: positions not sent:", kind)
                    return
                end
            end
        end
    end
end

return Sync
