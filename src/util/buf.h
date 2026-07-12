#ifndef YB_UTIL_BUF_H
#define YB_UTIL_BUF_H

#include <stddef.h>

/* Growable byte buffer. Always keeps a NUL terminator one past `len`, so
 * `data` is safe to treat as a C string when the content is textual. */
typedef struct {
    char  *data;
    size_t len;
    size_t cap;
} yb_buf;

void  yb_buf_init(yb_buf *b);
/* Append `n` bytes; returns 0 on success, -1 on allocation failure. */
int   yb_buf_append(yb_buf *b, const void *bytes, size_t n);
/* Detach the underlying storage; caller owns it and must free(). Buffer is
 * reset to empty. Returns a NUL-terminated pointer (possibly empty string). */
char *yb_buf_detach(yb_buf *b, size_t *len_out);
void  yb_buf_free(yb_buf *b);

#endif /* YB_UTIL_BUF_H */
