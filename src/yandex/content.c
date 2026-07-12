#include "yandex/content.h"

#include "util/log.h"

#include <stddef.h>

/* Deliberately unimplemented — see content.h and docs/PHASE0.md (track A).
 * These stubs exist only so the rest of the app links; wiring a reader to
 * them must wait until the reading protocol is confirmed in Phase 0. */

int yb_content_open(const char *token, const char *book_uuid,
                    yb_content_stream **out) {
    (void)token;
    (void)book_uuid;
    if (out) *out = NULL;
    YB_WARN("yb_content_open: reading protocol not yet implemented (Phase 0)");
    return YB_CONTENT_NOT_IMPLEMENTED;
}

void yb_content_close(yb_content_stream *s) {
    (void)s;
}
