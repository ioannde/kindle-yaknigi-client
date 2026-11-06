#ifndef YB_YANDEX_CONTENT_H
#define YB_YANDEX_CONTENT_H

#include "reader/document.h"

/* Bookmate reading protocol (confirmed in Phase 0, docs/PHASE0-FINDINGS.md):
 *
 *   1. GET /books/{uuid}/metadata/v4   -> document_uuid + AES-encrypted opf
 *   2. GET /metadata_secret            -> base64 AES-256 key
 *   3. AES-256-CBC decrypt opf (IV = first 16 bytes) -> EPUB OPF
 *   4. parse spine -> ordered chapter paths
 *   5. GET /documents/{document_uuid}/content?path=<dir>/<href> -> plain XHTML
 *   6. XHTML -> reader document
 *
 * Loads a book's full text into `out` (zeroed first). Returns 0 on success,
 * negative on error. If any spine chapter cannot be fetched the whole load
 * fails and `out` is left empty, so a partial book is never shown as complete.
 * Uses only the user's own legal access (their token). */
int yb_content_load_book(const char *token, const char *book_uuid, yb_document *out);

/* Same, calling `progress` after each chapter. */
typedef void (*yb_content_progress_fn)(void *ctx, size_t done, size_t total);
int yb_content_load_book_ex(const char *token, const char *book_uuid, yb_document *out,
                            yb_content_progress_fn progress, void *ctx);

#endif /* YB_YANDEX_CONTENT_H */
