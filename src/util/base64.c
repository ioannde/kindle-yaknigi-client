#include "util/base64.h"

#include <stdlib.h>
#include <string.h>

static int b64val(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

unsigned char *yb_base64_decode(const char *s, size_t *out_len) {
    if (!s) return NULL;
    size_t n = strlen(s);
    unsigned char *out = malloc(n / 4 * 3 + 4);
    if (!out) return NULL;

    size_t o = 0;
    int quad[4], qi = 0;
    for (size_t i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (c == '=' ) break;
        if (c == '\n' || c == '\r' || c == ' ' || c == '\t') continue;
        int v = b64val(c);
        if (v < 0) { free(out); return NULL; }
        quad[qi++] = v;
        if (qi == 4) {
            out[o++] = (unsigned char)((quad[0] << 2) | (quad[1] >> 4));
            out[o++] = (unsigned char)((quad[1] << 4) | (quad[2] >> 2));
            out[o++] = (unsigned char)((quad[2] << 6) | quad[3]);
            qi = 0;
        }
    }
    if (qi == 2) {
        out[o++] = (unsigned char)((quad[0] << 2) | (quad[1] >> 4));
    } else if (qi == 3) {
        out[o++] = (unsigned char)((quad[0] << 2) | (quad[1] >> 4));
        out[o++] = (unsigned char)((quad[1] << 4) | (quad[2] >> 2));
    }
    if (out_len) *out_len = o;
    return out;
}
