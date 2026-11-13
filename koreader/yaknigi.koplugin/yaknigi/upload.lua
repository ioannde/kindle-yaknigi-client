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

--- The books Yandex would take under root, the newest first: what was copied a minute ago
-- is the one wanted. Folders under avoid are not looked into.
function Upload.find(root, avoid)
    local lfs = require("libs/libkoreader-lfs")
    local found = {}
    local function walk(dir, depth)
        local ok, iter, state = pcall(lfs.dir, dir)
        if not ok then return end
        for name in iter, state do
            if #found >= MOST then return end
            if name ~= "." and name ~= ".." then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" then
                    if depth < DEPTH and not skipped_dir(name, path, avoid or {}) then walk(path, depth + 1) end
                elseif attr and attr.mode == "file" and Upload.kind(name) and name:sub(1, 1) ~= "." then
                    found[#found + 1] = { path = path, size = attr.size, time = attr.modification or 0 }
                end
            end
        end
    end
    walk(root, 1)
    table.sort(found, function(a, b)
        if a.time ~= b.time then return a.time > b.time end
        return a.path < b.path
    end)
    return found
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
