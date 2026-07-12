#include "reader/epub.h"

#include "reader/zip.h"
#include "util/buf.h"
#include "util/log.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ *
 * Small helpers (pragmatic string scanning; EPUB XML is regular enough
 * that a full XML parser is not warranted for text extraction).
 * ------------------------------------------------------------------ */

/* Extract attribute value: searches [start,end) for `attr` = "value" (single
 * or double quotes). Returns malloc'd value or NULL. */
static char *attr_get(const char *start, const char *end, const char *attr) {
    size_t alen = strlen(attr);
    for (const char *p = start; p + alen < end; ++p) {
        if (strncmp(p, attr, alen) != 0) continue;
        /* must be preceded by whitespace and followed by optional ws + '=' */
        if (p != start && !isspace((unsigned char)p[-1])) continue;
        const char *q = p + alen;
        while (q < end && isspace((unsigned char)*q)) q++;
        if (q >= end || *q != '=') continue;
        q++;
        while (q < end && isspace((unsigned char)*q)) q++;
        if (q >= end || (*q != '"' && *q != '\'')) continue;
        char quote = *q++;
        const char *v = q;
        while (q < end && *q != quote) q++;
        if (q >= end) return NULL;
        size_t vl = (size_t)(q - v);
        char *out = malloc(vl + 1);
        if (!out) return NULL;
        memcpy(out, v, vl);
        out[vl] = '\0';
        return out;
    }
    return NULL;
}

/* Encode a Unicode code point as UTF-8 into out (>=4 bytes); returns length. */
static int utf8_encode(unsigned cp, char *out) {
    if (cp < 0x80) { out[0] = (char)cp; return 1; }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

/* Decode a named/numeric entity starting after '&'. On success writes UTF-8
 * to `out` (returns bytes written) and advances *pp past the ';'. Returns 0
 * if not a recognized entity (caller emits '&' literally). */
static int decode_entity(const char **pp, char *out) {
    const char *p = *pp;
    const char *semi = strchr(p, ';');
    if (!semi || semi - p > 12) return 0;
    size_t n = (size_t)(semi - p);
    char name[16];
    memcpy(name, p, n);
    name[n] = '\0';

    unsigned cp = 0;
    if (name[0] == '#') {
        if (name[1] == 'x' || name[1] == 'X') cp = (unsigned)strtoul(name + 2, NULL, 16);
        else cp = (unsigned)strtoul(name + 1, NULL, 10);
        if (cp == 0) return 0;
    } else if (strcmp(name, "amp") == 0) cp = '&';
    else if (strcmp(name, "lt") == 0) cp = '<';
    else if (strcmp(name, "gt") == 0) cp = '>';
    else if (strcmp(name, "quot") == 0) cp = '"';
    else if (strcmp(name, "apos") == 0) cp = '\'';
    else if (strcmp(name, "nbsp") == 0) cp = ' ';
    else if (strcmp(name, "mdash") == 0) cp = 0x2014;
    else if (strcmp(name, "ndash") == 0) cp = 0x2013;
    else if (strcmp(name, "laquo") == 0) cp = 0x00AB;
    else if (strcmp(name, "raquo") == 0) cp = 0x00BB;
    else if (strcmp(name, "hellip") == 0) cp = 0x2026;
    else return 0;

    int len = utf8_encode(cp, out);
    *pp = semi + 1;
    return len;
}

/* Decode entities and collapse runs of whitespace to single spaces; trim
 * ends. Returns malloc'd string. */
static char *clean_text(const char *raw, size_t len) {
    char *out = malloc(len + 1);
    if (!out) return NULL;
    size_t o = 0;
    int last_space = 1; /* trims leading whitespace */
    const char *p = raw;
    const char *end = raw + len;
    while (p < end) {
        if (*p == '&') {
            char buf[4];
            const char *q = p + 1;
            int el = decode_entity(&q, buf);
            if (el > 0) {
                for (int i = 0; i < el; ++i) out[o++] = buf[i];
                last_space = (el == 1 && buf[0] == ' ');
                p = q;
                continue;
            }
        }
        unsigned char c = (unsigned char)*p;
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            if (!last_space) { out[o++] = ' '; last_space = 1; }
        } else {
            out[o++] = (char)c;
            last_space = 0;
        }
        p++;
    }
    while (o > 0 && out[o - 1] == ' ') o--; /* trim trailing */
    out[o] = '\0';
    return out;
}

