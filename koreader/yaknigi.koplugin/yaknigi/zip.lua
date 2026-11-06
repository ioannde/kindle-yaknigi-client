-- Writes uncompressed ZIP files. Enough for an EPUB that lives on the device:
-- books are rebuilt often, and crengine reads stored entries without inflating.
local bit = require("bit")
local band, bor, bxor, rshift = bit.band, bit.bor, bit.bxor, bit.rshift

local crc_table = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if band(c, 1) ~= 0 then
            c = bxor(0xEDB88320, rshift(c, 1))
        else
            c = rshift(c, 1)
        end
    end
    crc_table[i] = c
end

local function crc32(s)
    local c = bit.bnot(0)
    for i = 1, #s do
        c = bxor(crc_table[band(bxor(c, s:byte(i)), 0xFF)], rshift(c, 8))
    end
    c = bit.bnot(c)
    -- bit ops return signed values; the ZIP field is unsigned.
    return c < 0 and c + 4294967296 or c
end

local function u16(n)
    return string.char(band(n, 0xFF), band(rshift(n, 8), 0xFF))
end

local function u32(n)
    return string.char(n % 256, math.floor(n / 256) % 256,
                       math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local Zip = {}
Zip.crc32 = crc32

--- Writes entries, a list of {name=, data=}, to path, in the order given.
-- Returns true, or nil and an error message.
function Zip.write(path, entries)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    local offset, central = 0, {}
    for _, e in ipairs(entries) do
        local crc, size = crc32(e.data), #e.data
        -- Version 2.0, UTF-8 names, method 0 (stored), no timestamp.
        local common = u16(20) .. u16(0x0800) .. u16(0) .. u16(0) .. u16(0x21)
            .. u32(crc) .. u32(size) .. u32(size) .. u16(#e.name) .. u16(0)
        local header = "PK\3\4" .. common .. e.name
        local ok, werr = f:write(header, e.data)
        if not ok then f:close(); return nil, werr end
        central[#central + 1] = "PK\1\2" .. u16(20) .. common .. u16(0) .. u16(0)
            .. u16(0) .. u32(0) .. u32(offset) .. e.name
        offset = offset + #header + size
    end
    local dir = table.concat(central)
    local ok, werr = f:write(dir, "PK\5\6", u16(0), u16(0), u16(#entries), u16(#entries),
                             u32(#dir), u32(offset), u16(0))
    if not ok then f:close(); return nil, werr end
    f:close()
    return true
end

return Zip
