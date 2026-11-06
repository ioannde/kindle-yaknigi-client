-- Tests for the plugin's pure Lua modules. Run with: luajit tests/lua/run.lua
package.path = "koreader/yaknigi.koplugin/?.lua;" .. package.path
local Zip = require("yaknigi/zip")
local Opf = require("yaknigi/opf")
local Cfi = require("yaknigi/cfi")
local Http = require("yaknigi/http")
local Shelves = require("yaknigi/shelves")
local Catalogue = require("yaknigi/catalogue")
local Prefs = require("yaknigi/prefs")

local failed, passed = 0, 0
local function eq(got, want, name)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(("FAIL %s: got %s, want %s"):format(name, tostring(got), tostring(want)))
    end
end

-- shelves
eq(Shelves.of("finished", 40, 50), "finished", "a finished book stays finished")
eq(Shelves.of("reading", 0), "reading", "reading")
eq(Shelves.of("pending", 0), "want", "not begun")
eq(Shelves.of("pending", 0, 3), "reading", "begun here, Yandex still says pending")
eq(Shelves.of("pending", 12), "reading", "begun elsewhere")
eq(Shelves.normalize("ЁЖИК Абв-Я Ђ QwE"), "ежик абв-я ђ qwe", "normalize")
local shelf_items = {
    { title = "Технофеодализм", authors = "Янис Варуфакис", shelf = "reading", whole = true },
    { title = "Масса", authors = "Маргарита Ронжина", shelf = "want" },
    { title = "Ёлки", authors = "", shelf = "finished", whole = true },
}
eq(#Shelves.list(shelf_items, "all"), 3, "all")
eq(#Shelves.list(shelf_items, "device"), 2, "device")
eq(Shelves.list(shelf_items, "want")[1].title, "Масса", "a shelf")
eq(#Shelves.list(shelf_items, "all", "ТЕХНО варуфакис"), 1, "words in any field and case")
eq(#Shelves.list(shelf_items, "all", "елки"), 1, "е finds ё")
eq(#Shelves.list(shelf_items, "reading", "масса"), 0, "only in this shelf")
eq(#Shelves.list(shelf_items, "all", "масса варуфакис"), 0, "every word must be there")

-- zip
eq(Zip.crc32("123456789"), 0xCBF43926, "crc32 check value")
eq(Zip.crc32(""), 0, "crc32 empty")
local tmp = os.tmpname()
assert(Zip.write(tmp, { { name = "mimetype", data = "application/epub+zip" },
                        { name = "OEBPS/ф.html", data = ("<p>привет</p>"):rep(1000) } }))
local check = io.popen("python3 -I -c \"import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); " ..
    "print(z.testzip(), z.namelist()[0], len(z.read(z.namelist()[1])))\" " .. tmp)
eq(check:read("*l"), "None mimetype 19000", "python reads the zip")
check:close()
os.remove(tmp)

-- opf
eq(Opf.rootfile([[<rootfiles><rootfile media-type="x" full-path="OEBPS/c.opf"/></rootfiles>]]),
   "OEBPS/c.opf", "rootfile")
eq(Opf.dirname("OEBPS/c.opf"), "OEBPS/", "dirname")
eq(Opf.dirname("c.opf"), "", "dirname at root")
local book = Opf.parse([[<package><metadata><dc:title>A &amp; B</dc:title></metadata><manifest>
  <item id="n" href="t.ncx" media-type="application/x-dtbncx+xml"/>
  <item href="b.html" id="b" media-type="application/xhtml+xml"/>
  <item id='a' href='a&amp;1.html' media-type='application/xhtml+xml'/>
  <item id="s" href="s.css" media-type="text/css"/>
  <item id="i" href="i.jpg" media-type="image/jpeg"/>
  </manifest><spine toc="n"><itemref idref="a"/><itemref idref="i"/><itemref idref="b"/></spine></package>]])
eq(book.title, "A & B", "opf title")
eq(#book.spine, 2, "spine skips non-html")
eq(book.spine[1], "a&1.html", "spine order and unescape")
eq(book.spine[2], "b.html", "spine second")
eq(book.ncx, "t.ncx", "ncx")
eq(#book.items, 5, "items")

-- the cover and a chapter's pictures
eq(book.cover, nil, "an unnamed picture is not a cover")
local function cover_of(metadata, items)
    return Opf.parse("<package><metadata>" .. metadata .. "</metadata><manifest>" .. items .. "</manifest></package>").cover
end
eq(cover_of([[<meta name="cover" content="x"/>]], [[<item id="x" href="i/1.jpg" media-type="image/jpeg"/>]]),
   "i/1.jpg", "cover from a meta")
eq(cover_of("", [[<item id="x" href="1.png" media-type="image/png" properties="cover-image"/>]]),
   "1.png", "cover from properties")
eq(cover_of("", [[<item id="x" href="i/Cover.jpeg" media-type="image/jpeg"/>]]), "i/Cover.jpeg", "cover from a name")
eq(cover_of([[<meta name="cover" content="x"/>]], [[<item id="x" href="cover.html" media-type="application/xhtml+xml"/>]]),
   nil, "a page is not a cover picture")
local pics = Opf.pictures([[<p class="a"><IMG alt="" src="../i/a&amp;b.png"/></p><svg:image xlink:href="c.jpg"/>
  <image width="1" href='d.gif'></image><a href="no.html">x</a><img alt="no source"/>]])
eq(#pics, 3, "pictures of a chapter")
eq(pics[1], "../i/a&b.png", "img src")
eq(pics[2], "c.jpg", "svg image")
eq(pics[3], "d.gif", "image href")

-- what the page says about progress
local at = { ratio = 0.7, page = 723, pages = 1023, chapter_left = 9, chapter_pages = 12 }
eq(Prefs.progress_text("percent", at), "70%", "percent")
eq(Prefs.progress_text("percent", at, true), "70% книги", "percent, long")
eq(Prefs.progress_text("page", at), "723", "page")
eq(Prefs.progress_text("page", at, true), "Страница 723", "page, long")
eq(Prefs.progress_text("page_of", at), "723 из 1023", "page of pages")
do
    local left, right = Prefs.progress_text("chapter", at)
    eq(left, "До конца главы: 9 стр.", "chapter")
    eq(right, "75%", "chapter's share, to the other side")
    left, right = Prefs.progress_text("book", at)
    eq(left, "До конца книги: 300 стр.", "book")
    eq(right, "29%", "book's share, to the other side")
    eq(select(2, Prefs.progress_text("percent", at)), nil, "percent has one part")
end
for _, format in ipairs(Prefs.PROGRESS) do
    eq(Prefs.progress_text(format, { ratio = 0.5 }), "50%", "no pages yet: " .. format)
end
eq(Prefs.following(Prefs.PROGRESS, "percent"), "page", "the next progress")
eq(Prefs.following(Prefs.PROGRESS, "book"), "percent", "after the last progress")
eq(Prefs.following(Prefs.PROGRESS, "gone"), "percent", "an unknown progress")
do
    local urls = Prefs.sleep_cover_urls({
        small = "https://h/a/b-thumb.jpg?image_hash=1",
        large = "https://h/a/b-large.jpg?image_hash=1",
    })
    eq(urls[1], "https://h/a/b-original.jpg?image_hash=1", "the original first")
    eq(urls[2], "https://h/a/b-ipad.jpg?image_hash=1", "then the next size")
    eq(urls[3], "https://h/a/b-large.jpg?image_hash=1", "then what the card says")
    eq(urls[4], "https://h/a/b-thumb.jpg?image_hash=1", "and the smallest")
    eq(#urls, 4, "no more")
    local plain = Prefs.sleep_cover_urls({ url = "https://h/cover/3.png" })
    eq(#plain, 1, "no size in the name: nothing else to try")
    eq(#Prefs.sleep_cover_urls(nil), 0, "no cover")
end
eq(Prefs.network_symbol(true, true), "\u{ECA8}", "connected")
eq(Prefs.network_symbol(true, false), "\u{ECA9}", "no connection")
eq(Prefs.network_symbol(false, false), "\u{F072}", "airplane")

-- cfi
eq(Cfi.spine_index("/6/54!,/2/4/2/1:0,/2/4/2/1:9"), 26, "spine index")
eq(Cfi.spine_index("/6/2!,/2/4/2/2,/2/4/2/2"), 0, "first spine item")
eq(Cfi.spine_index(nil), nil, "no cfi")
eq(Cfi.spine_index("garbage"), nil, "bad cfi")
local path = Cfi.body_path("/6/8!,/2/4/2/34/1:7,/2/4/2/38/1:9")
eq(table.concat(path, ","), "1,17", "body path stops at text step")
eq(Cfi.body_path("/6/8!/,/2/4/2[x],/2/4/2[x]")[1], 1, "range with slash and id")
eq(Cfi.body_path("/6/8!,/2/2/2,/2/2/2"), nil, "not in body")

local chapter = [[<?xml version="1.0"?><html><head><title>t</title><meta charset="x"/></head>
<body class="c"><div id="o"><h1>T</h1><p>one</p><br/><p>two <i>x</i></p><div><p>in</p></div></div>
<p>after</p></body></html>]]
eq(Cfi.resolve(chapter, { 1 }), "div[1]", "first element")
eq(Cfi.resolve(chapter, { 2 }), "p[1]", "second element of body")
eq(Cfi.resolve(chapter, { 1, 2 }), "div[1]/p[1]", "h1 and p count separately")
eq(Cfi.resolve(chapter, { 1, 4 }), "div[1]/p[2]", "void br counts as a step")
eq(Cfi.resolve(chapter, { 1, 5, 1 }), "div[1]/div[1]/p[1]", "nested")
eq(Cfi.resolve(chapter, { 3 }), nil, "beyond the body")
eq(Cfi.resolve(chapter, { 1, 2, 1 }), nil, "no such child")
eq(Cfi.resolve(chapter, {}), "", "empty path")
eq(Cfi.to_xpointer("/6/8!,/2/4/2/1:0,/x", 4, chapter), "/body/DocFragment[4]/body/div[1]", "xpointer")
eq(Cfi.to_xpointer("/6/8!,/2/4/9/1:0,/x", 4, chapter), "/body/DocFragment[4]/body", "text step at body")
eq(Cfi.to_xpointer("nope", 4, chapter), "/body/DocFragment[4]/body", "fallback")

-- http
local function fake_sock(script, log)
    -- script: list of responses, one per request; nil sends an error.
    local s = { buf = "", closed = false }
    function s:send(d)
        log[#log + 1] = d
        local r = table.remove(script, 1)
        if r == false then return nil, "closed" end
        self.buf = r or ""
        return #d
    end
    function s:receive(n)
        if n == "*l" then
            local line, rest = self.buf:match("^(.-)\r?\n(.*)$")
            if not line then return nil, "closed" end
            self.buf = rest
            return line
        elseif n == "*a" then
            local d = self.buf
            self.buf = ""
            return d
        end
        if #self.buf < n then return nil, "closed" end
        local d = self.buf:sub(1, n)
        self.buf = self.buf:sub(n + 1)
        return d
    end
    function s:close() self.closed = true end
    return s
end

local connects, log = 0, {}
local script = { "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi",
                 "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n",
                 "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n" }
local sock = fake_sock(script, log)
local h = Http.new(function() connects = connects + 1; return sock end)
local st, body = h:request("GET", "https://x.test/a?b=1", { ["Auth-Token"] = "t" })
eq(st, 200, "status")
eq(body, "hi", "content-length body")
assert(log[1]:find("GET /a?b=1 HTTP/1.1\r\n", 1, true) and log[1]:find("Auth-Token: t\r\n", 1, true)
       and log[1]:sub(-4) == "\r\n\r\n", "request format")
st, body = h:request("GET", "https://x.test/b")
eq(body, "abcde", "chunked body")
st, body = h:request("GET", "https://x.test/c")
eq(st, 404, "empty 404")
eq(body, "", "empty body")
eq(connects, 1, "connection is reused")

-- The server closed the idle connection: retried on a new one.
connects = 0
local socks = { fake_sock({ "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\na", false }, log),
                fake_sock({ "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nb" }, log) }
h = Http.new(function() connects = connects + 1; return socks[connects] end)
h:request("GET", "http://x.test/1")
st, body = h:request("POST", "http://x.test/2", nil, "data")
eq(body, "b", "retry after idle close")
eq(connects, 2, "reconnected once")
assert(log[#log]:find("Content%-Length: 4\r\n\r\ndata$"), "post body")

-- A fresh connection that fails is not retried.
connects = 0
h = Http.new(function() connects = connects + 1; return fake_sock({ false }, log) end)
st, body = h:request("GET", "http://x.test/1")
eq(st, nil, "fresh failure reported")
eq(connects, 1, "no retry on a fresh connection")

-- Connection: close drops the socket; no length reads to the end.
connects = 0
h = Http.new(function() connects = connects + 1
    return fake_sock({ "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 1\r\n\r\nx" }, log) end)
h:request("GET", "http://x.test/1")
eq(h.sock, nil, "closed after Connection: close")

-- A different host does not reuse the connection.
connects = 0
h = Http.new(function() connects = connects + 1
    return fake_sock({ "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n",
                       "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" }, log) end)
h:request("GET", "http://x.test/1")
h:request("GET", "http://y.test/1")
eq(connects, 2, "new host, new connection")

-- The way back: an xpointer to Yandex's position.
eq(Cfi.start("/6/24!,/2/4/2/64/1:560,/2/4/2/66/5:89"), "/6/24!/2/4/2/64/1:560", "start of a range")
eq(Cfi.start("/6/24!/2/4/2/64/1:560"), "/6/24!/2/4/2/64/1:560", "a point is its start")
eq(Cfi.start(nil), nil, "no position")
eq(Cfi.at(11, "/2/4/2/64/1:560"), "/6/24!/2/4/2/64/1:560", "spine index to steps")
eq(Cfi.point_range("/6/24!/2/4/2/64/1:560"), "/6/24!,/2/4/2/64/1:560,/2/4/2/64/1:560", "range as the card holds it")
local F = "/body/DocFragment[13]/body"
local page = '<?xml version="1.0"?><html><head><title>x</title></head><body><div>'
    .. "<h1>Заголовок</h1><p>Первый абзац</p><!-- a > b --><p>Второй абзац</p><br/><p>Третий</p>"
    .. "<p>Раз <em>два</em> <b>три</b> четыре &amp; пять</p><img src='a.png'/>"
    .. "<div><p>Вложенный</p></div></div><p>Вне</p></body></html>"
eq(Cfi.locate(page, F .. "/div/p[1]/text().3"), "/2/4/2/4/1:3", "h1 counts as a step, not as a p")
eq(Cfi.locate(page, F .. "/div/p[2]/text().0"), "/2/4/2/6/1:0", "a comment is no step")
eq(Cfi.locate(page, F .. "/div/p[3]/text().2"), "/2/4/2/10/1:2", "br is a step")
eq(Cfi.locate(page, F .. "/div/p[4]/text()[1].2"), "/2/4/2/12/1:2", "text before the elements")
eq(Cfi.locate(page, F .. "/div/p[4]/em/text().1"), "/2/4/2/12/2/1:1", "text in an inline element")
eq(Cfi.locate(page, F .. "/div/p[4]/text()[3].1"), "/2/4/2/12/5:1", "text after two elements, with a space between")
eq(Cfi.locate(page, F .. "/div/p[4]/text()[3].999"), "/2/4/2/12/5:14", "past the end of the text, an entity is one letter")
eq(Cfi.locate(page, F .. "/div/img"), "/2/4/2/16/2/1:0", "a picture gives the text after it")
eq(Cfi.locate(page, F .. "/div/div/p/text().4"), "/2/4/2/16/2/1:4", "nested")
eq(Cfi.locate(page, F .. "/p/text().1"), "/2/4/4/1:1", "second child of body")
eq(Cfi.locate(page, F), "/2/4/2/2/1:0", "the chapter's start")
eq(Cfi.locate(page, F .. "/div/p[9]/text().1"), "/2/4/2/2/1:0", "no such element: what is known of the path")
eq(Cfi.locate(page, "/body/nonsense"), nil, "not in a chapter")
eq(Cfi.locate(nil, F), nil, "no chapter")
eq(Cfi.locate("<html><head/><body><img/></body></html>", F .. "/img"), nil, "no text at all")

-- catalogue
local function found_book(uuid, extra)
    local found = { book = { uuid = uuid, name = "Идиот", authors = { { name = "Ф. Достоевский" }, { name = "Б" } },
        annotation = "О князе", cover = { url = "https://h/be/69/CWU-ipad.jpeg?image_hash=ab" } } }
    for k, v in pairs(extra or {}) do found[k] = v end
    return found
end
local found_item = Catalogue.item(found_book("u1"))
eq(found_item.title, "Идиот", "a found book's title")
eq(found_item.authors, "Ф. Достоевский, Б", "a found book's authors")
eq(found_item.annotation, "О князе", "a found book's annotation")
eq(found_item.in_library, false, "not said to be in the library")
eq(found_item.mandatory, nil, "no mark on a book not in the library")
eq(found_item.card.book.uuid, "u1", "a card to work with")
eq(found_item.card.book.cover.small, "https://h/be/69/CWU-thumb.jpeg?image_hash=ab", "the small cover")
eq(found_item.card.book.cover.large, "https://h/be/69/CWU-ipad.jpeg?image_hash=ab", "the big cover")
eq(Catalogue.item(found_book("u2", { progress = { inLibrary = true } })).mandatory, "в библиотеке", "marked")
eq(Catalogue.item({ book = { name = "без id" } }), nil, "no uuid, no item")
eq(Catalogue.item({}), nil, "no book")
local bare = Catalogue.item({ book = { uuid = "u3" } })
eq(bare.title, "?", "no name")
eq(bare.authors, "", "no authors")
eq(bare.card.book.cover, nil, "no cover")

local state = Catalogue.new("идиот")
eq(Catalogue.start(state), true, "the first request")
eq(Catalogue.start(state), false, "only one request at a time")
Catalogue.fail(state, "нет связи")
eq(state.failed, "нет связи", "failure kept")
eq(Catalogue.start(state), true, "another try after a failure")
eq(state.failed, nil, "failure forgotten when trying again")
eq(#Catalogue.add(state, { Catalogue.item(found_book("a")), Catalogue.item(found_book("b")) }, "1,25"), 2, "first page")
eq(state.finished, false, "more to come")
eq(state.cursor, "1,25", "where the next page starts")
eq(#Catalogue.add(state, { Catalogue.item(found_book("b")), Catalogue.item(found_book("c")) }, "2,50"), 1, "no book twice")
eq(#state.items, 3, "all found so far")
eq(state.finished, false, "still more")
Catalogue.add(state, { Catalogue.item(found_book("d")) }, "2,50")
eq(state.finished, true, "a cursor going nowhere ends it")
eq(Catalogue.start(state), false, "nothing to ask after the last page")
state = Catalogue.new("x")
state.loading = true
Catalogue.add(state, {}, "")
eq(state.finished, true, "nothing found")
eq(state.loading, false, "no longer loading")
state = Catalogue.new("x")
Catalogue.add(state, { Catalogue.item(found_book("a")) }, "1,25")
Catalogue.add(state, { Catalogue.item(found_book("a")) }, "2,50")
eq(state.finished, true, "only repeats: ends it")
eq(Catalogue.new(nil).finished, true, "nothing asked")
eq(#Catalogue.cards({ found_item }), 1, "cards for the covers")
local marked = Catalogue.item(found_book("m"))
Catalogue.mark_added(marked, { uuid = "real" })
eq(marked.card.uuid, "real", "the real card after adding")
eq(marked.mandatory, "в библиотеке", "marked after adding")

-- The feed
local Feed = require("yaknigi/feed")
local function feed_section(name, typename, count, entry_type)
    local page = {}
    for i = 1, count do
        local book = found_book(name .. i)
        book.__typename = entry_type or "TextBook"
        page[i] = book
    end
    return { __typename = typename or "SimpleSection", name = name, items = { page = page } }
end
local sections = Feed.sections({
    feed_section("Featured post", "FeaturedSection", 5),
    feed_section("аудио", nil, 5, "Audiobook"),
    feed_section("мало", nil, 2),
    feed_section("книги", nil, 4),
    { __typename = "SimpleSection", items = { page = {} } },
    "не таблица",
})
eq(#sections, 1, "only sections with books to read")
eq(sections[1].name, "книги", "the section's name")
eq(#sections[1].items, 4, "its books")
eq(#Feed.sections(nil), 0, "no page")
local dup = feed_section("д", nil, 3)
dup.items.page[2] = dup.items.page[1]
eq(#Feed.sections({ dup }), 0, "repeats do not count")
local feed = Feed.new()
eq(Feed.start(feed), "", "the feed starts at its start")
eq(Feed.start(feed), nil, "one request at a time")
Feed.add(feed, sections, "20")
eq(feed.finished, false, "there is more")
eq(Feed.start(feed), "20", "the next page")
Feed.fail(feed, "нет")
eq(feed.failed, "нет", "a failure is kept")
eq(Feed.start(feed), "20", "and tried again")
eq(feed.failed, nil, "and forgotten")
Feed.add(feed, sections, "")
eq(#feed.sections, 2, "added")
eq(feed.finished, true, "the last page")
eq(Feed.start(feed), nil, "nothing after the last page")
Feed.renew(feed)
eq(Feed.start(feed), "", "asked anew from the start")
eq(#feed.sections, 2, "what is shown stays meanwhile")
Feed.add(feed, sections, "20")
eq(#feed.sections, 1, "the start replaces")
local endless = Feed.new()
for i = 1, 3 do
    Feed.start(endless)
    Feed.add(endless, {}, tostring(i * 20))
end
eq(endless.finished, true, "pages of nothing do not go on for ever")
Feed.start(Feed.new())
local same = Feed.new()
Feed.start(same)
Feed.add(same, sections, "20")
Feed.start(same)
Feed.add(same, sections, "20")
eq(same.finished, true, "a cursor that goes nowhere ends it")
local saved = Feed.from_saved({ sections = sections, cursor = "20", uuid = "u" })
eq(saved.stale, true, "what was saved is asked again")
eq(saved.uuid, "u", "with the same feed")
eq(Feed.start(saved), "", "from the start")
eq(#Feed.from_saved(nil).sections, 0, "nothing saved")
eq(#Feed.from_saved({ sections = "x" }).sections, 0, "something odd saved")
eq(#Feed.cards(sections, 2), 2, "the row's covers")
eq(#Feed.cards(sections), 4, "all covers")
eq(#Feed.items(feed), 4, "all books")

-- A page with words on it
package.preload["yaknigi/store"] = function() return {} end -- only the pure part is tried here
local Session = require("yaknigi/session")
eq(Session.has_words('<html><head><title>Обложка</title></head><body><img src="c.jpg" alt="Обложка"/></body></html>'), false, "a picture only")
eq(Session.has_words("<html><body><p>Он шёл по улице.</p></body></html>"), true, "a text")
eq(Session.start_of(3), "/body/DocFragment[3]", "where a fragment starts")

-- What can be cleared off the device
package.preload["libs/libkoreader-lfs"] = function() return {} end
local Storage = require("yaknigi/storage")
for name, want in pairs{ files = true, ["book.epub"] = true, state = true, priority = true,
    ["book.epub.build123"] = true, ["fragment.tmp"] = true, ["manifest.json"] = false, card = false,
    server_cfi = false, to_send = false, sent = false, news = false, checked = false, ["book.sdr"] = false } do
    eq(Storage.is_text_of_book(name), want, "text of a book: " .. name)
end
eq(Storage.is_leftover("add.result3"), true, "an answer nobody came for")
eq(Storage.is_leftover("library.json"), false, "the library stays")
eq(Storage.is_leftover("feed.json"), false, "the feed stays")
eq(Storage.size_text(0), "0 КБ", "nothing")
eq(Storage.size_text(340 * 1024), "340 КБ", "kilobytes")
eq(Storage.size_text(math.floor(3.4 * 1024 * 1024)), "3,4 МБ", "a decimal comma")
eq(Storage.size_text(12 * 1024 * 1024), "12 МБ", "megabytes")
eq(Storage.size_text(5 * 1024 * 1024), "5 МБ", "no empty decimal")
eq(Storage.size_text(math.floor(1.4 * 1024 * 1024 * 1024)), "1,4 ГБ", "gigabytes")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