/* Lowercase a tag name (letters only) into buf. */
static void tag_name(const char *p, const char *end, int *closing, char *buf, size_t bufsz) {
    *closing = 0;
    if (p < end && *p == '/') { *closing = 1; p++; }
    size_t i = 0;
    while (p < end && (isalnum((unsigned char)*p)) && i + 1 < bufsz)
        buf[i++] = (char)tolower((unsigned char)*p++);
    buf[i] = '\0';
}

static int is_block_tag(const char *name) {
    static const char *tags[] = {
        "p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "tr", "blockquote", "pre", "figcaption",
        "td", "hr", "title",
    };
    for (size_t i = 0; i < sizeof(tags)/sizeof(tags[0]); ++i)
        if (strcmp(name, tags[i]) == 0) return 1;
    return 0;
}

static int is_heading_tag(const char *name) {
    return name[0] == 'h' && name[1] >= '1' && name[1] <= '6' && name[2] == '\0';
}

/* Convert an XHTML chapter into document blocks. */
static void html_to_blocks(const char *html, yb_document *doc) {
    yb_buf para;
    yb_buf_init(&para);
    int heading_depth = 0;
    int skip_depth = 0;   /* inside <script>/<style> */

    const char *p = html;
    while (*p) {
        if (*p == '<') {
            const char *gt = strchr(p, '>');
            if (!gt) break;
            int closing;
            char name[16];
            tag_name(p + 1, gt, &closing, name, sizeof(name));

            if (strcmp(name, "script") == 0 || strcmp(name, "style") == 0) {
                skip_depth += closing ? -1 : 1;
                if (skip_depth < 0) skip_depth = 0;
            } else if (is_block_tag(name)) {
                if (para.len > 0) {
                    char *txt = clean_text(para.data, para.len);
                    yb_document_add(doc, heading_depth > 0, txt);
                    free(txt);
                    para.len = 0;
                    if (para.data) para.data[0] = '\0';
                }
                if (is_heading_tag(name)) {
                    if (closing) { if (heading_depth > 0) heading_depth--; }
                    else heading_depth++;
                }
            }
            p = gt + 1;
        } else {
            if (skip_depth == 0) yb_buf_append(&para, p, 1);
            p++;
        }
    }
    if (para.len > 0) {
        char *txt = clean_text(para.data, para.len);
        yb_document_add(doc, heading_depth > 0, txt);
        free(txt);
    }
    yb_buf_free(&para);
}

/* ------------------------------------------------------------------ *
 * OPF / spine handling
 * ------------------------------------------------------------------ */

/* Join an OPF-relative href onto the OPF's directory and normalize "./" and
 * "../" segments. Returns malloc'd path. */
static char *resolve_href(const char *opf_path, const char *href) {
    const char *slash = strrchr(opf_path, '/');
    size_t dirlen = slash ? (size_t)(slash - opf_path + 1) : 0;

    char *full = malloc(dirlen + strlen(href) + 1);
    if (!full) return NULL;
    memcpy(full, opf_path, dirlen);
    strcpy(full + dirlen, href);

    /* normalize in place */
    char *segs[64];
    int n = 0;
    char *tok = strtok(full, "/");
    while (tok && n < 64) {
        if (strcmp(tok, ".") == 0) { /* skip */ }
        else if (strcmp(tok, "..") == 0) { if (n > 0) n--; }
        else segs[n++] = tok;
        tok = strtok(NULL, "/");
    }
    char *out = malloc(strlen(opf_path) + strlen(href) + 2);
    if (!out) { free(full); return NULL; }
    out[0] = '\0';
    for (int i = 0; i < n; ++i) {
        if (i) strcat(out, "/");
        strcat(out, segs[i]);
    }
    free(full);
    return out;
}

