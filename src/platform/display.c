#include "platform/display.h"

#include "util/log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

yb_canvas *yb_canvas_new(int w, int h, int dpi) {
    if (w <= 0 || h <= 0) return NULL;
    yb_canvas *c = malloc(sizeof(*c));
    if (!c) return NULL;
    c->w = w;
    c->h = h;
    c->dpi = dpi;
    c->pix = malloc((size_t)w * (size_t)h);
    if (!c->pix) { free(c); return NULL; }
    memset(c->pix, 0xFF, (size_t)w * (size_t)h); /* white */
    return c;
}

void yb_canvas_free(yb_canvas *c) {
    if (!c) return;
    free(c->pix);
    free(c);
}

void yb_canvas_clear(yb_canvas *c, uint8_t value) {
    memset(c->pix, value, (size_t)c->w * (size_t)c->h);
}

void yb_canvas_blend(yb_canvas *c, int x, int y, uint8_t coverage) {
    if (x < 0 || y < 0 || x >= c->w || y >= c->h) return;
    uint8_t *px = &c->pix[(size_t)y * c->w + x];
    /* black ink over current value: dst = dst * (255 - coverage) / 255 */
    int v = (*px * (255 - coverage)) / 255;
    *px = (uint8_t)v;
}

int yb_canvas_save_pgm(const yb_canvas *c, const char *path) {
    FILE *f = fopen(path, "wb");
    if (!f) { YB_ERR("pgm: cannot write %s", path); return -1; }
    fprintf(f, "P5\n%d %d\n255\n", c->w, c->h);
    size_t n = (size_t)c->w * (size_t)c->h;
    size_t wr = fwrite(c->pix, 1, n, f);
    fclose(f);
    return wr == n ? 0 : -1;
}
