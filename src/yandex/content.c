#include "yandex/content.h"

#include "platform/net.h"
#include "reader/html.h"
#include "reader/opf.h"
#include "yandex/api.h"
#include "yandex/crypto.h"
#include "util/base64.h"
#include "util/log.h"
#include "util/url.h"

#include <cjson/cJSON.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

/* Convert a cJSON array of numbers into a byte buffer. */
static unsigned char *json_bytes(const cJSON *arr, size_t *len) {
    if (!cJSON_IsArray(arr)) return NULL;
    int n = cJSON_GetArraySize(arr);
    unsigned char *b = malloc((size_t)(n > 0 ? n : 1));
    if (!b) return NULL;
    for (int i = 0; i < n; ++i) {
        const cJSON *it = cJSON_GetArrayItem(arr, i);
        b[i] = (unsigned char)(cJSON_IsNumber(it) ? it->valueint & 0xFF : 0);
    }
    *len = (size_t)n;
    return b;
}

/* Walk every string in the JSON, base64-decode it, and return the first that
 * yields exactly 32 bytes — that's the AES-256 key. */
static int find_key(const cJSON *node, unsigned char out_key[32]) {
    if (cJSON_IsString(node) && node->valuestring) {
        size_t klen = 0;
        unsigned char *k = yb_base64_decode(node->valuestring, &klen);
        if (k) {
            if (klen == 32) { memcpy(out_key, k, 32); free(k); return 1; }
            free(k);
        }
    } else if (cJSON_IsObject(node) || cJSON_IsArray(node)) {
        for (const cJSON *c = node->child; c; c = c->next)
            if (find_key(c, out_key)) return 1;
    }
    return 0;
}

/* Derive the internal directory (e.g. "OEBPS/") from the container.xml
 * rootfile full-path. Returns malloc'd prefix (with trailing '/') or a copy of
 * the default. */
static char *dir_from_container(const unsigned char *container, size_t len) {
    char *def = strdup("OEBPS/");
    if (!container) return def;
    char *c = malloc(len + 1);
    if (!c) return def;
    memcpy(c, container, len);
    c[len] = '\0';

    char *fp = strstr(c, "full-path");
    char *prefix = NULL;
    if (fp) {
        char *q = strchr(fp, '"');
        if (!q) q = strchr(fp, '\'');
        if (q) {
            char quote = *q++;
            char *e = strchr(q, quote);
            char *slash = NULL;
            for (char *s = e; s && s > q; ) { if (*--s == '/') { slash = s; break; } }
            if (slash) {
                size_t n = (size_t)(slash - q + 1); /* include '/' */
                prefix = malloc(n + 1);
                if (prefix) { memcpy(prefix, q, n); prefix[n] = '\0'; }
            } else {
                prefix = strdup(""); /* opf at root */
            }
        }
    }
    free(c);
    if (prefix) { free(def); return prefix; }
    return def;
}

static int is_html_href(const char *href) {
    const char *dot = strrchr(href, '.');
    return dot && (strcasecmp(dot, ".html") == 0 || strcasecmp(dot, ".xhtml") == 0 ||
                   strcasecmp(dot, ".htm") == 0);
}

/* Fetch and decrypt the manifest, returning decrypted opf + container bytes and
 * the document_uuid. Returns 0 on success. */
