#!/usr/bin/env python3
"""A stand-in for the Yandex Books and OAuth servers, for running yb-sim offline.

Accepts only the code "abc123" and only with the correct PKCE verifier for the
challenge the client sent, so that it fails if the client's PKCE is wrong.
Usage: server.py PORT [koreader]

With "koreader", books have many chapters, a stylesheet, a table of contents and a
reading position, and chapters take a moment to arrive, as for the KOReader plugin.
"""
import base64
from html.parser import HTMLParser
import hashlib
import json
import re
import struct
import subprocess
import sys
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

KEY = bytes(range(32))
IV = bytes(range(16))
CONTAINER = b'<container><rootfiles><rootfile full-path="OEBPS/c.opf"/></rootfiles></container>'
OPF = (
    b'<package><metadata><dc:title>Mock</dc:title></metadata><manifest>'
    b'<item id="a" href="a.html"/><item id="b" href="b.html"/><item id="c" href="c.html"/>'
    b'</manifest><spine><itemref idref="a"/><itemref idref="b"/><itemref idref="c"/></spine></package>'
)
PARAGRAPH = (
    "Он шёл по длинной улице и думал о том, что прочитал накануне, а редкие "
    "прохожие оглядывались на него, не понимая, отчего он улыбается. "
)
BOOKS = 21


BIG_CHAPTERS = 40
BIG_OPF = (
    '<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<metadata><dc:title>Большая книга</dc:title></metadata><manifest>'
    '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
    '<item id="css" href="s.css" media-type="text/css"/>'
    + "".join(f'<item id="c{i}" href="c{i}.html" media-type="application/xhtml+xml"/>'
              for i in range(BIG_CHAPTERS))
    + '</manifest><spine toc="ncx">'
    + "".join(f'<itemref idref="c{i}"/>' for i in range(BIG_CHAPTERS))
    + "</spine></package>"
).encode()
BIG_NCX = (
    '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>'
    + "".join(f'<navPoint id="n{i}" playOrder="{i + 1}"><navLabel><text>Глава {i + 1}</text></navLabel>'
              f'<content src="c{i}.html"/></navPoint>' for i in range(BIG_CHAPTERS))
    + "</navMap></ncx>"
).encode()
BIG_CONTAINER = (
    b'<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    b'<rootfiles><rootfile full-path="OEBPS/c.opf" media-type="application/oebps-package+xml"/>'
    b"</rootfiles></container>"
)
# Chapter 31 (zero-based 30), second-level: div > p number 3, as the app's CFI points.
BIG_CFI = "/6/62!,/2/4/2/6/1:7,/2/4/2/6/1:9"
CHAPTER_DELAY = 0.1


def cover_png(n):
    """A small greyscale image, a different shade per book."""
    w, h = 90, 135
    shade = 60 + (n * 37) % 160
    rows = b"".join(b"\0" + bytes([shade if 8 < y < h - 8 else 0] * w) for y in range(h))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def big_chapter(path):
    number = int(path.split("/c")[-1].split(".")[0]) + 1
    # Every third paragraph has elements inside, as real books do, so that pages start in
    # all kinds of text node. The picture and the comment are steps a position must count.
    def paragraph(i):
        start = f"Глава {number}, абзац {i + 1}."
        if i % 3 == 2:
            return (f"<p>{start} {PARAGRAPH} <em>курсив {i} {PARAGRAPH}</em> <b>жирный {i} {PARAGRAPH}</b>"
                    f" хвост {i} {PARAGRAPH} &amp; {PARAGRAPH}</p>\n<!-- a > b --><br/>")
        return f"<p>{start} {PARAGRAPH * 4}</p>\n"
    paragraphs = "".join(paragraph(i) for i in range(30))
    return (
        '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml">'
        f'<head><title>Глава {number}</title><link rel="stylesheet" href="s.css"/></head>'
        f"<body><div>{paragraphs}</div></body></html>"
    )


class Chapter(HTMLParser):
    """The tree of a chapter, written apart from the plugin's walker to check its answers."""
    VOID = {"br", "img", "hr", "meta", "link"}

    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.root = {"children": []}
        self.stack = [self.root]
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        node = {"tag": tag, "children": []}
        self.stack[-1]["children"].append(node)
        if tag not in self.VOID:
            self.stack.append(node)

    def handle_endtag(self, tag):
        if tag not in self.VOID and len(self.stack) > 1:
            self.stack.pop()

    def handle_data(self, data):
        children = self.stack[-1]["children"]
        if children and isinstance(children[-1], str):
            children[-1] += data
        else:
            children.append(data)


