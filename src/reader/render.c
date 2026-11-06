#include "reader/render.h"

#include "reader/layout.h"
#include "util/log.h"

#include <ft2build.h>
#include FT_FREETYPE_H

#include <stdlib.h>
#include <string.h>

#define YB_ADVANCE_CACHE 1024

struct yb_font {
    FT_Library lib;
    FT_Face    face;
    int        px;
    int        line_height;
    int        ascender;
    /* Layout measures the same characters over and over, and asking FreeType
     * each time makes counting a book's pages far too slow on the device. */
    unsigned   cached_cp[YB_ADVANCE_CACHE];
    short      cached_adv[YB_ADVANCE_CACHE];
};

yb_font *yb_font_load(const char *path, int px_size) {
    yb_font *f = calloc(1, sizeof(*f));
    if (!f) return NULL;
    if (FT_Init_FreeType(&f->lib)) { free(f); return NULL; }
    if (FT_New_Face(f->lib, path, 0, &f->face)) {
        YB_ERR("font: cannot load %s", path);
        FT_Done_FreeType(f->lib);
        free(f);
        return NULL;
    }
    FT_Set_Pixel_Sizes(f->face, 0, (FT_UInt)px_size);
    f->px = px_size;
    f->line_height = (int)(f->face->size->metrics.height >> 6);
    f->ascender = (int)(f->face->size->metrics.ascender >> 6);
    if (f->line_height <= 0) f->line_height = px_size + px_size / 4;
    return f;
}

void yb_font_free(yb_font *f) {
    if (!f) return;
    FT_Done_Face(f->face);
    FT_Done_FreeType(f->lib);
    free(f);
}

/* Decode one UTF-8 code point from *p (bounded by end); advances *p. */
static unsigned utf8_next(const char **p, const char *end) {
    const unsigned char *s = (const unsigned char *)*p;
    unsigned cp;
    int n;
    if (s[0] < 0x80) { cp = s[0]; n = 1; }
    else if ((s[0] & 0xE0) == 0xC0) { cp = s[0] & 0x1F; n = 2; }
    else if ((s[0] & 0xF0) == 0xE0) { cp = s[0] & 0x0F; n = 3; }
    else if ((s[0] & 0xF8) == 0xF0) { cp = s[0] & 0x07; n = 4; }
    else { *p += 1; return 0xFFFD; }
    if ((const char *)s + n > end) { *p = end; return 0xFFFD; }
    for (int i = 1; i < n; ++i) cp = (cp << 6) | (s[i] & 0x3F);
    *p += n;
    return cp;
}

static int advance_of(yb_font *f, unsigned cp) {
    /* Slot 0 starts out zeroed, so code point 0 is never treated as cached. */
    unsigned slot = cp % YB_ADVANCE_CACHE;
    if (cp && f->cached_cp[slot] == cp) return f->cached_adv[slot];
    int adv = 0;
    if (FT_Load_Char(f->face, cp, FT_LOAD_DEFAULT) == 0)
        adv = (int)(f->face->glyph->advance.x >> 6);
    f->cached_cp[slot] = cp;
    f->cached_adv[slot] = (short)adv;
    return adv;
}

/* measure callback for the wrapper */
static int measure_cb(void *ctx, const char *text, size_t len) {
    yb_font *f = ctx;
    const char *p = text;
    const char *end = text + len;
    int w = 0;
    while (p < end) w += advance_of(f, utf8_next(&p, end));
    return w;
}

/* Draw a line of text with its baseline at y, left edge at x. */
static void draw_line(yb_font *f, yb_canvas *c, int x, int baseline,
                      const char *text, size_t len) {
    const char *p = text;
    const char *end = text + len;
    int pen = x;
    while (p < end) {
        unsigned cp = utf8_next(&p, end);
        if (FT_Load_Char(f->face, cp, FT_LOAD_RENDER)) continue;
        FT_GlyphSlot g = f->face->glyph;
        FT_Bitmap *bm = &g->bitmap;
        int gx = pen + g->bitmap_left;
        int gy = baseline - g->bitmap_top;
        for (unsigned row = 0; row < bm->rows; ++row) {
            for (unsigned col = 0; col < bm->width; ++col) {
                uint8_t cov = bm->buffer[row * bm->pitch + col];
                if (cov) yb_canvas_blend(c, gx + (int)col, gy + (int)row, cov);
            }
        }
        pen += (int)(g->advance.x >> 6);
    }
}

int yb_font_line_height(const yb_font *f) { return f->line_height; }
int yb_font_ascender(const yb_font *f) { return f->ascender; }

int yb_font_text_width(yb_font *f, const char *text) {
    return measure_cb(f, text, strlen(text));
}

void yb_font_draw_text(yb_font *f, yb_canvas *c, int x, int baseline, const char *text) {
    draw_line(f, c, x, baseline, text, strlen(text));
}

yb_pos yb_render_page(yb_font *font, yb_canvas *c, const yb_document *doc,
                      yb_pos start, int *done) {
    return yb_render_page_ex(font, c, c->w, c->h, doc, start, 0, done);
}

yb_pos yb_render_page_ex(yb_font *font, yb_canvas *c, int w, int h,
                         const yb_document *doc, yb_pos start,
                         int reserve_bottom, int *done) {
    if (done) *done = 0;
    if (c) yb_canvas_clear(c, 0xFF);

    int margin = font->px;                 /* ~1em margins */
    int max_w = w - 2 * margin;
    int x0 = margin;
    int y_limit = h - margin - reserve_bottom;
    int top = margin;
    int drew = 0;

    for (size_t b = start.block; b < doc->count; ++b) {
        const yb_block *blk = &doc->blocks[b];

        yb_line *lines = NULL;
        size_t nlines = yb_wrap_paragraph(blk->text, max_w, measure_cb, font, &lines);

        /* find the first line to draw (resume within a block) */
        size_t li = 0;
        if (b == start.block && start.line_off > 0) {
            while (li < nlines && lines[li].off < start.line_off) li++;
        } else if (blk->heading && drew) {
            top += font->line_height / 2;  /* breathing room before a heading */
        }

        for (; li < nlines; ++li) {
            int fits = (top + font->line_height <= y_limit);
            if (!fits && drew) {
                size_t resume_off = lines[li].off;
                free(lines);
                return (yb_pos){ b, resume_off };
            }
            int baseline = top + font->ascender;
            if (c) draw_line(font, c, x0, baseline, blk->text + lines[li].off, lines[li].len);
            drew = 1;
            top += font->line_height;
        }
        free(lines);
        top += font->line_height / 2;      /* paragraph spacing */
    }

    if (done) *done = 1;
    return (yb_pos){ doc->count, 0 };
}
