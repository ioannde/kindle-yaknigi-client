#include "test_util.h"

#include "reader/layout.h"

#include <stdlib.h>
#include <string.h>

/* fixed-width metric: 10px per byte (ASCII text keeps bytes == chars) */
static int measure10(void *ctx, const char *text, size_t len) {
    (void)ctx; (void)text;
    return (int)len * 10;
}

int main(void) {
    yb_line *lines = NULL;

    /* "aa bb cc dd" with max_w=55 -> "aa bb" / "cc dd" */
    size_t n = yb_wrap_paragraph("aa bb cc dd", 55, measure10, NULL, &lines);
    CHECK(n == 2);
    if (n == 2) {
        CHECK(lines[0].off == 0 && lines[0].len == 5); /* "aa bb" */
        CHECK(lines[1].off == 6 && lines[1].len == 5); /* "cc dd" */
    }
    free(lines);
    lines = NULL;

    /* an over-long single word gets its own line and doesn't stall */
    n = yb_wrap_paragraph("wwwwwwwwww short", 30, measure10, NULL, &lines);
    CHECK(n == 2);
    if (n == 2) {
        CHECK(lines[0].off == 0 && lines[0].len == 10);
        CHECK_STR("short", "short"); /* sanity */
    }
    free(lines);
    lines = NULL;

    /* single word */
    n = yb_wrap_paragraph("hello", 1000, measure10, NULL, &lines);
    CHECK(n == 1);
    if (n == 1) CHECK(lines[0].off == 0 && lines[0].len == 5);
    free(lines);

    if (tests_failed == 0) printf("test_layout: OK\n");
    return tests_failed != 0;
}
