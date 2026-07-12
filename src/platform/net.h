#ifndef YB_PLATFORM_NET_H
#define YB_PLATFORM_NET_H

#include <stddef.h>

/* HTTP(S) transport. On device this is backed by a statically linked
 * libcurl + mbedTLS + our own CA bundle (see PLAN.md 2.2); on the host build
 * it uses the system libcurl. The rest of the app only ever sees this
 * interface, never libcurl directly. */

typedef struct {
    const char *name;
    const char *value;
} yb_header;

typedef struct {
    long   status;     /* HTTP status code, or 0 if the request never completed */
    char  *body;       /* NUL-terminated, owned; free via yb_http_response_free */
    size_t body_len;
} yb_http_response;

/* One-time process init/teardown (wraps curl_global_*). */
void yb_net_global_init(void);
void yb_net_global_cleanup(void);

/* Perform a request. `headers` is an array terminated by a {NULL, NULL}
 * sentinel, or NULL for none. For GET pass body=NULL, body_len=0.
 * `content_type` may be NULL. Returns 0 on transport success (inspect
 * out->status), or -1 on transport failure (out is zeroed). */
int yb_http_request(const char *method,
                    const char *url,
                    const yb_header *headers,
                    const char *content_type,
                    const void *body,
                    size_t body_len,
                    yb_http_response *out);

void yb_http_response_free(yb_http_response *r);

/* Convenience: authenticated GET with a Bearer token (token may be NULL). */
int yb_http_get_bearer(const char *url, const char *token, yb_http_response *out);

#endif /* YB_PLATFORM_NET_H */
