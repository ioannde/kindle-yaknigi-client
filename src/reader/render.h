#ifndef YB_READER_RENDER_H
#define YB_READER_RENDER_H

#include "platform/display.h"
#include "reader/document.h"

/* FreeType-backed text renderer: paginates a document and draws pages into a
 * grayscale canvas. This is the real reader output path — the same code runs
 * on the host (into a PGM) and on the Kindle (into the framebuffer). */

typedef struct yb_font yb_font;

/* Load a TTF/OTF at the given pixel size. Returns NULL on error. */
yb_font *yb_font_load(const char *path, int px_size);
void     yb_font_free(yb_font *f);

/* Resume position: block index plus the byte offset within that block of the
 * next line to draw. {0,0} is the start of the book. */
typedef struct {
    size_t block;
    size_t line_off;
} yb_pos;

/* Render one page starting at `start` into `c` (cleared to white first).
 * Returns the position to pass for the next page; sets *done=1 when the end
 * of the document has been reached. */
yb_pos yb_render_page(yb_font *font, yb_canvas *c, const yb_document *doc,
                      yb_pos start, int *done);

#endif /* YB_READER_RENDER_H */