static int load_manifest(const char *token, const char *book_uuid,
                         char **opf_out, size_t *opf_len,
                         unsigned char **container_out, size_t *container_len,
                         char **document_uuid) {
    *opf_out = NULL; *container_out = NULL; *document_uuid = NULL;

    char url[512];
    snprintf(url, sizeof(url), "%s/books/%s/metadata/v4", yb_api_base(), book_uuid);
    char *body = NULL; size_t blen = 0;
    int rc = yb_api_get_raw(token, url, &body, &blen);
    if (rc != 0) { YB_ERR("content: metadata/v4 failed (%d)", rc); return -1; }

    cJSON *meta = cJSON_Parse(body ? body : "");
    free(body);
    if (!meta) { YB_ERR("content: metadata/v4 not JSON"); return -1; }

    const cJSON *duuid = cJSON_GetObjectItemCaseSensitive(meta, "document_uuid");
    if (cJSON_IsString(duuid)) *document_uuid = strdup(duuid->valuestring);

    size_t opf_enc_len = 0, cont_enc_len = 0;
    unsigned char *opf_enc = json_bytes(cJSON_GetObjectItemCaseSensitive(meta, "opf"), &opf_enc_len);
    unsigned char *cont_enc = json_bytes(cJSON_GetObjectItemCaseSensitive(meta, "container"), &cont_enc_len);
    cJSON_Delete(meta);

    if (!opf_enc || !*document_uuid) {
        YB_ERR("content: metadata/v4 missing opf/document_uuid");
        free(opf_enc); free(cont_enc); free(*document_uuid); *document_uuid = NULL;
        return -1;
    }

    /* fetch the AES key */
    snprintf(url, sizeof(url), "%s/metadata_secret", yb_api_base());
    if (yb_api_get_raw(token, url, &body, &blen) != 0) {
        YB_ERR("content: metadata_secret failed");
        free(opf_enc); free(cont_enc); free(*document_uuid); *document_uuid = NULL;
        return -1;
    }
    cJSON *sec = cJSON_Parse(body ? body : "");
    free(body);
    unsigned char key[32];
    int have_key = sec ? find_key(sec, key) : 0;
    cJSON_Delete(sec);
    if (!have_key) {
        YB_ERR("content: no 32-byte key in metadata_secret");
        free(opf_enc); free(cont_enc); free(*document_uuid); *document_uuid = NULL;
        return -1;
    }

    /* decrypt */
    *opf_out = (char *)yb_aes256_cbc_decrypt_ivprefix(key, opf_enc, opf_enc_len, opf_len);
    free(opf_enc);
    if (cont_enc) {
        *container_out = yb_aes256_cbc_decrypt_ivprefix(key, cont_enc, cont_enc_len, container_len);
        free(cont_enc);
    }
    if (!*opf_out) {
        YB_ERR("content: opf decrypt failed");
        free(*document_uuid); *document_uuid = NULL;
        free(*container_out); *container_out = NULL;
        return -1;
    }
    return 0;
}

int yb_content_load_book(const char *token, const char *book_uuid, yb_document *out) {
    yb_document_init(out);
    if (!book_uuid || !*book_uuid) return -1;

    char *opf = NULL; size_t opf_len = 0;
    unsigned char *container = NULL; size_t container_len = 0;
    char *document_uuid = NULL;
    if (load_manifest(token, book_uuid, &opf, &opf_len,
                      &container, &container_len, &document_uuid) != 0)
        return -1;

    char *prefix = dir_from_container(container, container_len);
    free(container);

    char *title = NULL, **hrefs = NULL;
    size_t nhrefs = 0;
    yb_opf_parse(opf, opf_len, &title, &hrefs, &nhrefs);
    if (title) { yb_document_set_title(out, title); free(title); }
    free(opf);

    int chapters = 0;
    for (size_t i = 0; i < nhrefs; ++i) {
        if (!is_html_href(hrefs[i])) continue;

        /* build internal path prefix + href, url-encode for ?path= */
        size_t plen = strlen(prefix) + strlen(hrefs[i]) + 1;
        char *path = malloc(plen);
        if (!path) continue;
        snprintf(path, plen, "%s%s", prefix, hrefs[i]);
        char *enc = yb_url_encode(path);
        free(path);
        if (!enc) continue;

        char url[768];
        snprintf(url, sizeof(url), "%s/documents/%s/content?path=%s",
                 yb_api_base(), document_uuid, enc);
        free(enc);

        char *html = NULL; size_t hlen = 0;
        if (yb_api_get_raw(token, url, &html, &hlen) == 0 && html) {
            yb_html_to_blocks(html, out);
            chapters++;
            free(html);
        }
    }

    yb_opf_free_hrefs(hrefs, nhrefs);
    free(prefix);
    free(document_uuid);

    YB_INFO("content: loaded '%s' — %d chapter(s), %zu block(s)",
            out->title ? out->title : "(untitled)", chapters, out->count);
    return out->count > 0 ? 0 : -1;
}
