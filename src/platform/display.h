#ifndef YB_PLATFORM_DISPLAY_H
#define YB_PLATFORM_DISPLAY_H

#include <stdint.h>

/* Off-screen grayscale canvas (8-bit, 0 = black .. 255 = white) matching the
 * e-ink model: 16 gray levels on device, full 8-bit here. The renderer draws
 * into this; a platform backend then `present`s it to the panel.
 *
 * On the host build, presenting means writing a PGM image (so pages are
 * viewable in dev). The device backends (eips / framebuffer, PLAN.md 2.3)
 * present the same canvas to the panel and are added in the cross build. */

typedef struct {
    int      w;
    int      h;
    int      dpi;
    uint8_t *pix;   /* w*h bytes, row-major, stride = w */
} yb_canvas;

yb_canvas *yb_canvas_new(int w, int h, int dpi);
void       yb_canvas_free(yb_canvas *c);
void       yb_canvas_clear(yb_canvas *c, uint8_t value);

/* Blend a coverage value (0..255) as black ink at (x,y): higher coverage =
 * darker. Out-of-bounds pixels are ignored. */
void yb_canvas_blend(yb_canvas *c, int x, int y, uint8_t coverage);

/* Host present: write the canvas as a binary PGM (P5). Returns 0 on success. */
int yb_canvas_save_pgm(const yb_canvas *c, const char *path);

#endif /* YB_PLATFORM_DISPLAY_H */
