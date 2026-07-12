#include "util/buf.h"

#include <stdlib.h>
#include <string.h>

void yb_buf_init(yb_buf *b) {
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

static int ensure(yb_buf *b, size_t extra) {
    /* need room for len + extra + 1 (NUL) */
    size_t need = b->len + extra + 1;
    if (need <= b->cap) return 0;

    size_t cap = b->cap ? b->cap : 64;
    while (cap < need) {
        size_t next = cap + cap / 2; /* 1.5x growth */
        if (next <= cap) return -1;  /* overflow */
        cap = next;
    }
    char *p = realloc(b->data, cap);
    if (!p) return -1;
    b->data = p;
    b->cap = cap;
    return 0;
}

int yb_buf_append(yb_buf *b, const void *bytes, size_t n) {
    if (n == 0) {
        if (ensure(b, 0) != 0) return -1;
        b->data[b->len] = '\0';
        return 0;
    }
    if (ensure(b, n) != 0) return -1;
    memcpy(b->data + b->len, bytes, n);
    b->len += n;
    b->data[b->len] = '\0';
    return 0;
}

char *yb_buf_detach(yb_buf *b, size_t *len_out) {
    if (!b->data) {
        /* return an owned empty string for a uniform caller contract */
        char *empty = malloc(1);
        if (empty) empty[0] = '\0';
        if (len_out) *len_out = 0;
        return empty;
    }
    char *p = b->data;
    if (len_out) *len_out = b->len;
    b->data = NULL;
    b->len = b->cap = 0;
    return p;
}

void yb_buf_free(yb_buf *b) {
    free(b->data);
    b->data = NULL;
    b->len = b->cap = 0;
}
