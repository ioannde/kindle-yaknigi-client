#include "test_util.h"

#include "reader/epub.h"

#include <stdio.h>
#include <string.h>

/* Writes a minimal STORED zip. yb_zip does not verify CRCs, so they stay 0. */
typedef struct { const char *name; const char *data; } entry;

static void put16(FILE *f, unsigned v) { fputc(v & 0xFF, f); fputc((v >> 8) & 0xFF, f); }
static void put32(FILE *f, unsigned long v) { put16(f, v & 0xFFFF); put16(f, (v >> 16) & 0xFFFF); }

static void write_zip(const char *path, const entry *e, unsigned n) {
    unsigned long off[16];
    FILE *f = fopen(path, "wb");
    if (!f) return;
    for (unsigned i = 0; i < n; ++i) {
        unsigned long nl = strlen(e[i].name), dl = strlen(e[i].data);
        off[i] = (unsigned long)ftell(f);
        put32(f, 0x04034b50UL); put16(f, 20); put16(f, 0); put16(f, 0);
        put16(f, 0); put16(f, 0); put32(f, 0); put32(f, dl); put32(f, dl);
        put16(f, (unsigned)nl); put16(f, 0);
        fwrite(e[i].name, 1, nl, f);
        fwrite(e[i].data, 1, dl, f);
    }
    unsigned long cd = (unsigned long)ftell(f);
    for (unsigned i = 0; i < n; ++i) {
        unsigned long nl = strlen(e[i].name), dl = strlen(e[i].data);
        put32(f, 0x02014b50UL); put16(f, 20); put16(f, 20); put16(f, 0); put16(f, 0);
        put16(f, 0); put16(f, 0); put32(f, 0); put32(f, dl); put32(f, dl);
        put16(f, (unsigned)nl); put16(f, 0); put16(f, 0); put16(f, 0); put16(f, 0);
        put32(f, 0); put32(f, off[i]);
        fwrite(e[i].name, 1, nl, f);
    }
    unsigned long cdlen = (unsigned long)ftell(f) - cd;
    put32(f, 0x06054b50UL); put16(f, 0); put16(f, 0); put16(f, n); put16(f, n);
    put32(f, cdlen); put32(f, cd); put16(f, 0);
    fclose(f);
}

static const char CONTAINER[] =
    "<container><rootfiles><rootfile full-path=\"OEBPS/c.opf\"/></rootfiles></container>";
static const char OPF[] =
    "<package><metadata><dc:title>T</dc:title></metadata><manifest>"
    "<item id=\"a\" href=\"a.html\"/><item id=\"b\" href=\"b.html\"/>"
    "</manifest><spine><itemref idref=\"a\"/><itemref idref=\"b\"/></spine></package>";

int main(void) {
    const char *path = "test_epub_tmp.epub";
    yb_document doc;

    /* every spine chapter present */
    const entry full[] = {
        { "META-INF/container.xml", CONTAINER }, { "OEBPS/c.opf", OPF },
        { "OEBPS/a.html", "<p>one</p>" }, { "OEBPS/b.html", "<p>two</p>" },
    };
    write_zip(path, full, 4);
    CHECK(yb_epub_load(path, &doc) == 0);
    CHECK(doc.count == 2);
    CHECK(doc.missing_chapters == 0);
    yb_document_free(&doc);

    /* a spine chapter is absent: loads, but reports it */
    write_zip(path, full, 3);
    CHECK(yb_epub_load(path, &doc) == 0);
    CHECK(doc.count == 1);
    CHECK(doc.missing_chapters == 1);
    yb_document_free(&doc);

    /* no chapter readable: fails and leaves nothing to free */
    write_zip(path, full, 2);
    CHECK(yb_epub_load(path, &doc) == -1);
    CHECK(doc.title == NULL);
    CHECK(doc.count == 0);

    remove(path);

    if (tests_failed == 0) printf("test_epub: OK\n");
    return tests_failed != 0;
}
