#ifndef YB_TEST_UTIL_H
#define YB_TEST_UTIL_H

#include <stdio.h>
#include <string.h>

/* Ultra-light test harness: CHECK increments a failure counter and prints the
 * first offending expression. Each test file defines main() and returns
 * `tests_failed != 0`. */

static int tests_failed = 0;

#define CHECK(cond)                                                        \
    do {                                                                   \
        if (!(cond)) {                                                     \
            tests_failed++;                                                \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);\
        }                                                                  \
    } while (0)

#define CHECK_STR(a, b)                                                    \
    do {                                                                   \
        const char *va = (a), *vb = (b);                                   \
        if (!va || !vb || strcmp(va, vb) != 0) {                           \
            tests_failed++;                                                \
            fprintf(stderr, "FAIL %s:%d: \"%s\" != \"%s\"\n", __FILE__,    \
                    __LINE__, va ? va : "(null)", vb ? vb : "(null)");     \
        }                                                                  \
    } while (0)

#endif /* YB_TEST_UTIL_H */
