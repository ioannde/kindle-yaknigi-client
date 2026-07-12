#include "yandex/json.h"

#include <stdlib.h>
#include <string.h>

char *yb_json_dup_string(const cJSON *obj, const char *key) {
    const cJSON *n = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (!cJSON_IsString(n) || !n->valuestring) return NULL;
    size_t len = strlen(n->valuestring);
    char *p = malloc(len + 1);
    if (!p) return NULL;
    memcpy(p, n->valuestring, len + 1);
    return p;
}

int yb_json_int(const cJSON *obj, const char *key, int dflt) {
    const cJSON *n = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (!cJSON_IsNumber(n)) return dflt;
    return n->valueint;
}

const cJSON *yb_json_obj(const cJSON *obj, const char *key) {
    return cJSON_GetObjectItemCaseSensitive(obj, key);
}
