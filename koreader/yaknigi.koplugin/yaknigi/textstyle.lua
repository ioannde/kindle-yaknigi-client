-- Alignment, hyphenation and where a tap turns the page: KOReader's settings, in the app's
-- own words. Takes effect at once in an open book, and in the next one from what is saved.
local TextStyle = {}

-- KOReader's tweaks that decide alignment. Only one of them may stand at a time.
TextStyle.ALIGN_TWEAKS = {
    "text_align_most_left", "text_align_all_left", "text_align_most_justify", "text_align_all_justify",
}

-- "Как в книге" sets nothing, so that a book looks as it did before this setting came.
TextStyle.ALIGN = {
    { key = "book", label = "Как в книге" },
    { key = "justify", label = "По ширине", tweak = "text_align_most_justify" },
    { key = "left", label = "По левому краю", tweak = "text_align_most_left" },
}

TextStyle.TAP_MODES = {
    { key = "default", label = "Слева и справа" },
    { key = "top_bottom", label = "Сверху и снизу" },
}

--- A copy of the tweaks with this alignment and no other.
function TextStyle.with_align(tweaks, align)
    local copy = {}
    for id, on in pairs(tweaks or {}) do copy[id] = on end
    for _, id in ipairs(TextStyle.ALIGN_TWEAKS) do copy[id] = nil end
    for _, choice in ipairs(TextStyle.ALIGN) do
        if choice.key == align and choice.tweak then copy[choice.tweak] = true end
    end
    return copy
end

--- A copy of a book's own tweaks with nothing of alignment, and whether there was any.
function TextStyle.without_align(tweaks)
    local copy, changed = {}, false
    for id, on in pairs(tweaks or {}) do copy[id] = on end
    for _, id in ipairs(TextStyle.ALIGN_TWEAKS) do
        if copy[id] ~= nil then
            copy[id] = nil
            changed = true
        end
    end
    return copy, changed
end

function TextStyle.align()
    return G_reader_settings:readSetting("yaknigi_text_align") or "book"
end

function TextStyle.set_align(ui, align)
    G_reader_settings:saveSetting("yaknigi_text_align", align)
    local tweaks = G_reader_settings:readSetting("style_tweaks")
        or require("ui/data/css_tweaks").DEFAULT_GLOBAL_STYLE_TWEAKS
    tweaks = TextStyle.with_align(tweaks, align)
    G_reader_settings:saveSetting("style_tweaks", tweaks)
    local tweak = ui and ui.document and ui.styletweak
    if tweak then
        tweak.global_tweaks = tweaks
        tweak.doc_tweaks = TextStyle.without_align(tweak.doc_tweaks)
        tweak:updateCssText(true)
    end
end

function TextStyle.hyphenation()
    return G_reader_settings:nilOrTrue("hyphenation")
end

function TextStyle.set_hyphenation(ui, on)
    G_reader_settings:saveSetting("hyphenation", on)
    if ui and ui.document and ui.typography then
        ui.typography.hyphenation = on
        ui.document:setTextHyphenation(on)
        ui:handleEvent(require("ui/event"):new("UpdatePos"))
    end
end

function TextStyle.tap_mode()
    return G_reader_settings:readSetting("page_turns_tap_zones") == "top_bottom" and "top_bottom" or "default"
end

function TextStyle.set_tap_mode(ui, mode)
    if mode == "top_bottom" then
        G_reader_settings:saveSetting("page_turns_tap_zones", "top_bottom")
        G_reader_settings:saveSetting("page_turns_tap_zone_forward_size_ratio", 0.5)
        G_reader_settings:saveSetting("page_turns_tap_zone_backward_size_ratio", 0.5)
    else
        G_reader_settings:saveSetting("page_turns_tap_zones", "default")
        G_reader_settings:delSetting("page_turns_tap_zone_forward_size_ratio")
        G_reader_settings:delSetting("page_turns_tap_zone_backward_size_ratio")
    end
    if ui and ui.document and ui.view then
        ui.view:setupTouchZones()
        -- Registering anew takes a zone out of what ours come before.
        if ui.yaknigi and ui.yaknigi.shell then ui.yaknigi.shell:registerZone() end
    end
end

return TextStyle
