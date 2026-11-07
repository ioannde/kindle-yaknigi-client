-- Highlights, notes and bookmarks of one book, kept the same here and at Yandex.
--
-- There is no queue of what was done. The device remembers what both sides last agreed on, and
-- each run compares the three: what has changed since is what was done. A run cut short leaves
-- nothing to repair, as the next one finds the same differences, or finds them gone.
--
-- A note here: { key, uuid, kind = "quote" | "bookmark", comment, pos, content, progress, cfi,
-- hidden }. cfi is there only if the note is new or has moved. hidden, for a highlight only, is
-- nil if this device has not yet heard. What was agreed, by uuid: { kind, comment, cfi, pos, hidden }.
local NoteSync = {}

-- Not everything this runs in has KOReader's logger, the unit tests for one.
local has_logger, logger = pcall(require, "logger")
if not has_logger then logger = { info = function() end } end

local KINDS = { quotes = "quote", bookmarks = "bookmark" }
-- With no notes here and this many agreed on, the notes were lost, not deleted one by one.
local LOST_AT = 3

local function text(value)
    return type(value) == "string" and value or ""
end

local function belongs(entry, book)
    return (type(entry.book) == "table" and entry.book.uuid == book)
        or entry.book_uuid == book or entry.book_init_uuid == book
end

--- All of this book's notes at Yandex, and the uuids it says were deleted, of any book. Being
-- absent from the list is no sign of deletion: only the word "removed" is.
function NoteSync.fetch(api, book)
    local items, removed = {}, {}
    for list, kind in pairs(KINDS) do
        local entries, why, detail = api:notes(list)
        if not entries then return nil, why, detail end
        for _, entry in ipairs(entries) do
            if entry.state == "removed" then
                removed[entry.uuid] = true
            elseif entry.state == "exists" and belongs(entry, book) then
                items[entry.uuid] = {
                    uuid = entry.uuid,
                    kind = kind,
                    cfi = entry.cfi,
                    content = text(entry.content),
                    comment = text(entry.comment),
                    color = entry.color,
                    hidden = entry.permanent_hidden == true,
                }
            end
        end
    end
    return { items = items, removed = removed }
end

local function agreed(kind, comment, cfi, pos, hidden)
    return { kind = kind, comment = comment, cfi = cfi, pos = pos, hidden = hidden }
end

-- Tells the device of Yandex's privacy of a highlight, should it hold another. The device leaves
-- it alone if it has been changed there since it was read.
local function hide_as_at_yandex(note, item, out)
    if note.hidden ~= item.hidden then
        out.hide[note.key] = { hidden = item.hidden, was = note.hidden }
    end
end

-- A note whose uuid is known: something may have changed on either side.
local function settle_linked(api, note, base, server, out)
    local uuid = note.uuid
    if server.removed[uuid] then
        out.drop[#out.drop + 1] = note.key
        return
    end
    local item = server.items[uuid]
    if not item then
        -- Neither there nor deleted: nothing can be said, so nothing is done.
        if base then out.known[uuid] = base end
        return
    end
    -- With nothing to compare with, Yandex's is taken as it stands.
    base = base or agreed(note.kind, item.comment, item.cfi, note.pos)
    local moved = note.cfi and note.cfi ~= base.cfi
    local commented = note.comment ~= base.comment
    -- A note that moved into a chapter not here yet has no new place: it is asked again next time.
    local pos = note.cfi and note.pos or base.pos
    local quote = note.kind == "quote"
    -- A value here that was never agreed on can only come of a change here: a note hears of it
    -- from Yandex and agrees on it in one go.
    local rehidden = quote and note.hidden ~= nil and note.hidden ~= base.hidden and note.hidden ~= item.hidden
    local hidden = nil
    if quote then
        hidden = item.hidden
        if rehidden then hidden = note.hidden else hide_as_at_yandex(note, item, out) end
    end
    if quote and (rehidden or (moved and note.cfi ~= item.cfi) or (commented and note.comment ~= item.comment)) then
        local ok = api:update_quote(uuid, {
            content = moved and note.content or item.content,
            comment = note.comment,
            cfi = moved and note.cfi or item.cfi,
            color = item.color,
            hidden = hidden,
        })
        if ok then
            out.known[uuid] = agreed(note.kind, note.comment, moved and note.cfi or item.cfi, pos, hidden)
        else
            out.known[uuid] = base
        end
        return
    end
    if not commented and item.comment ~= base.comment then
        out.set[note.key] = { comment = item.comment, was = note.comment }
    end
    out.known[uuid] = agreed(note.kind, item.comment, item.cfi, pos, hidden)
end

-- A note never yet at Yandex, as far as this device knows. It may be there all the same, sent
-- just as the book closed, so one in the same place is taken for it.
local function settle_new(api, book, note, server, claimed, out)
    if not note.cfi then -- its chapter is not here yet, or there is no text to place it by
        logger.info("yaknigi: a note has no place to send:", note.kind, note.key)
        return
    end
    for uuid, item in pairs(server.items) do
        if not claimed[uuid] and item.kind == note.kind and item.cfi == note.cfi then
            claimed[uuid] = true
            out.link[note.key] = uuid
            local comment = item.comment
            if note.kind == "quote" and note.comment ~= "" and note.comment ~= item.comment then
                if api:update_quote(uuid, { content = item.content, comment = note.comment, cfi = item.cfi,
                                            color = item.color, hidden = item.hidden }) then
                    comment = note.comment
                end
            elseif note.comment ~= item.comment then
                out.set[note.key] = { comment = item.comment, was = note.comment }
            end
            local hidden = nil
            if note.kind == "quote" then
                hidden = item.hidden
                hide_as_at_yandex(note, item, out)
            end
            out.known[uuid] = agreed(note.kind, comment, item.cfi, note.pos, hidden)
            return
        end
    end
    local made = api:create_note(note.kind, book, note)
    if made and made.uuid then
        claimed[made.uuid] = true
        out.link[note.key] = made.uuid
        out.known[made.uuid] = agreed(note.kind, note.comment, note.cfi, note.pos, note.hidden)
    end
end

--- Brings the two sides together, writing to Yandex what it lacks. Returns what is to be done
-- here: { known, link = {key = uuid}, set = {key = {comment, was}}, hide = {key = {hidden, was}},
-- drop = {key}, add = {item} }.
-- If the list could not be had, returns nil and why, and nothing has been touched.
function NoteSync.run(api, book, notes, known)
    local server, why, detail = NoteSync.fetch(api, book)
    if not server then return nil, why, detail end

    local out = { known = {}, link = {}, set = {}, hide = {}, drop = {}, add = {} }
    local claimed = {}
    for _, note in ipairs(notes) do
        if note.uuid then
            claimed[note.uuid] = true
            settle_linked(api, note, known[note.uuid], server, out)
        end
    end
    for _, note in ipairs(notes) do
        if not note.uuid then settle_new(api, book, note, server, claimed, out) end
    end

    local agreed_on = 0
    for _ in pairs(known) do agreed_on = agreed_on + 1 end
    local lost = #notes == 0 and agreed_on >= LOST_AT
    for uuid, item in pairs(server.items) do
        if not claimed[uuid] then
            if known[uuid] and not lost then
                -- Agreed on once and gone from here: it was deleted here.
                if not api:delete_note(item.kind, uuid) then out.known[uuid] = known[uuid] end
            else
                out.add[#out.add + 1] = item
            end
        end
    end
    return out
end

return NoteSync
