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
                            if want == #path then return table.concat(parts, "/"), e + 1 end
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

-- A phone counts every letter of a piece of text. crengine keeps one space of any run of them; both
-- read an entity as one letter. Goes on until stop(phone's count, crengine's count), and gives both.
local function count_letters(text, stop)
    local phone, kept, pos, after_space = 0, 0, 1, false
    while pos <= #text and not stop(phone, kept) do
        local c = text:byte(pos)
        local space = c == 32 or c == 9 or c == 10 or c == 13
        if c == 38 then
            pos = (select(2, text:find("^&[#%w]+;", pos)) or pos) + 1
        else
            pos = pos + (c < 128 and 1 or c < 224 and 2 or c < 240 and 3 or 4)
        end
        phone = phone + 1
        if not (space and after_space) then kept = kept + 1 end
        after_space = space
    end
    return phone, kept
end

--- Which text under an element a CFI's odd step means: its number among the element's pieces of
-- text as crengine has them, and the text. pos is where the element's contents start.
local function text_run(html, pos, odd)
    local before = (odd - 1) / 2
    local elements, depth, runs = 0, 0, 0
    while true do
        local s = html:find("<", pos, true)
        if not s then return nil end
        if depth == 0 then
            local text = html:sub(pos, s - 1)
            local blank = not text:find("[^%s]")
            -- As in Cfi.locate: crengine drops whitespace except between two elements in a line.
            if not blank or (elements > 0 and html:sub(s + 1, s + 1) ~= "/") then
                runs = runs + 1
                if elements == before and not blank then return runs, text end
            end
            if elements > before then return nil end
        end
        local e
        if html:sub(s, s + 3) == "<!--" then
            e = select(2, html:find("-->", s, true))
        else
            e = html:find(">", s, true)
        end
        if not e then return nil end
        pos = e + 1
        local tag = html:sub(s, e)
        local first = tag:sub(2, 2)
        if first == "/" then
            if not VOID[(tag:match("^</([%w:_%-]+)") or ""):lower()] then
                if depth == 0 then return nil end
                depth = depth - 1
            end
        elseif first ~= "!" and first ~= "?" then
            local name = tag:match("^<([%w:_%-]+)")
            if name then
                if depth == 0 then elements = elements + 1 end
                if tag:sub(-2) ~= "/>" and not VOID[name:lower():gsub("^.*:", "")] then depth = depth + 1 end
            end
        end
    end
end

--- The other way from Cfi.locate: the xpointer of a spot in a chapter, down to the letter.
-- inner is the part of a CFI after the "!", such as /2/4/6/1:154. Also gives the text the spot is
-- in. Nil if the chapter has no such place.
function Cfi.to_point(html, fragment, inner)
    local odd, offset = (type(inner) == "string" and inner or ""):match("/(%d+):(%d+)$")
    odd, offset = tonumber(odd), tonumber(offset)
    if not odd or odd % 2 == 0 or type(html) ~= "string" then return nil end
    local path = Cfi.body_path("/6/2!" .. inner)
    if not path then return nil end
    local base = "/body/DocFragment[" .. fragment .. "]/body"
    local where, start = "", nil
    if #path == 0 then
        start = select(2, html:find("<body[^>]*>"))
        start = start and start + 1
    else
        where, start = Cfi.resolve(html, path)
        if not where then return nil end
        where = "/" .. where
    end
    if not start then return nil end
    local run, text = text_run(html, start, odd)
    if not run then return nil end
    local _, kept = count_letters(text, function(phone) return phone >= offset end)
    return base .. where .. "/text()" .. (run > 1 and "[" .. run .. "]" or "") .. "." .. kept, text
end

--- The two ends of a range such as /6/22!,/2/4/6/1:154,/2/4/6/1:157: the chapter's place in the
-- spine, counted from zero, and where each end is in the chapter. Nil if it is not a range.
function Cfi.range(cfi)
    local head, common, first, last = (type(cfi) == "string" and cfi or ""):match("^(/[^!]*!)([^,]*),([^,]*),([^,]*)$")
    if not head then return nil end
    return Cfi.spine_index(head), common .. first, common .. last
end

--- A range from its two ends, as Yandex writes it.
function Cfi.make_range(spine_index, start, finish)
    return "/6/" .. (spine_index + 1) * 2 .. "!," .. start .. "," .. finish
end

--- The start of a position, without the range: /6/24!/2/4/2/64/1:560. Yandex stores
-- where a page starts and where it ends, and only the start says where the reader is.
function Cfi.start(cfi)
    if type(cfi) ~= "string" then return nil end
    local spine, first = cfi:match("^(/[^!]*!)/?,?(/[^,]*)")
    return spine and spine .. first or nil
end

--- A position as the single-point range the library card holds.
function Cfi.point_range(start)
    local spine, inner = start:match("^(/[^!]*!)(/.*)$")
    return spine .. "," .. inner .. "," .. inner
