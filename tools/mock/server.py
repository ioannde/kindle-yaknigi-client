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
    '<metadata><dc:title>Большая книга</dc:title><meta name="cover" content="cov"/></metadata><manifest>'
    '<item id="cov" href="cover.png" media-type="image/png"/>'
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
# Its spine starts with a page that is only a picture, as real books' do.
COVER_PAGE_BOOK = "found7"
COVER_PAGE_OPF = (
    '<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<metadata><dc:title>Книга с обложкой</dc:title><meta name="cover" content="p"/></metadata><manifest>'
    '<item id="p" href="cover.png" media-type="image/png"/>'
    '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
    '<item id="t" href="title.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="a" href="first.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="b" href="second.xhtml" media-type="application/xhtml+xml"/>'
    '</manifest><spine toc="ncx"><itemref idref="t"/><itemref idref="a"/><itemref idref="b"/></spine></package>'
).encode()
COVER_PAGE_NCX = (
    '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>'
    '<navPoint id="n1" playOrder="1"><navLabel><text>Первая глава</text></navLabel><content src="first.xhtml"/></navPoint>'
    '<navPoint id="n2" playOrder="2"><navLabel><text>Вторая глава</text></navLabel><content src="second.xhtml"/></navPoint>'
    '</navMap></ncx>'
).encode()
COVER_PAGE = ('<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head>'
              '<body><img src="cover.png" alt="cover"/></body></html>')
