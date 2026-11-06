-- Turns the reading position Yandex stores (an EPUB CFI) into a crengine xpointer.
--
-- Library cards hold ranges shaped like /6/54!,/2/4/2/34/1:7,/2/4/2/38/1:9
-- where /6/54 is the spine item (even steps count element children from 2) and the
-- first branch after the comma is where the reader's page starts.
local Cfi = {}

--- Returns the zero-based spine index, or nil.
function Cfi.spine_index(cfi)
    local step = type(cfi) == "string" and cfi:match("^/%d+/(%d+)!")
    if not step then return nil end
    return math.floor(tonumber(step) / 2) - 1
end

--- Returns a list of element steps inside the chapter: 1-based element indexes
-- starting under <body>. Stops at the first text-node (odd) step. Returns nil when
-- the CFI does not point into a body.
function Cfi.body_path(cfi)
    if type(cfi) ~= "string" then return nil end
    local rest = cfi:match("!/?,?(/[^,]*)")
    if not rest then return nil end
    local steps = {}
    for step in rest:gmatch("/(%d+)") do steps[#steps + 1] = tonumber(step) end
    -- Steps are counted from the document: /2 is <html>, /4 is <body> in it.
    if steps[1] ~= 2 or steps[2] ~= 4 then return nil end
    local path = {}
    for i = 3, #steps do
        if steps[i] % 2 == 1 then break end
        path[#path + 1] = steps[i] / 2
    end
    return path
end

local VOID = { br = true, hr = true, img = true, meta = true, link = true, input = true,
               col = true, area = true, base = true, embed = true, source = true, wbr = true }

--- Follows element indexes through an XHTML chapter.
-- Returns the name-indexed path crengine uses, such as "div[2]/p[3]", or nil if the
-- chapter has no such element. An empty path returns "".
function Cfi.resolve(html, path)
    local depth, want = 0, 1
    -- counts[depth] is the elements and names seen so far under the current element.
    local counts = { { n = 0, names = {} } }
    local parts = {}
    local inside_body = false
    if #path == 0 then return "" end

    local pos = 1
    while true do
        local s, e = html:find("<[^>]*>", pos)
        if not s then return nil end
        pos = e + 1
        local tag = html:sub(s, e)
        local first = tag:sub(2, 2)
        if first == "/" then
            if inside_body then
                depth = depth - 1
                if depth < 0 then return nil end -- left <body>, or the wanted parent
            end
        elseif first ~= "!" and first ~= "?" then
            local name = tag:match("^<([%w:_%-]+)")
            if name then
                name = name:lower()
                local selfclosed = tag:sub(-2) == "/>" or VOID[name]
                if not inside_body then
                    if name == "body" and not selfclosed then inside_body = true end
                else
                    if depth == 0 then
                        local c = counts[want]
                        c.n = c.n + 1
                        c.names[name] = (c.names[name] or 0) + 1
                        if c.n == path[want] then
                            parts[#parts + 1] = name .. "[" .. c.names[name] .. "]"
                            if want == #path then return table.concat(parts, "/") end
                            if selfclosed then return nil end
                            want = want + 1
                            counts[want] = { n = 0, names = {} }
                            -- Descend: depth stays 0 relative to the new parent.
                        elseif not selfclosed then
                            depth = 1
                        end
                    elseif not selfclosed then
                        depth = depth + 1
                    end
                end
            end
        end
    end
end

--- Returns the xpointer for a CFI given the chapter's text, or nil.
-- fragment is the 1-based DocFragment. Falls back to the chapter's start.
function Cfi.to_xpointer(cfi, fragment, html)
    local base = "/body/DocFragment[" .. fragment .. "]/body"
    local path = html and Cfi.body_path(cfi)
    local inner = path and Cfi.resolve(html, path)
    if inner and inner ~= "" then return base .. "/" .. inner end
    return base
end

return Cfi
