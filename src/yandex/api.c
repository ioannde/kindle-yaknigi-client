#include "yandex/api.h"

#include "platform/net.h"
#include "yandex/json.h"
#include "util/log.h"

#include <cjson/cJSON.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Best-guess default pending Phase 0 confirmation; override with YB_API_BASE. */
#define YB_API_BASE_DEFAULT "https://api.bookmate.yandex.net/api/v5"

const char *yb_api_base(void) {
    const char *e = getenv("YB_API_BASE");
    return (e && *e) ? e : YB_API_BASE_DEFAULT;
}

/* Find the array of items in a library response. The envelope shape is not
 * yet pinned down, so accept a top-level array or a nested one under any of
 * the common keys. Returns a borrowed array node or NULL. */
static const cJSON *find_items_array(const cJSON *root) {
    if (cJSON_IsArray(root)) return root;
    static const char *keys[] = { "items", "cards", "library_cards", "books", "objects" };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) {
        const cJSON *a = yb_json_obj(root, keys[i]);
        if (cJSON_IsArray(a)) return a;
    }
    return NULL;
}

/* Shared GET + JSON parse. On success returns 0 and sets *out_json (owned by
 * caller, free via cJSON_Delete). On HTTP >= 400 returns the status. */
static int api_get_json(const char *token, const char *url, cJSON **out_json) {
    *out_json = NULL;
    yb_http_response resp;
    if (yb_http_get_bearer(url, token, &resp) != 0) return -1;

    if (resp.status >= 400) {
        int st = (int)resp.status;
        YB_WARN("GET %s -> HTTP %d", url, st);
        yb_http_response_free(&resp);
        return st;
    }
    cJSON *j = cJSON_Parse(resp.body ? resp.body : "");
    yb_http_response_free(&resp);
    if (!j) {
        YB_ERR("GET %s: invalid JSON", url);
        return -1;
    }
    *out_json = j;
    return 0;
}

int yb_api_get_my_library(const char *token, yb_library *out) {
    memset(out, 0, sizeof(*out));

    char url[512];
    snprintf(url, sizeof(url), "%s/my/library/books", yb_api_base());

    cJSON *root = NULL;
    int rc = api_get_json(token, url, &root);
    if (rc != 0) return rc;

    const cJSON *arr = find_items_array(root);
    if (!arr) {
        YB_ERR("library: no items array in response");
        cJSON_Delete(root);
        return -1;
    }

    int n = cJSON_GetArraySize(arr);
    if (n > 0) {
        out->items = calloc((size_t)n, sizeof(yb_library_card));
        if (!out->items) { cJSON_Delete(root); return -1; }
        for (int i = 0; i < n; ++i) {
            const cJSON *item = cJSON_GetArrayItem(arr, i);
            if (yb_library_card_parse(item, &out->items[out->count]) == 0)
                out->count++;
        }
    }
    cJSON_Delete(root);
    return 0;
}

int yb_api_get_book(const char *token, const char *uuid, yb_book *out) {
    memset(out, 0, sizeof(*out));
    if (!uuid || !*uuid) return -1;

    char url[512];
    snprintf(url, sizeof(url), "%s/books/%s", yb_api_base(), uuid);

    cJSON *root = NULL;
    int rc = api_get_json(token, url, &root);
    if (rc != 0) return rc;

    /* book may be at the top level or wrapped under "book". */
    const cJSON *book_node = yb_json_obj(root, "book");
    if (!cJSON_IsObject(book_node)) book_node = root;

    int r = yb_book_parse(book_node, out);
    cJSON_Delete(root);
    return r;
}