SHOWCASE = 'query Showcase($showcaseParamsInput: ShowcaseParamsInput!, $showcaseItemsCursor: String!, $sectionItemsCursor: String = "" ) { showcase(params: $showcaseParamsInput) { __typename ...fragmentShowcase ...childrenFragmentShowcase ...parentsFragmentShowcase items(cursor: $showcaseItemsCursor) { page { __typename ...featuredSectionFragment ...notificationFragment ...shelvesSectionFragment ...simpleSectionFragment ...statisticsSectionFragment ...topSectionFragment ...seriesSectionFragment ...ratingSectionFragment } cursor } } }  fragment fragmentShowcase on Showcase { name uuid availableFilters }  fragment childrenFragmentShowcase on Showcase { children { __typename ...fragmentShowcase } }  fragment parentsFragmentShowcase on Showcase { parents { __typename ...fragmentShowcase } }  fragment ageRestrictionFragment on Availability { ageRestriction { name value } }  fragment coverFragment on Cover { url ratio backgroundColorHex }  fragment personFragment on Person { avatar { __typename ...coverFragment } name uuid worksCount roles }  fragment bookFragment on Book { annotation name cover { __typename ...coverFragment } uuid initUuid authors { __typename ...personFragment } editorAnnotation }  fragment audioBookFragment on AudioBook { availability { __typename ...ageRestrictionFragment } book { __typename ...bookFragment } }  fragment comicBookFragment on ComicBook { availability { __typename ...ageRestrictionFragment } book { __typename ...bookFragment } }  fragment textBookFragment on TextBook { availability { __typename ...ageRestrictionFragment } book { __typename ...bookFragment } }  fragment textSerialFragment on TextSerial { availability { __typename ...ageRestrictionFragment } book { __typename ...bookFragment } }  fragment notificationFragment on Notification { consumer notificationPayloadId payload templateId feedbackToken }  fragment featuredSectionFragment on FeaturedSection { items(cursor: $sectionItemsCursor) { cursor page { __typename ...audioBookFragment ...comicBookFragment ...textBookFragment ...textSerialFragment ...notificationFragment } } name uuid }  fragment userFragment on User { avatar { __typename ...coverFragment } name uuid followersCount login }  fragment bookshelfFragment on Bookshelf { cover { __typename ...coverFragment } name uuid user { __typename ...userFragment } posts { total } followersCount description }  fragment shelvesSectionFragment on ShelvesSection { items(cursor: $sectionItemsCursor) { cursor page { __typename ...bookshelfFragment } } name uuid }  fragment seriesFragment on Series { authors { __typename ...personFragment } cover { __typename ...coverFragment } name uuid items { followersCount total } }  fragment simpleSectionFragment on SimpleSection { availableFilters items(cursor: $sectionItemsCursor) { cursor page { __typename ...audioBookFragment ...comicBookFragment ...textBookFragment ...textSerialFragment ...seriesFragment } } name uuid }  fragment statisticsSectionFragment on StatisticsSection { daysReadingInMonth updatedAt name uuid }  fragment topSectionFragment on TopSection { items(cursor: $sectionItemsCursor) { cursor page { __typename ...audioBookFragment ...comicBookFragment ...textBookFragment ...textSerialFragment } } name uuid }  fragment seriesSectionFragment on SeriesSection { items(cursor: $sectionItemsCursor) { cursor page { __typename ...seriesFragment } } name uuid }  fragment ratingSectionFragment on RatingSection { items(cursor: $sectionItemsCursor) { cursor page { __typename ...audioBookFragment ...comicBookFragment ...textBookFragment ...textSerialFragment } } name uuid }'
ROOT_SHOWCASES = 'query RootShowcases($rootShowcaseParamsInput: RootShowcaseParamsInput!) { rootShowcases(params: $rootShowcaseParamsInput) { children { __typename ...fragmentShowcase ...childrenFragmentShowcase ...parentsFragmentShowcase } notification { __typename ...notificationFragment } } }  fragment fragmentShowcase on Showcase { name uuid availableFilters }  fragment childrenFragmentShowcase on Showcase { children { __typename ...fragmentShowcase } }  fragment parentsFragmentShowcase on Showcase { parents { __typename ...fragmentShowcase } }  fragment notificationFragment on Notification { consumer notificationPayloadId payload templateId feedbackToken }'
PROGRESS_UPDATED = ("mutation ProgressUpdated($textbookProgresses: [TextbookProgressUpdatedInput!], $textSerialProgresses: [TextSerialProgressUpdatedInput!], $audiobookProgresses: [AudiobookProgressUpdatedInput!], $comicbookProgresses: [ComicbookProgressUpdatedInput!]) { progressUpdated(textbookProgresses: $textbookProgresses, textSerialProgresses: $textSerialProgresses, audiobookProgresses: $audiobookProgresses, comicbookProgresses: $comicbookProgresses) { value } }")
SEARCH = ("query Search($query: SearchParamsInput!) { search(query: $query) { page { __typename ...searchSnippetAudioBookFragment ...searchSnippetTextBookFragment ...searchSnippetComicBookFragment ...searchSnippetTextSerialFragment ...bookshelfFragment ...personFragment ...publisherFragment ...seriesFragment ...topicFragment ...userFragment } cursor rankedFilter { filterType } misspell { correctedText correctionType } } }  fragment coverFragment on Cover { url ratio backgroundColorHex }  fragment personFragment on Person { avatar { __typename ...coverFragment } name uuid worksCount roles }  fragment bookFragment on Book { annotation name cover { __typename ...coverFragment } uuid initUuid authors { __typename ...personFragment } editorAnnotation }  fragment publisherFragment on Publisher { avatar { __typename ...coverFragment } name uuid worksCount }  fragment publisherBookFragment on Book { publisher { __typename ...publisherFragment } }  fragment translatorsBookFragment on Book { translators { __typename ...personFragment } }  fragment topicsBookFragment on Book { topics { name totalBook uuid } }  fragment subscriptionLevelsFragment on Book { subscriptionLevels }  fragment snippetBookFragment on Book { __typename ...bookFragment ...publisherBookFragment ...translatorsBookFragment ...topicsBookFragment ...subscriptionLevelsFragment }  fragment narratorsAudioBookFragment on AudioBook { narrators { __typename ...personFragment } }  fragment progressFragment on Progress { finished inLibrary progress isPublic }  fragment progressAudioBookFragment on AudioBook { progress { __typename ...progressFragment } }  fragment listenersCountAudioBookFragment on AudioBook { listenersCount }  fragment subscriptionsFragment on Availability { subscriptions { types } }  fragment ageRestrictionFragment on Availability { ageRestriction { name value } }  fragment snippetAudioBookFragment on AudioBook { __typename book { __typename ...snippetBookFragment } ...narratorsAudioBookFragment ...progressAudioBookFragment ...listenersCountAudioBookFragment availability { __typename ...subscriptionsFragment ...ageRestrictionFragment } }  fragment bookTagsFragment on Book { tags { name value } }  fragment searchSnippetAudioBookFragment on AudioBook { __typename ...snippetAudioBookFragment book { __typename ...bookTagsFragment } }  fragment progressTextBookFragment on TextBook { progress { __typename ...progressFragment } }  fragment readersCountTextBookFragment on TextBook { readersCount }  fragment snippetTextBookFragment on TextBook { __typename book { __typename ...snippetBookFragment } availability { __typename ...subscriptionsFragment ...ageRestrictionFragment } ...progressTextBookFragment ...readersCountTextBookFragment }  fragment searchSnippetTextBookFragment on TextBook { __typename ...snippetTextBookFragment book { __typename ...bookTagsFragment } }  fragment progressComicBookFragment on ComicBook { progress { __typename ...progressFragment } }  fragment readersCountComicBookFragment on ComicBook { readersCount }  fragment snippetComicBookFragment on ComicBook { __typename book { __typename ...snippetBookFragment } ...progressComicBookFragment ...readersCountComicBookFragment availability { __typename ...subscriptionsFragment ...ageRestrictionFragment } }  fragment searchSnippetComicBookFragment on ComicBook { __typename ...snippetComicBookFragment book { __typename ...bookTagsFragment } }  fragment textSerialFragment on TextSerial { availability { __typename ...ageRestrictionFragment } book { __typename ...bookFragment } }  fragment episodesTextSerialFragment on TextSerial { episodes { total } }  fragment readersCountTextSerialFragment on TextSerial { readersCount }  fragment snippetTextSerialFragment on TextSerial { __typename book { __typename ...snippetBookFragment } availability { __typename ...subscriptionsFragment ...ageRestrictionFragment } ...textSerialFragment ...episodesTextSerialFragment ...readersCountTextSerialFragment }  fragment searchSnippetTextSerialFragment on TextSerial { __typename ...snippetTextSerialFragment book { __typename ...bookTagsFragment } }  fragment userFragment on User { avatar { __typename ...coverFragment } name uuid followersCount login }  fragment bookshelfFragment on Bookshelf { cover { __typename ...coverFragment } name uuid user { __typename ...userFragment } posts { total } followersCount description }  fragment seriesFragment on Series { authors { __typename ...personFragment } cover { __typename ...coverFragment } name uuid items { followersCount total } }  fragment topicFragment on Topic { name slug totalBook uuid parent { name slug totalBook uuid } }")
FOUND = 60
FOUND_PAGE = 25
SEARCH_TYPES = ["TEXTBOOK", "SERIAL", "SERIES", "AUTHOR"]
SERIALS = {"serial-1": ("Сериал", 4), "serial-2": ("Новый сериал", 2)}


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
        # A first letter in an element of its own and a non-breaking space soon after it.
        if i == 6:
            return (f'<p><span class="first">{start[0]}</span>{start[1:]}&#160;{PARAGRAPH}\n'
                    f"  {PARAGRAPH * 3}</p>\n")
        # A space first in a paragraph, and in the middle a run of them: both are in real books.
        return f"<p>{' ' if i == 3 else ''}{start} {PARAGRAPH}\n  {PARAGRAPH * 3}</p>\n"
    paragraphs = "".join(paragraph(i) for i in range(30))
    if number == 5:
        # A note on the page and a link to another chapter, as there are in real books.
        paragraphs = ('<p>Текст со сноской<a id="r5" href="#n5" role="doc-noteref">[1]</a> '
                      'и <a id="x5" href="c8.html">переход в другую главу</a>.</p>\n'
                      + paragraphs
                      + '<aside id="n5" role="doc-footnote"><p>Текст сноски.</p></aside>\n')
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
            "state": "reading" if i < 3 else "finished" if 10 <= i < 14 else "pending",
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
            card["state"] = update["state"] or card["state"]
        if i == 3:
            card["book"].update(self.serial_book("serial-1"))
            self.serial_place(card, "ep1-2")
        return card

    def serial_place(self, card, episode=None):
        """A serial's card says which episode is being read, and the place in that episode."""
        update = self.server.card_updates.get(card["uuid"]) or {}
        episode = update.get("current_episode_uuid") or episode
        card["cfi"] = None
        if not episode:
            return
        card["current_episode_uuid"] = episode
        card["current_episode_position"] = int(episode.split("-")[1])
        position = self.server.positions.get(episode)
        if position:
            spine, start = position["start"].split("!")
            card["cfi"] = f'{spine}!,{start},{position["end"].split("!")[1]}'

    def cover(self, n):
        return f"http://127.0.0.1:{self.server.server_address[1]}/cover/{n}.png"

    def serial_book(self, uuid):
        title, episodes = SERIALS[uuid]
        return {"uuid": uuid, "title": title, "source_type": "serial", "episodes_count": episodes,
                "authors": "Автор сериала", "authors_objects": [{"name": "Автор сериала", "uuid": "author-1"}],
                "can_be_read": True, "cover": {"small": self.cover(150), "large": self.cover(150)}}

    def episode(self, uuid):
        """The book of an episode, by its id: ep2-1 is the first of serial-2."""
        serial, number = re.fullmatch(r"ep(\d)-(\d)", uuid).groups()
        taken = uuid in self.server.taken
        return {"uuid": uuid, "title": f"Эпизод {number}", "source_type": "serial_episode",
                "parent_uuid": f"serial-{serial}", "position": int(number), "can_be_read": uuid != "ep1-3",
                "authors": "Автор сериала", "authors_objects": [{"name": "Автор сериала", "uuid": "author-1"}],
                "cover": {"small": self.cover(150 + int(number)), "large": self.cover(150 + int(number))},
                "in_library": taken, "library_card": {"uuid": f"c-{uuid}"} if taken else None}

    def taken_card(self, uuid):
        """The card of an episode, or of a serial that was added."""
        book = self.serial_book(uuid) if uuid in SERIALS else self.episode(uuid)
        book.pop("library_card", None)
        card = {"uuid": f"c-{uuid}", "state": "pending", "progress": 0, "cfi": None, "public": True,
                "document_uuid": "d1", "book": book}
        position = self.server.positions.get(uuid)
        if position:
            spine, start = position["start"].split("!")
            card["cfi"] = f'{spine}!,{start},{position["end"].split("!")[1]}'
        if uuid in SERIALS:
            self.serial_place(card)
        return card

    def rest_book(self, i):
        """A book as the lists give it, written otherwise than in the results of a search."""
        uuid = f"found{i}"
        book = {"uuid": uuid, "title": f"Найденная книга {i}", "authors": f"Автор {i}",
                "authors_objects": [{"name": "Автор подборки", "uuid": "author-1"}],
                "annotation": f"Аннотация книги {i}.", "can_be_read": True, "source_type": "html",
                "cover": {"small": self.cover(100 + i), "large": self.cover(100 + i)},
                "in_library": uuid in self.server.added, "library_card": None}
        if i == 20:
            book["series_list"] = [{"position": 1, "position_label": "1", "uuid": "series-1", "title": "Подборка"}]
        return book

    def shelf(self, uuid, title, count):
        return {"uuid": uuid, "title": title, "books_count": count, "editable": uuid == "shelf-1",
                "creator": {"name": "Читатель"},
                "cover": {"small": self.cover(150), "large": self.cover(150)}}

    def rest_series(self, uuid):
        title, kinds, parts = {"series-1": ("Подборка", ["books"], 2),
                               "series-audio": ("Только послушать", ["audio"], 4)}[uuid]
        return {"uuid": uuid, "title": title, "kinds": kinds, "parts_count": parts, "authors": "Автор подборки",
                "cover": {"small": self.cover(140), "large": self.cover(140)}}

    def mixed_results(self):
        """Everything search can give, with what must not get through."""
        person = {"__typename": "Person", "uuid": "author-1", "name": "Автор подборки", "worksCount": 751,
                  "roles": ["AUTHOR"], "avatar": {"url": self.cover(141)}}
        series = {"__typename": "Series", "uuid": "series-1", "name": "Подборка", "items": {"total": 2, "followersCount": 3},
                  "authors": [{"name": "Автор подборки", "uuid": "author-1"}], "cover": {"url": self.cover(140)}}
        serial = {"__typename": "TextSerial", "readersCount": 5, "availability": {}, "episodes": {"total": 2},
                  "book": {"uuid": "serial-2", "name": "Новый сериал", "annotation": "Об этом сериале.",
                           "authors": [{"name": "Автор сериала", "uuid": "author-1"}], "cover": {"url": self.cover(150)}}}
        return [person,
                {**person, "uuid": "translator-1", "name": "Переводчик", "roles": ["TRANSLATOR"]},
                {**person, "uuid": "author-0", "name": "Без книг", "worksCount": 0},
                series,
                {**series, "uuid": "series-audio", "name": "Только послушать"},
                serial,
                self.found(20)]

    def found(self, i):
        """A book in the search results; the first few are the odd cases."""
        uuid = {0: "book5", 2: "found-on-phone", 3: "found-denied"}.get(i, f"found{i}")
        return {
            "__typename": "TextBook",
            "book": {
                "uuid": uuid,
                "initUuid": uuid,
                "name": "Книга номер 5" if i == 0 else f"Найденная книга {i}",
                "authors": [{"name": f"Автор {i}", "uuid": f"a{i}"}],
                "annotation": None if i == 4 else f"Аннотация книги {i}. " + PARAGRAPH * 8,
                "cover": {"url": f"http://127.0.0.1:{self.server.server_address[1]}/cover/{100 + i}.png", "ratio": 0.7},
            },
            "availability": {"subscriptions": {"types": ["plus"]}},
            "progress": {"inLibrary": uuid == "book5" or uuid == "found-on-phone" or uuid in self.server.added,
                         "progress": 0, "finished": False, "isPublic": True},
        }

    def search(self, variables):
        asked = variables["query"]
        if self.server.fail_search > 0:
            self.server.fail_search -= 1
            self.reply(500, b"")
            return
        if asked.get("types") != SEARCH_TYPES or asked.get("noMisspell") is not False or not asked.get("query"):
            print("bad Search:", variables, flush=True)
            self.reply_json(200, {"errors": [{"message": "bad input"}], "data": None})
            return
        none = {"page": [], "cursor": "", "misspell": {"correctedText": "", "correctionType": "NOT_CORRECTED"}}
        if "нет такой" in asked["query"]:
            self.reply_json(200, {"data": {"search": none}})
            return
        if "подборка" in asked["query"]:
            self.reply_json(200, {"data": {"search": {**none, "page": self.mixed_results()}}})
            return
        start = int(asked["cursor"].split(",")[1]) if asked["cursor"] else 0
        end = min(start + FOUND_PAGE, FOUND)
        self.reply_json(200, {"data": {"search": {
            **none,
            "page": [self.found(i) for i in range(start, end)],
            "cursor": f"{start // FOUND_PAGE + 1},{end}" if end < FOUND else "",
        }}})

    def showcase(self, variables):
        asked = variables.get("showcaseParamsInput") or {}
        if self.server.fail_showcase > 0:
            self.server.fail_showcase -= 1
            self.reply(500, b"")
            return
        if (asked.get("uuid") != "EKSEfw9w" or asked.get("contentFilter") != []
                or asked.get("notificationFilters") != [] or asked.get("isSearch") is not False):
            print("bad Showcase:", variables, flush=True)
            self.reply_json(200, {"errors": [{"message": "bad input"}], "data": None})
            return

        def text(i):  # the feed says nothing of the library
            found = self.found(i)
            return {"__typename": "TextBook", "availability": found["availability"], "book": found["book"]}

        def section(name, books, kind="SimpleSection"):
            return {"__typename": kind, "name": name, "items": {"cursor": "20", "page": books}}

        def row(name, start):
            return section(name, [text(i) for i in range(start, start + 6)])

        audio = [{"__typename": "Audiobook", "availability": {}, "book": {"uuid": f"audio{i}", "name": f"Аудио {i}"}}
                 for i in range(6)]
        cursor = variables.get("showcaseItemsCursor")
        if cursor == "":
            page = [section("Featured post 1", [text(i) for i in range(30, 36)], "FeaturedSection"),
                    section("Только послушать", audio), row("Новинки", 5), row("Популярное", 0),
                    row("Классика", 11), section("Мало книг", [text(20)]), row("Детективы", 21)]
            following = "20"
        elif cursor == "20":
            page = [row("Фантастика", 27), row("Нон-фикшн", 33), row("Поэзия", 39)]
            following = ""
        else:
            print("bad Showcase cursor:", variables, flush=True)
            self.reply_json(200, {"errors": [{"message": "bad cursor"}], "data": None})
            return
        self.reply_json(200, {"data": {"showcase": {"name": "Яндекс Книги", "uuid": asked["uuid"], "children": [],
                                                    "items": {"page": page, "cursor": following}}}})

    def added_card(self, uuid):
        i = int(uuid.replace("found", ""))
        return {"uuid": f"added{i}", "state": "pending", "progress": 0, "cfi": None, "public": True,
                "document_uuid": "d1", "book": {**self.found(i)["book"], "title": f"Найденная книга {i}",
                                                "cover": {"small": self.found(i)["book"]["cover"]["url"]}}}

    def add_book(self):
        form = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        if self.headers.get("Auth-Token") != "mock-token":
            self.reply(401, b"")
            return
        want = {"lc[state]": ["pending"], "lc[progress]": ["0"], "lc[public]": ["true"], "lc[is_in_child_library]": ["false"]}
        book = form.pop("book_uuid", [""])[0]
        if form != want or not re.fullmatch(r"found\d+|serial-2|ep2-\d", book):
            print("bad add:", book, form, flush=True)
            self.reply(400, b"")
            return
        if not book.startswith("found"):
            # A serial and its episodes: the order is the phone's, the serial first.
            if book.startswith("ep") and "serial-2" not in self.server.taken:
                print("an episode before its serial:", book, flush=True)
                self.reply(400, b"")
                return
            self.server.taken.append(book)
            self.reply_json(200, {"library_card": self.taken_card(book)})
            return
        self.server.added.append(book)
        self.reply_json(200, {"library_card": self.added_card(book)})

    def note_change(self):
        self.server.notes_changes += 1
        return self.server.notes_changes

    def create_note(self, book, list_name):
        form = parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode(), keep_blank_values=True)
        kind = list_name[:-1]
        # What the phone sends, to the letter: that one name really has no closing bracket.
        wanted = (["quote[content]", "quote[comment]", "quote[cfi]", "quote[color]", "quote[permanent_hidden",
                   "quote[progress]"] if kind == "quote"
                  else ["bookmark[cfi]", "bookmark[content]", "bookmark[progress]"])
        if self.headers.get("Auth-Token") != "mock-token" or sorted(form) != sorted(wanted):
            print("bad note:", sorted(form), flush=True)
            self.reply(422, b"")
            return
        self.server.notes_made += 1
        uuid = f"note{self.server.notes_made}"
        note = {"state": "exists", "uuid": uuid, "changes_count": self.note_change(),
                "cfi": form[f"{kind}[cfi]"][0], "content": form[f"{kind}[content]"][0],
                "progress": int(form[f"{kind}[progress]"][0]), "kind_here": kind}
        if kind == "quote":
            note.update(book={"uuid": book}, comment=form["quote[comment]"][0] or None,
                        color=int(form["quote[color]"][0]),
                        permanent_hidden=form["quote[permanent_hidden"][0] == "true")
        else:
            note.update(book_uuid=book, book_init_uuid=book)
        self.server.notes[uuid] = note
        self.reply_json(200, {kind: note})

    def notes_page(self, list_name, since):
        if self.headers.get("Auth-Token") != "mock-token":
            self.reply(401, b"")
            return
        if self.server.fail_notes > 0:
            self.server.fail_notes -= 1
            self.reply(500, b"")
            return
        kind = list_name[:-1]
        entries = sorted((n for n in self.server.notes.values()
                          if n["kind_here"] == kind and n["changes_count"] > since),
                         key=lambda n: n["changes_count"])
        # Short pages, so that all of them have to be asked for.
        self.reply_json(200, {list_name: entries[:2]})

    def do_DELETE(self):
        note = re.search(r"/(quotes|bookmarks)/([^/]+)$", self.path)
        if note and self.headers.get("Auth-Token") == "mock-token":
            found = self.server.notes.get(note.group(2))
            if not found or found["state"] == "removed" or found["kind_here"] + "s" != note.group(1):
                self.reply(404, b"")
                return
            self.server.notes[note.group(2)] = {"state": "removed", "uuid": note.group(2),
                                                "changes_count": self.note_change(),
                                                "kind_here": found["kind_here"]}
            self.reply(204, b"")
            return
        match = re.search(r"/profile/library_cards/([^/]+)$", self.path)
        if self.headers.get("Auth-Token") != "mock-token" or not match:
            self.reply(401, b"")
            return
        self.server.removed.append(match.group(1))
        self.reply(204, b"")

    def do_PUT(self):
        length = int(self.headers.get("Content-Length", 0))
        form = parse_qs(self.rfile.read(length).decode(), keep_blank_values=True)
        quote = re.search(r"/quotes/([^/]+)$", self.path)
        if quote and self.headers.get("Auth-Token") == "mock-token":
            found = self.server.notes.get(quote.group(1))
            wanted = ["quote[cfi]", "quote[color]", "quote[comment]", "quote[content]", "quote[permanent_hidden"]
            if not found or found["state"] == "removed":
                self.reply(404, b"")
            elif sorted(form) != wanted:
                print("bad quote:", sorted(form), flush=True)
                self.reply(422, b"")
            else:
                found.update(cfi=form["quote[cfi]"][0], content=form["quote[content]"][0],
                             comment=form["quote[comment]"][0] or None, color=int(form["quote[color]"][0]),
                             permanent_hidden=form["quote[permanent_hidden"][0] == "true",
                             changes_count=self.note_change())
                self.server.notes_writes += 1
                self.reply_json(200, {"quote": found})
            return
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
            "current_episode_uuid": form.get("lc[current_episode_uuid]", [None])[0],
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
        # The real server takes only queries on its whitelist, to the letter.
        if body.get("operationName") == "Search" and body["query"] == SEARCH:
            self.search(body["variables"])
            return
        if body.get("operationName") == "Showcase" and body["query"] == SHOWCASE:
            self.showcase(body["variables"])
            return
        if body.get("operationName") == "RootShowcases" and body["query"] == ROOT_SHOWCASES:
            self.reply_json(200, {"data": {"rootShowcases": {"children": [{"name": "Яндекс Книги", "uuid": "EKSEfw9w"}]}}})
            return
        if body["query"] != PROGRESS_UPDATED:
            self.reply_json(200, {"errors": [{"message": "Whitelist: query not found"}]})
            return
        variables = body["variables"]
        for p in (variables.get("textbookProgresses") or []) + (variables.get("textSerialProgresses") or []):
            good = (isinstance(p["timespent"], int) and p["timespent"] > 0
                    and p["consumptionType"] == "CONSUMPTION"
                    and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}\+00:00", p["readAt"])
                    and re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}", p["sessionId"])
                    and p["documentUuid"] == (f'd-{p["episodeUuid"]}' if p.get("episodeUuid") else "d1")
                    and "!/" in p["cfi"]["start"] and "!/" in p["cfi"]["end"]
                    )
            if not good:
                print("bad ProgressUpdated:", p, flush=True)
                self.reply_json(200, {"errors": [{"message": "bad input"}], "data": None})
                return
            if "textSerialProgresses" in variables:
                self.server.serial_progress = {"uuid": p["uuid"], "episode": p["episodeUuid"]}
            book = p.get("episodeUuid") or p["uuid"]
            self.server.positions[book] = {"start": p["cfi"]["start"], "end": p["cfi"]["end"],
                                           "writes": self.server.positions.get(book, {}).get("writes", 0) + 1}
        self.reply_json(200, {"data": {"progressUpdated": None}})

    def do_POST(self):
        if self.path == "/graphql":
            self.graphql()
            return
        if self.path.endswith("/profile/library_cards"):
            self.add_book()
            return
        note = re.search(r"/books/([^/]+)/(quotes|bookmarks)$", self.path)
        if note:
            self.create_note(note.group(1), note.group(2))
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
        elif url.path.endswith("/quotes/incremental_sync"):
            self.notes_page("quotes", int(query["changes_count"][0]))
        elif url.path.endswith("/bookmarks/incremental_sync"):
            self.notes_page("bookmarks", int(query["changes_count"][0]))
        elif url.path == "/test/notes":
            self.reply_json(200, {"notes": [n for n in self.server.notes.values() if n["state"] == "exists"],
                                  "made": self.server.notes_made, "writes": self.server.notes_writes})
        elif url.path == "/test/fail_notes":
            self.server.fail_notes = int(query["n"][0])
            self.reply(200, b"")
        elif url.path == "/test/note_add":
            # As if written on the phone.
            self.server.notes_made += 1
            uuid = f"phone{self.server.notes_made}"
            note = {"state": "exists", "uuid": uuid, "changes_count": self.note_change(), "cfi": query["cfi"][0],
                    "content": query.get("content", [""])[0], "progress": 1, "kind_here": query["kind"][0]}
            if query["kind"][0] == "quote":
                note.update(book={"uuid": query["book"][0]}, comment=query.get("comment", [None])[0], color=0,
                            permanent_hidden=False)
            else:
                note.update(book_uuid=query["book"][0], book_init_uuid=query["book"][0])
            self.server.notes[uuid] = note
            self.reply_json(200, note)
        elif url.path == "/test/note_edit":
            note = self.server.notes[query["uuid"][0]]
            if "comment" in query:
                note["comment"] = query["comment"][0]
            if "hidden" in query:
                note["permanent_hidden"] = query["hidden"][0] == "1"
            note["changes_count"] = self.note_change()
            self.reply_json(200, note)
        elif url.path == "/test/note_remove":
            uuid = query["uuid"][0]
            self.server.notes[uuid] = {"state": "removed", "uuid": uuid, "changes_count": self.note_change(),
                                       "kind_here": self.server.notes[uuid]["kind_here"]}
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
        elif url.path == "/test/fail_showcase":
            self.server.fail_showcase = int(query["n"][0])
            self.reply(200, b"ok")
        elif url.path == "/test/fail_search":
            self.server.fail_search = int(query["n"][0])
            self.reply(200, b"")
        elif url.path == "/test/removed":
            self.reply_json(200, {"removed": self.server.removed})
        elif url.path == "/test/added":
            self.reply_json(200, {"added": self.server.added})
        elif url.path == "/test/serial":
            self.reply_json(200, {"taken": self.server.taken, "progress": self.server.serial_progress,
                                  "updates": self.server.card_updates})
        elif re.fullmatch(r".*/series/[^/]+", url.path):
            self.reply_json(200, {"series": self.rest_series(url.path.split("/")[-1])})
        elif url.path.endswith("/profile/bookshelves"):
            self.reply_json(200, {"bookshelves": [self.shelf("shelf-1", "Моя полка", 2)]})
        elif url.path.endswith("/profile/bookshelves/following"):
            shelves = [self.shelf("shelf-1", "Моя полка", 2), self.shelf("shelf-2", "Чужая полка", 21)]
            self.reply_json(200, {"bookshelves": shelves if query.get("page") == ["1"] else []})
        elif url.path.endswith("/bookshelves/shelf-1/books"):
            books = [self.rest_book(20), self.rest_book(22)]
            self.reply_json(200, {"books": books if query.get("page") == ["1"] else []})
        elif url.path.endswith("/series/series-1/parts"):
            first = query.get("page") == ["1"]
            closed = self.rest_book(23)
            closed["can_be_read"] = False
            parts = [{"position": 1, "position_label": "1", "resource_type": "audiobook", "resource": {"uuid": "audio0", "title": "Первая вслух"}},
                     {"position": 1, "position_label": "1", "resource_type": "book", "resource": self.rest_book(20)},
                     {"position": 2, "position_label": "2", "resource_type": "audiobook", "resource": {"uuid": "audio1", "title": "Послушать"}},
                     {"position": 3, "position_label": "3", "resource_type": "book", "resource": self.rest_book(21)},
                     {"position": 4, "position_label": "4", "resource_type": "book", "resource": closed}]
            self.reply_json(200, {"parts": parts if first else []})
        elif url.path.endswith("/authors/author-1/books"):
            if query.get("role") != ["author"]:
                self.reply(404, b"")
                return
            self.reply_json(200, {"books": [self.rest_book(20), self.rest_book(22)] if query.get("page") == ["1"] else []})
        elif url.path.endswith("/authors/author-1/series"):
            if query.get("role") != ["author"]:
                self.reply(404, b"")
                return
            self.reply_json(200, {"series": [self.rest_series("series-1"), self.rest_series("series-audio")]})
        elif re.search(r"/books/serial-\d/episodes$", url.path):
            serial = url.path.split("/")[-2]
            number = serial.split("-")[1]
            episodes = [self.episode(f"ep{number}-{n + 1}") for n in range(SERIALS[serial][1])]
            self.reply_json(200, {"episodes": episodes if query.get("page") == ["1"] else []})
        elif re.search(r"/books/ep\d-\d$", url.path):
            self.reply(404, b"")  # as there: an episode has no page of a book
        elif re.search(r"/books/serial-\d$", url.path):
            uuid = url.path.split("/")[-1]
            card = "card3" if uuid == "serial-1" else f"c-{uuid}" if uuid in self.server.taken else None
            self.reply_json(200, {"book": {**self.serial_book(uuid), "in_library": card is not None,
                                           "library_card_uuid": card}})
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
        elif re.search(r"/books/[^/]+$", url.path):
            # What a book's page says, whether it is in the library or not.
            uuid = url.path.split("/")[-1]
            card = {"book5": "card5", "found-on-phone": "card7"}.get(uuid)
            if uuid in self.server.added:
                card = "added" + uuid.replace("found", "")
            self.reply_json(200, {"book": {"uuid": uuid, "can_be_read": uuid != "found-denied",
                                           "in_library": card is not None, "library_card_uuid": card}})
        elif re.search(r"/profile/library_cards/c-[^/]+$", url.path):
            self.reply_json(200, {"library_card": self.taken_card(url.path.split("/c-")[-1])})
        elif re.search(r"/profile/library_cards/added\d+$", url.path):
            self.reply_json(200, {"library_card": self.added_card("found" + url.path.split("added")[-1])})
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
            everything = ([self.card(i) for i in range(BOOKS)] + [self.added_card(u) for u in self.server.added]
                          + [self.taken_card(u) for u in self.server.taken])
            everything = [c for c in everything if c["uuid"] not in self.server.removed]
            cards = everything[start:start + 10]
            self.reply_json(200, {"library_cards": cards})
        elif url.path.startswith("/cover/"):
            if self.headers.get("Auth-Token"):
                self.reply(400, b"the covers' host must not get the token")
                return
            self.reply(200, cover_png(int(url.path.split("/")[-1].split(".")[0])))
        elif "serial" in url.path:
            self.reply(404, b"")
        elif re.search(r"/books/ep\d-\d/metadata/v4$", url.path):
            episode = url.path.split("/")[-3]
            # What the list of episodes says of ep1-3 keeps it from being asked for; this one
            # is refused only when asked for.
            if episode == "ep1-3":
                print("a closed episode was asked for", flush=True)
                self.reply(500, b"")
            elif episode == "ep1-4":
                self.reply(403, b"")
            else:
                self.reply_json(200, {"document_uuid": f"d-{episode}", "opf": encrypted(OPF), "container": encrypted(CONTAINER)})
        elif url.path.endswith("/metadata/v4"):
            if f"/{COVER_PAGE_BOOK}/" in url.path:
                self.reply_json(200, {"document_uuid": "d1", "opf": encrypted(COVER_PAGE_OPF),
                                      "container": encrypted(BIG_CONTAINER), "ncx": encrypted(COVER_PAGE_NCX)})
            elif self.server.big:
                self.reply_json(200, {"document_uuid": "d1", "opf": encrypted(BIG_OPF),
                                      "container": encrypted(BIG_CONTAINER), "ncx": encrypted(BIG_NCX)})
            else:
                self.reply_json(200, {"document_uuid": "d1", "opf": encrypted(OPF), "container": encrypted(CONTAINER)})
        elif url.path.endswith("/metadata_secret"):
            self.reply_json(200, {"secret": base64.b64encode(KEY).decode()})
        elif url.path.endswith("/content"):
            path = query["path"][0]
            if "/d-ep" in url.path:
                # An episode's document has the episode's own paths, not those of the whole serial.
                page = f'<html xmlns="http://www.w3.org/1999/xhtml"><body>{chapter(path)}</body></html>'
                self.reply(404 if "ep" in path else 200, page.encode())
                return
            # This route knows a book by its document, not its uuid: these names are that book's.
            if path.endswith("title.xhtml"):
                self.reply(200, COVER_PAGE.encode())
            elif path.endswith(("first.xhtml", "second.xhtml")):
                self.reply(200, ('<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml">'
                                 f'<head><title>t</title></head><body>{chapter(path)}</body></html>').encode())
            elif not self.server.big:
                self.reply(200, chapter(path).encode())
            elif path.endswith(".css"):
                self.reply(200, b"p { margin: 0; }")
            elif path.endswith(".png"):
                self.reply(200, cover_png(5))
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
    server.notes = {}
    server.notes_changes = 0
    server.notes_made = 0
    server.notes_writes = 0
    server.fail_notes = 0
    server.added = []
    # Of the serial that is in the library, two episodes of three came with it so far.
    server.taken = ["ep1-1", "ep1-2"]
    # The phone has got to the second chapter of the second episode.
    server.positions["ep1-2"] = {"start": "/6/4!/4/2:0", "end": "/6/4!/4/2:0", "writes": 0}
    server.serial_progress = None
    server.removed = []
    server.fail_search = 0
    server.fail_showcase = 0
    server.fail_card = 0
    server.chapter_delay = CHAPTER_DELAY
    server.big = len(sys.argv) > 2 and sys.argv[2] == "koreader"
    server.serve_forever()
