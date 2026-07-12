#include "platform/net.h"

#include "util/buf.h"
#include "util/log.h"

#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* User-Agent identifies our client; kept generic for now. */
#define YB_USER_AGENT "kindle-yaknigi/0.1"

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    yb_buf *b = (yb_buf *)userdata;
    size_t total = size * nmemb;
    if (yb_buf_append(b, ptr, total) != 0) return 0; /* signal error to curl */
    return total;
}

void yb_net_global_init(void) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

void yb_net_global_cleanup(void) {
    curl_global_cleanup();
}

int yb_http_request(const char *method,
                    const char *url,
                    const yb_header *headers,
                    const char *content_type,
                    const void *body,
                    size_t body_len,
                    yb_http_response *out) {
    memset(out, 0, sizeof(*out));

    CURL *curl = curl_easy_init();
    if (!curl) {
        YB_ERR("curl_easy_init failed");
        return -1;
    }

    yb_buf resp;
    yb_buf_init(&resp);

    struct curl_slist *hdr_list = NULL;
    if (content_type) {
        char ct[256];
        snprintf(ct, sizeof(ct), "Content-Type: %s", content_type);
        hdr_list = curl_slist_append(hdr_list, ct);
    }
    if (headers) {
        for (const yb_header *h = headers; h->name; ++h) {
            char line[1024];
            snprintf(line, sizeof(line), "%s: %s", h->name, h->value ? h->value : "");
            hdr_list = curl_slist_append(hdr_list, line);
        }
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, YB_USER_AGENT);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 20L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 60L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &resp);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);

    /* On device we ship our own CA bundle; allow overriding the path so the
     * same binary works in dev and on the Kindle. */
    const char *ca = getenv("YB_CA_BUNDLE");
    if (ca && *ca) curl_easy_setopt(curl, CURLOPT_CAINFO, ca);

    if (hdr_list) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdr_list);

    if (method && strcmp(method, "POST") == 0) {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body ? body : "");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_len);
    } else if (method && strcmp(method, "GET") != 0) {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, method);
        if (body) {
            curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
            curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_len);
        }
    }

    CURLcode rc = curl_easy_perform(curl);
    int ret;
    if (rc != CURLE_OK) {
        YB_ERR("HTTP %s %s failed: %s", method ? method : "GET", url,
               curl_easy_strerror(rc));
        yb_buf_free(&resp);
        ret = -1;
    } else {
        long status = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
        out->status = status;
        out->body = yb_buf_detach(&resp, &out->body_len);
        YB_DEBUG("HTTP %s %s -> %ld (%zu bytes)", method ? method : "GET", url,
                 status, out->body_len);
        ret = 0;
    }

    if (hdr_list) curl_slist_free_all(hdr_list);
    curl_easy_cleanup(curl);
    return ret;
}

void yb_http_response_free(yb_http_response *r) {
    if (!r) return;
    free(r->body);
    r->body = NULL;
    r->body_len = 0;
    r->status = 0;
}

int yb_http_get_bearer(const char *url, const char *token, yb_http_response *out) {
    if (token && *token) {
        char auth[2048];
        snprintf(auth, sizeof(auth), "OAuth %s", token); /* Yandex uses "OAuth <token>" */
        yb_header hdrs[] = {
            { "Authorization", auth },
            { NULL, NULL },
        };
        return yb_http_request("GET", url, hdrs, NULL, NULL, 0, out);
    }
    return yb_http_request("GET", url, NULL, NULL, NULL, 0, out);
}
