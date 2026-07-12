#ifndef YB_UTIL_BASE64_H
#define YB_UTIL_BASE64_H

#include <stddef.h>

/* Decode standard base64 (ignoring whitespace) into a freshly malloc'd buffer.
 * Returns the bytes and sets *out_len; caller frees. Returns NULL on invalid
 * input or OOM. */
unsigned char *yb_base64_decode(const char *s, size_t *out_len);

#endif /* YB_UTIL_BASE64_H */
