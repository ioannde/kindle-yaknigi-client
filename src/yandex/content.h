#ifndef YB_YANDEX_CONTENT_H
#define YB_YANDEX_CONTENT_H

/* Book reading-content acquisition.
 *
 * ┌─────────────────────────────────────────────────────────────────────┐
 * │ BLOCKED ON PHASE 0 (docs/PHASE0.md, track A) — the single biggest    │
 * │ product risk. yandex-book-api exposes metadata only; the reading     │
 * │ protocol (chapter manifest, per-chapter documents, and any content   │
 * │ decryption) is undocumented and must be reverse-engineered from      │
 * │ traffic under the user's own legal access before this is written.    │
 * └─────────────────────────────────────────────────────────────────────┘
 *
 * Intended shape once Phase 0 lands: resolve a book_uuid to an ordered set
 * of chapter documents, stream+decrypt them (never the whole book in RAM —
 * PLAN.md 2.3), and hand a normalized document to reader/. The interface
 * below is a placeholder to keep call sites compiling; every function returns
 * "not implemented" until then.
 */

typedef enum {
    YB_CONTENT_NOT_IMPLEMENTED = -100,
} yb_content_result;

/* Placeholder: will become an opaque handle to a resolved book's chapter
 * stream. */
typedef struct yb_content_stream yb_content_stream;

/* Returns YB_CONTENT_NOT_IMPLEMENTED until Phase 0 defines the protocol. */
int yb_content_open(const char *token, const char *book_uuid,
                    yb_content_stream **out);
void yb_content_close(yb_content_stream *s);

#endif /* YB_YANDEX_CONTENT_H */
