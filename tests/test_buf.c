#include "test_util.h"

#include "util/buf.h"

#include <stdlib.h>
#include <string.h>

int main(void) {
    yb_buf b;
    yb_buf_init(&b);
    CHECK(yb_buf_append(&b, "hello", 5) == 0);
    CHECK(yb_buf_append(&b, ", ", 2) == 0);
    CHECK(yb_buf_append(&b, "world", 5) == 0);
    CHECK(b.len == 12);
    CHECK_STR(b.data, "hello, world");

    /* grow across several reallocs */
    for (int i = 0; i < 1000; ++i) CHECK(yb_buf_append(&b, "x", 1) == 0);
    CHECK(b.len == 1012);

    size_t len = 0;
    char *detached = yb_buf_detach(&b, &len);
    CHECK(len == 1012);
    CHECK(detached != NULL);
    CHECK(b.data == NULL);
    CHECK(b.len == 0);
    free(detached);

    /* detach on empty returns an owned empty string */
    yb_buf e;
    yb_buf_init(&e);
    char *empty = yb_buf_detach(&e, &len);
    CHECK(empty != NULL);
    CHECK(len == 0);
    CHECK_STR(empty, "");
    free(empty);
    yb_buf_free(&e);

    if (tests_failed == 0) printf("test_buf: OK\n");
    return tests_failed != 0;
}
