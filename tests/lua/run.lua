-- Tests for the plugin's pure Lua modules. Run with: luajit tests/lua/run.lua
package.path = "koreader/yaknigi.koplugin/?.lua;" .. package.path
local Zip = require("yaknigi/zip")
local Opf = require("yaknigi/opf")
local Cfi = require("yaknigi/cfi")
local Http = require("yaknigi/http")

local failed, passed = 0, 0
local function eq(got, want, name)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(("FAIL %s: got %s, want %s"):format(name, tostring(got), tostring(want)))
    end
end

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

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
