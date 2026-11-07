-- The notes of the open book as KOReader has them, for yaknigi/notesync.lua.
--
-- The uuid of a note is kept on KOReader's own item, and what was agreed with Yandex in the same
-- file. So if that file goes, both go, and no note here can look as if it had been deleted.
--
-- ctx: { ui, store, stubs, position = function(xp) -> cfi of a point or nil, progress = number,
-- default_hidden = whether a new highlight starts as private }
local Event = require("ui/event")
local T = require("ffi/util").template
local _ = require("gettext")
local logger = require("logger")

local Cfi = require("yaknigi/cfi")
local Prefs = require("yaknigi/prefs")

local NotesLocal = {}

local SETTING = "yaknigi_notes"
local BOOKMARK_LETTERS = 150 -- what the phone sends with a bookmark
local COMPARED_LETTERS = 40

local function key_of(item)
    return item.drawer and (tostring(item.pos0) .. "|" .. tostring(item.pos1)) or item.page
end

local function letters(text, count)
    local out = {}
    for letter in (text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #out >= count then break end
        out[#out + 1] = letter
    end
    return table.concat(out)
end

NotesLocal.letters = letters

-- The same words may differ in spaces and soft hyphens between a phone and crengine: a book's
-- non-breaking spaces reach Yandex as plain ones, and Lua's %s knows neither of them.
local function comparable(text)
    return letters(Cfi.plain_spaces(text):gsub("\194\173", ""):gsub("%s+", ""), COMPARED_LETTERS)
end

NotesLocal.comparable = comparable

function NotesLocal.known(ui)
    return ui.doc_settings:readSetting(SETTING) or {}
end

--- Whether a highlight is private, as far as is known here. One not yet stamped goes out as the
-- setting says; one from before this was kept here hears of it at the next comparison.
function NotesLocal.is_private(item)
    if item.yaknigi_hidden ~= nil then return item.yaknigi_hidden end
    return not item.yaknigi and Prefs.private_notes()
end

--- Changes the privacy of this one highlight, here and, from the next comparison, at Yandex.
function NotesLocal.set_private(ui, item, on)
    item.yaknigi_hidden = on and true or false
    ui:handleEvent(Event:new("YaknigiNotesChanged"))
end

local function range_of(ctx, item)
    if not item.drawer then
        local point = ctx.position(item.page)
        return point and Cfi.point_range(point)
    end
    local first, last = ctx.position(item.pos0), ctx.position(item.pos1)
    if not first or not last then return nil end
    local spine, start = first:match("^(/[^!]*!)(/.*)$")
    local other, finish = last:match("^(/[^!]*!)(/.*)$")
    return spine and spine == other and spine .. "," .. start .. "," .. finish or nil
end

local function page_words(doc, xp)
    local ok, text = pcall(function()
        return doc:getTextFromXPointers(xp, doc:getPageXPointer(doc:getPageFromXPointer(xp) + 1))
    end)
    return ok and letters((text or ""):gsub("%s+", " "):gsub("^ ", ""), BOOKMARK_LETTERS) or ""
end

--- The notes as yaknigi/notesync.lua takes them. A chapter not yet here gives no place.
function NotesLocal.collect(ctx, known)
    local doc = ctx.ui.document
    local notes = {}
    for _, item in ipairs(ctx.ui.annotation.annotations or {}) do
        local key = key_of(item)
        local base = item.yaknigi and known[item.yaknigi]
        -- Settled once, so that a change of the setting does not change a highlight already made.
        if item.drawer and not item.yaknigi and item.yaknigi_hidden == nil then
            item.yaknigi_hidden = ctx.default_hidden == true
        end
        local note = {
            key = key,
            uuid = item.yaknigi,
            kind = item.drawer and "quote" or "bookmark",
            comment = item.drawer and item.note or "",
            pos = key,
            progress = ctx.progress,
            hidden = item.yaknigi_hidden,
        }
        note.comment = note.comment or ""
        if not (base and base.pos == key) then
            note.cfi = range_of(ctx, item)
            if item.drawer then
                note.content = Cfi.plain_spaces(item.text)
            elseif not item.yaknigi then
                note.content = Cfi.plain_spaces(page_words(doc, item.page))
            end
        end
        notes[#notes + 1] = note
    end
    return notes
end

-- A note from Yandex as KOReader's item, or nil if its chapter is not here or holds other words.
local function make_item(ctx, note)
    local doc = ctx.ui.document
    local function not_placed(why)
        logger.info("yaknigi: a note not placed:", note.kind, note.uuid, why)
        return nil
    end
    local spine, start, finish = Cfi.range(note.cfi)
    local fragment = spine and ctx.store:fragment_of_spine_index(spine)
    local path = fragment and ctx.store.paths[fragment]
    if not path then return not_placed("no such chapter") end
    if ctx.stubs[fragment] or not ctx.store:has(path) then return not_placed("its chapter is not here yet") end
    local html = ctx.store:read(path)
    local first = Cfi.to_point(html, fragment, start)
    if not first then return not_placed("its start is not in the chapter") end
    if not doc:isXPointerInDocument(first) then return not_placed("crengine has no " .. first) end
    local chapter = ctx.ui.toc:getTocTitleByPage(first)
    if chapter == "" then chapter = nil end
    if note.kind == "bookmark" then
        return { page = first, chapter = chapter, text = chapter and T(_("in %1"), chapter) or nil,
                 yaknigi = note.uuid }
    end
    local last = Cfi.to_point(html, fragment, finish)
    if not last then return not_placed("its end is not in the chapter") end
    if not doc:isXPointerInDocument(last) then return not_placed("crengine has no " .. last) end
    if comparable(doc:getTextFromXPointers(first, last)) ~= comparable(note.content) then
        logger.warn("yaknigi: a note's place holds other words:", note.uuid, first, last)
        return nil
    end
    local highlight = ctx.ui.view.highlight
    return {
        page = first, pos0 = first, pos1 = last,
        text = note.content,
        note = note.comment ~= "" and note.comment or nil,
        drawer = highlight.saved_drawer or "lighten",
        color = highlight.saved_color,
        chapter = chapter,
        yaknigi = note.uuid,
        yaknigi_hidden = note.hidden,
    }
end

local function added_event(item, index)
    local event = { item, index_modified = index }
    if item.note then event.nb_notes_added = 1 elseif item.drawer then event.nb_highlights_added = 1 end
    return Event:new("AnnotationsModified", event)
end

--- Does here what the run says is to be done, and remembers what was agreed. A note that cannot
-- be placed now is left out of that, so the next run brings it again. Returns whether anything
-- among the notes changed.
function NotesLocal.apply(ctx, result)
    local ui = ctx.ui
    local by_key = {}
    for _, item in ipairs(ui.annotation.annotations or {}) do by_key[key_of(item)] = item end
    local known = result.known or {}
    local changed = false
    local function guarded(what, work)
        local ok, err = pcall(work)
        if ok then
            changed = true
        else
            logger.warn("yaknigi: could not", what, "a note:", err)
        end
    end

    for key, uuid in pairs(result.link or {}) do
        -- It may have been deleted just now: the next run sees it as deleted here.
        if by_key[key] then
            by_key[key].yaknigi = uuid
            changed = true
        end
    end
    for key, change in pairs(result.set or {}) do
        local item = by_key[key]
        -- Written over only if nobody has written in it since it was read.
        if item and (item.note or "") == change.was then
            guarded("change", function()
                local had = item.note
                item.note = change.comment ~= "" and change.comment or nil
                ui:handleEvent(Event:new("AnnotationsModified", {
                    item,
                    nb_notes_added = (item.note and 1 or 0) - (had and 1 or 0),
                    nb_highlights_added = (had and 1 or 0) - (item.note and 1 or 0),
                }))
            end)
        end
    end
    for key, change in pairs(result.hide or {}) do
        local item = by_key[key]
        -- Not over a change made here while the comparison was going on: that goes out next.
        if item and item.yaknigi_hidden == change.was then
            item.yaknigi_hidden = change.hidden == true
            changed = true
        end
    end
    for _, key in ipairs(result.drop or {}) do
        local item = by_key[key]
        if item then guarded("remove", function() ui.bookmark:removeItem(item) end) end
    end
    for _, note in ipairs(result.add or {}) do
        local made, item = pcall(make_item, ctx, note)
        if not made then logger.warn("yaknigi: could not place a note:", item) end
        if made and item then
            guarded("add", function()
                local index = ui.annotation:addItem(item)
                ui:handleEvent(added_event(item, index))
                known[note.uuid] = { kind = note.kind, comment = note.comment, cfi = note.cfi, pos = key_of(item),
                                     hidden = item.yaknigi_hidden }
            end)
        end
    end
    if changed then ui.bookmark:setDogearVisibility(ui.document:getXPointer()) end
    ui.doc_settings:saveSetting(SETTING, known)
    return changed
end

return NotesLocal
