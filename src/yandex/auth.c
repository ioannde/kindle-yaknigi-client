#include "yandex/auth.h"

#include "platform/net.h"
#include "util/log.h"
#include "util/url.h"

#include <cjson/cJSON.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define YB_OAUTH_DEVICE_CODE_URL "https://oauth.yandex.ru/device/code"
#define YB_OAUTH_TOKEN_URL       "https://oauth.yandex.ru/token"
#define YB_ACCOUNT_INFO_URL      "https://login.yandex.ru/info?format=json"

/* Append "&key=urlencoded(value)" (or "key=..." when first) to *body.
 * *body is realloc'd; returns 0 on success. */
static int form_add(char **body, size_t *len, const char *key, const char *value) {
    if (!value) return 0;
    char *enc = yb_url_encode(value);
    if (!enc) return -1;
    size_t add = strlen(key) + 1 + strlen(enc) + 1; /* key=enc& */
    char *p = realloc(*body, *len + add + 1);
    if (!p) { free(enc); return -1; }
    *body = p;
    int n = snprintf(*body + *len, add + 1, "%s%s=%s",
                     *len ? "&" : "", key, enc);
    if (n > 0) *len += (size_t)n;
    free(enc);
    return 0;
}

void yb_device_code_free(yb_device_code *dc) {
    if (!dc) return;
    free(dc->device_code);
    free(dc->user_code);
    free(dc->verification_url);
    memset(dc, 0, sizeof(*dc));
}

static char *dup_str(const cJSON *o, const char *k) {
    const cJSON *n = cJSON_GetObjectItemCaseSensitive(o, k);
    if (!cJSON_IsString(n) || !n->valuestring) return NULL;
    return strdup(n->valuestring);
}

int yb_auth_request_device_code(const char *client_id,
                                const char *client_secret,
                                const char *device_id,
                                const char *device_name,
                                yb_device_code *out) {
    memset(out, 0, sizeof(*out));
    if (!client_id || !*client_id) {
        YB_ERR("device code: client_id is required");
        return -1;
    }

    char *body = NULL;
    size_t len = 0;
    int rc = 0;
    rc |= form_add(&body, &len, "client_id", client_id);
    rc |= form_add(&body, &len, "client_secret", client_secret);
    rc |= form_add(&body, &len, "device_id", device_id);
    rc |= form_add(&body, &len, "device_name", device_name);
    if (rc != 0) { free(body); return -1; }

    yb_http_response resp;
    int r = yb_http_request("POST", YB_OAUTH_DEVICE_CODE_URL, NULL,
                            "application/x-www-form-urlencoded",
                            body, len, &resp);
    free(body);
    if (r != 0) return -1;

    if (resp.status < 200 || resp.status >= 300) {
        YB_ERR("device code request failed: HTTP %ld: %s", resp.status,
               resp.body ? resp.body : "");
        yb_http_response_free(&resp);
        return -1;
    }

    cJSON *j = cJSON_Parse(resp.body ? resp.body : "");
    yb_http_response_free(&resp);
    if (!j) { YB_ERR("device code: invalid JSON"); return -1; }

    out->device_code = dup_str(j, "device_code");
    out->user_code = dup_str(j, "user_code");
    out->verification_url = dup_str(j, "verification_url");
    const cJSON *iv = cJSON_GetObjectItemCaseSensitive(j, "interval");
    out->interval = cJSON_IsNumber(iv) ? iv->valueint : 5;
    const cJSON *ex = cJSON_GetObjectItemCaseSensitive(j, "expires_in");
    out->expires_in = cJSON_IsNumber(ex) ? ex->valueint : 600;
    cJSON_Delete(j);

    if (!out->device_code || !out->user_code) {
        YB_ERR("device code: response missing codes");
        yb_device_code_free(out);
        return -1;
    }
    return 0;
}

yb_auth_status yb_auth_poll_token(const char *client_id,
                                  const char *client_secret,
                                  const char *device_code,
                                  char **token_out) {
    if (token_out) *token_out = NULL;

    char *body = NULL;
    size_t len = 0;
    int rc = 0;
    rc |= form_add(&body, &len, "grant_type", "device_code");
    rc |= form_add(&body, &len, "code", device_code);
    rc |= form_add(&body, &len, "client_id", client_id);
    rc |= form_add(&body, &len, "client_secret", client_secret);
    if (rc != 0) { free(body); return YB_AUTH_ERROR; }

    yb_http_response resp;
    int r = yb_http_request("POST", YB_OAUTH_TOKEN_URL, NULL,
                            "application/x-www-form-urlencoded",
                            body, len, &resp);
    free(body);
    if (r != 0) return YB_AUTH_ERROR;

    cJSON *j = cJSON_Parse(resp.body ? resp.body : "");
    long status = resp.status;
    yb_http_response_free(&resp);
    if (!j) return YB_AUTH_ERROR;

    yb_auth_status result;
    char *access = dup_str(j, "access_token");
    if (access) {
        if (token_out) *token_out = access; else free(access);
        result = YB_AUTH_OK;
    } else {
        char *err = dup_str(j, "error");
        if (err && strcmp(err, "authorization_pending") == 0) result = YB_AUTH_PENDING;
        else if (err && strcmp(err, "slow_down") == 0) result = YB_AUTH_SLOW_DOWN;
        else {
            YB_WARN("token poll: HTTP %ld error=%s", status, err ? err : "(none)");
            result = YB_AUTH_DENIED;
        }
        free(err);
    }
    cJSON_Delete(j);
    return result;
}

int yb_auth_test_token(const char *token) {
    if (!token || !*token) return 0;
    yb_http_response resp;
    if (yb_http_get_bearer(YB_ACCOUNT_INFO_URL, token, &resp) != 0) return -1;
    int ok = (resp.status >= 200 && resp.status < 300);
    if (!ok) YB_DEBUG("test_token: HTTP %ld", resp.status);
    yb_http_response_free(&resp);
    return ok ? 1 : 0;
}
