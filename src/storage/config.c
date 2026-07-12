#include "storage/config.h"

#include "util/log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

typedef struct {
    char *key;
    char *value;
} kv;

struct yb_config {
    char *path;
    kv   *items;
    size_t count;
    size_t cap;
};

static char *path_dup(void) {
    const char *e = getenv("YB_CONFIG");
    if (e && *e) return strdup(e);

    const char *home = getenv("HOME");
    if (home && *home) {
        char buf[1024];
        snprintf(buf, sizeof(buf), "%s/.config/kindle-yaknigi/config", home);
        return strdup(buf);
    }
    return strdup("kindle-yaknigi.conf");
}

static kv *find(yb_config *c, const char *key) {
    for (size_t i = 0; i < c->count; ++i)
        if (strcmp(c->items[i].key, key) == 0) return &c->items[i];
    return NULL;
}

static void trim_newline(char *s) {
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\n' || s[n - 1] == '\r')) s[--n] = '\0';
}

yb_config *yb_config_open(void) {
    yb_config *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->path = path_dup();

    FILE *f = c->path ? fopen(c->path, "r") : NULL;
    if (f) {
        char line[4096];
        while (fgets(line, sizeof(line), f)) {
            trim_newline(line);
            if (line[0] == '\0' || line[0] == '#') continue;
            char *eq = strchr(line, '=');
            if (!eq) continue;
            *eq = '\0';
            yb_config_set(c, line, eq + 1);
        }
        fclose(f);
    }
    return c;
}

void yb_config_free(yb_config *c) {
    if (!c) return;
    for (size_t i = 0; i < c->count; ++i) {
        free(c->items[i].key);
        free(c->items[i].value);
    }
    free(c->items);
    free(c->path);
    free(c);
}

const char *yb_config_get(yb_config *c, const char *key) {
    kv *e = find(c, key);
    return e ? e->value : NULL;
}

int yb_config_set(yb_config *c, const char *key, const char *value) {
    kv *e = find(c, key);
    if (e) {
        char *v = strdup(value ? value : "");
        if (!v) return -1;
        free(e->value);
        e->value = v;
        return 0;
    }
    if (c->count == c->cap) {
        size_t cap = c->cap ? c->cap * 2 : 8;
        kv *p = realloc(c->items, cap * sizeof(kv));
        if (!p) return -1;
        c->items = p;
        c->cap = cap;
    }
    c->items[c->count].key = strdup(key);
    c->items[c->count].value = strdup(value ? value : "");
    if (!c->items[c->count].key || !c->items[c->count].value) return -1;
    c->count++;
    return 0;
}

/* Ensure the parent directory of `path` exists (single level of mkdir -p for
 * the ~/.config/kindle-yaknigi case). */
static void ensure_parent_dir(const char *path) {
    char buf[1024];
    snprintf(buf, sizeof(buf), "%s", path);
    char *slash = strrchr(buf, '/');
    if (!slash) return;
    *slash = '\0';
    /* create intermediate dirs */
    for (char *p = buf + 1; *p; ++p) {
        if (*p == '/') {
            *p = '\0';
            mkdir(buf, 0700);
            *p = '/';
        }
    }
    mkdir(buf, 0700);
}

int yb_config_save(yb_config *c) {
    if (!c->path) return -1;
    ensure_parent_dir(c->path);
    FILE *f = fopen(c->path, "w");
    if (!f) {
        YB_ERR("config: cannot write %s", c->path);
        return -1;
    }
    for (size_t i = 0; i < c->count; ++i)
        fprintf(f, "%s=%s\n", c->items[i].key, c->items[i].value);
    fclose(f);
    return 0;
}

const char *yb_config_device_id(yb_config *c) {
    const char *existing = yb_config_get(c, "device_id");
    if (existing && *existing) return existing;

    /* Generate a random-ish stable id. Not security-sensitive; just needs to
     * be unique per install for the OAuth device flow. */
    unsigned long seed = (unsigned long)time(NULL) ^ (unsigned long)(size_t)c;
    char id[40];
    snprintf(id, sizeof(id), "kindle-%08lx%08lx", seed, seed * 2654435761UL);
    yb_config_set(c, "device_id", id);
    return yb_config_get(c, "device_id");
}
