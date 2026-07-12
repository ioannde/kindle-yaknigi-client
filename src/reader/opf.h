#ifndef YB_READER_OPF_H
#define YB_READER_OPF_H

#include <stddef.h>

/* Parse an EPUB OPF package document. Shared by the EPUB loader (opf read from
 * the zip) and the Yandex content loader (opf decrypted from metadata/v4).
 *
 * On success returns 0 and sets:
 *   *title  - malloc'd book title (may be NULL), caller frees
 *   *hrefs  - malloc'd array of malloc'd manifest hrefs in SPINE order
 *   *count  - number of hrefs
 * Caller frees with yb_opf_free_hrefs. */
int yb_opf_parse(const char *opf, size_t len,
                 char **title, char ***hrefs, size_t *count);

void yb_opf_free_hrefs(char **hrefs, size_t count);

#endif /* YB_READER_OPF_H */
