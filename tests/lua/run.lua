-- Tests for the plugin's pure Lua modules. Run with: luajit tests/lua/run.lua
package.path = "koreader/yaknigi.koplugin/?.lua;" .. package.path
local Zip = require("yaknigi/zip")
local Opf = require("yaknigi/opf")
local Cfi = require("yaknigi/cfi")
local Http = require("yaknigi/http")
local Shelves = require("yaknigi/shelves")
local Catalogue = require("yaknigi/catalogue")
local Prefs = require("yaknigi/prefs")
local NoteSync = require("yaknigi/notesync")
local Updater = require("yaknigi/updater")
local Access = require("yaknigi/access")
local TextStyle = require("yaknigi/textstyle")
local Fonts = require("yaknigi/fonts")
local Upload = require("yaknigi/upload")

local failed, passed = 0, 0
local function eq(got, want, name)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(("FAIL %s: got %s, want %s"):format(name, tostring(got), tostring(want)))
    end
end

-- fonts
do
    local list = Fonts.order({ "Literata", "Noto Sans CJK SC", "FreeSans", "Noto Serif", "DejaVu Sans Mono", "Literata" })
    eq(table.concat(list, ","), "Noto Serif,FreeSans,Literata", "usual fonts first, none for other scripts, once each")
    eq(table.concat(Fonts.visible(list, { FreeSans = true }), ","), "Noto Serif,Literata", "a font turned off")
    eq(#Fonts.visible(list, { ["Noto Serif"] = true, FreeSans = true, Literata = true }), 3, "all off shows all")
end

-- books of one's own
eq(Upload.kind("/mnt/us/documents/A.EPUB"), "epub", "an epub in capitals")
eq(Upload.kind("book.fb2"), "fb2", "fb2")
eq(Upload.kind("book.fb2.zip"), nil, "a zipped fb2 is not taken")
eq(Upload.kind("book.pdf"), nil, "pdf is not taken")
eq(Upload.kind("epub"), nil, "no extension")
eq(Upload.kind("dir.epub/x"), nil, "an extension of a folder")
eq(Upload.content_type("x.fb2"), "application/x-fictionbook+xml", "fb2 type")
eq(Upload.file_name("/a/b/Война и мир.epub"), "Война и мир.epub", "file name")
eq(Upload.title("/a/b/v1.0.final.epub"), "v1.0.final", "title keeps inner dots")
eq(Upload.books_word(1) .. Upload.books_word(3) .. Upload.books_word(5), "книгакнигикниг", "1, 3, 5 books")
eq(Upload.books_word(11) .. Upload.books_word(21) .. Upload.books_word(112), "книгкнигакниг", "11, 21, 112 books")
eq(Upload.size_text(5.2 * 1024 * 1024), "5,2 МБ", "megabytes with a comma")
eq(Upload.size_text(840 * 1024), "840 КБ", "kilobytes")
eq(Upload.size_text(100), "1 КБ", "a tiny file is not 0")
do
    local now = os.time{ year = 2026, month = 11, day = 13, hour = 9 }
    eq(Upload.date_text(now - 3600, now), "сегодня", "an hour ago")
    eq(Upload.date_text(os.time{ year = 2026, month = 11, day = 12, hour = 23 }, now), "вчера", "late yesterday")
    eq(Upload.date_text(os.time{ year = 2026, month = 5, day = 2, hour = 12 }, now), "2 мая", "this year")
    eq(Upload.date_text(os.time{ year = 2025, month = 11, day = 13, hour = 12 }, now), "13 нояб. 2025", "last year")
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
local at = { ratio = 0.7, page = 723, pages = 1023, chapter_left = 9 }
eq(Prefs.progress_text("percent", at), "70%", "percent")
eq(Prefs.progress_text("percent", at, true), "70% книги", "percent, long")
eq(Prefs.progress_text("page", at), "723", "page")
eq(Prefs.progress_text("page", at, true), "Страница 723", "page, long")
eq(Prefs.progress_text("page_of", at), "723 из 1023", "page of pages")
do
    local episode = { ratio = 0.1, page = 3, pages = 30, whole = "эпизода" }
    eq(Prefs.progress_text("book", episode), "До конца эпизода: 27 стр.", "to the end of an episode")
    eq(Prefs.progress_text("percent", episode, true), "10% эпизода", "percent of an episode, long")
end
do
    local left, right = Prefs.progress_text("chapter", at)
    eq(left, "До конца главы: 9 стр.", "chapter")
    eq(right, "70%", "the book's share read, to the other side, even for a chapter")
    left, right = Prefs.progress_text("book", at)
    eq(left, "До конца книги: 300 стр.", "book")
    eq(right, "70%", "the book's share read, to the other side")
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
eq(Cfi.to_xpointer("/6/8!,/2/4/2/4/1:2,/2/4/2/4/1:3", 4, chapter), "/body/DocFragment[4]/body/div[1]/p[1]/text().2",
   "down to the letter where the page starts")
eq(Cfi.to_xpointer("/6/8!/2/4/2/8/1:3", 4, chapter), "/body/DocFragment[4]/body/div[1]/p[2]/text().3",
   "a start without a range")
eq(Cfi.to_xpointer("/6/8!,/2/4/2/4/1:2,/x", 4, nil), "/body/DocFragment[4]/body", "no chapter text")

-- http
local function fake_sock(script, log)
    -- script: list of responses, one per request; nil sends an error.
    local s = { buf = "", closed = false }
    -- The answer comes once the request has been sent, in as many pieces as it took.
    function s:send(d)
        log[#log + 1] = d
        if script[1] == false then table.remove(script, 1); return nil, "closed" end
        self.waiting = true
        return #d
    end
    function s:receive(n)
        if self.waiting then
            self.waiting = false
            self.buf = table.remove(script, 1) or ""
        end
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

-- A body in pieces is sent piece by piece, its length the sum of them.
log = {}
h = Http.new(function() return fake_sock({ "HTTP/1.1 204 No Content\r\n\r\n" }, log) end)
st = h:request("POST", "http://x.test/up", { ["Content-Type"] = "multipart/form-data" }, { "ab", "cde", "" })
eq(st, 204, "pieces answered")
assert(log[1]:find("Content%-Length: 5\r\n\r\n$"), "length of the pieces")
eq(table.concat(log, "", 2), "abcde", "pieces after the head")

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

-- from a CFI to a place in the text
local NOTE_HTML = '<html><head><title>t</title></head><body><p>раз</p>\n<div><p>два</p><p>три <em>жирно</em> хвост <b>x</b>\nконец</p></div></body></html>'
local to_point = function(inner) return (Cfi.to_point(NOTE_HTML, 3, inner)) end
do -- spaces: a phone counts them all, crengine keeps one of a run
    local spaced = "<html><head></head><body><p>ab  \n cd &amp; эф</p></body></html>"
    local at = function(n) return (Cfi.to_point(spaced, 1, "/2/4/2/1:" .. n)) end
    eq(at(2), "/body/DocFragment[1]/body/p[1]/text().2", "before a run of spaces")
    eq(at(4), "/body/DocFragment[1]/body/p[1]/text().3", "in a run of spaces")
    eq(at(6), "/body/DocFragment[1]/body/p[1]/text().3", "after a run of spaces")
    eq(at(12), "/body/DocFragment[1]/body/p[1]/text().9", "after an entity")
    eq(Cfi.locate(spaced, at(2)), "/2/4/2/1:2", "back, before a run of spaces")
    eq(Cfi.locate(spaced, at(6)), "/2/4/2/1:6", "back, after a run of spaces")
    eq(Cfi.locate(spaced, at(12)), "/2/4/2/1:12", "back, after an entity")
    eq(Cfi.locate(spaced, "/body/DocFragment[1]/body/p/text().99"), "/2/4/2/1:13", "past the end")
end
eq(to_point("/2/4/2/1:1"), "/body/DocFragment[3]/body/p[1]/text().1", "text in a first paragraph")
eq(to_point("/2/4/4/4/1:2"), "/body/DocFragment[3]/body/div[1]/p[2]/text().2", "by number among its kind")
eq(to_point("/2/4/4/4/3:1"), "/body/DocFragment[3]/body/div[1]/p[2]/text()[2].1", "text after an element")
eq(to_point("/2/4/4/4/5:3"), "/body/DocFragment[3]/body/div[1]/p[2]/text()[3].3", "text after two")
eq(to_point("/2/4/4/4/2/1:1"), "/body/DocFragment[3]/body/div[1]/p[2]/em[1]/text().1", "inside an element")
eq(to_point("/2/4/4/4/9:0"), nil, "no such text")
eq(to_point("/2/4/40/1:0"), nil, "no such element")
eq(to_point("nonsense"), nil, "not a place")
eq(select(2, Cfi.to_point(NOTE_HTML, 3, "/2/4/4/4/3:1")), " хвост ", "and what text it is")
-- There and back: what Cfi.locate writes, Cfi.to_point reads.
for _, inner in ipairs({ "/2/4/2/1:2", "/2/4/4/2/1:1", "/2/4/4/4/1:3", "/2/4/4/4/3:2", "/2/4/4/4/5:1", "/2/4/4/4/2/1:4" }) do
    eq(Cfi.locate(NOTE_HTML, to_point(inner)), inner, "there and back: " .. inner)
end
local range_spine, range_start, range_end = Cfi.range("/6/22!,/2/4/6/1:154,/2/4/6/1:157")
eq(range_spine, 10, "a range's chapter")
eq(range_start, "/2/4/6/1:154", "a range's start")
eq(range_end, "/2/4/6/1:157", "a range's end")
eq(select(3, Cfi.range("/6/22!/2/4,/6/1:1,/8/1:2")), "/2/4/8/1:2", "a range with a common part")
eq(Cfi.range("/6/22!/2/4/1:0"), nil, "a point is no range")
eq(Cfi.locate("<html><head></head><body><p>Текст</p></body></html>", "/body/DocFragment[3].0"), "/2/4/2/1:0",
   "a pointer at the chapter itself gives its first text")
eq(Cfi.locate("<html><head></head><body><p>Текст</p></body></html>", "/body/DocFragment[3]/body.0"), "/2/4/2/1:0",
   "as does one at its body")
eq(Cfi.make_range(10, "/2/4/6/1:154", "/2/4/6/1:157"), "/6/22!,/2/4/6/1:154,/2/4/6/1:157", "a range written")

-- notes: what was agreed, what is here and what is at Yandex
do
    local function fake(quotes, bookmarks, broken)
        local api = { calls = {}, quotes = quotes or {}, bookmarks = bookmarks or {} }
        function api:notes(list)
            if broken then return nil, "network" end
            return self[list]
        end
        function api:create_note(kind, _, note)
            self.calls[#self.calls + 1] = "create " .. kind .. " " .. note.cfi
            self.created = note
            if self.fail then return nil, "http" end
            return { uuid = "new" .. #self.calls }
        end
        function api:update_quote(uuid, q)
            self.calls[#self.calls + 1] = "update " .. uuid .. " " .. q.comment .. " " .. tostring(q.hidden) .. " " .. tostring(q.color)
            if self.fail then return nil, "http" end
            return { uuid = uuid }
        end
        function api:delete_note(kind, uuid)
            self.calls[#self.calls + 1] = "delete " .. kind .. " " .. uuid
            if self.fail then return nil, "http" end
            return true
        end
        return api
    end
    local function quote(uuid, comment, extra)
        local q = { state = "exists", uuid = uuid, book = { uuid = "b" }, cfi = "c-" .. uuid, content = "t", comment = comment, color = 0 }
        for k, v in pairs(extra or {}) do q[k] = v end
        return q
    end
    local function local_quote(key, uuid, comment, cfi)
        return { key = key, uuid = uuid, kind = "quote", comment = comment or "", pos = key, cfi = cfi, content = "t" }
    end
    local function agreed(uuid, comment)
        return { kind = "quote", comment = comment or "", cfi = "c-" .. uuid, pos = "p-" .. uuid }
    end
    local function run(api, notes, known) return NoteSync.run(api, "b", notes, known) end
    local function calls(api) return table.concat(api.calls, "; ") end

    eq(Cfi.plain_spaces("а\194\160б\226\128\137в\226\128\175г д"), "а б в г д", "wide spaces made plain")
    eq(Cfi.plain_spaces(nil), "", "no text, no spaces")

    -- privacy: the one who changed it is right, and nothing else is touched
    do
        local function hidden_quote(key, uuid, hidden)
            local note = local_quote(key, uuid)
            note.hidden = hidden
            return note
        end
        local function hidden_base(uuid, hidden)
            local base = agreed(uuid)
            base.hidden = hidden
            return base
        end
        local api = fake()
        local new = hidden_quote("k", nil, true)
        new.cfi = "c9"
        local out = run(api, { new }, {})
        eq(api.created.hidden, true, "a new highlight goes as it is here")
        eq(out.known.new1.hidden, true, "and that is agreed on")

        api = fake({ quote("q1", "", { permanent_hidden = true }) })
        out = run(api, { hidden_quote("k", "q1", false) }, { q1 = hidden_base("q1", true) })
        eq(calls(api):find("update q1  false", 1, true) ~= nil, true, "changed here: goes to Yandex")
        eq(out.known.q1.hidden, false, "and is agreed on")
        eq(next(out.hide), nil, "nothing to change here")

        api = fake({ quote("q1", "", { permanent_hidden = true }) })
        out = run(api, { hidden_quote("k", "q1", false) }, { q1 = hidden_base("q1", false) })
        eq(calls(api), "", "changed at Yandex: nothing is written")
        eq(out.hide.k.hidden, true, "it comes here")
        eq(out.hide.k.was, false, "unless changed here since")
        eq(out.known.q1.hidden, true, "and is agreed on")

        api = fake({ quote("q1", "", { permanent_hidden = true }) })
        out = run(api, { hidden_quote("k", "q1", nil) }, { q1 = agreed("q1") })
        eq(calls(api), "", "not known here yet: nothing is written")
        eq(out.hide.k.hidden, true, "Yandex's is taken")

        api = fake({ quote("q1", "", { permanent_hidden = true }) })
        out = run(api, { hidden_quote("k", "q1", true) }, { q1 = hidden_base("q1", true) })
        eq(calls(api), "", "the same on both sides: nothing is written")
        eq(next(out.hide), nil, "nor changed here")

        api = fake({ quote("q1", "новый", { permanent_hidden = true }) })
        out = run(api, { hidden_quote("k", "q1", false) }, { q1 = hidden_base("q1", false) })
        eq(out.hide.k.hidden, true, "a comment coming does not stop the privacy")

        api = fake({ quote("q1", "", { permanent_hidden = false }) })
        api.fail = true
        out = run(api, { hidden_quote("k", "q1", true) }, { q1 = hidden_base("q1", false) })
        eq(out.known.q1.hidden, false, "not written: asked again next time")

        api = fake({ quote("q1", "", { permanent_hidden = true, cfi = "c9" }) })
        new = hidden_quote("k", nil, false)
        new.cfi = "c9"
        out = run(api, { new }, {})
        eq(out.link.k, "q1", "the same place is the same highlight")
        eq(out.hide.k.hidden, true, "and Yandex's privacy is taken")
    end

    local api = fake()
    local out = run(api, { local_quote("k", nil, "", "c9") }, {})
    eq(calls(api), "create quote c9", "a new highlight goes to Yandex")
    eq(out.link.k, "new1", "and is linked to what it became")
    eq(out.known.new1.cfi, "c9", "and agreed on")

    api = fake(); api.fail = true
    out = run(api, { local_quote("k", nil, "", "c9") }, {})
    eq(out.link.k, nil, "if that failed, nothing is linked")
    eq(out.known.new1, nil, "and it is tried again next time")

    api = fake()
    out = run(api, { local_quote("k", nil, "") }, {})
    eq(calls(api), "", "a note in a chapter not here yet waits")

    api = fake({ quote("q1", "с телефона") })
    out = run(api, { local_quote("k", nil, "", "c-q1") }, {})
    eq(calls(api), "", "sent as the book closed: not sent twice")
    eq(out.link.k, "q1", "the one at Yandex is taken for it")
    eq(out.set.k.comment, "с телефона", "with its comment")

    api = fake({ quote("q1", "там") })
    out = run(api, { local_quote("k", nil, "тут", "c-q1") }, {})
    eq(calls(api), "update q1 тут false 0", "different comments in one place: this device's is sent")

    api = fake({ quote("q1", "старый", { permanent_hidden = true, color = 3 }) })
    out = run(api, { local_quote("p-q1", "q1", "новый") }, { q1 = agreed("q1", "старый") })
    eq(calls(api), "update q1 новый true 3", "a comment changed here: privacy and colour stay as they are")
    eq(out.known.q1.comment, "новый", "agreed on afterwards")

    api = fake({ quote("q1", "старый") }); api.fail = true
    out = run(api, { local_quote("p-q1", "q1", "новый") }, { q1 = agreed("q1", "старый") })
    eq(out.known.q1.comment, "старый", "a change not sent is still seen as a change")

    api = fake({ quote("q1", "новый") })
    out = run(api, { local_quote("p-q1", "q1", "старый") }, { q1 = agreed("q1", "старый") })
    eq(calls(api), "", "a comment changed on the phone: nothing to send")
    eq(out.set["p-q1"].comment, "новый", "it comes here")
    eq(out.set["p-q1"].was, "старый", "if nobody has written since")

    api = fake({ quote("q1", "телефон") })
    out = run(api, { local_quote("p-q1", "q1", "киндл") }, { q1 = agreed("q1", "старый") })
    eq(calls(api), "update q1 киндл false 0", "changed on both sides: this device's stays")

    api = fake({ quote("q1", "одно") })
    out = run(api, { local_quote("p-q1", "q1", "одно") }, { q1 = agreed("q1", "старый") })
    eq(calls(api), "", "changed to the same on both sides: nothing to send")
    eq(out.known.q1.comment, "одно", "and agreed on")
    eq(next(out.set), nil, "nothing to change here")

    api = fake({ quote("q1", "") })
    out = run(api, { local_quote("p-q1", "q1", "", "c-moved") }, { q1 = agreed("q1") })
    eq(calls(api), "update q1  false 0", "a highlight moved here goes to Yandex")
    eq(out.known.q1.cfi, "c-moved", "with its new place")

    api = fake({ { state = "removed", uuid = "q1" } })
    out = run(api, { local_quote("p-q1", "q1", "киндл") }, { q1 = agreed("q1") })
    eq(out.drop[1], "p-q1", "deleted on the phone: goes from here")
    eq(out.known.q1, nil, "and is forgotten")

    api = fake({})
    out = run(api, { local_quote("p-q1", "q1", "") }, { q1 = agreed("q1") })
    eq(out.drop[1], nil, "not in the list but not said to be deleted: it stays")
    eq(out.known.q1.cfi, "c-q1", "and is remembered")

    api = fake({ quote("q1", ""), quote("q2", "") })
    out = run(api, { local_quote("p-q2", "q2", "") }, { q1 = agreed("q1"), q2 = agreed("q2") })
    eq(calls(api), "delete quote q1", "deleted here: goes from Yandex")
    eq(out.known.q1, nil, "and is forgotten")
    eq(#out.add, 0, "and does not come back")

    api = fake({ quote("q1", "") }); api.fail = true
    out = run(api, { }, { q1 = agreed("q1") })
    eq(out.known.q1.cfi, "c-q1", "a deletion that failed is tried again")

    api = fake({ quote("q1", "") })
    out = run(api, {}, { q1 = agreed("q1") })
    eq(calls(api), "delete quote q1", "the only note deleted here")

    api = fake({ quote("q1", ""), quote("q2", ""), quote("q3", "") })
    out = run(api, {}, { q1 = agreed("q1"), q2 = agreed("q2"), q3 = agreed("q3") })
    eq(calls(api), "", "no notes here and many agreed on: lost, nothing is deleted at Yandex")
    eq(#out.add, 3, "they come back")

    api = fake({}, {}, true)
    local none, why = run(api, {}, { q1 = agreed("q1") })
    eq(none, nil, "no list: nothing is decided")
    eq(why, "network", "and it says why")

    api = fake({ quote("q1", "с телефона"), quote("other", "", { book = { uuid = "x" } }) },
        { { state = "exists", uuid = "m1", book_uuid = "b", cfi = "c-m1", content = "Н" } })
    out = run(api, {}, {})
    eq(#out.add, 2, "what is new at Yandex comes here, of this book only")

    api = fake({}, { { state = "exists", uuid = "m1", book_uuid = "b", cfi = "c-m1" } })
    out = run(api, { { key = "pg", kind = "bookmark", comment = "", pos = "pg", cfi = "c-m1" } }, {})
    eq(out.link.pg, "m1", "a bookmark on the same place is the same bookmark")

    api = fake({ { state = "exists", uuid = "q1", book = { uuid = "b" }, cfi = "c", content = "t" } })
    out = run(api, {}, {})
    eq(out.add[1].comment, "", "no comment at all is an empty one")
    eq(out.add[1].hidden, false, "public unless said otherwise")
end

-- what search finds besides books, and the lists
do
    local list = Catalogue.collection("bookshelf", "s", "Полка")
    list.items, list.seen, list.cursor, list.finished, list.failed = { 1 }, { a = true }, "2", true, "нет"
    Catalogue.renew(list)
    eq(#list.items, 0, "a renewed list has no books")
    eq(next(list.seen), nil, "and has seen none")
    eq(list.cursor, "", "and starts from the first page")
    eq(list.finished, false, "and is not finished")
    eq(list.failed, nil, "and has not failed")
    eq(Catalogue.start(list), true, "and can be asked for")
    local round = list.round
    Catalogue.renew(list)
    eq(list.round ~= round, true, "what was on its way is of the old list")
end
eq(Catalogue.count(1, "книга", "книги", "книг"), "1 книга", "one")
eq(Catalogue.count(3, "книга", "книги", "книг"), "3 книги", "few")
eq(Catalogue.count(11, "книга", "книги", "книг"), "11 книг", "eleven")
eq(Catalogue.count(751, "произведение", "произведения", "произведений"), "751 произведение", "and so on")
local person = { __typename = "Person", uuid = "p1", name = "Автор", worksCount = 22, roles = { "TRANSLATOR", "AUTHOR" },
    avatar = { url = "https://h/a-large.jpeg" } }
eq(Catalogue.item(person).kind, "author", "an author")
eq(Catalogue.item(person).kind_text, "Автор · 22 произведения", "what an author has")
eq(Catalogue.item(person).card.book.cover.small, "https://h/a-thumb.jpeg", "a small portrait")
person.avatar.url = "https://h/default/a.jpeg"
eq(Catalogue.item(person).card.book.cover, nil, "the drawing for no portrait is no portrait")
person.worksCount = 0
eq(Catalogue.item(person), nil, "an author with nothing")
person.worksCount, person.roles = 1, { "TRANSLATOR" }
eq(Catalogue.item(person), nil, "not an author")
local found_series = Catalogue.item({ __typename = "Series", uuid = "s1", name = "Серия", authors = { { name = "А" } },
    items = { total = 8 }, cover = { url = "https://h/s-large.jpeg" } })
eq(found_series.kind, "series", "a series")
eq(found_series.kind_text, "Серия · 8 книг", "how long it is")
eq(found_series.authors, "А", "its authors")
local found_shelf = Catalogue.item({ __typename = "Bookshelf", uuid = "b1", name = "Полка", posts = { total = 28 },
    user = { name = "Читатель" }, cover = { url = "https://h/b-large.jpeg" } })
eq(found_shelf.kind, "bookshelf", "a shelf")
eq(found_shelf.kind_text, "Полка · 28 книг", "how long the shelf is")
eq(found_shelf.authors, "Читатель", "whose the shelf is")
do
    local function shelf(n) return { __typename = "Bookshelf", uuid = "b" .. n, name = "П" .. n, cover = { url = "https://h/b.jpeg" } } end
    local function titles(items)
        local out = {}
        for _, item in ipairs(items) do out[#out + 1] = item.title end
        return table.concat(out, "|")
    end
    local function books(n)
        local out = {}
        for i = 1, n do out[i] = { title = "К" .. i } end
        return out
    end
    eq(titles(Catalogue.with_shelves(books(5), { shelf(1), shelf(2), shelf(3), shelf(4) }, "q")),
        "К1|К2|К3|П1|П2|П3|Все полки|К4|К5", "shelves go after the first books, then the way to the rest")
    eq(titles(Catalogue.with_shelves(books(5), { shelf(1), shelf(2) }, "q")), "К1|К2|К3|П1|П2|К4|К5", "no way to no more shelves")
    eq(titles(Catalogue.with_shelves(books(1), {}, "q")), "К1", "no shelves")
    eq(titles(Catalogue.with_shelves({}, { shelf(1) }, "q")), "П1", "nothing but a shelf")
end
local found_serial = Catalogue.item({ __typename = "TextSerial", episodes = { total = 9 },
    book = { uuid = "x1", name = "Сериал", authors = { { name = "Б", uuid = "b" } } } })
eq(found_serial.kind, "serial", "a serial")
eq(found_serial.kind_text, "Сериал · 9 эпизодов", "how many episodes")
eq(found_serial.uuid, "x1", "a serial's id")
local rest = Catalogue.rest_book({ uuid = "b1", title = "Книга", authors = "А, Б", in_library = true,
    cover = { small = "s", large = "l" } })
eq(rest.authors, "А, Б", "authors as text")
eq(rest.mandatory, "в библиотеке", "in the library")
eq(rest.card.book.cover.large, "l", "the cover")
eq(Catalogue.rest_book({ uuid = "b2", source_type = "serial", title = "С", episodes_count = 2 }).kind, "serial", "a serial in a list")
eq(Catalogue.part({ resource_type = "audiobook", position = 1, resource = { uuid = "a" } }, { [1] = true }), nil, "the audio of a book in a series")
eq(Catalogue.part({ resource_type = "audiobook", position = 2, resource = { uuid = "a" } }, { [1] = true }).mandatory, "только аудио", "a part with only audio")
eq(Catalogue.rest_book({ uuid = "b3", can_be_read = false }).unavailable ~= nil, true, "a book that cannot be read")
local closed = Catalogue.from_page("series", { parts = {
    { resource_type = "book", position = 1, resource = { uuid = "b4", title = "Т", can_be_read = false } },
    { resource_type = "audiobook", position = 1, resource = { uuid = "a4", title = "А" } },
    { resource_type = "audiobook", position = 2, resource = { uuid = "a5", title = "Б" } },
} })
eq(#closed, 2, "the audio of a closed book is still its audio")
eq(closed[1].mandatory, "недоступна", "a book that cannot be read says so")
eq(closed[2].unavailable ~= nil, true, "and audio alone is not opened")
local shelves = Catalogue.from_page("bookshelves", { bookshelves = {
    { uuid = "s1", title = "Полка", books_count = 21, creator = { name = "Кто" }, cover = { small = "c" } },
    { title = "без uuid" },
} })
eq(#shelves, 1, "a shelf without an id is left out")
eq(shelves[1].kind, "bookshelf", "a shelf leads to a list")
eq(shelves[1].kind_text, "Подписка · 21 книга", "whose it is and how long")
eq(shelves[1].authors, "Кто", "whose it is")
eq(Catalogue.part({ resource_type = "book", position_label = "2", resource = { uuid = "b" } }).kind_text, "Книга 2", "a part")
local of_author = Catalogue.from_page("author", {
    series = { { uuid = "s1", title = "Книги", kinds = { "books" }, parts_count = 2 }, { uuid = "s2", title = "Аудио", kinds = { "audio" } } },
    books = { { uuid = "b1", title = "Книга" } },
})
eq(#of_author, 2, "audio-only series stay out")
eq(of_author[1].kind, "series", "series before the books")
eq(of_author[2].title, "Книга", "then the books")
local links = Catalogue.links({ series_list = { { uuid = "s", title = "Серия" } }, authors_objects = { { uuid = "a", name = "А" } } })
eq(links[1].kind, "series", "a book leads to its series")
eq(links[2].title, "А", "and to its author")
eq(#Catalogue.links({ authors = "текстом" }), 0, "nowhere, if nothing is known")
local list_state = Catalogue.collection("author", "a1", "А")
eq(list_state.kind, "author", "a list knows what it is")
eq(list_state.finished, false, "and is to be asked for")

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

-- A serial as one book.
local Serial = require("yaknigi/serial")
local CONTAINER_X = '<container><rootfiles><rootfile full-path="OEBPS/c.opf"/></rootfiles></container>'
local function episode_opf(first)
    return '<package><metadata><meta name="cover" content="pic"/></metadata><manifest>'
        .. '<item id="pic" href="i/cover.png" media-type="image/png"/>'
        .. '<item id="st" href="s.css" media-type="text/css"/>'
        .. '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
        .. '<item id="a" href="a.html"/><item id="b" href="b &amp; c.xhtml" media-type="application/xhtml+xml"/>'
        .. '</manifest><spine toc="ncx"><itemref idref="pic"/><itemref idref="a"/><itemref idref="b"/></spine></package>'
end
local NCX_X = '<ncx><navMap><navPoint id="n1" playOrder="1"><navLabel><text>Раз</text></navLabel><content src="a.html"/></navPoint>'
    .. '<navPoint id="n2" playOrder="2"><navLabel><text>Два</text></navLabel><content src="b.xhtml#x"/></navPoint></navMap></ncx>'
local merged = Serial.merge("ser", "Сериал & Ко", {
    { uuid = "e1", title = "Первый", document = "d1", container = CONTAINER_X, opf = episode_opf(), ncx = NCX_X, card = "c1" },
    { uuid = "e2", title = "", position = 2, locked = true },
    { uuid = "e3", document = "d3", position = 3, container = CONTAINER_X, opf = episode_opf() },
})
local long = Opf.parse(merged.opf)
eq(merged.total, 3, "three episodes")
eq(merged.document_uuid, "d1", "a document for the whole")
eq(long.title, "Сериал & Ко", "the title is escaped")
eq(#long.fragments, 7, "every itemref stays, as positions count them")
eq(long.fragments[1], false, "a picture in the spine is no chapter")
eq(long.spine[1], "e1/a.html", "a chapter under its episode")
eq(long.spine[2], "e1/b & c.xhtml", "a name with an ampersand")
eq(long.spine[3], "e2/locked.xhtml", "a closed episode has its page")
eq(long.fragments[4], 3, "and it counts")
eq(long.spine[4], "e3/a.html", "the next episode goes on")
eq(long.cover, "e1/i/cover.png", "the first cover is the cover")
eq(long.ncx, "toc.ncx", "contents of its own")
eq(merged.episodes[2].first, 3, "where the second begins")
eq(merged.episodes[3].first, 4, "where the third begins")
eq(merged.ncx:find('<content src="e1/a.html"/></navPoint>', 1, true) ~= nil, true, "an inner entry goes under the episode")
eq(merged.ncx:find('id="e1_n2"', 1, true) ~= nil, true, "inner entries have ids of their own")
eq(merged.ncx:find("playOrder", 1, true), nil, "no order left to contradict")
eq(merged.ncx:find(">Эпизод 2<", 1, true) ~= nil, true, "an episode without a title")
eq(merged.ncx:find(">Эпизод 3<", 1, true) ~= nil, true, "and by its position")
local part, inner = Serial.file_of(merged, "OEBPS/e3/s.css")
eq(part.uuid, "e3", "whose file")
eq(inner, "OEBPS/s.css", "and its path in the episode")
eq(Serial.file_of(merged, "OEBPS/content.opf"), nil, "not of an episode")
eq(Serial.part_of("OEBPS/e3/i/x.png"), "e3", "the directory of an episode")
eq(Serial.to_merged(merged, "e3", "/6/4!/4/2:0"), "/6/12!/4/2:0", "from an episode into the book")
eq(Serial.to_merged(merged, "e1", "/6/2!,/2/4,/2/6"), "/6/2!,/2/4,/2/6", "the first episode stays as it is")
eq(Serial.to_merged(merged, "e3", "/6/40!/4"), "/6/10!/4", "a place beyond the episode goes to its start")
eq(Serial.to_merged(merged, "nobody", "/6/4!/4"), nil, "not an episode of this")
eq(Serial.to_merged(merged, "e3", nil), nil, "no place")
local there, here_at = Serial.to_episode(merged, "/6/12!/4/2:0")
eq(there.uuid, "e3", "from the book into an episode")
eq(here_at, "/6/4!/4/2:0", "with the place in it")
eq(Serial.to_episode(merged, "/6/100!/4"), nil, "beyond the book")
local wire = Serial.position(merged, "/6/2!/4/2:0", "/6/4!/4/2:0")
eq(wire.book, "e1", "the episode to tell of")
eq(wire.document, "d1", "its document")
eq(wire.card, "c1", "its card")
eq(wire.finish, "/6/4!/4/2:0", "the page's end in the same episode")
eq(Serial.position(merged, "/6/6!/4/2:0", "/6/8!/4/2:0").book, "e1", "the last chapter of the episode")
eq(Serial.position(merged, "/6/6!/4/2:0", "/6/8!/4/2:0").finish, "/6/6!/4/2:0", "a page ending in the next one ends where it starts")
eq(Serial.position(merged, "/6/8!/4/2:0", "/6/10!/4/2:0"), nil, "a closed episode is no place to send")
eq(Serial.is_serial({ book = { source_type = "serial" } }), true, "a serial's card")
eq(Serial.is_serial({ book = {} }), false, "a book's")
eq(Serial.is_serial(nil), false, "nothing")
local serial_card = { uuid = "c", cfi = "/6/4!/4", current_episode_uuid = "e3", book = { source_type = "serial" } }
eq(Serial.view_with(merged, serial_card).cfi, "/6/12!/4", "a card seen in the long book")
eq(serial_card.cfi, "/6/4!/4", "the card stays as Yandex has it")
eq(Serial.view_with(nil, serial_card).cfi, nil, "nowhere until the episodes are known")
eq(Serial.stale(nil, serial_card), true, "nothing known")
eq(Serial.stale(merged, { book = { episodes_count = 3 } }), true, "something is closed: it may have opened")
local open_only = Serial.merge("s", "t", { { uuid = "e1", document = "d", container = CONTAINER_X, opf = episode_opf() } })
eq(Serial.stale(open_only, { book = { episodes_count = 1 } }), false, "all is known")
eq(Serial.stale(open_only, { book = { episodes_count = 2 } }), true, "a new episode")
eq(Serial.shifted(open_only, merged), false, "new episodes after the old move nothing")
eq(Serial.shifted(merged, open_only), true, "episodes gone do")
eq(Serial.shifted(nil, merged), false, "nothing to move")
-- Notes: Yandex by episode, the comparison in the long book.
local calls = {}
local notes_api = Serial.notes_api({
    notes = function() return {
        { uuid = "q1", state = "exists", book = { uuid = "e3" }, cfi = "/6/4!/4,/2,/4" },
        { uuid = "q2", state = "exists", book_uuid = "other", cfi = "/6/4!/4" },
        { uuid = "q3", state = "removed" },
    } end,
    create_note = function(_, kind, book, note) calls[#calls + 1] = book .. " " .. note.cfi; return { uuid = "new" } end,
    update_quote = function(_, uuid, quote) calls[#calls + 1] = uuid .. " " .. quote.cfi; return true end,
    delete_note = function(_, kind, uuid) calls[#calls + 1] = kind .. " " .. uuid; return true end,
}, merged, "ser")
local entries = notes_api:notes("quotes")
eq(#entries, 2, "another book's note is not this one's, and what was removed is said")
eq(entries[1].book_uuid, "ser", "an episode's note is the serial's")
eq(entries[1].cfi, "/6/12!/4,/2,/4", "in the long book")
eq(entries[2].uuid, "q3", "what was removed")
eq(notes_api:create_note("quote", "ser", { cfi = "/6/12!/4" }).uuid, "new", "a note goes")
eq(calls[1], "e3 /6/4!/4", "to its episode")
eq(notes_api:create_note("quote", "ser", { cfi = "/6/8!/4" }), nil, "not in what is closed")
eq(notes_api:update_quote("q1", { cfi = "/6/12!/4" }), true, "an edit goes")
eq(calls[2], "q1 /6/4!/4", "with the place in the episode")

-- The icons: one set, by one rule, and nothing of KOReader's.
do
    local root = "koreader/yaknigi.koplugin/"
    local function lines_of(command)
        local out, pipe = {}, io.popen(command)
        for line in pipe:lines() do out[#out + 1] = line end
        pipe:close()
        return out
    end
    local function read(path)
        local f = assert(io.open(path, "rb"))
        local text = f:read("*a")
        f:close()
        return text
    end
    local ink = require("yaknigi/iconink")
    local have = {}
    for _, path in ipairs(lines_of("ls " .. root .. "yaknigi/icons/*.svg")) do
        local name = path:match("([^/]+)%.svg$")
        have[name] = true
        local svg = read(path)
        eq(svg:find('viewBox="0 0 24 24"', 1, true) ~= nil, true, name .. " is on the 24 grid")
        for width in svg:gmatch('stroke%-width="([^"]+)"') do
            eq(width, "2.2", name .. " has the set's stroke")
        end
        for _, word in ipairs{ "clip-path", "mask", "filter", "<style", "transform" } do
            eq(svg:find(word, 1, true), nil, name .. " has nothing nanosvg cannot draw: " .. word)
        end
        if not name:find("%.idle$") then
            eq(ink[name] ~= nil, true, name .. " is measured")
        end
    end
    for name in pairs(ink) do eq(have[name], true, name .. " measured and there") end
    local sources = lines_of("ls " .. root .. "main.lua " .. root .. "yaknigi/*.lua")
    local used = 0
    for _, path in ipairs(sources) do
        local source = read(path)
        for _, pattern in ipairs{ 'Kit%.icon%("([^"]+)"', 'Kit%.icon_button%("([^"]+)"',
                'Kit%.icon_right_room%("([^"]+)"', 'Kit%.icon_ink_width%("([^"]+)"', '[{,] *icon = "([^"]+)"' } do
            for name in source:gmatch(pattern) do
                used = used + 1
                eq(have[name], true, path .. " uses the icon " .. name)
            end
        end
        eq(source:find("IconWidget:new", 1, true) ~= nil and not path:find("kit%.lua$"), false,
            path .. " makes icons through the kit")
    end
    eq(used > 20, true, "the icons in use were found")
end

-- updates
eq(Updater.newer("1.0.1", "1.0.0"), true, "a later patch")
eq(Updater.newer("1.10.0", "1.9.9"), true, "numbers, not letters")
eq(Updater.newer("1.0.0", "1.0.0"), false, "the same is not later")
eq(Updater.newer("1.0.0", "2.0.0"), false, "an earlier one")
local good_manifest = { version = "1.2.3", base = "b", sha256 = ("a"):rep(64) }
eq(Updater.valid_manifest(good_manifest), true, "a manifest")
eq(Updater.valid_manifest({ version = "1.2", base = "b", sha256 = ("a"):rep(64) }), false, "a bad version")
eq(Updater.valid_manifest({ version = "1.2.3", base = "b", sha256 = "abc" }), false, "a short digest")
eq(Updater.valid_manifest({ version = "1.2.3", sha256 = ("a"):rep(64) }), false, "no base")
eq(Updater.valid_manifest("1.2.3"), false, "not a table")
eq(Updater.decide(good_manifest, "1.2.3", "b"), "none", "nothing newer")
eq(Updater.decide(good_manifest, "1.2.2", "b"), "download", "newer")
eq(Updater.decide(good_manifest, "1.2.2", "other"), "manual", "another launcher")
eq(Updater.decide(good_manifest, "1.2.2", "b", "1.2.3"), "none", "this one did not start here")
eq(Updater.decide(good_manifest, "1.2.2", "b", "1.2.1"), "download", "another one did not start")
local from = "https://github.com/o/r/releases/latest/download/x"
eq(Updater.redirect_allowed(from, "https://github.com/o/r/releases/download/v1/x"), true, "github")
eq(Updater.redirect_allowed(from, "https://release-assets.githubusercontent.com/x"), true, "the assets")
eq(Updater.redirect_allowed(from, "http://github.com/x"), false, "never down to plain HTTP")
eq(Updater.redirect_allowed(from, "https://example.com/x"), false, "another host")
eq(Updater.redirect_allowed(from, "https://evilgithub.com/x"), false, "a name that only ends the same")
eq(Updater.redirect_allowed(from, "https://github.com.evil.org/x"), false, "a name that only starts the same")
eq(Updater.redirect_allowed(from, "/relative"), false, "not a whole address")
eq(Updater.redirect_allowed("http://127.0.0.1:1/a", "http://127.0.0.1:1/b"), true, "the same host")
eq(Updater.redirect_allowed("http://127.0.0.1:1/a", "http://127.0.0.1:2/b"), false, "another port")
eq(Updater.due(nil, 100), true, "never asked")
eq(Updater.due(100, 100 + Updater.DAY - 1), false, "asked today")
eq(Updater.due(100, 100 + Updater.DAY), true, "asked yesterday")
eq(Updater.due(1000, 100), true, "the clock went back")
do
    local replies = {
        ["https://github.com/a"] = { 302, "", { location = "https://github.com/b" } },
        ["https://github.com/b"] = { 200, "body", {} },
        ["https://github.com/gone"] = { 404, "", {} },
        ["https://github.com/loop"] = { 302, "", { location = "https://github.com/loop" } },
        ["https://github.com/out"] = { 302, "", { location = "https://example.com/" } },
        ["https://github.com/bad"] = { 500, "", {} },
    }
    local fake = {
        request = function(_, _, url)
            local r = replies[url]
            return r[1], r[2], r[3]
        end,
    }
    eq(Updater.get(fake, "https://github.com/a"), "body", "a redirect is followed")
    eq(select(2, Updater.get(fake, "https://github.com/gone")), "not_found", "nothing there")
    eq(select(2, Updater.get(fake, "https://github.com/loop")), "network", "a loop ends")
    eq(select(2, Updater.get(fake, "https://github.com/out")), "network", "no way out of GitHub")
    eq(select(2, Updater.get(fake, "https://github.com/bad")), "network", "a server error")
    local down = { request = function() return nil, "timeout" end }
    eq(select(2, Updater.get(down, "https://github.com/a")), "network", "no network")
end

-- what the subscriptions say
do
    local now = 1800000000
    local function levels(...)
        local dates = {}
        for i, pair in ipairs { ... } do dates[i] = { level = pair[1], expires_at = pair[2] } end
        return { expiration_dates = dates }
    end
    eq(Access.verdict(nil, now), "unknown", "no answer")
    eq(Access.verdict({}, now), "unknown", "an answer of another shape")
    eq(Access.verdict(levels(), now), "none", "no subscriptions")
    eq(Access.verdict(levels({ "bookmate", now + 60 }), now), "active", "running")
    eq(Access.verdict(levels({ "plus", now - 60 }), now), "none", "ended")
    eq(Access.verdict(levels({ "plus", (now + 60) * 1000 }), now), "active", "running, in milliseconds")
    eq(Access.verdict(levels({ "plus", (now - 60) * 1000 }), now), "none", "ended, in milliseconds")
    eq(Access.verdict(levels({ "basic_music", now + 60 }), now), "none", "music gives no books")
    eq(Access.verdict(levels({ "something_new", now + 60 }), now), "unknown", "a level not known")
    eq(Access.verdict(levels({ "something_new", now - 60 }), now), "none", "a level not known has ended")
    eq(Access.verdict(levels({ "something_new", now + 60 }, { "simple_bookmate", now + 60 }), now), "active",
        "a level for books settles it")
    eq(Access.verdict(levels({ "plus" }), now), "unknown", "no date")
    eq(Access.verdict({ expiration_dates = {}, active_recurrents = { {} } }, now), "unknown", "something recurs")
end

-- alignment
do
    local base = { footnote = true, text_align_all_left = true, text_align_most_left = true }
    local left = TextStyle.with_align(base, "left")
    eq(left.text_align_most_left, true, "left is set")
    eq(left.text_align_all_left, nil, "another left goes")
    eq(left.footnote, true, "other tweaks stay")
    eq(base.text_align_all_left, true, "what was given is not changed")
    local justify = TextStyle.with_align(left, "justify")
    eq(justify.text_align_most_justify, true, "justify is set")
    eq(justify.text_align_most_left, nil, "left goes")
    eq(next(TextStyle.with_align({ text_align_all_justify = true }, "book")), nil, "as in the book sets nothing")
    eq(next(TextStyle.with_align(nil, "book")), nil, "no tweaks yet")
    local clean, changed = TextStyle.without_align({ text_align_all_left = false, footnote = true })
    eq(changed, true, "a book's own alignment is noticed")
    eq(clean.text_align_all_left, nil, "and taken out, even when switched off")
    eq(clean.footnote, true, "the rest stays")
    eq(select(2, TextStyle.without_align({ footnote = true })), false, "nothing to take out")
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
