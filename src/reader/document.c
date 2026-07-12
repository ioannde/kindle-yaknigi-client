#include "reader/document.h"

#include <stdlib.h>
#include <string.h>

void yb_document_init(yb_document *d) {
    memset(d, 0, sizeof(*d));
}

static int is_blank(const char *s) {
    for (; *s; ++s)
        if (*s != ' ' && *s != '\t' && *s != '\n' && *s != '\r') return 0;
    return 1;
}

void yb_document_set_title(yb_document *d, const char *title) {
    free(d->title);
    d->title = title ? strdup(title) : NULL;
}

int yb_document_add(yb_document *d, int heading, const char *text) {
    if (!text || is_blank(text)) return 0;
    if (d->count == d->cap) {
        size_t cap = d->cap ? d->cap * 2 : 32;
        yb_block *p = realloc(d->blocks, cap * sizeof(yb_block));
        if (!p) return -1;
        d->blocks = p;
        d->cap = cap;
    }
    d->blocks[d->count].heading = heading;
    d->blocks[d->count].text = strdup(text);
    if (!d->blocks[d->count].text) return -1;
    d->count++;
    return 0;
}

void yb_document_free(yb_document *d) {
    if (!d) return;
    for (size_t i = 0; i < d->count; ++i) free(d->blocks[i].text);
    free(d->blocks);
    free(d->title);
    memset(d, 0, sizeof(*d));
}
