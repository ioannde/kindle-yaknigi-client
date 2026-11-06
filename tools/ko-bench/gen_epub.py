#!/usr/bin/env python3
"""Generate synthetic Russian EPUBs for measuring crengine open time.

gen_epub.py OUT_DIR
  OUT_DIR/full_<MB>.epub      every chapter filled in
  OUT_DIR/skeleton_<MB>.epub  same spine and manifest, but only chapters 30 and
                              31 have text; the rest are one-line placeholders
"""
import os
import random
import sys
import zipfile

WORDS = ("время человек рука дело глаз жизнь голова день друг дом слово место "
         "лицо сторона нога дверь работа земля конец вопрос город сила отец "
         "женщина машина случай ночь мир вид ряд начало книга голос утро улица "
         "говорил думал смотрел знал хотел видел пошёл сказал стоял сидел "
         "большой новый последний старый молодой хороший белый тихий далёкий "
         "медленно вдруг снова почти никогда теперь потом сегодня однако").split()

CONTAINER = ('<?xml version="1.0"?><container version="1.0" '
             'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
             '<rootfile full-path="OEBPS/content.opf" '
             'media-type="application/oebps-package+xml"/></rootfiles></container>')


def paragraph(rnd):
    sentences = []
    for _ in range(rnd.randint(2, 7)):
        s = " ".join(rnd.choice(WORDS) for _ in range(rnd.randint(6, 18)))
        sentences.append(s.capitalize() + ".")
    return "<p>" + " ".join(sentences) + "</p>"


def chapter(rnd, n, size):
    body = [f"<h2>Глава {n}</h2>"]
    used = 0
    while used < size:
        p = paragraph(rnd)
        body.append(p)
        used += len(p.encode())
    return wrap(n, "\n".join(body))


def wrap(n, body):
    return ('<?xml version="1.0" encoding="utf-8"?><html '
            'xmlns="http://www.w3.org/1999/xhtml"><head>'
            f"<title>Глава {n}</title></head><body>{body}</body></html>")


def write(path, chapters):
    n = len(chapters)
    items = "".join(f'<item id="c{i}" href="c{i}.html" '
                    'media-type="application/xhtml+xml"/>' for i in range(n))
    spine = "".join(f'<itemref idref="c{i}"/>' for i in range(n))
    opf = ('<?xml version="1.0"?><package version="2.0" '
           'xmlns="http://www.idpf.org/2007/opf" unique-identifier="b"><metadata '
           'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Bench</dc:title>'
           '<dc:language>ru</dc:language><dc:identifier id="b">bench</dc:identifier>'
           f"</metadata><manifest>{items}</manifest><spine>{spine}</spine></package>")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip")
        z.writestr("META-INF/container.xml", CONTAINER)
        z.writestr("OEBPS/content.opf", opf)
        for i, c in enumerate(chapters):
            z.writestr(f"OEBPS/c{i}.html", c)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for mb, count in ((1, 60), (6, 90)):
        rnd = random.Random(mb)
        size = mb * 1024 * 1024 // count
        full = [chapter(rnd, i, size) for i in range(count)]
        write(f"{out}/full_{mb}.epub", full)
        skel = [c if i in (30, 31) else wrap(i, "<p>Глава загружается…</p>")
                for i, c in enumerate(full)]
        write(f"{out}/skeleton_{mb}.epub", skel)


if __name__ == "__main__":
    main()