end

--- The position of a spot in a chapter; inner comes from Cfi.locate.
function Cfi.at(spine_index, inner)
    return "/6/" .. (spine_index + 1) * 2 .. "!" .. inner
end

-- /body/DocFragment[3]/body/div/p[2]/text()[2].15 gives the elements under <body> with
-- their indexes among same-named siblings, the text node and the offset in it. The last
-- two are nil when the pointer is at an element.
local function parse_xpointer(xp)
    local rest = type(xp) == "string" and xp:match("^/body/DocFragment[^/]*/body(.*)$")
    if not rest then return nil end
    local target, text_index, offset = {}, nil, nil
    for seg in rest:gmatch("/([^/]+)") do
        if seg:match("^text%(%)") then
            text_index = tonumber(seg:match("^text%(%)%[(%d+)%]")) or 1
            offset = tonumber(seg:match("%.(%d+)$")) or 0
            break
        end
        local name = seg:match("^[%w:_%-]+")
        if not name then return nil end
        target[#target + 1] = {
            name = name:lower():gsub("^.*:", ""),
            index = tonumber(seg:match("%[(%d+)%]")) or 1,
        }
    end
    return target, text_index, offset
end

--- Where an xpointer is in a chapter, as the part of a CFI after the "!", such as
-- /2/4/2/64/1:560. Yandex's positions always end in a text node, so a pointer at an
-- element, such as a picture, gives the next text. Returns nil if there is no text at
-- or after it.
-- Elements count every sibling in even steps; text nodes sit between them in odd steps.
function Cfi.locate(html, xp)
    local target, text_index, offset = parse_xpointer(xp)
    if not target or type(html) ~= "string" then return nil end

    local body_step
    local stack = { { n = 0, names = {}, on_target = true, is_target = #target == 0 } }
    local seek = #target == 0 and not text_index
    local runs = 0
    local deepest, fallback, fallback_depth = 0, nil, -1

    local function here(chars)
        local steps = { "/2/" .. body_step }
        for i = 2, #stack do steps[#steps + 1] = "/" .. stack[i].step end
        steps[#steps + 1] = "/" .. 2 * stack[#stack].n + 1 .. ":" .. chars
        return table.concat(steps)
    end

    --- Returns the answer if this piece of text is it.
    local function on_text(text, before_element)
        local top = stack[#stack]
        local blank = not text:find("[^%s]")
        -- crengine drops whitespace except between two elements in a line of text.
        if blank and not (top.n > 0 and before_element) then return nil end
        if not blank and seek then return here(0) end
        if top.is_target and text_index then
            runs = runs + 1
            if runs == text_index and not blank then
                local phone, kept = count_letters(text, function(_, kept) return kept > offset end)
                return here(kept > offset and phone - 1 or phone)
            end
        end
        if not blank and deepest > fallback_depth then
            fallback, fallback_depth = here(0), deepest
        end
    end

    local pos = 1
    while true do
        local s = html:find("<", pos, true)
        if not s then return fallback end
        if body_step then
            local found = on_text(html:sub(pos, s - 1), html:sub(s + 1, s + 1) ~= "/")
            if found then return found end
        end
        local e
        if html:sub(s, s + 3) == "<!--" then
            e = select(2, html:find("-->", s, true))
        else
            e = html:find(">", s, true)
        end
        if not e then return fallback end
        pos = e + 1
        local tag = html:sub(s, e)
        local first = tag:sub(2, 2)
        if first == "/" then
            if body_step then
                if not VOID[(tag:match("^</([%w:_%-]+)") or ""):lower()] then
                    if #stack == 1 then return fallback end
                    local closed = table.remove(stack)
                    -- The text the pointer named is not there: settle for what follows.
                    if closed.is_target then seek = true end
                end
            end
        elseif first ~= "!" and first ~= "?" then
            local name = tag:match("^<([%w:_%-]+)")
            if name then
                name = name:lower():gsub("^.*:", "")
                local closes_itself = tag:sub(-2) == "/>" or VOID[name]
                if not body_step then
                    if name == "body" and not closes_itself then
                        body_step = html:sub(1, s):lower():find("<head", 1, true) and 4 or 2
                    end
                else
                    local top = stack[#stack]
                    top.n = top.n + 1
                    top.names[name] = (top.names[name] or 0) + 1
                    local want = target[#stack]
                    local on_target = top.on_target and want ~= nil and want.name == name
                        and want.index == top.names[name]
                    local is_target = on_target and #stack == #target
                    if on_target then deepest = math.max(deepest, #stack) end
                    if is_target and (closes_itself or not text_index) then seek = true end
                    if not closes_itself then
                        stack[#stack + 1] = { n = 0, names = {}, step = top.n * 2,
                                              on_target = on_target, is_target = is_target }
                    end
                end
            end
        end
    end
end

return Cfi