/* Find the OPF path from META-INF/container.xml. */
static char *find_opf(yb_zip *z) {
    char *container = NULL;
    size_t len = 0;
    if (yb_zip_read(z, "META-INF/container.xml", &container, &len) != 0) return NULL;
    /* look for rootfile ... full-path="..." */
    char *rf = strstr(container, "rootfile");
    char *path = NULL;
    if (rf) path = attr_get(rf, container + len, "full-path");
    free(container);
    return path;
}

int yb_epub_load(const char *path, yb_document *out) {
    yb_document_init(out);
    yb_zip *z = yb_zip_open(path);
    if (!z) return -1;

    char *opf_path = find_opf(z);
    if (!opf_path) { YB_ERR("epub: no OPF rootfile"); yb_zip_close(z); return -1; }

    char *opf = NULL;
    size_t opf_len = 0;
    if (yb_zip_read(z, opf_path, &opf, &opf_len) != 0) {
        YB_ERR("epub: cannot read OPF %s", opf_path);
        free(opf_path); yb_zip_close(z); return -1;
    }
    const char *opf_end = opf + opf_len;

    /* title */
    char *tstart = strstr(opf, "<dc:title");
    if (!tstart) tstart = strstr(opf, "<title");
    if (tstart) {
        char *gt = strchr(tstart, '>');
        char *close = gt ? strstr(gt, "</") : NULL;
        if (gt && close) {
            char *t = clean_text(gt + 1, (size_t)(close - gt - 1));
            yb_document_set_title(out, t);
            free(t);
        }
    }

    /* manifest: build id -> href map (parallel arrays) */
    char **ids = NULL, **hrefs = NULL;
    size_t man_n = 0, man_cap = 0;
    for (const char *p = opf; (p = strstr(p, "<item ")) != NULL; ) {
        const char *gt = strchr(p, '>');
        if (!gt) break;
        char *id = attr_get(p, gt, "id");
        char *href = attr_get(p, gt, "href");
        if (id && href) {
            if (man_n == man_cap) {
                man_cap = man_cap ? man_cap * 2 : 32;
                ids = realloc(ids, man_cap * sizeof(char *));
                hrefs = realloc(hrefs, man_cap * sizeof(char *));
            }
            ids[man_n] = id;
            hrefs[man_n] = href;
            man_n++;
        } else { free(id); free(href); }
        p = gt + 1;
    }

    /* spine: iterate itemref idref in order, resolve to href, extract text */
    const char *spine = strstr(opf, "<spine");
    const char *scan = spine ? spine : opf;
    int chapters = 0;
    for (const char *p = scan; (p = strstr(p, "<itemref")) != NULL; ) {
        const char *gt = strchr(p, '>');
        if (!gt || gt > opf_end) break;
        char *idref = attr_get(p, gt, "idref");
        p = gt + 1;
        if (!idref) continue;

        const char *href = NULL;
        for (size_t i = 0; i < man_n; ++i)
            if (strcmp(ids[i], idref) == 0) { href = hrefs[i]; break; }
        free(idref);
        if (!href) continue;

        char *full = resolve_href(opf_path, href);
        char *doc = NULL;
        size_t dlen = 0;
        if (full && yb_zip_read(z, full, &doc, &dlen) == 0) {
            html_to_blocks(doc, out);
            chapters++;
            free(doc);
        }
        free(full);
    }

    for (size_t i = 0; i < man_n; ++i) { free(ids[i]); free(hrefs[i]); }
    free(ids); free(hrefs);
    free(opf);
    free(opf_path);
    yb_zip_close(z);

    YB_INFO("epub: loaded '%s' — %d chapter(s), %zu block(s)",
            out->title ? out->title : "(untitled)", chapters, out->count);
    return out->count > 0 ? 0 : -1;
}
