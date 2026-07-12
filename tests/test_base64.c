#include "test_util.h"

#include "util/base64.h"

#include <stdlib.h>
#include <string.h>

int main(void) {
    size_t len = 0;
    unsigned char *d = yb_base64_decode("SGVsbG8sIHdvcmxkIQ==", &len); /* "Hello, world!" */
    CHECK(d != NULL);
    CHECK(len == 13);
    if (d) CHECK(memcmp(d, "Hello, world!", 13) == 0);
    free(d);

    d = yb_base64_decode("", &len);
    CHECK(d != NULL);
    CHECK(len == 0);
    free(d);

    /* base64 of 32 zero bytes -> 32 bytes (key-sized) */
    d = yb_base64_decode("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", &len);
    CHECK(d != NULL);
    CHECK(len == 32);
    free(d);

    /* whitespace is ignored */
    d = yb_base64_decode("SGVs\nbG8=", &len);
    CHECK(len == 5);
    if (d) CHECK(memcmp(d, "Hello", 5) == 0);
    free(d);

    /* invalid chars -> NULL */
    d = yb_base64_decode("!!!!", &len);
    CHECK(d == NULL);
    free(d);

    if (tests_failed == 0) printf("test_base64: OK\n");
    return tests_failed != 0;
}
