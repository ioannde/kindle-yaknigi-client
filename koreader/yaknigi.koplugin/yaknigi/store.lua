-- A book on disk: its manifest, the files fetched so far, and the EPUB built from them.
--
-- The EPUB always has the book's full spine; a chapter not fetched yet is a one-line
-- stub. Its DocFragment numbers therefore never change, so an xpointer, and with it
-- the reading position and highlights, stays valid when the file is rebuilt with more
-- chapters in it.
local Opf = require("yaknigi/opf")
local Zip = require("yaknigi/zip")
local ffi = require("ffi")
local json = require("rapidjson")

pcall(ffi.cdef, "int getpid(void);")

local Store = {}
Store.__index = Store

local STUB_TEXT = "Глава загружается…"

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_atomic(path, data)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    local ok
    ok, err = f:write(data)
    f:close()
    if not ok then os.remove(tmp); return nil, err end
    return os.rename(tmp, path)
end

local function normalize(path)
    local parts = {}
    for seg in path:gmatch("[^/]+") do
        if seg == ".." then
            parts[#parts] = nil
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return table.concat(parts, "/")
end

--- root must exist. Returns nil for ids that are not safe as a directory name.
function Store.open(root, id)
    if type(id) ~= "string" or not id:match("^[%w_%-]+$") then return nil end
    local dir = root .. "/" .. id
    os.execute("mkdir -p '" .. dir .. "/files'")
    local self = setmetatable({ dir = dir, id = id }, Store)
    self.epub = dir .. "/book.epub"
    local raw = read_file(dir .. "/manifest.json")
    if raw then
        local manifest = json.decode(raw)
        if type(manifest) == "table" then self:use_manifest(manifest) end
    end
    return self
end

function Store:use_manifest(manifest)
    self.manifest = manifest
    local opf_path = Opf.rootfile(manifest.container or "") or "OEBPS/content.opf"
    self.opf_path = opf_path
    local prefix = Opf.dirname(opf_path)
    self.book = Opf.parse(manifest.opf)
    self.paths, self.resources = {}, {}
    for i, href in ipairs(self.book.spine) do
        self.paths[i] = normalize(prefix .. href)
    end
    local is_chapter = {}
    for _, p in ipairs(self.paths) do is_chapter[p] = true end
    for _, item in ipairs(self.book.items) do
        local p = normalize(prefix .. item.href)
        if not is_chapter[p] and item.href ~= self.book.ncx then
            self.resources[#self.resources + 1] = p
        end
    end
end

function Store:set_manifest(manifest)
    local ok, err = write_atomic(self.dir .. "/manifest.json", json.encode(manifest))
    if not ok then return nil, err end
    self:use_manifest(manifest)
    return true
end

local function file_name(path)
    return (path:gsub("[^%w%.%-]", function(c) return ("_%02X"):format(c:byte()) end))
end

function Store:has(path)
    local f = io.open(self.dir .. "/files/" .. file_name(path), "rb")
    if f then f:close() end
    return f ~= nil
end

function Store:read(path)
    return read_file(self.dir .. "/files/" .. file_name(path))
end

function Store:write(path, data)
    return write_atomic(self.dir .. "/files/" .. file_name(path), data)
end

--- Number of the chapter a Yandex spine index refers to, 1-based; 1 if unknown.
function Store:fragment_of_spine_index(index)
    local fragment = index and self.book.fragments[index + 1]
    return fragment or 1
end

--- The Yandex spine index of a chapter, zero-based; nil if unknown.
function Store:spine_index_of_fragment(fragment)
    for i, f in ipairs(self.book.fragments) do
        if f == fragment then return i - 1 end
    end
    return nil
end

--- Paths of everything still to fetch, chapters nearest to `around` first and
-- forward before backward, then resources. Stylesheets go first of all, since they
-- change how every chapter looks.
function Store:missing(around)
    local out = {}
    local function add(p)
        if p and not self:has(p) then out[#out + 1] = p end
    end
    for _, p in ipairs(self.resources) do
        if p:lower():match("%.css$") then add(p) end
    end
    local n = #self.paths
    local c = math.max(1, math.min(around or 1, n))
    add(self.paths[c])
    for d = 1, n do
        add(self.paths[c + d])
        add(self.paths[c - d])
    end
    for _, p in ipairs(self.resources) do
        if not p:lower():match("%.css$") then add(p) end
    end
    return out
end

local function stub(title)
    return '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml">'
        .. "<head><title>" .. title .. "</title></head><body><p>" .. title .. "</p></body></html>"
end

--- Rebuilds the EPUB from what is on disk.
-- Returns a table of 1-based fragment numbers that are stubs, empty when the book is
-- whole; or nil and an error.
function Store:build()
    local m = self.manifest
    local prefix = Opf.dirname(self.opf_path)
    local entries = {
        { name = "mimetype", data = "application/epub+zip" },
        { name = "META-INF/container.xml", data = m.container },
        { name = self.opf_path, data = m.opf },
    }
    if m.ncx and self.book.ncx then
        entries[#entries + 1] = { name = normalize(prefix .. self.book.ncx), data = m.ncx }
    end
    local stubs = {}
    local have_stubs = false
    for i, p in ipairs(self.paths) do
        local data = self:read(p)
        if not data then
            data = stub(STUB_TEXT)
            stubs[i] = true
            have_stubs = true
        end
        entries[#entries + 1] = { name = p, data = data }
    end
    for _, p in ipairs(self.resources) do
        local data = self:read(p)
        if data then entries[#entries + 1] = { name = p, data = data } end
    end
    local tmp = self.epub .. ".build" .. ffi.C.getpid() -- the reader and the worker may both build
    local ok, err = Zip.write(tmp, entries)
    if not ok then os.remove(tmp); return nil, err end
    ok, err = os.rename(tmp, self.epub)
    if not ok then os.remove(tmp); return nil, err end
    local whole = not have_stubs and #self:missing() == 0
    write_atomic(self.dir .. "/state", whole and "whole" or "partial")
    return stubs
end

--- True if book.epub holds the whole book.
function Store:is_whole()
    if read_file(self.dir .. "/state") ~= "whole" then return false end
    local f = io.open(self.epub, "rb")
    if f then f:close() end
    return f ~= nil
end

return Store
