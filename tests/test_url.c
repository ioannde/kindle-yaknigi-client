#include "test_util.h"

#include "util/url.h"

#include <stdlib.h>

int main(void) {
    char *a = yb_url_encode("a b/c");
    CHECK_STR(a, "a%20b%2Fc");
    free(a);

    char *b = yb_url_encode("Toke-n_1.2~x");  /* all unreserved, unchanged */
    CHECK_STR(b, "Toke-n_1.2~x");
    free(b);

    char *c = yb_url_encode("клиент");         /* UTF-8 bytes all encoded */
    CHECK(c != NULL);
    CHECK(c[0] == '%');
    free(c);

    char *e = yb_url_encode("");
    CHECK_STR(e, "");
    free(e);

    if (tests_failed == 0) printf("test_url: OK\n");
    return tests_failed != 0;
}
