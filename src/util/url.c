#include "util/url.h"

#include <stdlib.h>
#include <string.h>

static int is_unreserved(unsigned char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
           (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~';
}

char *yb_url_encode(const char *s) {
    if (!s) s = "";
    size_t len = strlen(s);
    /* worst case: every byte becomes %XX */
    char *out = malloc(len * 3 + 1);
    if (!out) return NULL;

    static const char hex[] = "0123456789ABCDEF";
    char *p = out;
    for (size_t i = 0; i < len; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (is_unreserved(c)) {
            *p++ = (char)c;
        } else {
            *p++ = '%';
            *p++ = hex[c >> 4];
            *p++ = hex[c & 0xF];
        }
    }
    *p = '\0';
    return out;
}
