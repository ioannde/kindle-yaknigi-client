-- Copied to the app's own KO_HOME on first start and whenever this file changes.
return {
    ["language"] = "ru",
    ["quickstart_shown_version"] = 999999999999,
    ["start_with"] = "filemanager",
    ["auto_restore_files"] = false,
    -- Looking at a word or a passage with a long press asks what to do with it.
    ["highlight_action_on_single_word"] = true,
    -- Text settings for the first book.
    ["cre_font"] = "Noto Serif",
    ["copt_line_spacing"] = 115,
    ["copt_h_page_margins"] = { 20, 20 },
    ["copt_t_page_margin"] = 15,
    ["copt_b_page_margin"] = 10,
    -- Only the percentage and a thin line at the bottom of the page.
    -- KOReader takes this table instead of its defaults, not on top of them, so it is whole.
    ["footer"] = {
        disable_progress_bar = false, chapter_progress_bar = false, disabled = false,
        all_at_once = true, reclaim_height = false, toc_markers = false,
        page_progress = false, pages_left_book = false, time = false, pages_left = false,
        battery = false, battery_hide_threshold = 100, percentage = true,
        book_time_to_read = false, chapter_time_to_read = false, frontlight = false,
        mem_usage = false, wifi_status = false, page_turning_inverted = false,
        book_author = false, book_title = false, book_chapter = false, bookmark_count = false,
        chapter_progress = false, item_prefix = "icons", toc_markers_width = 2,
        text_font_size = 13, text_font_bold = false,
        text_font_face = "./fonts/noto/NotoSans-Regular.ttf",
        container_height = 20, container_bottom_padding = 1,
        progress_margin_width = 10, progress_margin = false, progress_bar_min_width_pct = 20,
        book_author_max_width_pct = 30, book_title_max_width_pct = 30, book_chapter_max_width_pct = 30,
        skim_widget_on_hold = false, progress_style_thin = true, progress_bar_position = "below",
        bottom_horizontal_separator = false, align = "center", auto_refresh_time = false,
        progress_style_thin_height = 2, progress_style_thick_height = 7,
        hide_empty_generators = false, lock_tap = false, items_separator = "bar",
        progress_pct_format = "0", pages_left_includes_current_page = false, initial_marker = false,
        invert_progress_direction = false,
    },
    ["reader_footer_mode"] = 6,
    -- Nothing here is reachable from the app's screens. Gestures would also add its own
    -- corner taps and swipes, and the rest only take time and memory at each start.
    ["plugins_disabled"] = {
        ["SSH"] = true, ["archiveviewer"] = true, ["autoturn"] = true, ["batterystat"] = true,
        ["bookshortcuts"] = true, ["calibre"] = true, ["cloudstorage"] = true, ["coverbrowser"] = true,
        ["coverimage"] = true, ["docsettingtweak"] = true, ["exporter"] = true, ["gestures"] = true,
        ["hello"] = true, ["hotkeys"] = true, ["httpinspector"] = true, ["japanese"] = true,
        ["kosync"] = true, ["movetoarchive"] = true, ["newsdownloader"] = true, ["opds"] = true,
        ["perceptionexpander"] = true, ["profiles"] = true, ["qrclipboard"] = true, ["readtimer"] = true,
        ["statistics"] = true, ["systemstat"] = true, ["terminal"] = true, ["texteditor"] = true,
        ["vocabbuilder"] = true, ["wallabag"] = true,
    },
}
