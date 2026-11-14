-- The fonts a book can be read in: those the device has for books, the usual ones first, and
-- of them those the reader has not turned off in the settings.
local Fonts = {}

local PREFERRED = { "Noto Serif", "FreeSerif", "Noto Sans", "FreeSans" }
-- Bundled for other scripts and for the interface, not for reading a book.
local NOT_FOR_BOOKS = { "CJK", "Arabic", "Bengali", "Devanagari", "Naskh", "Symbol", "Dingbats", "Mono", "Nerd", "Nimbus" }

local SETTING = "yaknigi_hidden_fonts"

--- Of the faces the engine has, those for books in their order; pure, for the tests.
function Fonts.order(faces)
    local present, seen, list = {}, {}, {}
    for _, name in ipairs(faces) do present[name] = true end
    for _, name in ipairs(PREFERRED) do
        if present[name] then list[#list + 1] = name; seen[name] = true end
    end
    -- Whatever the user added to the device's font folder.
    for _, name in ipairs(faces) do
        local skip = seen[name]
        for _, word in ipairs(NOT_FOR_BOOKS) do
            if name:find(word, 1, true) then skip = true end
        end
        if not skip then list[#list + 1] = name; seen[name] = true end
    end
    return list
end

--- Those of the list not turned off; all of them if every one is.
function Fonts.visible(list, hidden)
    local shown = {}
    for _, name in ipairs(list) do
        if not hidden[name] then shown[#shown + 1] = name end
    end
    return #shown > 0 and shown or list
end

local function engine()
    return require("document/credocument"):engineInit()
end

function Fonts.all()
    return Fonts.order(engine().getFontFaces())
end

function Fonts.hidden()
    return G_reader_settings:readSetting(SETTING) or {}
end

function Fonts.set_hidden(name, off)
    local hidden = Fonts.hidden()
    hidden[name] = off or nil
    G_reader_settings:saveSetting(SETTING, hidden)
end

--- What the text panel goes through.
function Fonts.shown()
    return Fonts.visible(Fonts.all(), Fonts.hidden())
end

--- The face of the font itself at this size, or nil if it cannot be had.
function Fonts.face(name, size)
    local filename, index = engine().getFontFaceFilenameAndFaceIndex(name)
    if not filename then return nil end
    local ok, face = pcall(require("ui/font").getFace, require("ui/font"), filename, size, index)
    return ok and face or nil
end

return Fonts
