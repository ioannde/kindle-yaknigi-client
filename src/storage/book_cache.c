#include "storage/book_cache.h"

#include "util/log.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define BOOK_MAGIC "YBBOOK1\n"
#define BOOK_MAX_STRING (64u * 1024u * 1024u)

int yb_book_id_valid(const char *id) {
    if (!id || !*id || strlen(id) > 128) return 0;
    for (const char *p = id; *p; ++p) {
        char c = *p;
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '-' || c == '_'))
            return 0;
    }
    return 1;
}

int yb_mkdir_p(const char *path) {
    char buf[1024];
    if (snprintf(buf, sizeof(buf), "%s", path) >= (int)sizeof(buf)) return -1;
    for (char *p = buf + 1; *p; ++p) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1;
        *p = '/';
    }
    if (mkdir(buf, 0755) != 0 && errno != EEXIST) return -1;
    return 0;
}

static int put_string(FILE *f, const char *s) {
    uint32_t n = s ? (uint32_t)strlen(s) : 0;
    if (fwrite(&n, sizeof(n), 1, f) != 1) return -1;
    if (n && fwrite(s, 1, n, f) != n) return -1;
    return 0;
}

/* The file comes from local storage, which the user can edit, so sizes are
 * checked before anything is allocated from them. */
static char *get_string(FILE *f) {
    uint32_t n;
    if (fread(&n, sizeof(n), 1, f) != 1 || n > BOOK_MAX_STRING) return NULL;
    char *s = malloc((size_t)n + 1);
    if (!s) return NULL;
    if (n && fread(s, 1, n, f) != n) {
        free(s);
        return NULL;
    }
    s[n] = '\0';
    return s;
}

int yb_book_cache_save(const char *dir, const char *id, const yb_document *doc) {
    if (!yb_book_id_valid(id) || yb_mkdir_p(dir) != 0) return -1;
    char path[1024], tmp[1040];
    snprintf(path, sizeof(path), "%s/%s.book", dir, id);
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);

    FILE *f = fopen(tmp, "wb");
    if (!f) return -1;
    uint32_t count = (uint32_t)doc->count;
    int rc = fwrite(BOOK_MAGIC, 1, strlen(BOOK_MAGIC), f) == strlen(BOOK_MAGIC) ? 0 : -1;
    if (rc == 0) rc = put_string(f, doc->title);
    if (rc == 0 && fwrite(&count, sizeof(count), 1, f) != 1) rc = -1;
    for (size_t i = 0; rc == 0 && i < doc->count; ++i) {
        uint8_t heading = doc->blocks[i].heading ? 1 : 0;
        if (fwrite(&heading, 1, 1, f) != 1) rc = -1;
        if (rc == 0) rc = put_string(f, doc->blocks[i].text);
    }
    if (fclose(f) != 0) rc = -1;
    if (rc == 0 && rename(tmp, path) != 0) rc = -1;
    if (rc != 0) {
        YB_WARN("cache: could not save book %s", id);
        unlink(tmp);
    }
    return rc;
}

int yb_book_cache_load(const char *dir, const char *id, yb_document *out) {
    yb_document_init(out);
    if (!yb_book_id_valid(id)) return -1;
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.book", dir, id);
    FILE *f = fopen(path, "rb");
    if (!f) return -1;

    int rc = -1;
    char magic[sizeof(BOOK_MAGIC) - 1];
    uint32_t count = 0;
    char *title = NULL;
    if (fread(magic, 1, sizeof(magic), f) != sizeof(magic) ||
        memcmp(magic, BOOK_MAGIC, sizeof(magic)) != 0)
        goto out;
    title = get_string(f);
    if (!title || fread(&count, sizeof(count), 1, f) != 1) goto out;
    if (*title) yb_document_set_title(out, title);

    for (uint32_t i = 0; i < count; ++i) {
        uint8_t heading;
        if (fread(&heading, 1, 1, f) != 1) goto out;
        char *text = get_string(f);
        if (!text) goto out;
        int added = yb_document_add(out, heading, text);
        free(text);
        if (added != 0) goto out;
    }
    rc = out->count > 0 ? 0 : -1;
out:
    free(title);
    fclose(f);
    if (rc != 0) {
        YB_WARN("cache: book file %s is damaged", id);
        yb_document_free(out);
    }
    return rc;
}

int yb_book_cache_exists(const char *dir, const char *id) {
    if (!yb_book_id_valid(id)) return 0;
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.book", dir, id);
    return access(path, R_OK) == 0;
}

int yb_book_pos_save(const char *dir, const char *id, yb_pos pos) {
    if (!yb_book_id_valid(id) || yb_mkdir_p(dir) != 0) return -1;
    char path[1024], tmp[1040];
    snprintf(path, sizeof(path), "%s/%s.pos", dir, id);
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f) return -1;
    int rc = fprintf(f, "%zu %zu\n", pos.block, pos.line_off) > 0 ? 0 : -1;
    if (fclose(f) != 0) rc = -1;
    if (rc == 0 && rename(tmp, path) != 0) rc = -1;
    if (rc != 0) unlink(tmp);
    return rc;
}

void yb_book_pos_load(const char *dir, const char *id, yb_pos *pos) {
    pos->block = 0;
    pos->line_off = 0;
    if (!yb_book_id_valid(id)) return;
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s.pos", dir, id);
    FILE *f = fopen(path, "r");
    if (!f) return;
    size_t block, off;
    if (fscanf(f, "%zu %zu", &block, &off) == 2) {
        pos->block = block;
        pos->line_off = off;
    }
    fclose(f);
}
