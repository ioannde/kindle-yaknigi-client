-- Reads the parts of container.xml and an OPF package that the loader needs.
local Opf = {}

local function attr(tag, name)
    return tag:match("[%s\"']" .. name .. '%s*=%s*"([^"]*)"')
        or tag:match("[%s\"']" .. name .. "%s*=%s*'([^']*)'")
end

local function unescape(s)
    return (s:gsub("&amp;", "&"):gsub("&apos;", "'"):gsub("&quot;", '"')
             :gsub("&lt;", "<"):gsub("&gt;", ">"))
end

--- Returns the OPF's path inside the book, such as "OEBPS/content.opf".
function Opf.rootfile(container)
    for tag in container:gmatch("<%s*rootfile%s[^>]*>") do
        local path = attr(tag, "full%-path")
        if path then return unescape(path) end
    end
end

--- Returns the directory part of a path with its trailing slash, or "".
function Opf.dirname(path)
    return path:match("^(.*/)") or ""
end

--- Parses an OPF. Hrefs are relative to the OPF, as written in it.
-- Returns { title=, spine={href,...}, fragments={...}, items={ {href=, media=, id=}, ... }, ncx=href }.
-- spine holds only (X)HTML documents, the same ones crengine makes DocFragments of.
-- fragments[i] is the 1-based position in spine of the book's i-th itemref, or false
-- if that itemref is not a document: Yandex's positions count every itemref.
function Opf.parse(opf)
    local out = { spine = {}, fragments = {}, items = {} }
    local title = opf:match("<dc:title[^>]*>(.-)</dc:title>")
    out.title = title and unescape(title) or nil

    local by_id = {}
    for tag in opf:gmatch("<%s*item%s[^>]*>") do
        local id, href = attr(tag, "id"), attr(tag, "href")
        if id and href then
            local item = { id = id, href = unescape(href), media = attr(tag, "media%-type") or "" }
            by_id[id] = item
            out.items[#out.items + 1] = item
            if item.media == "application/x-dtbncx+xml" then out.ncx = item.href end
        end
    end
    for tag in opf:gmatch("<%s*itemref%s[^>]*>") do
        local item = by_id[attr(tag, "idref") or ""]
        if item and Opf.is_html(item) then
            out.spine[#out.spine + 1] = item.href
            out.fragments[#out.fragments + 1] = #out.spine
        elseif item then
            out.fragments[#out.fragments + 1] = false
        end
    end
    return out
end

function Opf.is_html(item)
    return item.media:find("html", 1, true) ~= nil
        or item.href:lower():match("%.x?html?$") ~= nil
end

return Opf
