#ifndef YB_READER_DOCUMENT_H
#define YB_READER_DOCUMENT_H

#include <stddef.h>

/* Normalized, format-independent representation of a book: a title plus an
 * ordered list of text blocks (paragraphs / headings). This is what the
 * layout engine paginates and what any source format (EPUB now, the Yandex
 * reading protocol after Phase 0) is converted into. */

typedef struct {
    int   heading;  /* 1 if this block is a heading */
    char *text;     /* owned, UTF-8, whitespace-collapsed */
} yb_block;

typedef struct {
    char     *title;
    yb_block *blocks;
    size_t    count;
    size_t    cap;
} yb_document;

void yb_document_init(yb_document *d);
/* Appends a block (text is copied, empty/whitespace-only is ignored).
 * Returns 0 on success. */
int  yb_document_add(yb_document *d, int heading, const char *text);
void yb_document_set_title(yb_document *d, const char *title);
void yb_document_free(yb_document *d);

#endif /* YB_READER_DOCUMENT_H */
