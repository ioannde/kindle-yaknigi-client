-- Books of one's own into Yandex Books, as the phone app sends them: Yandex takes EPUB and FB2.
local Upload = {}

local TYPES = {
    epub = "application/epub+zip",
    fb2 = "application/x-fictionbook+xml",
}
-- The whole file is held in memory to be sent; a Kindle has little of it.
Upload.MAX_BYTES = 100 * 1024 * 1024
-- How deep into folders to look, and for how many files at most.
local DEPTH, MOST = 4, 500

--- "epub" or "fb2" for a file Yandex takes, by its name; nil for any other.
function Upload.kind(path)
    local ext = type(path) == "string" and path:match("%.([^./]+)$")
    ext = ext and ext:lower()
    return TYPES[ext] and ext or nil
end

function Upload.content_type(path)
    return TYPES[Upload.kind(path) or ""]
end

--- The name to show and to send: what follows the last slash.
function Upload.file_name(path)
    return path:match("([^/]+)$") or path
end

--- The name without its extension, for messages.
function Upload.title(path)
    local name = Upload.file_name(path)
    return name:match("^(.+)%.[^.]+$") or name
end

local function skipped_dir(name, path, avoid)
    if name:sub(1, 1) == "." or name:match("%.sdr$") then return true end
    for _, prefix in ipairs(avoid) do
        if path == prefix or path:sub(1, #prefix + 1) == prefix .. "/" then return true end
    end
    return false
end

--- What is in a folder: { name, path, mode, size, time } of each entry worth looking at.
local function entries(dir, avoid)
    local lfs = require("libs/libkoreader-lfs")
    local list = {}
    local ok, iter, state = pcall(lfs.dir, dir)
    if not ok then return list end
    for name in iter, state do
        if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" and not skipped_dir(name, path, avoid) then
                list[#list + 1] = { name = name, path = path, mode = "directory" }
            elseif attr and attr.mode == "file" and Upload.kind(name) then
                list[#list + 1] = { name = name, path = path, mode = "file", size = attr.size,
                    time = attr.modification or 0 }
            end
        end
    end
    return list
end

--- How many books Yandex would take there are under a folder, looking no deeper than DEPTH
-- and counting no further than MOST.
function Upload.count(dir, avoid, depth)
    depth = depth or 1
    local n = 0
    for _, entry in ipairs(entries(dir, avoid or {})) do
        if entry.mode == "file" then
            n = n + 1
        elseif depth < DEPTH then
            n = n + Upload.count(entry.path, avoid, depth + 1)
        end
        if n >= MOST then return MOST end
    end
    return n
end

--- A folder as the file picker shows it: the folders under it that have books, by name, and its
-- own books, the newest first: what was copied a minute ago is the one wanted.
function Upload.list(dir, avoid)
    avoid = avoid or {}
    local folders, files = {}, {}
    for _, entry in ipairs(entries(dir, avoid)) do
        if entry.mode == "file" then
            files[#files + 1] = entry
        else
            entry.count = Upload.count(entry.path, avoid, 2)
            if entry.count > 0 then folders[#folders + 1] = entry end
        end
    end
    table.sort(folders, function(a, b) return a.name:lower() < b.name:lower() end)
    table.sort(files, function(a, b)
        if a.time ~= b.time then return a.time > b.time end
        return a.name < b.name
    end)
    return { folders = folders, files = files }
end

--- "книга", "книги" or "книг", as goes with n.
function Upload.books_word(n)
    local tens, ones = n % 100, n % 10
    if tens >= 11 and tens <= 14 then return "книг" end
    if ones == 1 then return "книга" end
    if ones >= 2 and ones <= 4 then return "книги" end
    return "книг"
end

--- "5,2 МБ", "840 КБ".
function Upload.size_text(bytes)
    if bytes >= 1024 * 1024 then
        return (("%.1f"):format(bytes / 1024 / 1024):gsub("%.", ",")) .. " МБ"
    end
    return math.max(1, math.floor(bytes / 1024 + 0.5)) .. " КБ"
end

local MONTHS = { "янв.", "февр.", "марта", "апр.", "мая", "июня", "июля", "авг.", "сент.", "окт.", "нояб.", "дек." }

--- When a file came: "сегодня", "вчера", "13 нояб.", and the year if it is not this one.
function Upload.date_text(time, now)
    now = now or os.time()
    local day = os.date("*t", time)
    local today = os.date("*t", now)
    local function midnight(t) return os.time{ year = t.year, month = t.month, day = t.day, hour = 12 } end
    local days = math.floor((midnight(today) - midnight(day)) / 86400 + 0.5)
    if days == 0 then return "сегодня" end
    if days == 1 then return "вчера" end
    local text = day.day .. " " .. MONTHS[day.month]
    if day.year ~= today.year then text = text .. " " .. day.year end
    return text
end

--- Reads the file and sends it, unless Yandex has it already. Returns "sent" or "had", or nil
-- and the kind of failure. For a process of its own: the sums of a big book take a while.
function Upload.send(api, path)
    local content_type = Upload.content_type(path)
    if not content_type then return nil, "rejected" end
    local f = io.open(path, "rb")
    if not f then return nil, "unreadable" end
    local size = f:seek("end")
    if not size or size == 0 then f:close(); return nil, "unreadable" end
    if size > Upload.MAX_BYTES then f:close(); return nil, "too_big" end
    f:seek("set")
    local data = f:read("*a")
    f:close()
    if not data or #data ~= size then return nil, "unreadable" end
    local sha2 = require("ffi/sha2")
    local had, kind = api:has_upload(sha2.sha1(data), sha2.md5(data))
    if had then return "had" end
    if kind then return nil, kind end
    local ok
    ok, kind = api:upload_book(Upload.file_name(path), content_type, data)
    if not ok then return nil, kind end
    return "sent"
end

return Upload
