-- Measure how long crengine takes to open a book, using KOReader's own libraries.
-- Run from KOReader's directory: ./luajit bench.lua EPUB_DIR CACHE_DIR
-- Prints one line per step. Covers both open paths the reader would take:
-- a whole book, and a skeleton holding only the chapters being read.
require("setupkoenv")
local ffi = require("ffi")
ffi.cdef [[
struct bench_timespec { long tv_sec; long tv_nsec; };
int clock_gettime(int, struct bench_timespec *);
]]
local function now()
    local t = ffi.new("struct bench_timespec")
    ffi.C.clock_gettime(1, t)
    return tonumber(t.tv_sec) + tonumber(t.tv_nsec) / 1e9
end

local dir, cache = arg[1], arg[2]
local W, H = 1236, 1648
local PAGE_VIEW_MODE = 1

local cre = require("libs/libkoreader-cre")
os.execute("mkdir -p '" .. cache .. "'")
cre.initCache(cache, 64 * 1024 * 1024, true, 40)
cre.initHyphDict("./data/hyph/")
cre.registerFont("./fonts/freefont/FreeSerif.ttf")

local function open(file)
    local d = cre.newDocView(W, H, PAGE_VIEW_MODE)
    d:readDefaults()
    d:setStringProperty("font.face.default", "FreeSerif")
    d:setIntProperty("crengine.cache.filesize.min", 65536)
    d:adjustFontSizes(300)
    d:setFontSize(44)
    d:setStyleSheet("./data/epub.css", "")
    local t0 = now()
    assert(d:loadDocument(file, false), "load failed: " .. file)
    local t1 = now()
    d:renderDocument()
    local t2 = now()
    return d, t1 - t0, t2 - t1
end

local function row(name, dom, render, pages)
    print(string.format("%-22s dom=%7.3fs render=%7.3fs total=%7.3fs pages=%d",
                        name, dom, render, dom + render, pages))
end

local function measure(name, file, runs)
    for i = 1, runs do
        local d, dom, render = open(file)
        row(name .. (i == 1 and " cold" or " cached"), dom, render, d:getPages())
        d:close()
    end
end

for _, mb in ipairs { 1, 6 } do
    measure("full " .. mb .. "MB", dir .. "/full_" .. mb .. ".epub", 2)
    measure("skeleton " .. mb .. "MB", dir .. "/skeleton_" .. mb .. ".epub", 2)
end

-- A position taken in the skeleton must land on the same text in the full book,
-- otherwise swapping one for the other would move the reader.
for _, mb in ipairs { 1, 6 } do
    local s = open(dir .. "/skeleton_" .. mb .. ".epub")
    local probe = "/body/DocFragment[32]/body/p[12]/text().0"
    local p = s:getPageFromXPointer(probe)
    s:gotoPage(p + 3)
    local xp = s:getXPointer()
    local text_s = s:getTextFromXPointer(xp)
    s:close()
    local f = open(dir .. "/full_" .. mb .. ".epub")
    local text_f = f:getTextFromXPointer(xp)
    f:gotoXPointer(xp)
    print(string.format("xpointer %dMB: %s same_text=%s back=%s", mb, xp,
                        tostring(text_s ~= nil and text_s == text_f), tostring(f:getXPointer() == xp)))
    f:close()
end
print("rss_kb=" .. (io.open("/proc/self/status") and
    io.open("/proc/self/status"):read("*a"):match("VmHWM:%s*(%d+)") or "?"))
