-- What the app keeps on the device and what of it can go. A book without its files can always be
-- had again from Yandex, so what is removed is the text; the place in the book, the notes and
-- what is still to be sent stay where they are.
local Storage = {}

-- Text of a book, and nothing else in its directory. Anything not named here stays: the
-- manifest, the book's card, the position saved and waiting to be sent, book.sdr with the notes.
function Storage.is_text_of_book(name)
    return name == "files" or name == "book.epub" or name == "state" or name == "priority"
        or name:match("%.tmp$") ~= nil or name:match("^book%.epub%.build%d+$") ~= nil
end

--- Answers of requests that nobody came for, left by a crash or a process stopped midway.
function Storage.is_leftover(name)
    return name:match("%.result%d*$") ~= nil or name:match("%.tmp$") ~= nil
end

--- "340 КБ", "12 МБ", "1,4 ГБ".
function Storage.size_text(bytes)
    local function short(value, unit)
        local text = value < 10 and string.format("%.1f", value) or string.format("%.0f", value)
        return (text:gsub("%.0$", ""):gsub("%.", ",")) .. " " .. unit
    end
    if bytes < 1024 * 1024 then return short(math.max(bytes / 1024, 0), "КБ") end
    if bytes < 1024 * 1024 * 1024 then return short(bytes / (1024 * 1024), "МБ") end
    return short(bytes / (1024 * 1024 * 1024), "ГБ")
end

local function lfs() return require("libs/libkoreader-lfs") end

--- Calls visit(path, attributes) for what is in dir, not going into what skip(name) says.
local function each(dir, visit, skip)
    local ok, iter, state = pcall(lfs().dir, dir)
    if not ok then return end
    for name in iter, state do
        if name ~= "." and name ~= ".." and not (skip and skip(name)) then
            local path = dir .. "/" .. name
            local attributes = lfs().symlinkattributes(path)
            if attributes then visit(path, attributes, name) end
        end
    end
end

--- The size of a file or of all under a directory.
local function size_of(path, attributes)
    attributes = attributes or lfs().symlinkattributes(path)
    if not attributes then return 0 end
    if attributes.mode ~= "directory" then return attributes.size or 0 end
    local total = 0
    each(path, function(inner, inner_attributes) total = total + size_of(inner, inner_attributes) end)
    return total
end

--- Removes a file, or what is under a directory and the directory if asked. Returns the bytes.
local function remove(path, attributes, keep_directory)
    attributes = attributes or lfs().symlinkattributes(path)
    if not attributes then return 0 end
    if attributes.mode ~= "directory" then
        local size = attributes.size or 0
        return os.remove(path) and size or 0
    end
    local freed = 0
    each(path, function(inner, inner_attributes) freed = freed + remove(inner, inner_attributes) end)
    if not keep_directory then lfs().rmdir(path) end
    return freed
end

local function is_whole(dir)
    local f = io.open(dir .. "/state", "rb")
    if not f then return false end
    local state = f:read("*a")
    f:close()
    return state == "whole"
end

local function text_size(dir)
    local total = 0
    each(dir, function(path, attributes, name)
        if Storage.is_text_of_book(name) then total = total + size_of(path, attributes) end
    end)
    return total
end

--- Takes the text of one book off the device. Returns the bytes freed. The directory for its
-- chapters stays: an open store goes on writing there.
function Storage.remove_book(dir)
    local freed = 0
    each(dir, function(path, attributes, name)
        if Storage.is_text_of_book(name) then
            freed = freed + remove(path, attributes, name == "files")
        end
    end)
    return freed
end

-- The fonts' list takes a long time to make anew and is no mess. The directories stay, for the
-- engine goes on keeping its layouts where it was told at the start.
local function skip_in_cache(name) return name == "fontlist" end

local function each_leftover(root, visit)
    local now = os.time()
    each(root, function(path, attributes, name)
        -- A recent one may well be being waited for.
        if attributes.mode == "file" and Storage.is_leftover(name)
            and now - (attributes.modification or 0) > 60 then
            visit(path, attributes)
        end
    end)
end

--- How much each kind of thing takes. paths: { cache, root, books, covers, keep_cover }.
function Storage.measure(paths)
    local sizes = { junk = 0, covers = 0, partial = 0, books = 0, books_count = 0 }
    each(paths.cache, function(path, attributes)
        sizes.junk = sizes.junk + size_of(path, attributes)
    end, skip_in_cache)
    each_leftover(paths.root, function(_, attributes) sizes.junk = sizes.junk + (attributes.size or 0) end)
    each(paths.covers, function(path, attributes)
        if path ~= paths.keep_cover then sizes.covers = sizes.covers + size_of(path, attributes) end
    end)
    each(paths.books, function(path, attributes)
        if attributes.mode ~= "directory" then return end
        local size = text_size(path)
        if is_whole(path) then
            sizes.books = sizes.books + size
            sizes.books_count = sizes.books_count + 1
        else
            sizes.partial = sizes.partial + size
        end
    end)
    return sizes
end

--- Removes what picks say: { junk, covers, partial, books }. Returns the bytes freed.
function Storage.clear(paths, picks)
    local freed = 0
    if picks.junk then
        each(paths.cache, function(path, attributes)
            freed = freed + remove(path, attributes, true)
        end, skip_in_cache)
        each_leftover(paths.root, function(path, attributes) freed = freed + remove(path, attributes) end)
    end
    if picks.covers then
        each(paths.covers, function(path, attributes)
            if path ~= paths.keep_cover then freed = freed + remove(path, attributes) end
        end)
    end
    if picks.partial or picks.books then
        each(paths.books, function(path, attributes)
            if attributes.mode ~= "directory" then return end
            local pick = picks.partial
            if is_whole(path) then pick = picks.books end
            if pick then freed = freed + Storage.remove_book(path) end
        end)
    end
    return freed
end

return Storage
