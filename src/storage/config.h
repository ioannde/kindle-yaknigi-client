#ifndef YB_STORAGE_CONFIG_H
#define YB_STORAGE_CONFIG_H

/* Tiny persistent key=value store for the OAuth token, a stable device_id,
 * and settings. Backed by a flat file (one `key=value` per line).
 *
 * Path resolution: env YB_CONFIG, else $HOME/.config/kindle-yaknigi/config,
 * else ./kindle-yaknigi.conf. On the Kindle this points into the app's
 * writable data dir. */

typedef struct yb_config yb_config;

/* Load (or create empty) config. Caller frees with yb_config_free. */
yb_config *yb_config_open(void);
void       yb_config_free(yb_config *c);

/* Borrowed pointer to the value, or NULL if unset. */
const char *yb_config_get(yb_config *c, const char *key);
/* Copies key/value into the store. Returns 0 on success. */
int         yb_config_set(yb_config *c, const char *key, const char *value);
/* Persist to disk. Returns 0 on success. */
int         yb_config_save(yb_config *c);

/* Returns a stable device_id, generating and persisting one on first use. */
const char *yb_config_device_id(yb_config *c);

#endif /* YB_STORAGE_CONFIG_H */
