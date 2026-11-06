#include "reader/pages.h"

#include <stdlib.h>
#include <string.h>

int yb_page_index_build(yb_page_index *idx, yb_font *font, int w, int h,
                        const yb_document *doc, int reserve_bottom) {
    memset(idx, 0, sizeof(*idx));
    size_t cap = 0;
    yb_pos pos = { 0, 0 };
    int done = 0;
    while (!done) {
        if (idx->count == cap) {
            size_t new_cap = cap ? cap * 2 : 256;
            yb_pos *grown = realloc(idx->starts, new_cap * sizeof(*grown));
            if (!grown) {
                yb_page_index_free(idx);
                return -1;
            }
            idx->starts = grown;
            cap = new_cap;
        }
        idx->starts[idx->count++] = pos;
        pos = yb_render_page_ex(font, NULL, w, h, doc, pos, reserve_bottom, &done);
    }
    return 0;
}

void yb_page_index_free(yb_page_index *idx) {
    free(idx->starts);
    memset(idx, 0, sizeof(*idx));
}

static int pos_after(yb_pos a, yb_pos b) {
    return a.block > b.block || (a.block == b.block && a.line_off > b.line_off);
}

size_t yb_page_index_find(const yb_page_index *idx, yb_pos pos) {
    size_t lo = 0, hi = idx->count;
    while (hi - lo > 1) {
        size_t mid = lo + (hi - lo) / 2;
        if (pos_after(idx->starts[mid], pos)) hi = mid;
        else lo = mid;
    }
    return lo;
}
