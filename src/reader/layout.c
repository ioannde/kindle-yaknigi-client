#include "reader/layout.h"

#include <stdlib.h>
#include <string.h>

static int push_line(yb_line **arr, size_t *n, size_t *cap, size_t off, size_t len) {
    if (*n == *cap) {
        size_t c = *cap ? *cap * 2 : 16;
        yb_line *p = realloc(*arr, c * sizeof(yb_line));
        if (!p) return -1;
        *arr = p;
        *cap = c;
    }
    (*arr)[*n].off = off;
    (*arr)[*n].len = len;
    (*n)++;
    return 0;
}

/* Greedy word wrap. Words are runs of non-space; the cleaned text already has
 * single-space separators. A word wider than max_w gets its own line. */
size_t yb_wrap_paragraph(const char *text, int max_w,
                         yb_measure_fn measure, void *ctx,
                         yb_line **out_lines) {
    size_t total = strlen(text);
    yb_line *lines = NULL;
    size_t n = 0, cap = 0;

    size_t ls = 0, le = 0;   /* current line: [ls, le) */
    int line_open = 0;

    size_t i = 0;
    while (i < total) {
        while (i < total && text[i] == ' ') i++;   /* skip spaces */
        if (i >= total) break;
        size_t ws = i;
        while (i < total && text[i] != ' ') i++;
        size_t we = i;                              /* word = [ws, we) */

        if (!line_open) {
            ls = ws; le = we; line_open = 1;
            if (measure(ctx, text + ls, le - ls) > max_w) {
                push_line(&lines, &n, &cap, ls, le - ls); /* over-long word alone */
                line_open = 0;
            }
        } else if (measure(ctx, text + ls, we - ls) <= max_w) {
            le = we;                                 /* extend current line */
        } else {
            push_line(&lines, &n, &cap, ls, le - ls);
            ls = ws; le = we; line_open = 1;
            if (measure(ctx, text + ls, le - ls) > max_w) {
                push_line(&lines, &n, &cap, ls, le - ls);
                line_open = 0;
            }
        }
    }
    if (line_open) push_line(&lines, &n, &cap, ls, le - ls);

    *out_lines = lines;
    return n;
}