def child_at(node, step):
    """A CFI step: elements are 2, 4..., with odd steps for the text around them."""
    elements = 0
    for child in node["children"]:
        if isinstance(child, str):
            if step == elements * 2 + 1:
                return child
        else:
            elements += 1
            if step == elements * 2:
                return child
    return None


def text_after(node, skip):
    """All text after a child of node."""
    found = []
    children = node["children"]
    for child in children[skip:]:
        if isinstance(child, str):
            found.append(child)
        else:
            found.extend(text_after(child, 0))
    return found


def text_at(html, inner):
    """The text from a position on, to the end of the chapter."""
    steps = inner.split(":")[0].strip("/").split("/")
    offset = int(inner.split(":")[1])
    path = []
    node = Chapter(html).root
    for step in steps:
        path.append(node)
        node = child_at(node, int(step))
        if node is None:
            return None
    if not isinstance(node, str) or offset > len(node):
        return None
    found = [node[offset:]]
    current = node
    for parent in reversed(path):
        index = next(i for i, c in enumerate(parent["children"]) if c is current)
        found.extend(text_after(parent, index + 1))
        current = parent
    return " ".join("".join(found).split())


def encrypted(data):
    out = subprocess.run(
        ["openssl", "enc", "-aes-256-cbc", "-K", KEY.hex(), "-iv", IV.hex()],
        input=data, capture_output=True, check=True,
    ).stdout
    return list(IV + out)


