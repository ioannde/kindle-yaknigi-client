#include "yandex/api.h"

#include "platform/net.h"
#include "yandex/json.h"
#include "util/log.h"

#include <cjson/cJSON.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Confirmed in Phase 0 from the reference client (docs/PHASE0-FINDINGS.md):
 *   REST base : https://api.bookmate.yandex.net/api/v5
 *   GraphQL   : https://api-gateway.bookmate.yandex.net/graphql
 *   Auth      : header "Auth-Token: <y0_token>" (NOT "Authorization: OAuth")
 *   plus the App-x, Bookmate-Version and okhttp headers below.
 * Both URLs are overridable via env for flexibility. */
#define YB_API_BASE_DEFAULT    "https://api.bookmate.yandex.net/api/v5"
#define YB_GRAPHQL_URL_DEFAULT "https://api-gateway.bookmate.yandex.net/graphql"

const char *yb_api_base(void) {
    const char *e = getenv("YB_API_BASE");
    return (e && *e) ? e : YB_API_BASE_DEFAULT;
}

const char *yb_api_graphql_url(void) {
    const char *e = getenv("YB_GRAPHQL_URL");
    return (e && *e) ? e : YB_GRAPHQL_URL_DEFAULT;
}

/* The exact Bookmate app headers the mobile client sends. Auth-Token carries
 * the Yandex OAuth token from the device flow. */
#define YB_BOOKMATE_HEADERS(token)                       \
    {                                                    \
        { "Auth-Token", (token) ? (token) : "" },        \
        { "App-Platform", "android" },                   \
        { "App-Language", "ru" },                        \
        { "App-Locale", "ru" },                          \
        { "Device-Os", "Android" },                      \
        { "Bookmate-Version", "20200305" },              \
        { "User-Agent", "okhttp/4.12.0" },               \
        { NULL, NULL },                                   \
    }

int yb_api_get_raw(const char *token, const char *url, char **body, size_t *len) {
    if (body) *body = NULL;
    if (len) *len = 0;
    yb_header headers[] = YB_BOOKMATE_HEADERS(token);

    yb_http_response resp;
    if (yb_http_request("GET", url, headers, NULL, NULL, 0, &resp) != 0) return -1;

    if (resp.status >= 400) {
        int st = (int)resp.status;
        YB_WARN("GET %s -> HTTP %d", url, st);
        yb_http_response_free(&resp);
        return st;
    }
    if (body) { *body = resp.body; resp.body = NULL; }
    if (len) *len = resp.body_len;
    yb_http_response_free(&resp);
    return 0;
}

static const cJSON *find_items_array(const cJSON *root) {
    if (cJSON_IsArray(root)) return root;
    static const char *keys[] = { "library_cards", "items", "cards", "books", "objects" };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) {
        const cJSON *a = yb_json_obj(root, keys[i]);
        if (cJSON_IsArray(a)) return a;
    }
    return NULL;
}

/* Authenticated Bookmate GET + JSON parse. On success returns 0 and sets
 * *out_json (caller frees via cJSON_Delete). On HTTP >= 400 returns status. */
static int bookmate_get(const char *token, const char *url, cJSON **out_json) {
    *out_json = NULL;
    yb_header headers[] = YB_BOOKMATE_HEADERS(token);

    yb_http_response resp;
    if (yb_http_request("GET", url, headers, NULL, NULL, 0, &resp) != 0) return -1;

    if (resp.status >= 400) {
        int st = (int)resp.status;
        YB_WARN("GET %s -> HTTP %d", url, st);
        yb_http_response_free(&resp);
        return st;
    }
    cJSON *j = cJSON_Parse(resp.body ? resp.body : "");
    yb_http_response_free(&resp);
    if (!j) { YB_ERR("GET %s: invalid JSON", url); return -1; }
    *out_json = j;
    return 0;
}

int yb_api_get_my_library(const char *token, yb_library *out) {
    memset(out, 0, sizeof(*out));

    char url[512];
    snprintf(url, sizeof(url), "%s/profile/library_cards", yb_api_base());

    cJSON *root = NULL;
    int rc = bookmate_get(token, url, &root);
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
    int rc = bookmate_get(token, url, &root);
    if (rc != 0) return rc;

    const cJSON *book_node = yb_json_obj(root, "book");
    if (!cJSON_IsObject(book_node)) book_node = root;

    int r = yb_book_parse(book_node, out);
    cJSON_Delete(root);
    return r;
}

int yb_api_graphql(const char *token, const char *query,
                   const char *variables_json, char **out_body) {
    if (out_body) *out_body = NULL;

    /* payload = {"operationName":"Query","variables":<vars>,"query":<q>} */
    cJSON *payload = cJSON_CreateObject();
    cJSON_AddStringToObject(payload, "operationName", "Query");
    cJSON *vars = variables_json ? cJSON_Parse(variables_json) : NULL;
    cJSON_AddItemToObject(payload, "variables", vars ? vars : cJSON_CreateObject());
    cJSON_AddStringToObject(payload, "query", query ? query : "");
    char *body = cJSON_PrintUnformatted(payload);
    cJSON_Delete(payload);
    if (!body) return -1;

    yb_header headers[] = YB_BOOKMATE_HEADERS(token);
    yb_http_response resp;
    int r = yb_http_request("POST", yb_api_graphql_url(), headers,
                            "application/json", body, strlen(body), &resp);
    free(body);
    if (r != 0) return -1;

    int rc;
    if (resp.status >= 400) {
        rc = (int)resp.status;
        YB_WARN("graphql -> HTTP %d", rc);
    } else {
        rc = 0;
        if (out_body) { *out_body = resp.body; resp.body = NULL; }
    }
    yb_http_response_free(&resp);
    return rc;
}
