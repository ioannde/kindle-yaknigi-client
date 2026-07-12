#ifndef YB_READER_HTML_H
#define YB_READER_HTML_H

#include "reader/document.h"

#include <stddef.h>

/* XHTML -> document blocks. Shared by the EPUB loader and the Yandex content
 * loader (both consume plain XHTML chapters). Appends blocks to `doc`. */
void yb_html_to_blocks(const char *html, yb_document *doc);

/* Decode entities and collapse whitespace in [raw, raw+len); malloc'd result
 * (used for titles and inline text). */
char *yb_html_clean_text(const char *raw, size_t len);

#endif /* YB_READER_HTML_H */
