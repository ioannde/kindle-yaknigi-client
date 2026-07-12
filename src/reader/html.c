#include "reader/html.h"

#include "util/buf.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

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

/* Decode an entity starting after '&'. Writes UTF-8 to out, advances *pp past
 * ';', returns bytes written, or 0 if unrecognized. */
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

char *yb_html_clean_text(const char *raw, size_t len) {
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

void yb_html_to_blocks(const char *html, yb_document *doc) {
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
                    char *txt = yb_html_clean_text(para.data, para.len);
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
        char *txt = yb_html_clean_text(para.data, para.len);
        yb_document_add(doc, heading_depth > 0, txt);
        free(txt);
    }
    yb_buf_free(&para);
}
