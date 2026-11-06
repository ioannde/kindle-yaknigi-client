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

/* Same, for a page of w x h pixels with `reserve_bottom` pixels kept free for a
 * footer. With c == NULL only the layout runs, which is how pages get counted. */
yb_pos yb_render_page_ex(yb_font *font, yb_canvas *c, int w, int h,
                         const yb_document *doc, yb_pos start,
                         int reserve_bottom, int *done);

/* Interface text. */
int  yb_font_line_height(const yb_font *f);
int  yb_font_ascender(const yb_font *f);
int  yb_font_text_width(yb_font *f, const char *text);
void yb_font_draw_text(yb_font *f, yb_canvas *c, int x, int baseline, const char *text);

#endif /* YB_READER_RENDER_H */