def chapter(path):
    paragraphs = "".join(f"<p>{PARAGRAPH * 4}</p>" for _ in range(30))
    return f"<h1>Глава {path}</h1>{paragraphs}"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, code, body):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def reply_json(self, code, value):
        self.reply(code, json.dumps(value).encode())

    def card(self, i):
        card = {
            "uuid": f"card{i}",
            "progress": 1,
            "book": {
                "uuid": f"book{i}",
                "title": "Очень длинное название книги, которое не помещается в одну строку экрана"
                         if i == 1 else f"Книга номер {i}",
                "authors": [{"name": f"Автор {i}"}],
                "cover": {"small": f"http://127.0.0.1:{self.server.server_address[1]}/cover/{i}.png"},
            },
        }
        if self.server.big:
            card["accessed_at"] = 1793000000 - i * 86400 if i < 20 else None
            card["cfi"] = BIG_CFI if i == 0 else None
            card["progress"] = 77 if i == 0 else 0
        position = self.server.positions.get(card["book"]["uuid"])
        if position:
            spine, start = position["start"].split("!")
            card["cfi"] = f'{spine}!,{start},{position["end"].split("!")[1]}'
        update = self.server.card_updates.get(card["uuid"])
        if update:
            card["progress"] = update["progress"]
            card["state"] = update["state"]
        if i == 3:
            card["book"]["uuid"] = "serial-1"
            card["book"]["title"] = "Сериал"
        return card

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", 0))
        form = parse_qs(self.rfile.read(length).decode(), keep_blank_values=True)
        match = re.search(r"/profile/library_cards/([^/]+)$", self.path)
        if self.headers.get("Auth-Token") != "mock-token" or not match:
            self.reply(401, b"")
            return
        card = match.group(1)
        # As on the real server, the position in this request changes nothing.
        self.server.card_updates[card] = {
            "progress": int(form["lc[progress]"][0]),
            "state": form.get("lc[state]", [None])[0],
            "sent_cfi": form["lc[cfi]"][0],
        }
        self.reply_json(200, {"library_card": {"uuid": card, "cfi": form["lc[cfi]"][0]}})

    def graphql(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if self.headers.get("Auth-Token") != "mock-token":
            self.reply(401, b"")
            return
        if self.server.fail_writes > 0:
            self.server.fail_writes -= 1
            self.reply(500, b"")
            return
        for p in body["variables"]["textbookProgresses"]:
            good = (isinstance(p["timespent"], int) and p["timespent"] > 0
                    and p["consumptionType"] == "CONSUMPTION"
                    and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}\+00:00", p["readAt"])
                    and re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}", p["sessionId"])
                    and p["documentUuid"] == "d1" and "!/" in p["cfi"]["start"] and "!/" in p["cfi"]["end"]
                    and "ProgressUpdated" in body["query"])
            if not good:
                print("bad ProgressUpdated:", p, flush=True)
                self.reply_json(200, {"errors": [{"message": "bad input"}], "data": None})
                return
            self.server.positions[p["uuid"]] = {"start": p["cfi"]["start"], "end": p["cfi"]["end"],
                                                  "writes": self.server.positions.get(p["uuid"], {}).get("writes", 0) + 1}
        self.reply_json(200, {"data": {"progressUpdated": None}})

    def do_POST(self):
        if self.path == "/graphql":
            self.graphql()
            return
        form = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        verifier = form.get("code_verifier", [""])[0]
        digest = hashlib.sha256(verifier.encode()).digest()
        challenge = base64.urlsafe_b64encode(digest).decode().rstrip("=")
        print(f"token request: code={form.get('code')} challenge_ok={challenge == self.server.challenge}",
              flush=True)
        if form.get("code") == ["abc123"] and challenge == self.server.challenge:
            self.reply_json(200, {"access_token": "mock-token", "refresh_token": "mock-refresh"})
        else:
            self.reply_json(400, {"error": "invalid_grant"})

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if url.path == "/test/fail_writes":
            self.server.fail_writes = int(query["n"][0])
            self.reply(200, b"")
        elif url.path == "/test/phone_read":
            # Someone reads on the phone: a position this device did not send.
            self.server.positions[query["book"][0]] = {"start": query["start"][0], "end": query["start"][0], "writes": 0}
            self.reply(200, b"")
        elif url.path == "/test/position":
            book = query["book"][0]
            self.reply_json(200, {**self.server.positions.get(book, {}),
                                  **self.server.card_updates.get(book.replace("book", "card"), {})})
        elif url.path == "/test/text_at":
            # What a phone would show first at this position.
            spine, inner = query["cfi"][0].split("!")
            chapter_number = int(spine.split("/")[-1]) // 2 - 1
            self.reply_json(200, {"text": text_at(big_chapter(f"OEBPS/c{chapter_number}.html"), inner)})
        elif url.path == "/challenge":
            # The simulator cannot scan a QR code, so the test script passes it here.
            self.server.challenge = query["c"][0]
            self.reply(200, b"")
        elif url.path == "/test/chapter_delay":
            self.server.chapter_delay = float(query["s"][0])
            self.reply(200, b"")
        elif url.path == "/test/fail_card":
            self.server.fail_card = int(query["n"][0])
            self.reply(200, b"")
        elif re.search(r"/profile/library_cards/card\d+$", url.path):
            if self.headers.get("Auth-Token") != "mock-token":
                self.reply(401, b"")
                return
            if self.server.fail_card > 0:
                self.server.fail_card -= 1
                self.reply(500, b"")
                return
            self.reply_json(200, {"library_card": self.card(int(url.path.split("card")[-1]))})
        elif url.path.endswith("/profile/library_cards"):
            if self.headers.get("Auth-Token") != "mock-token":
                self.reply(401, b"")
                return
            page = int(query.get("page", ["1"])[0])
            start = (page - 1) * 10
            cards = [self.card(i) for i in range(start, min(start + 10, BOOKS))]
            self.reply_json(200, {"library_cards": cards})
        elif url.path.startswith("/cover/"):
            if self.headers.get("Auth-Token"):
                self.reply(400, b"the covers' host must not get the token")
                return
            self.reply(200, cover_png(int(url.path.split("/")[-1].split(".")[0])))
        elif "serial" in url.path:
            self.reply(404, b"")
        elif url.path.endswith("/metadata/v4"):
            if self.server.big:
                self.reply_json(200, {"document_uuid": "d1", "opf": encrypted(BIG_OPF),
                                      "container": encrypted(BIG_CONTAINER), "ncx": encrypted(BIG_NCX)})
            else:
                self.reply_json(200, {"document_uuid": "d1", "opf": encrypted(OPF), "container": encrypted(CONTAINER)})
        elif url.path.endswith("/metadata_secret"):
            self.reply_json(200, {"secret": base64.b64encode(KEY).decode()})
        elif url.path.endswith("/content"):
            path = query["path"][0]
            if not self.server.big:
                self.reply(200, chapter(path).encode())
            elif path.endswith(".css"):
                self.reply(200, b"p { margin: 0; }")
            else:
                time.sleep(self.server.chapter_delay)
                self.reply(200, big_chapter(path).encode())
        else:
            self.reply(404, b"")


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
    server.challenge = None
    server.positions = {}
    server.card_updates = {}
    server.fail_writes = 0
    server.fail_card = 0
    server.chapter_delay = CHAPTER_DELAY
    server.big = len(sys.argv) > 2 and sys.argv[2] == "koreader"
    server.serve_forever()
