-- How the library is divided, as in the phone app, and how it is searched. Works on the
-- library's items, which carry { title, authors, shelf, whole }.
local Shelves = {}

local NAMES = {
    reading = "Читаю",
    want = "Хочу прочитать",
    finished = "Прочитанные",
    device = "На устройстве",
    all = "Все книги",
}

function Shelves.name(id) return NAMES[id] end

--- Which shelf a book is on. A book begun here may stay "pending" at Yandex, and one with
-- the read mark taken off is "pending" at 99%: the reader expects both among the books being read.
function Shelves.of(state, progress, read_here)
    if state == "finished" then return "finished" end
    if state == "reading" or read_here or (tonumber(progress) or 0) > 0 then return "reading" end
    return "want"
end

--- Lower case without "ё", for comparing: Lua's own lower() knows only Latin letters.
function Shelves.normalize(text)
    return (text:lower()
        :gsub("\208([\128-\175])", function(c)
            local b = c:byte()
            if b < 0x90 then return "\209" .. string.char(b + 0x10) end -- Ѐ-Џ
            if b < 0xA0 then return "\208" .. string.char(b + 0x20) end -- А-П
            return "\209" .. string.char(b - 0x20) -- Р-Я
        end)
        :gsub("\209\145", "\208\181"))
end

--- Whether every word of the query is in the book's title or authors.
function Shelves.matches(item, query)
    if not item.search_key then
        item.search_key = Shelves.normalize((item.title or "") .. " " .. (item.authors or ""))
    end
    for word in Shelves.normalize(query):gmatch("%S+") do
        if not item.search_key:find(word, 1, true) then return false end
    end
    return true
end

--- The items of a shelf, in the order given. A query narrows them down.
function Shelves.list(items, id, query)
    local out = {}
    for _, item in ipairs(items) do
        local on_shelf = id == "all" or item.shelf == id or (id == "device" and item.whole)
        if on_shelf and (not query or Shelves.matches(item, query)) then out[#out + 1] = item end
    end
    return out
end

return Shelves
