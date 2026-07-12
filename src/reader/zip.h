#ifndef YB_READER_ZIP_H
#define YB_READER_ZIP_H

#include <stddef.h>
#include <stdint.h>

/* Minimal read-only ZIP reader built on zlib (EPUB is a ZIP container).
 * Self-contained on purpose: only zlib is needed, which cross-compiles
 * cleanly for the Kindle. Entries are read on demand (the whole archive is
 * never held in RAM) to respect the 256 MB floor (PLAN.md 2.3). */

typedef struct yb_zip yb_zip;

/* Open an archive by path. Returns NULL on error. */
yb_zip *yb_zip_open(const char *path);
void    yb_zip_close(yb_zip *z);

size_t      yb_zip_count(const yb_zip *z);
/* Borrowed entry name by index, or NULL if out of range. */
const char *yb_zip_name(const yb_zip *z, size_t index);

/* Extract an entry by exact name into a freshly malloc'd, NUL-terminated
 * buffer (the NUL is one past *out_len, convenient for text). Returns 0 on
 * success; -1 if not found or on decompression error. Caller frees *out. */
int yb_zip_read(yb_zip *z, const char *name, char **out, size_t *out_len);

#endif /* YB_READER_ZIP_H */
