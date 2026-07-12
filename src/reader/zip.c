#include "reader/zip.h"

#include "util/log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

typedef struct {
    char    *name;
    uint16_t method;      /* 0 = stored, 8 = deflate */
    uint32_t comp_size;
    uint32_t uncomp_size;
    uint32_t local_off;   /* offset of local file header */
} zip_entry;

struct yb_zip {
    FILE      *f;
    zip_entry *entries;
    size_t     count;
};

static int read_at(FILE *f, long off, void *buf, size_t n) {
    if (fseek(f, off, SEEK_SET) != 0) return -1;
    return fread(buf, 1, n, f) == n ? 0 : -1;
}

static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* Locate the End Of Central Directory record by scanning the tail. Returns
 * its file offset, or -1. */
static long find_eocd(FILE *f, long file_size) {
    long max_back = 64 * 1024 + 22;      /* max comment + EOCD size */
    long start = file_size - max_back;
    if (start < 0) start = 0;
    long span = file_size - start;
    if (span < 22) return -1;

    unsigned char *buf = malloc((size_t)span);
    if (!buf) return -1;
    if (read_at(f, start, buf, (size_t)span) != 0) { free(buf); return -1; }

    long found = -1;
    for (long i = span - 22; i >= 0; --i) {
        if (buf[i] == 0x50 && buf[i+1] == 0x4b && buf[i+2] == 0x05 && buf[i+3] == 0x06) {
            found = start + i;
            break;
        }
    }
    free(buf);
    return found;
}

yb_zip *yb_zip_open(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { YB_ERR("zip: cannot open %s", path); return NULL; }

    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long file_size = ftell(f);
    if (file_size < 22) { fclose(f); return NULL; }

    long eocd = find_eocd(f, file_size);
    if (eocd < 0) { YB_ERR("zip: no EOCD (not a zip?)"); fclose(f); return NULL; }

    unsigned char eb[22];
    if (read_at(f, eocd, eb, sizeof(eb)) != 0) { fclose(f); return NULL; }
    uint16_t total = rd16(eb + 10);
    uint32_t cd_size = rd32(eb + 12);
    uint32_t cd_off  = rd32(eb + 16);

    unsigned char *cd = malloc(cd_size);
    if (!cd) { fclose(f); return NULL; }
    if (read_at(f, (long)cd_off, cd, cd_size) != 0) { free(cd); fclose(f); return NULL; }

    yb_zip *z = calloc(1, sizeof(*z));
    if (!z) { free(cd); fclose(f); return NULL; }
    z->f = f;
    z->entries = calloc(total, sizeof(zip_entry));
    if (!z->entries && total) { free(cd); free(z); fclose(f); return NULL; }

    size_t pos = 0;
    for (uint16_t i = 0; i < total; ++i) {
        if (pos + 46 > cd_size) break;
        const unsigned char *h = cd + pos;
        if (!(h[0] == 0x50 && h[1] == 0x4b && h[2] == 0x01 && h[3] == 0x02)) break;
        uint16_t method  = rd16(h + 10);
        uint32_t csize   = rd32(h + 20);
        uint32_t usize   = rd32(h + 24);
        uint16_t namelen = rd16(h + 28);
        uint16_t extralen = rd16(h + 30);
        uint16_t commentlen = rd16(h + 32);
        uint32_t loff    = rd32(h + 42);
        if (pos + 46 + namelen > cd_size) break;

        zip_entry *e = &z->entries[z->count];
        e->name = malloc((size_t)namelen + 1);
        if (!e->name) break;
        memcpy(e->name, h + 46, namelen);
        e->name[namelen] = '\0';
        e->method = method;
        e->comp_size = csize;
        e->uncomp_size = usize;
        e->local_off = loff;
        z->count++;

        pos += 46u + namelen + extralen + commentlen;
    }

    free(cd);
    return z;
}

void yb_zip_close(yb_zip *z) {
    if (!z) return;
    for (size_t i = 0; i < z->count; ++i) free(z->entries[i].name);
    free(z->entries);
    if (z->f) fclose(z->f);
    free(z);
}

size_t yb_zip_count(const yb_zip *z) { return z ? z->count : 0; }

const char *yb_zip_name(const yb_zip *z, size_t index) {
    if (!z || index >= z->count) return NULL;
    return z->entries[index].name;
}

static zip_entry *find_entry(yb_zip *z, const char *name) {
    for (size_t i = 0; i < z->count; ++i)
        if (strcmp(z->entries[i].name, name) == 0) return &z->entries[i];
    return NULL;
}

/* Read the compressed bytes at the entry's local header and inflate/copy. */
static int extract(yb_zip *z, zip_entry *e, char **out, size_t *out_len) {
    unsigned char lh[30];
    if (read_at(z->f, (long)e->local_off, lh, sizeof(lh)) != 0) return -1;
    if (!(lh[0] == 0x50 && lh[1] == 0x4b && lh[2] == 0x03 && lh[3] == 0x04)) return -1;
    uint16_t namelen = rd16(lh + 26);
    uint16_t extralen = rd16(lh + 28);
    long data_off = (long)e->local_off + 30 + namelen + extralen;

    unsigned char *comp = malloc(e->comp_size ? e->comp_size : 1);
    if (!comp) return -1;
    if (e->comp_size && read_at(z->f, data_off, comp, e->comp_size) != 0) {
        free(comp);
        return -1;
    }

    char *dst = malloc((size_t)e->uncomp_size + 1);
    if (!dst) { free(comp); return -1; }

    if (e->method == 0) {                    /* stored */
        memcpy(dst, comp, e->uncomp_size);
    } else if (e->method == 8) {             /* raw deflate */
        z_stream zs;
        memset(&zs, 0, sizeof(zs));
        if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) { free(comp); free(dst); return -1; }
        zs.next_in = comp;
        zs.avail_in = e->comp_size;
        zs.next_out = (unsigned char *)dst;
        zs.avail_out = e->uncomp_size;
        int r = inflate(&zs, Z_FINISH);
        inflateEnd(&zs);
        if (r != Z_STREAM_END && r != Z_OK) {
            YB_ERR("zip: inflate failed for %s (%d)", e->name, r);
            free(comp); free(dst); return -1;
        }
    } else {
        YB_ERR("zip: unsupported method %u for %s", e->method, e->name);
        free(comp); free(dst); return -1;
    }

    free(comp);
    dst[e->uncomp_size] = '\0';
    *out = dst;
    if (out_len) *out_len = e->uncomp_size;
    return 0;
}

int yb_zip_read(yb_zip *z, const char *name, char **out, size_t *out_len) {
    *out = NULL;
    if (out_len) *out_len = 0;
    zip_entry *e = find_entry(z, name);
    if (!e) { YB_DEBUG("zip: entry not found: %s", name); return -1; }
    return extract(z, e, out, out_len);
}
