#ifndef YB_YANDEX_JSON_H
#define YB_YANDEX_JSON_H

#include <cjson/cJSON.h>

/* Small convenience helpers over cJSON used when mapping API responses into
 * our model structs. All getters are NULL-safe and return defaults for
 * missing/mistyped fields, so callers can parse defensively. */

/* Returns a freshly malloc'd copy of obj[key] as a string, or NULL if absent.
 * Caller owns the result. */
char *yb_json_dup_string(const cJSON *obj, const char *key);

/* Returns obj[key] as int, or `dflt` if absent/not a number. */
int yb_json_int(const cJSON *obj, const char *key, int dflt);

/* Returns obj[key] as an object/array node, or NULL. Borrowed (do not free). */
const cJSON *yb_json_obj(const cJSON *obj, const char *key);

#endif /* YB_YANDEX_JSON_H */
