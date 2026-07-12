#ifndef YB_READER_EPUB_H
#define YB_READER_EPUB_H

#include "reader/document.h"

/* Parse an EPUB file into a normalized document: reads the OPF via
 * META-INF/container.xml, walks the spine in order, and converts each XHTML
 * chapter into text blocks. Returns 0 on success, -1 on error. */
int yb_epub_load(const char *path, yb_document *out);

#endif /* YB_READER_EPUB_H */
