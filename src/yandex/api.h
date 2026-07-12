#ifndef YB_YANDEX_API_H
#define YB_YANDEX_API_H

#include "yandex/models.h"

/* Read-side client for the Yandex Books (Bookmate) REST API. Method set is
 * ported from yandex-book-api (PLAN.md 7).
 *
 * NOTE: the exact base URL and paths are confirmed in Phase 0 (traffic
 * capture / reference-library source). Both are overridable at runtime via
 * the YB_API_BASE env var so findings can be slotted in without a rebuild. */

/* Effective API base / GraphQL URL (env override, else the compiled default). */
const char *yb_api_base(void);
const char *yb_api_graphql_url(void);

/* GET the authenticated user's library into `out` (zeroed first). Returns 0
 * on success, -1 on transport/parse error, or the HTTP status (>=400) when
 * the server rejected the request (e.g. 401 for a bad token). */
int yb_api_get_my_library(const char *token, yb_library *out);

/* GET a single book's metadata by uuid into `out` (zeroed first). */
int yb_api_get_book(const char *token, const char *uuid, yb_book *out);

/* Authenticated Bookmate GET returning the raw response body (used for the
 * reading protocol: metadata/v4, metadata_secret, document content). On
 * success returns 0 and sets *body (owned, NUL-terminated) and *len. Returns
 * the HTTP status on >= 400, or -1 on transport error. */
int yb_api_get_raw(const char *token, const char *url, char **body, size_t *len);

/* POST a GraphQL query (transport for search/stats). `variables_json` is a
 * JSON object string or NULL. On success returns 0 and sets *out_body to the
 * raw response (caller frees). The concrete search query text is captured in
 * Phase 0. Returns HTTP status on >= 400, -1 on transport error. */
int yb_api_graphql(const char *token, const char *query,
                   const char *variables_json, char **out_body);

#endif /* YB_YANDEX_API_H */
